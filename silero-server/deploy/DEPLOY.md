# Деплой Silero TTS на сервер (Hetzner + Cloudflare Tunnel)

Цель: стабильный HTTPS-эндпоинт `https://tts.pdf-voice.com`, работающий 24/7,
без открытых портов, с авто-перезапуском.

Схема: `приложение → https://tts.pdf-voice.com → Cloudflare → cloudflared (на сервере) → uvicorn:8000 (только localhost)`

---

## 0. Что нужно до начала

- [ ] Домен `pdf-voice.com` куплен и активен в Cloudflare (зона = Active).
- [ ] Заказан сервер Hetzner Cloud **CAX21** (ARM, 4 vCPU / 8 ГБ, ~€7/мес), ОС **Ubuntu 24.04**.
      Рассчитан на ~5 одновременных слушателей (2 воркера). CAX11 (4 ГБ) тянет лишь 1 воркер — впритык.
- [ ] Есть IP сервера и доступ по SSH (ключ добавлен при создании сервера).

---

## 1. Базовая подготовка сервера

```bash
ssh root@<IP-СЕРВЕРА>

# отдельный пользователь (не работаем из-под root)
adduser --disabled-password --gecos "" silero

apt update && apt -y upgrade
apt install -y python3-venv python3-pip git ufw

# firewall: наружу открыт только SSH. 8000 и 443 НЕ открываем — туннель исходящий.
ufw allow OpenSSH
ufw --force enable
```

---

## 2. Выложить код silero-server

С локальной машины (из корня проекта `pdf-voice`):

```bash
# скопировать папку сервера (без .venv) на сервер
rsync -av --exclude='.venv' --exclude='__pycache__' \
  silero-server/ root@<IP-СЕРВЕРА>:/home/silero/silero-server/
```

На сервере:

```bash
chown -R silero:silero /home/silero/silero-server
sudo -u silero bash -lc '
  cd /home/silero/silero-server
  mkdir -p /home/silero/tmp
  export TMPDIR=/home/silero/tmp          # /tmp на Hetzner = tmpfs ~1.9 ГБ, pip его переполнит
  python3 -m venv .venv
  .venv/bin/pip install --upgrade pip -q
  # ВАЖНО: CPU-only torch. Обычный "pip install torch" тянет ~2 ГБ CUDA-колёс (GPU нам не нужен)
  # и забивает tmpfs → "No space left on device".
  .venv/bin/pip install -q torch --index-url https://download.pytorch.org/whl/cpu
  .venv/bin/pip install -q omegaconf fastapi "uvicorn[standard]" numpy
'
```
> CPU-torch (~1 ГБ venv) ставится под архитектуру сервера (x86 или ARM — без разницы),
> для Silero v3 этого достаточно, GPU не нужен.
> Проверка: `.venv/bin/python -c "import torch; print(torch.__version__)"` → должно быть `…+cpu`.

---

## 3. API-ключ и переменные окружения

```bash
sudo -u silero bash -lc '
  cd /home/silero/silero-server
  KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
  # ВАЖНО: без inline-комментариев в строках — systemd EnvironmentFile их НЕ парсит
  # (значением станет "2  # ...", и uvicorn упадёт). Только чистые KEY=VALUE.
  # WORKERS: число процессов синтеза (≈ слушателей/4-6). На CX23 (4 ГБ) ставь 1, на 8 ГБ — 2.
  # TORCH_THREADS: потоков torch на воркер; WORKERS*TORCH_THREADS ≈ числу vCPU.
  printf "SILERO_API_KEY=%s\nWORKERS=1\nTORCH_THREADS=2\n" "$KEY" > .env
  chmod 600 .env
  echo "=== СОХРАНИ SILERO_API_KEY ДЛЯ ПРИЛОЖЕНИЯ ==="
  cat .env
'
```
Запиши значение `SILERO_API_KEY` — его пропишем в приложении (Настройки → Silero → API-ключ).

> **Под нагрузку:** правило — `WORKERS ≈ ожидаемые_слушатели / 4–6`, и `WORKERS × TORCH_THREADS ≈ числу vCPU`,
> при этом RAM ограничивает: каждый воркер ~1.8 ГБ. Точную ёмкость измерит `benchmark.py` (см. §6).
>
> | Сервер | vCPU / RAM | WORKERS | TORCH_THREADS | ~слушателей |
> |---|---|---|---|---|
> | CX23 / CAX11 | 2 / 4 ГБ | **1** | 2 | ~4–5 |
> | CX33 / CAX21 / CPX31 | 4 / 8 ГБ | **2** | 2 | ~8–12 |
> | CX43 / CAX31 | 8 / 16 ГБ | **4** | 2 | ~16–24 |
>
> На 4 ГБ ставь именно `WORKERS=1` — две копии модели (~3.6 ГБ) рискуют словить OOM при старте.

---

## 4. systemd-служба для Silero

```bash
cp /home/silero/silero-server/deploy/silero.service /etc/systemd/system/silero.service
systemctl daemon-reload
systemctl enable --now silero

# дождаться загрузки модели (первый старт ~1-2 мин), затем проверить:
systemctl status silero --no-pager
curl -s http://127.0.0.1:8000/health    # ждём {"status":"ok",...}
```
Логи при проблемах: `journalctl -u silero -f`

---

## 5. Cloudflare Tunnel (named)

