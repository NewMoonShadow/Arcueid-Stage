from __future__ import annotations

from pydantic import BaseModel, Field


class TtsRequest(BaseModel):
    text: str = Field(min_length=1)
    request_id: str = ""
    segment_index: int = -1
    bypass_cache: bool = False
    text_lang: str | None = None
    ref_audio_path: str | None = None
    prompt_text: str | None = None
    prompt_lang: str | None = None
    model_id: str = "arcueid_utf8_v2pro"
    top_k: int | None = None
    top_p: float | None = None
    temperature: float | None = None
    text_split_method: str | None = None
    batch_size: int | None = None
    speed_factor: float | None = None
    fragment_interval: float | None = None
    media_type: str | None = None
    streaming_mode: bool | int | None = None
    parallel_infer: bool | None = None
    repetition_penalty: float | None = None
    seed: int | None = None


class TtsError(BaseModel):
    detail: str
