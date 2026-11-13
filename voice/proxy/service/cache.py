from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path
from typing import Any

from .models import TtsRequest


def build_cache_key(request: TtsRequest, payload: dict[str, Any]) -> str:
    canonical = json.dumps(
        {
            "model_id": request.model_id,
            "payload": payload,
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def cache_path(cache_dir: Path, key: str) -> Path:
    return cache_dir / f"{key}.wav"


def finish_stream_wav(audio: bytearray) -> bytes:
    """Replace the live WAV's unknown lengths before saving a reusable file."""
    if len(audio) < 12 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
        raise ValueError("stream did not return WAV audio")
    offset = 12
    while offset + 8 <= len(audio):
        size = struct.unpack_from("<I", audio, offset + 4)[0]
        if audio[offset:offset + 4] == b"data":
            actual = len(audio) - offset - 8
            if not actual or size not in (0, 0xFFFFFFFF, actual):
                raise ValueError("incomplete streamed WAV")
            struct.pack_into("<I", audio, 4, len(audio) - 8)
            struct.pack_into("<I", audio, offset + 4, actual)
            return bytes(audio)
        offset += 8 + size + size % 2
    raise ValueError("stream has no WAV data chunk")
