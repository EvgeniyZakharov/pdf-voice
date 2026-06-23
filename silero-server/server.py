import io
import wave
import asyncio
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

app = FastAPI()
executor = ThreadPoolExecutor(max_workers=1)

SAMPLE_RATE = 24000
SPEAKERS = ["aidar", "baya", "kseniya", "xenia", "eugene"]

print("Загрузка модели Silero (первый запуск скачает ~200MB)...")
model, _ = torch.hub.load(
    repo_or_dir="snakers4/silero-models",
    model="silero_tts",
    language="ru",
    speaker="v3_1_ru",
)
model.eval()
print("Модель загружена. Сервер готов.")


class TTSRequest(BaseModel):
    text: str
    speaker: str = "xenia"


def _synthesize(text: str, speaker: str) -> bytes:
    with torch.no_grad():
        audio = model.apply_tts(text=text, speaker=speaker, sample_rate=SAMPLE_RATE)
    pcm = (audio.numpy() * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm.tobytes())
    return buf.getvalue()


@app.post("/synthesize")
async def synthesize(req: TTSRequest):
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
