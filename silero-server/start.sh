#!/bin/bash
set -e
cd "$(dirname "$0")"

if [ ! -d ".venv" ]; then
  echo "Создаю виртуальное окружение..."
  python3 -m venv .venv
fi

source .venv/bin/activate

echo "Устанавливаю зависимости..."
pip install -q -r requirements.txt

echo "Запускаю сервер на http://localhost:8000"
uvicorn server:app --host 0.0.0.0 --port 8000
