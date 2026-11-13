from __future__ import annotations

from pathlib import Path
from collections.abc import AsyncIterator
from typing import Any
import os

import httpx

from .config import ServiceConfig
from .models import TtsRequest


class GptSovitsHttpBackend:
    def __init__(self, config: ServiceConfig) -> None:
        self._endpoint = config.backend.endpoint
        self._defaults = config.defaults
        self._arcueid_ref_override = os.environ.get("ARCUEID_ARCUEID_REF_AUDIO_PATH", "")
        self._neco_endpoint = os.environ.get("ARCUEID_NECO_TTS_ENDPOINT", "")
        self._neco_ref_audio = os.environ.get("ARCUEID_NECO_REF_AUDIO_PATH", "")
        self._neco_prompt_text = os.environ.get("ARCUEID_NECO_PROMPT_TEXT", "")
        self._ciel_endpoint = os.environ.get("ARCUEID_CIEL_TTS_ENDPOINT", "")
        self._ciel_ref_audio = os.environ.get("ARCUEID_CIEL_REF_AUDIO_PATH", "")
        self._ciel_prompt_text = os.environ.get("ARCUEID_CIEL_PROMPT_TEXT", "")
        # This backend is retained for the process lifetime. Creating a client per
        # segment needlessly repeats proxy/environment initialization on Windows.
        self._client = httpx.AsyncClient(timeout=120.0, trust_env=False)

    def build_payload(self, request: TtsRequest) -> dict[str, Any]:
        ciel = request.model_id == "ciel_fullclips_v2pro_20261005_e12_s8"
        if ciel:
            if not self._ciel_endpoint or not self._ciel_ref_audio or not self._ciel_prompt_text:
                raise RuntimeError("Ciel voice profile is not configured")
            ref_audio_path = request.ref_audio_path or self._ciel_ref_audio
            prompt_text = request.prompt_text if request.prompt_text is not None else self._ciel_prompt_text
            text_lang = request.text_lang or "ja"
            prompt_lang = request.prompt_lang or "ja"
        elif request.model_id == "neco_arc_v2pro":
            if not self._neco_endpoint or not self._neco_ref_audio:
                raise RuntimeError("Neco-Arc voice profile is not configured")
            ref_audio_path = request.ref_audio_path or self._neco_ref_audio
            prompt_text = request.prompt_text if request.prompt_text is not None else self._neco_prompt_text
            text_lang = request.text_lang or "ja"
            prompt_lang = request.prompt_lang or "ja"
        else:
            ref_audio_path = request.ref_audio_path or self._arcueid_ref_override or self._defaults.ref_audio_path
            prompt_text = request.prompt_text if request.prompt_text is not None else self._defaults.prompt_text
            text_lang = request.text_lang or self._defaults.text_lang
            prompt_lang = request.prompt_lang or self._defaults.prompt_lang
        if ref_audio_path.startswith("/"):
            resolved_ref_audio_path = ref_audio_path
        else:
            resolved_ref_audio_path = str(Path(ref_audio_path).resolve())
        payload: dict[str, Any] = {
            "text": request.text,
            "text_lang": text_lang,
            "ref_audio_path": resolved_ref_audio_path,
            "prompt_text": prompt_text,
            "prompt_lang": prompt_lang,
            "top_k": request.top_k if request.top_k is not None else 15 if ciel else self._defaults.top_k,
            "top_p": request.top_p if request.top_p is not None else 1.0 if ciel else self._defaults.top_p,
            "temperature": request.temperature if request.temperature is not None else 0.8 if ciel else self._defaults.temperature,
            "text_split_method": request.text_split_method or ("cut5" if ciel else self._defaults.text_split_method),
            "batch_size": request.batch_size if request.batch_size is not None else 1 if ciel else self._defaults.batch_size,
            "speed_factor": request.speed_factor if request.speed_factor is not None else 1.0 if ciel else self._defaults.speed_factor,
            "fragment_interval": request.fragment_interval if request.fragment_interval is not None else self._defaults.fragment_interval,
            "media_type": request.media_type or self._defaults.media_type,
            "streaming_mode": request.streaming_mode if request.streaming_mode is not None else self._defaults.streaming_mode,
            "parallel_infer": request.parallel_infer if request.parallel_infer is not None else True if ciel else self._defaults.parallel_infer,
            "repetition_penalty": request.repetition_penalty if request.repetition_penalty is not None else 1.35 if ciel else self._defaults.repetition_penalty,
        }
        if request.seed is not None or ciel:
            payload["seed"] = request.seed if request.seed is not None else 1234
        return payload

    def endpoint_for(self, model_id: str) -> str:
        if model_id == "ciel_fullclips_v2pro_20261005_e12_s8":
            return self._ciel_endpoint
        return self._neco_endpoint if model_id == "neco_arc_v2pro" else self._endpoint

    async def synthesize(self, payload: dict[str, Any], model_id: str = "") -> bytes:
        response = await self._client.post(self.endpoint_for(model_id), json=payload)
        response.raise_for_status()
        return response.content

    async def synthesize_stream(self, payload: dict[str, Any], model_id: str = "") -> AsyncIterator[bytes]:
        """Yield GPT-SoVITS WAV chunks without buffering the full response."""
        async with self._client.stream("POST", self.endpoint_for(model_id), json=payload) as response:
            response.raise_for_status()
            async for chunk in response.aiter_bytes():
                if chunk:
                    yield chunk

    async def close(self) -> None:
        await self._client.aclose()
