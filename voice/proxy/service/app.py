from __future__ import annotations

import json
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from queue import SimpleQueue
from threading import Thread
from time import perf_counter
from typing import Any
from collections.abc import AsyncIterator

from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import FileResponse, StreamingResponse

from .backend import GptSovitsHttpBackend
from .cache import build_cache_key, cache_path, finish_stream_wav
from .config import load_config
from .models import TtsRequest


BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.json"
_latency_queue: SimpleQueue[tuple[Path, str]] = SimpleQueue()
_runtime: tuple[Path, GptSovitsHttpBackend] | None = None


def _latency_write_loop() -> None:
    while True:
        path, line = _latency_queue.get()
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
            print(f"ARCUEID_LATENCY {line}", flush=True)
        except OSError:
            pass


Thread(target=_latency_write_loop, name="voice-latency-writer", daemon=True).start()


def _ms(seconds: float) -> float:
    return round(seconds * 1000, 1)


def _record_latency(cache_dir: Path, event: str, request: TtsRequest, **fields: Any) -> None:
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "component": "voice_proxy",
        "event": event,
        "request_id": request.request_id,
        "segment_index": request.segment_index,
        "model_id": request.model_id,
        **fields,
    }
    line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    _latency_queue.put((cache_dir / "latency_voice.jsonl", line))


def _timing_headers(cache_status: str, total_ms: float, backend_ms: float = 0.0) -> dict[str, str]:
    return {
        "X-Arcueid-Cache": cache_status,
        "X-Arcueid-Total-Ms": f"{total_ms:.1f}",
        "X-Arcueid-Backend-Ms": f"{backend_ms:.1f}",
        "Server-Timing": f"gpt_sovits;dur={backend_ms:.1f}, voice_proxy;dur={total_ms:.1f}",
    }


def get_runtime() -> tuple[Path, GptSovitsHttpBackend]:
    global _runtime
    if _runtime is not None:
        return _runtime
    if not CONFIG_PATH.exists():
        raise RuntimeError("missing service/config.json; copy config.example.json first")
    config = load_config(CONFIG_PATH)
    cache_dir = (BASE_DIR / config.cache_dir).resolve()
    cache_dir.mkdir(parents=True, exist_ok=True)
    _runtime = cache_dir, GptSovitsHttpBackend(config)
    return _runtime


@asynccontextmanager
async def lifespan(_app: FastAPI):
    try:
        yield
    finally:
        global _runtime
        if _runtime is not None:
            await _runtime[1].close()
            _runtime = None


app = FastAPI(title="Arcueid Voice Service", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/tts")
async def tts(request: TtsRequest) -> FileResponse:
    started = perf_counter()
    try:
        cache_dir, backend = get_runtime()
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    try:
        payload = backend.build_payload(request)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    key = build_cache_key(request, payload)
    wav_path = cache_path(cache_dir, key)
    if wav_path.exists() and not request.bypass_cache:
        total_ms = _ms(perf_counter() - started)
        _record_latency(cache_dir, "tts.cache_hit", request, total_ms=total_ms, audio_bytes=wav_path.stat().st_size)
        return FileResponse(wav_path, media_type="audio/wav", filename=f"{key}.wav", headers={**_timing_headers("hit", total_ms), "X-Arcueid-Cache-Key": key})

    try:
        backend_started = perf_counter()
        audio_bytes = await backend.synthesize(payload, request.model_id)
        backend_ms = _ms(perf_counter() - backend_started)
    except Exception as exc:  # noqa: BLE001
        _record_latency(cache_dir, "tts.failed", request, total_ms=_ms(perf_counter() - started), error=type(exc).__name__)
        raise HTTPException(status_code=502, detail=f"tts backend failed: {exc}") from exc

    write_started = perf_counter()
    wav_path.write_bytes(audio_bytes)
    write_ms = _ms(perf_counter() - write_started)
    total_ms = _ms(perf_counter() - started)
    _record_latency(
        cache_dir,
        "tts.generated",
        request,
        backend_ms=backend_ms,
        cache_write_ms=write_ms,
        total_ms=total_ms,
        audio_bytes=len(audio_bytes),
    )
    return FileResponse(wav_path, media_type="audio/wav", filename=f"{key}.wav", headers={**_timing_headers("miss", total_ms, backend_ms), "X-Arcueid-Cache-Key": key})


@app.post("/api/tts/stream")
async def tts_stream(request: TtsRequest) -> Response:
    """Stream a WAV while also committing the finished audio to the normal cache."""
    started = perf_counter()
    try:
        cache_dir, backend = get_runtime()
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    try:
        payload = backend.build_payload(request)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    # GPT-SoVITS mode 2 yields a WAV header followed by medium-quality PCM chunks.
    payload["streaming_mode"] = 2
    key = build_cache_key(request, payload)
    wav_path = cache_path(cache_dir, key)
    if wav_path.exists() and not request.bypass_cache:
        total_ms = _ms(perf_counter() - started)
        _record_latency(cache_dir, "tts.stream_cache_hit", request, total_ms=total_ms, audio_bytes=wav_path.stat().st_size)
        return FileResponse(wav_path, media_type="audio/wav", filename=f"{key}.wav", headers=_timing_headers("hit", total_ms))

    async def generate() -> AsyncIterator[bytes]:
        audio = bytearray()
        backend_started = perf_counter()
        try:
            async for chunk in backend.synthesize_stream(payload, request.model_id):
                audio.extend(chunk)
                if len(audio) > 48 * 1024 * 1024:
                    raise ValueError("streamed audio exceeds cache limit")
                yield chunk
            completed_audio = finish_stream_wav(audio)
        except Exception as exc:  # noqa: BLE001
            _record_latency(cache_dir, "tts.stream_failed", request, total_ms=_ms(perf_counter() - started), error=type(exc).__name__)
            raise
        else:
            wav_path.write_bytes(completed_audio)
            backend_ms = _ms(perf_counter() - backend_started)
            _record_latency(cache_dir, "tts.stream_generated", request, backend_ms=backend_ms, total_ms=_ms(perf_counter() - started), audio_bytes=len(audio))

    return StreamingResponse(generate(), media_type="audio/wav", headers={"X-Arcueid-Cache": "miss"})
