# Silero TTS server

Сервер озвучки для PDF Voice: принимает текст, возвращает WAV голосами Silero (ru).
Эндпоинты: `POST /synthesize` (требует `X-API-Key`), `GET /health` (открыт).

## Прод

Сервер развёрнут на отдельной машине (Hetzner) и работает 24/7 за постоянным
HTTPS-адресом **`https://tts.pdf-voice.com`** (Cloudflare Tunnel). Приложение зашито
на этот адрес — никакой ручной настройки в Настройках больше нет.

Полная инструкция по развёртыванию/пересозданию сервера: **[`deploy/DEPLOY.md`](deploy/DEPLOY.md)**.
Обновить код на сервере:
```bash
rsync -av --exclude='.venv' --exclude='__pycache__' \
  silero-server/ root@<IP>:/home/silero/silero-server/
ssh root@<IP> 'systemctl restart silero'
```

## Локальная разработка

`start.sh` поднимает сервер на маке (`localhost:8000`) — чтобы обкатать правки
`server.py` через `curl`, прежде чем катить на прод. В обычной работе не нужен.

```bash
cd silero-server
./start.sh                 # создаёт .venv, качает модель ~200MB, печатает API-ключ

# проверка в другом терминале:
curl -s -X POST http://localhost:8000/synthesize \
  -H "Content-Type: application/json" -H "X-API-Key: $(cat .api_key)" \
  -d '{"text":"проверка","speaker":"xenia"}' -o test.wav
```

> Приложение зашито на прод-адрес, поэтому направить его на локальный сервер
> нельзя — локально тестируем сервер только через `curl`.

## Заметки

- Silero v3 — CPU-only, синтез быстрый; GPU не нужен.
- Авторизация: `X-API-Key`. Локально ключ генерится в `.api_key`; на проде — в `.env`
  (`SILERO_API_KEY`), см. `deploy/DEPLOY.md`. Пустой ключ → проверка выключена.
- Голоса: `aidar`, `baya`, `kseniya`, `xenia`, `eugene`.
