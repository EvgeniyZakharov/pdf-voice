import io
import os
import wave
import asyncio
import secrets
from typing import Optional
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import torch
from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import Response
from pydantic import BaseModel

app = FastAPI()
# Внутри одного процесса синтез строго последовательный (один torch не любит
# параллельный apply_tts). Параллелизм даёт несколько процессов: uvicorn --workers N.
executor = ThreadPoolExecutor(max_workers=1)

# Потоки torch НА ПРОЦЕСС. Цель: WORKERS * TORCH_THREADS ≈ числу vCPU, иначе
# воркеры переподпишут ядра и синтез замедлится у всех. По умолчанию 2.
torch.set_num_threads(int(os.environ.get("TORCH_THREADS", "2")))
print(f"[pid {os.getpid()}] torch threads = {torch.get_num_threads()}")

SAMPLE_RATE = 24000
SPEAKERS = ["aidar", "baya", "kseniya", "xenia", "eugene"]

# API-ключ для удалённого доступа. Если переменная не задана — авторизации нет
# (режим localhost). Для туннеля в интернет ЗАДАЙ её: export SILERO_API_KEY=...
API_KEY = os.environ.get("SILERO_API_KEY", "").strip()
if API_KEY:
    print("Авторизация включена (X-API-Key).")
else:
    print("ВНИМАНИЕ: SILERO_API_KEY не задан — сервер открыт без авторизации.")


def _check_key(provided: Optional[str]) -> None:
    if not API_KEY:
        return
    if not provided or not secrets.compare_digest(provided, API_KEY):
        raise HTTPException(401, "invalid or missing X-API-Key")

print("Загрузка модели Silero (первый запуск скачает ~200MB)...")
model, _ = torch.hub.load(
    repo_or_dir="snakers4/silero-models",
    model="silero_tts",
    language="ru",
    speaker="v3_1_ru",
    trust_repo=True,  # не спрашивать интерактивно (служба без stdin → иначе Aborted!)
)
print("Модель загружена. Сервер готов.")


class TTSRequest(BaseModel):
    text: str
    speaker: str = "xenia"


def _wav_bytes(pcm: np.ndarray) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm.tobytes())
    return buf.getvalue()


def _silence(seconds: float = 0.12) -> bytes:
    return _wav_bytes(np.zeros(int(SAMPLE_RATE * seconds), dtype=np.int16))


def _synthesize(text: str, speaker: str) -> bytes:
    # Silero падает на тексте без букв (чистые номера разделов «2.1», «§ 4»).
    # Такие подзаголовки незачем озвучивать — отдаём короткую тишину, чтобы
    # очередь чтения не прерывалась.
    if not any(ch.isalpha() for ch in text):
        return _silence()
    try:
        with torch.no_grad():
            audio = model.apply_tts(text=text, speaker=speaker, sample_rate=SAMPLE_RATE)
        pcm = (audio.numpy() * 32767).astype(np.int16)
        return _wav_bytes(pcm)
    except Exception as exc:
        # Любой сбой синтеза не должен ронять воспроизведение на клиенте.
        print(f"Синтез не удался для {text!r}: {exc}")
        return _silence()


@app.post("/synthesize")
async def synthesize(req: TTSRequest, x_api_key: Optional[str] = Header(default=None)):
    _check_key(x_api_key)
    if not req.text.strip():
        raise HTTPException(400, "text is empty")
    if req.speaker not in SPEAKERS:
        raise HTTPException(400, f"unknown speaker, use one of: {SPEAKERS}")
    loop = asyncio.get_event_loop()
    wav = await loop.run_in_executor(executor, _synthesize, req.text, req.speaker)
    return Response(content=wav, media_type="audio/wav")


@app.get("/health")
async def health():
    return {"status": "ok", "speakers": SPEAKERS}
