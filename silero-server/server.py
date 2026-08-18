import io
import os
import fcntl
import wave
import asyncio
import secrets
from pathlib import Path
from typing import Optional
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import torch
from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

# --- лимит размера тела запроса (до чтения body) --------------------------
# Защита от OOM: без этого клиент может прислать сколь угодно большое тело
# на машине с 4-8 ГБ RAM. 64 КБ с запасом покрывает текст ≤800 символов в JSON.
MAX_BODY_BYTES = 64 * 1024


class MaxBodySizeMiddleware:
    """Сырое ASGI-middleware: отбивает слишком большие запросы ДО того, как
    тело дойдёт до FastAPI/pydantic. Content-Length проверяется мгновенно;
    для chunked-тел (без Content-Length) лимит считается по мере чтения."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers") or [])
        content_length = headers.get(b"content-length")
        if content_length is not None:
            try:
                declared = int(content_length)
            except ValueError:
                declared = None
            if declared is not None and declared > MAX_BODY_BYTES:
                await self._reject(send)
                return

        total = 0

        async def limited_receive():
            nonlocal total
            message = await receive()
            if message["type"] == "http.request":
                total += len(message.get("body") or b"")
                if total > MAX_BODY_BYTES:
                    raise HTTPException(413, "request body too large")
            return message

        await self.app(scope, limited_receive, send)

    @staticmethod
    async def _reject(send):
        await send(
            {
                "type": "http.response.start",
                "status": 413,
                "headers": [(b"content-type", b"application/json")],
            }
        )
        await send(
            {
                "type": "http.response.body",
                "body": b'{"detail":"request body too large"}',
            }
        )


app = FastAPI()
app.add_middleware(MaxBodySizeMiddleware)

executor = ThreadPoolExecutor(max_workers=1)

torch.set_num_threads(int(os.environ.get("TORCH_THREADS", "2")))
print(f"[pid {os.getpid()}] torch threads = {torch.get_num_threads()}")

SAMPLE_RATE = 24000
SPEAKERS = ["aidar", "baya", "kseniya", "xenia", "eugene"]

API_KEY = os.environ.get("SILERO_API_KEY", "").strip()
ALLOW_ANON = os.environ.get("SILERO_ALLOW_ANON", "") == "1"
if API_KEY:
    print("Авторизация включена (X-API-Key).")
elif ALLOW_ANON:
    print("ВНИМАНИЕ: SILERO_API_KEY не задан — сервер открыт без авторизации (SILERO_ALLOW_ANON=1).")
else:
    raise SystemExit(
        "SILERO_API_KEY не задан. Установи переменную окружения SILERO_API_KEY, "
        "либо явно разреши анонимный доступ через SILERO_ALLOW_ANON=1 (не для прода)."
    )


def _check_key(provided: Optional[str]) -> None:
    if not API_KEY:
        return
    # compare_digest требует ASCII-only str (иначе TypeError -> необработанный 500).
    # Заголовок может прийти с непечатными/не-ASCII байтами — сравниваем как bytes.
    provided_bytes = (provided or "").encode("utf-8", "surrogateescape")
    expected_bytes = API_KEY.encode("utf-8", "surrogateescape")
    if not provided or not secrets.compare_digest(provided_bytes, expected_bytes):
        raise HTTPException(401, "invalid or missing X-API-Key")


print("Загрузка модели Silero (первый запуск скачает ~200MB)...")
# Файловая блокировка вокруг torch.hub.load: при WORKERS>=2 несколько
# процессов-воркеров стартуют одновременно и без лока могут одновременно
# писать в один и тот же кэш torch.hub -> повреждённые файлы -> рестарт-луп.
_hub_dir = Path(torch.hub.get_dir())
_hub_dir.mkdir(parents=True, exist_ok=True)
_hub_lock_path = _hub_dir / ".silero.lock"
with open(_hub_lock_path, "w") as _hub_lock_file:
    fcntl.flock(_hub_lock_file, fcntl.LOCK_EX)
    try:
        model, _ = torch.hub.load(
            repo_or_dir="snakers4/silero-models",
            model="silero_tts",
            language="ru",
            speaker="v3_1_ru",
            trust_repo=True,  # не спрашивать интерактивно (служба без stdin → иначе Aborted!)
        )
    finally:
        fcntl.flock(_hub_lock_file, fcntl.LOCK_UN)
# Обёртка Silero (TTSModelMultiAcc_v3) сама не наследует nn.Module и не даёт
# .eval() — реальная сеть лежит в .model (jit ScriptModule). Переводим её в
# eval-режим явно (BatchNorm/Dropout детерминированы, синтез быстрее).
model.model.eval()
print("Модель загружена. Сервер готов.")

# --- бэкпрешер: ограничиваем число одновременно ожидающих запросов --------
# Ёмкость намеренно не равна размеру пула потоков (=1) — так под кратким
# всплеском клиенты видят предсказуемый 503 вместо роста очереди/таймаутов.
QUEUE_CAPACITY = int(os.environ.get("WORKERS", "1")) + 4
_semaphore = asyncio.Semaphore(QUEUE_CAPACITY)
_queue_waiting = 0

RETRY_AFTER_HEADERS = {"Retry-After": "5"}


class TTSRequest(BaseModel):
    # 800 символов даёт запас над лимитом клиента (режет предложения ≤700).
    text: str = Field(max_length=800)
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
        model.model.eval()
        with torch.no_grad():
            audio = model.apply_tts(text=text, speaker=speaker, sample_rate=SAMPLE_RATE)
        # клип перед масштабированием в int16 — редкий выброс >1.0 иначе даёт
        # переполнение/щелчок при приведении типа.
        pcm = (np.clip(audio.numpy(), -1.0, 1.0) * 32767).astype(np.int16)
        return _wav_bytes(pcm)
    except HTTPException:
        # Уже осмысленная HTTP-ошибка (если появится выше) — не глушить.
        raise
    except MemoryError:
        # Нехватка памяти — не маскировать тишиной, пусть процесс/оркестратор увидит сбой.
        raise
    except Exception as exc:
        # Реальный сбой синтеза: клиент должен узнать об этом (не-200), чтобы
        # корректно откатиться на системный голос, а не подсвечивать текст под тишину.
        # KeyboardInterrupt/SystemExit не Exception — сюда не попадают и пробрасываются сами.
        print(f"Синтез не удался (len={len(text)}, speaker={speaker}): {exc}")
        raise HTTPException(status_code=503, detail="tts synthesis failed")


@app.post("/synthesize")
async def synthesize(req: TTSRequest, request: Request, x_api_key: Optional[str] = Header(default=None)):
    _check_key(x_api_key)
    if not req.text.strip():
        raise HTTPException(400, "text is empty")
    if req.speaker not in SPEAKERS:
        raise HTTPException(400, f"unknown speaker, use one of: {SPEAKERS}")

    global _queue_waiting
    _queue_waiting += 1
    try:
        try:
            await asyncio.wait_for(_semaphore.acquire(), timeout=8)
        except asyncio.TimeoutError:
            raise HTTPException(503, "server busy, try again shortly", headers=RETRY_AFTER_HEADERS)
    finally:
        _queue_waiting -= 1

    try:
        if await request.is_disconnected():
            return Response(status_code=499)

        loop = asyncio.get_running_loop()
        try:
            wav = await asyncio.wait_for(
                loop.run_in_executor(executor, _synthesize, req.text, req.speaker),
                timeout=20,
            )
        except asyncio.TimeoutError:
            raise HTTPException(503, "tts synthesis timed out", headers=RETRY_AFTER_HEADERS)
        return Response(content=wav, media_type="audio/wav")
    finally:
        _semaphore.release()


@app.get("/health")
async def health():
    return {"status": "ok", "speakers": SPEAKERS, "queue_waiting": _queue_waiting}
