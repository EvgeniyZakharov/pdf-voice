# Silero TTS server — удалённый доступ

Локальный сервер озвучки можно открыть в интернет, чтобы iPhone читал PDF
голосами Silero откуда угодно. Безопасность держится на двух вещах:

- **HTTPS** — даёт Cloudflare Tunnel (iOS блокирует обычный http к внешним адресам).
- **API-ключ** — заголовок `X-API-Key`, генерируется автоматически в `.api_key`.

`/health` остаётся открытым (для проверок), `/synthesize` требует ключ.

---

## Быстрый старт (временный адрес, без домена)

Подходит, чтобы попробовать прямо сейчас. Адрес меняется при каждом перезапуске.

```bash
brew install cloudflared          # один раз

# Терминал 1 — сервер озвучки:
cd silero-server
./start.sh                        # покажет API-ключ, держи его

# Терминал 2 — туннель:
cd silero-server
./tunnel.sh                       # ищи в выводе https://<...>.trycloudflare.com
```

В приложении → **Настройки → Нейросетевой голос**:
- включить **Silero TTS**
- **Адрес сервера**: `https://<...>.trycloudflare.com` (из вывода tunnel.sh)
- **API-ключ**: значение из `silero-server/.api_key`

Проверка с компьютера:
```bash
curl https://<...>.trycloudflare.com/health
```

---

## Постоянный адрес (свой домен на Cloudflare)

Чтобы URL не менялся, нужен домен, добавленный в Cloudflare (бесплатный план ок).

```bash
cloudflared tunnel login                       # авторизация в браузере
cloudflared tunnel create silero               # создаёт туннель + креды
cloudflared tunnel route dns silero tts.твойдомен.com
```

Создай `~/.cloudflared/config.yml`:
```yaml
tunnel: silero
credentials-file: /Users/<ты>/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: tts.твойдомен.com
    service: http://localhost:8000
  - service: http_status:404
```

Запуск:
```bash
cloudflared tunnel run silero
```

Чтобы держался в фоне и переживал перезагрузку Mac:
```bash
sudo cloudflared service install
```

В приложении укажи `https://tts.твойдомен.com` и тот же API-ключ.

---

## Заметки

- Silero v3 — CPU-only, синтез быстрый; отдельный GPU не нужен.
- Синтез идёт на твоём Mac — он должен быть включён, пока ты слушаешь.
- Сменить ключ: удали `.api_key` и перезапусти `start.sh` (потом обнови ключ в приложении).
- Хочешь снова чисто локально без авторизации — удали `.api_key` (тогда `SILERO_API_KEY` пуст и проверка ключа выключается).
