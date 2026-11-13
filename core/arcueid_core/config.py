from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, replace
from pathlib import Path


def _resolve_root() -> Path:
    configured = os.environ.get("ARCUEID_STAGE_ROOT")
    if configured:
        return Path(configured).resolve()
    candidates = [Path(__file__).resolve().parents[2]]
    if getattr(sys, "frozen", False):
        executable = Path(sys.executable).resolve()
        candidates.extend(executable.parents)
    for candidate in candidates:
        if (candidate / "corpus" / "stage_index" / "manifest.json").exists():
            return candidate
    return candidates[0]


ROOT = _resolve_root()


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    data_dir: Path
    index_dir: Path
    runtime_config: Path
    provider: str
    api_key: str
    model: str
    base_url: str
    temperature: float
    top_p: float
    voice_url: str
    enable_local_models: bool
    thinking_enabled: bool = False


def load_settings() -> Settings:
    runtime_config = ROOT / "config" / "runtime_config.json"
    example_config = ROOT / "config" / "runtime_config.example.json"
    source = runtime_config if runtime_config.exists() else example_config
    payload = json.loads(source.read_text(encoding="utf-8")) if source.exists() else {}
    local_app_data = Path(os.environ.get("LOCALAPPDATA", ROOT / ".runtime")) / "ArcueidStage"
    data_dir = Path(os.environ.get("ARCUEID_STAGE_DATA_DIR", local_app_data))
    settings = Settings(
        host="127.0.0.1",
        port=int(os.environ.get("ARCUEID_APP_PORT", payload.get("port", 8765))),
        data_dir=data_dir,
        index_dir=Path(os.environ.get("ARCUEID_STAGE_INDEX_DIR", ROOT / "corpus" / "stage_index")),
        runtime_config=runtime_config,
        provider=str(payload.get("provider", "openai-compatible")),
        api_key=str(os.environ.get("DEEPSEEK_API_KEY") or os.environ.get("OPENAI_API_KEY") or payload.get("api_key", "")),
        model=str(os.environ.get("DEEPSEEK_MODEL") or os.environ.get("OPENAI_MODEL") or payload.get("model", "")),
        base_url=str(os.environ.get("DEEPSEEK_BASE_URL") or os.environ.get("OPENAI_BASE_URL") or payload.get("base_url", "https://api.deepseek.com")).rstrip("/"),
        temperature=float(payload.get("temperature", 0.85)),
        top_p=float(payload.get("top_p", 0.95)),
        voice_url=os.environ.get("ARCUEID_VOICE_URL", "http://127.0.0.1:8766"),
        enable_local_models=os.environ.get("ARCUEID_ENABLE_LOCAL_MODELS", "0") == "1",
        thinking_enabled=os.environ.get("ARCUEID_THINKING", str(payload.get("thinking", False))).lower() in {"1", "true", "yes", "enabled"},
    )
    override = data_dir / "model_api.json"
    if override.exists():
        try:
            custom = json.loads(override.read_text(encoding="utf-8"))
            settings = replace(settings, **{name: custom[name] for name in
                ("provider", "api_key", "model", "base_url") if isinstance(custom.get(name), str)})
        except (OSError, ValueError, TypeError):
            pass
    return settings