```bash
# поставить cloudflared (сам подберёт arm64/amd64 под архитектуру сервера)
cd /tmp
ARCH=$(dpkg --print-architecture)   # amd64 для x86-сервера, arm64 для ARM
curl -L -o cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb
apt install -y ./cloudflared.deb

mkdir -p /home/silero/.cloudflared && chmod 700 /home/silero/.cloudflared
chown -R silero:silero /home/silero/.cloudflared

# авторизация. ВАЖНО: запускать ИЗ каталога ~/.cloudflared (cloudflared пишет туда
# временный ключ; из чужого CWD будет "permission denied"). HOME задаём явно.
# Команда напечатает ссылку — открой её в браузере, выбери зону pdf-voice.com, Authorize.
# После авторизации сертификат скачается сам, команда завершится.
cd /home/silero/.cloudflared
sudo -u silero env HOME=/home/silero cloudflared tunnel login

# создать туннель (вернёт UUID и создаст credentials .json в ~/.cloudflared)
sudo -u silero env HOME=/home/silero cloudflared tunnel create silero

# привязать поддомен к туннелю (создаст DNS-запись CNAME автоматически)
sudo -u silero env HOME=/home/silero cloudflared tunnel route dns silero tts.pdf-voice.com
```

Положить конфиг и подставить UUID:

```bash
cp /home/silero/silero-server/deploy/cloudflared-config.yml /home/silero/.cloudflared/config.yml
UUID=$(basename $(ls /home/silero/.cloudflared/*.json | head -1) .json)
sed -i "s/<TUNNEL-UUID>/$UUID/g" /home/silero/.cloudflared/config.yml
chown -R silero:silero /home/silero/.cloudflared
cat /home/silero/.cloudflared/config.yml   # проверить, что UUID подставился
```

Запустить cloudflared как службу (свой юнит — запуск под silero с нашим конфигом):

```bash
cp /home/silero/silero-server/deploy/cloudflared.service /etc/systemd/system/cloudflared.service
systemctl daemon-reload
systemctl enable --now cloudflared
systemctl status cloudflared --no-pager      # ждём active + "Registered tunnel connection"
```

---

## 6. Проверка снаружи

С любой машины:

```bash
curl -s https://tts.pdf-voice.com/health
# ожидаем: {"status":"ok","speakers":["aidar","baya","kseniya","xenia","eugene"]}

# синтез (подставь свой ключ):
curl -s -X POST https://tts.pdf-voice.com/synthesize \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <ТВОЙ-КЛЮЧ>" \
  -d '{"text":"Привет, это проверка","speaker":"xenia"}' \
  -o test.wav && echo OK
```
Если `test.wav` проигрывается — серверная часть готова. ✅

### 6.1 Нагрузочный тест — сколько слушателей реально тянет машина

Запусти **на самом сервере** (меряет чистый синтез без накладных сети):

```bash
sudo -u silero bash -lc '
  cd /home/silero/silero-server
  .venv/bin/python deploy/benchmark.py \
    --url http://127.0.0.1:8000 --key "$(grep SILERO_API_KEY .env | cut -d= -f2)" \
    --concurrency 5 --requests 4
'
```

Скрипт шлёт N параллельных потоков запросов и печатает:
- **RTF** (секунд счёта на секунду аудио) — чем меньше, тем лучше;
- **ёмкость**: сколько секунд аудио в секунду производит сервер = скольких слушателей реального
  времени держит. Если **capacity ≥ 5** при `--concurrency 5` — цель достигнута.

Если ёмкость ниже нужной — подними `WORKERS` в `.env` (в пределах RAM) и
`systemctl restart silero`, прогони снова. Так подбираешь конфиг по факту, а не на глаз.

---

## 7. Защита от абьюза (Cloudflare, бесплатно)

В панели Cloudflare → домен `pdf-voice.com`:
- **Security → WAF → Rate limiting rules**: правило на `tts.pdf-voice.com/synthesize`,
  например «не более 60 запросов за 1 минуту с одного IP» → Block.
- **Analytics**: следить за всплесками трафика на поддомен.

API-ключ из приложения извлекаем, поэтому rate-limit здесь — основная защита CPU.

---

## 8. Интеграция с приложением (сделано)

- `SettingsStore.swift`: `sileroServerURL`/`sileroAPIKey` — вшитые константы
  (`https://tts.pdf-voice.com` + ключ из шага 3); поля в Настройках убраны.
- Fallback: при недоступном сервере `SpeechEngine` беззвучно переключается на
  системный голос (`SpeechEvent.failed` → `fallBackToSystemVoice`). Проверка —
  `systemctl stop silero`, послушать, что чтение продолжается системным голосом,
  затем `systemctl start silero`.

---

## Обновление сервера в будущем

```bash
rsync -av --exclude='.venv' --exclude='__pycache__' \
  silero-server/ root@<IP>:/home/silero/silero-server/
ssh root@<IP> 'systemctl restart silero'
```

## Шпаргалка по сервисам

| Действие | Команда |
|---|---|
| Статус Silero | `systemctl status silero` |
| Логи Silero | `journalctl -u silero -f` |
| Рестарт Silero | `systemctl restart silero` |
| Статус туннеля | `systemctl status cloudflared` |
| Логи туннеля | `journalctl -u cloudflared -f` |
