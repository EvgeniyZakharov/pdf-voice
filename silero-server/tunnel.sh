#!/bin/bash
# Поднимает Cloudflare Tunnel к локальному Silero-серверу (порт 8000).
# Даёт бесплатный HTTPS-адрес *.trycloudflare.com — без аккаунта и без проброса портов.
#
# Использование:
#   1) В одном терминале:  ./start.sh        (запустит TTS-сервер на :8000)
#   2) В другом терминале:  ./tunnel.sh      (откроет туннель и покажет HTTPS-URL)
#   3) URL вида https://xxxx.trycloudflare.com вставь в Настройки приложения.
#
# ВНИМАНИЕ: быстрый туннель даёт НОВЫЙ адрес при каждом перезапуске.
# Для постоянного адреса нужен свой домен на Cloudflare и named tunnel
# (см. README рядом).

set -e

if ! command -v cloudflared >/dev/null 2>&1; then
    echo "cloudflared не установлен. Установи: brew install cloudflared"
    exit 1
fi

echo "Открываю туннель к http://localhost:8000 ..."
echo "Ищи в выводе строку вида: https://<...>.trycloudflare.com"
cloudflared tunnel --url http://localhost:8000
