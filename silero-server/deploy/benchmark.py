#!/usr/bin/env python3
"""Нагрузочный тест Silero-сервера: измеряет RTF и реальную ёмкость (слушателей).

Запуск (на сервере, чтобы исключить сеть):
    .venv/bin/python deploy/benchmark.py --url http://127.0.0.1:8000 \
        --key "$(grep SILERO_API_KEY .env | cut -d= -f2)" --concurrency 5 --requests 4

Только стандартная библиотека — никаких зависимостей.
"""
import argparse
import json
import time
import wave
import io
import threading
import urllib.request
import urllib.error

# Представительные предложения (разной длины), как в реальной книге.
SENTENCES = [
    "Сегодня прекрасный день, и мы отправляемся в долгое путешествие по горам.",
    "Он остановился, посмотрел на неё и тихо произнёс несколько слов.",
    "Наука движется вперёд маленькими шагами, каждый из которых важен.",
    "В комнате стояла тишина, нарушаемая лишь тиканьем старинных часов на стене.",
]


def synth_once(url: str, key: str, text: str, speaker: str):
    """Один запрос. Возвращает (время_синтеза_сек, длительность_аудио_сек)."""
    body = json.dumps({"text": text, "speaker": speaker}).encode()
    req = urllib.request.Request(url.rstrip("/") + "/synthesize", data=body,
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    if key:
        req.add_header("X-API-Key", key)
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=120) as resp:
        wav = resp.read()
    synth_s = time.monotonic() - t0
    with wave.open(io.BytesIO(wav), "rb") as wf:
        audio_s = wf.getnframes() / wf.getframerate()
    return synth_s, audio_s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--key", default="")
    ap.add_argument("--speaker", default="xenia")
    ap.add_argument("--concurrency", type=int, default=5,
                    help="параллельных слушателей (потоков)")
    ap.add_argument("--requests", type=int, default=4,
                    help="запросов на поток")
    args = ap.parse_args()

    results = []  # (synth_s, audio_s)
    errors = []
    lock = threading.Lock()

    def worker(wid: int):
        for i in range(args.requests):
            text = SENTENCES[(wid + i) % len(SENTENCES)]
            try:
                r = synth_once(args.url, args.key, text, args.speaker)
                with lock:
                    results.append(r)
            except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
                with lock:
                    errors.append(str(e))

    print(f"Прогрев…")
    synth_once(args.url, args.key, SENTENCES[0], args.speaker)  # warm-up (не в зачёт)

    print(f"Старт: concurrency={args.concurrency}, requests/thread={args.requests}")
    threads = [threading.Thread(target=worker, args=(w,))
               for w in range(args.concurrency)]
    t0 = time.monotonic()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.monotonic() - t0

    if not results:
        print(f"ВСЕ запросы упали. Пример ошибки: {errors[:1]}")
        return

    n = len(results)
    total_synth = sum(s for s, _ in results)
    total_audio = sum(a for _, a in results)
    avg_lat = total_synth / n
    rtf = total_synth / total_audio                 # секунд счёта на секунду аудио
    capacity = total_audio / wall                   # секунд аудио в секунду = слушателей RT

    print("\n────────── РЕЗУЛЬТАТ ──────────")
    print(f"запросов успешно : {n}  (ошибок: {len(errors)})")
    print(f"wall-clock       : {wall:.1f} с")
    print(f"ср. латентность  : {avg_lat:.2f} с/предложение")
    print(f"RTF              : {rtf:.3f}  (меньше = лучше; <1 = быстрее реального времени)")
    print(f"ЁМКОСТЬ          : {capacity:.1f} слушателей реального времени")
    verdict = "✅ цель достигнута" if capacity >= args.concurrency else "⚠️  ниже цели — подними WORKERS"
    print(f"при цели {args.concurrency}: {verdict}")
    print("───────────────────────────────")


if __name__ == "__main__":
    main()
