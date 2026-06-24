#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

source .venv/bin/activate
pip install -q -r requirements.txt

# API-ключ для удалённого доступа: генерируем один раз и храним в .api_key.
# Для чисто локального использования можно удалить этот файл.
if [ ! -f ".api_key" ]; then
    python3 -c "import secrets; print(secrets.token_urlsafe(24))" > .api_key
    echo "Сгенерирован новый API-ключ -> silero-server/.api_key"
fi
export SILERO_API_KEY="$(cat .api_key)"
echo "API-ключ (вставь в Настройки приложения): $SILERO_API_KEY"

echo "Silero TTS server starting on http://0.0.0.0:8000"
uvicorn server:app --host 0.0.0.0 --port 8000
