from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass
class BackendConfig:
    type: str
    endpoint: str


@dataclass
class DefaultsConfig:
    text_lang: str
    prompt_lang: str
    ref_audio_path: str
    prompt_text: str
    model_id: str
    top_k: int
    top_p: float
    temperature: float
    text_split_method: str
    batch_size: int
    speed_factor: float
    fragment_interval: float
    media_type: str
    streaming_mode: bool
    parallel_infer: bool
    repetition_penalty: float


@dataclass
class ServiceConfig:
    host: str
    port: int
    cache_dir: str
    backend: BackendConfig
    defaults: DefaultsConfig


def load_config(path: str | Path) -> ServiceConfig:
    raw = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    defaults = raw.get("defaults", {})
    return ServiceConfig(
        host=raw.get("host", "127.0.0.1"),
        port=int(raw.get("port", 8766)),
        cache_dir=raw.get("cache_dir", "../cache"),
        backend=BackendConfig(
            type=raw["backend"]["type"],
            endpoint=raw["backend"]["endpoint"],
        ),
        defaults=DefaultsConfig(
            text_lang=defaults.get("text_lang", "ja"),
            prompt_lang=defaults.get("prompt_lang", "ja"),
            ref_audio_path=defaults.get("ref_audio_path", "../models/ref.wav"),
            prompt_text=defaults.get("prompt_text", ""),
            model_id=defaults.get("model_id", "arcueid_utf8_v2pro"),
            top_k=int(defaults.get("top_k", 15)),
            top_p=float(defaults.get("top_p", 1.0)),
            temperature=float(defaults.get("temperature", 1.0)),
            text_split_method=defaults.get("text_split_method", "cut5"),
            batch_size=int(defaults.get("batch_size", 1)),
            speed_factor=float(defaults.get("speed_factor", 1.0)),
            fragment_interval=float(defaults.get("fragment_interval", 0.3)),
            media_type=defaults.get("media_type", "wav"),
            streaming_mode=bool(defaults.get("streaming_mode", False)),
            parallel_infer=bool(defaults.get("parallel_infer", True)),
            repetition_penalty=float(defaults.get("repetition_penalty", 1.35)),
        ),
    )
