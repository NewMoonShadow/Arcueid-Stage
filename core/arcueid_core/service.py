from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import uuid
from contextlib import asynccontextmanager, suppress
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from queue import SimpleQueue
from threading import Thread
from time import perf_counter
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .config import Settings, load_settings
from .process_lifecycle import process_is_alive
from .model_api import register_model_api
from .audio_stream import WavPcmDecoder
from .database import StageDatabase
from .llm import AssistantReply, AssistantSegment, combine_segments, complete, stream_segments, translate_to_japanese, unavailable_reply
from .prompts import TEACHER_SAVE_NAME, build_ciel_messages, build_messages, build_story_messages, build_teacher_messages
from .classroom import clean_state, route_classroom
from .classroom_intent import ClassroomIntent, classify_classroom_intent, initial_speaker
from .retrieval import HybridIndex
from .lore_knowledge import LoreKnowledge
from .story import SCENE_ID, StoryDirector, fallback_reply
from . import park_dialogue
from .park_sessions import ParkSessions

VOICE_MODELS = {"arcueid": "arcueid_utf8_v2pro", "neco_arc": "neco_arc_v2pro", "ciel": "ciel_fullclips_v2pro_20261005_e12_s8"}

class SaveCreate(BaseModel):
    name: str = Field(default="新的记录", max_length=80)
    identity_mode: str = "self"
    user_name: str = Field(default="", max_length=80)


class SavePatch(BaseModel):
    name: str | None = Field(default=None, max_length=80)
    identity_mode: str | None = None
    user_name: str | None = Field(default=None, max_length=80)


class MemoryPatch(BaseModel):
    content: str | None = Field(default=None, max_length=600)
    status: str | None = None


class LegacyChat(BaseModel):
    message: str = Field(min_length=1, max_length=2000)
    top_k: int = 5


class StoryStart(BaseModel):
    restart: bool = False


class ParkSpeech(BaseModel):
    speaker_id: str = Field(max_length=24)
    text: str = Field(min_length=1, max_length=600)
    tts_text: str = Field(default="", max_length=1200)
    request_id: str = Field(default="", max_length=100)
    bypass_cache: bool = False


class ParkTurn(BaseModel):
    cue_id: str = Field(default="", max_length=24)
    session_id: str = Field(default="", max_length=40)
    revision: int = Field(default=0, ge=0)
    message: str = Field(min_length=1, max_length=300)
    request_id: str = Field(min_length=1, max_length=100)
    history: list[dict[str, str]] = Field(default_factory=list, max_length=16)
    decisions: dict[str, dict[str, str]] = Field(default_factory=dict, max_length=3)


class ParkSpeechGroup(BaseModel):
    lines: list[ParkSpeech] = Field(min_length=2,max_length=2)
    request_id: str = Field(max_length=100)


class ParkPrepare(BaseModel):
    cue_id: str = Field(max_length=24)
    request_id: str = Field(min_length=1, max_length=100)
    session_id: str = Field(default="", max_length=40)
    previous_session_id: str = Field(default="", max_length=40)
    history: list[dict[str,str]] = Field(default_factory=list, max_length=16)
    decisions: dict[str,dict[str,str]] = Field(default_factory=dict, max_length=3)
    rehearsal: bool = False
    discard_pending: bool = True


class ParkCommit(BaseModel):
    request_id: str = Field(min_length=1, max_length=100)
    revision: int = Field(ge=0)


class TeacherUI(BaseModel):
    revision: int = Field(ge=0)
    selected_speaker_id: str = "auto"
    draft: str = Field(default="", max_length=2000)


class TeacherCheckpoint(TeacherUI):
    name: str = Field(default="", max_length=80)


def _ms(seconds: float) -> float:
    return round(seconds * 1000, 1)


class LatencyRecorder:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._queue: SimpleQueue[str | None] = SimpleQueue()
        self._worker = Thread(target=self._write_loop, name="arcueid-latency-writer", daemon=True)
        self._worker.start()

    def record(self, event: str, request_id: str, **fields: Any) -> None:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "component": "core",
            "event": event,
            "request_id": request_id,
            **fields,
        }
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        self._queue.put(line)

    def close(self) -> None:
        self._queue.put(None)
        self._worker.join(timeout=1.0)

    def _write_loop(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8", buffering=1) as handle:
                while True:
                    line = self._queue.get()
                    if line is None:
                        return
                    handle.write(line + "\n")
                    print(f"ARCUEID_LATENCY {line}", flush=True)
        except OSError:
            pass


@dataclass
class SynthesisResult:
    key: str | None
    cache_hit: bool
    slot_wait_ms: float
    proxy_http_ms: float
    proxy_total_ms: float | None = None
    gpt_sovits_ms: float | None = None
    error: str = ""


class Core:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.database = StageDatabase(settings.data_dir / "arcueid_stage.sqlite3")
        self.story = StoryDirector(self.database)
        self.index = HybridIndex(settings.index_dir, settings.enable_local_models)
        self.knowledge = LoreKnowledge()
        self.audio_dir = settings.data_dir / "audio_cache"
        self.audio_dir.mkdir(parents=True, exist_ok=True)
        self.tts_slots = asyncio.Semaphore(1)
        self.park_sessions = ParkSessions(settings.data_dir / 'park_sessions')
        self.teacher_sessions: dict[str, tuple[asyncio.Task, asyncio.Event]] = {}
        self.teacher_busy: set[str] = set()
        self.classroom_intents: dict[str, tuple[ClassroomIntent, str, str]] = {}
        self.latency = LatencyRecorder(settings.data_dir / "latency_core.jsonl")
        self.voice_client = httpx.AsyncClient(timeout=120, trust_env=False)
        self.llm_client = httpx.AsyncClient(
            timeout=httpx.Timeout(90.0, connect=10.0),
            trust_env=False,
        )

    async def close(self) -> None:
        await asyncio.gather(self.voice_client.aclose(), self.llm_client.aclose())
        self.knowledge.close()

    def retrieve(self, message: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        results = self.index.search_many(message, {"canon": 6, "style": 3})
        lore = self.knowledge.search(message)
        canon = lore + results["canon"].rows[:6 - len(lore)]
        return canon, results["style"].rows

    def character_settings(self, speaker_id: str) -> Settings:
        if speaker_id != "ciel":
            return self.settings
        return replace(
            self.settings,
            provider=os.environ.get("ARCUEID_CIEL_PROVIDER", self.settings.provider),
            api_key=os.environ.get("ARCUEID_CIEL_API_KEY", self.settings.api_key),
            model=os.environ.get("ARCUEID_CIEL_MODEL", self.settings.model),
            base_url=os.environ.get("ARCUEID_CIEL_BASE_URL", self.settings.base_url).rstrip("/"),
        )

    def prepare_response(self, save_id: str, message: str, turn_id: str, speaker_id: str = "arcueid", story_scene: dict[str, Any] | None = None, story_intent: str | None = None) -> tuple[list[dict[str, str]], list[dict[str, Any]], list[dict[str, Any]], dict[str, float]]:
        if speaker_id not in {"arcueid", "ciel", "neco_arc", "auto"}:
            raise ValueError("unknown speaker_id")
        prepare_started = perf_counter()
        save = self.database.get_save(save_id)
        if speaker_id in {"neco_arc", "auto"} and not ((save.get("module") == "teacher" or save["name"] == TEACHER_SAVE_NAME) and save["identity_mode"] == "self"):
            raise ValueError("automatic addressing and Neco-Arc are only available in the classroom")
        teacher_mode = story_scene is None and speaker_id in {"arcueid", "neco_arc", "auto"} and (save.get("module") == "teacher" or save["name"] == TEACHER_SAVE_NAME) and save["identity_mode"] == "self"
        intent_started = perf_counter()
        intent = ClassroomIntent()
        state: dict[str, Any] = {}
        if teacher_mode:
            state = self.database.classroom_state(save_id)
            intent_enabled = os.environ.get("ARCUEID_CLASSROOM_INTENT", "1") != "0"
            if intent_enabled:
                try:
                    intent = classify_classroom_intent(message, state)
                except Exception:
                    # Dialogue still works when the optional classifier fails.
                    intent = ClassroomIntent()
                boundary = intent.next_boundary(str(state.get("speaker_boundary", "")))
            else:
                boundary = ""
            self.classroom_intents[turn_id] = (intent, boundary, initial_speaker(speaker_id, intent, boundary))
        intent_ms = _ms(perf_counter() - intent_started)
        query = intent.retrieval_query or message
        retrieval_started = perf_counter()
        canon, style = ([], [])
        if story_scene is None:
            if speaker_id in {"arcueid", "auto", "neco_arc"}:
                canon, style = self.retrieve(query)
            elif speaker_id == "ciel":
                # Ciel receives shared/source-linked cards, not Arcueid's raw or Style retrieval.
                canon = self.knowledge.search(message, speaker_id="ciel")
        retrieval_ms = _ms(perf_counter() - retrieval_started)
        prompt_started = perf_counter()
        recent = (self.database.recent_messages(save_id, 24) if teacher_mode else self.database.recent_character_messages(save_id, speaker_id, 8)) if story_scene is None else []
        if story_scene is not None:
            prompt = build_story_messages(speaker_id, message, story_scene, story_intent)
        elif speaker_id == "ciel":
            prompt = build_ciel_messages(save, message, recent, canon)
        elif teacher_mode:
            _intent, boundary, target = self.classroom_intents[turn_id]
            prompt_state = state if os.environ.get("ARCUEID_CLASSROOM_INTENT", "1") != "0" else {key: value for key, value in state.items() if key != "speaker_boundary"}
            prompt = build_teacher_messages(save, message, canon, style, recent, target, prompt_state, intent.prompt_hint(boundary))
        else:
            memories = [row for row in self.database.memories(save_id) if row["status"] in {"active", "pinned"}][:5]
            prompt = build_messages(save, message, canon, style, memories, self.database.latest_summary(save_id), recent)
        self.database.add_message(save_id, turn_id, "user", message, recipient_id=None if speaker_id == "auto" else speaker_id, scene_id=SCENE_ID if story_scene is not None else None)
        timings = {
            "intent_ms": intent_ms,
            "retrieval_ms": retrieval_ms,
            "prompt_and_context_ms": _ms(perf_counter() - prompt_started),
            "prepare_total_ms": _ms(perf_counter() - prepare_started),
        }
        return prompt, canon, style, timings

    def finish_response(self, save_id: str, message: str, turn_id: str, reply: AssistantReply, speaker_id: str = "arcueid", story_mode: bool = False) -> list[dict[str, Any]]:
        save = self.database.get_save(save_id)
        is_teacher = (save.get("module") == "teacher" or save["name"] == TEACHER_SAVE_NAME) and save["identity_mode"] == "self"
        control = self.classroom_intents.pop(turn_id, None) if is_teacher else None
        if is_teacher and reply.segments and any(segment.speaker_id for segment in reply.segments):
            # Preserve every actual speaker turn, including Arcueid -> Neco -> Arcueid.
            groups: list[list[AssistantSegment]] = []
            for segment in reply.segments:
                if not groups or groups[-1][-1].speaker_id != segment.speaker_id:
                    groups.append([])
                groups[-1].append(segment)
            merged_state = clean_state(self.database.classroom_state(save_id))
            for segment in reply.segments:
                model_state = clean_state(segment.conversation_state)
                model_state.pop("speaker_boundary", None)
                merged_state.update(model_state)
            if control and control[0].boundary_action != "none":
                merged_state["speaker_boundary"] = control[1]
            with self.database.connection:
                for index, group in enumerate(groups):
                    text = combine_segments(group)
                    self.database.add_message(save_id, turn_id, "assistant", text.reply, text.tts_text,
                                              text.mood, text.expression, group[0].speaker_id,
                                              conversation_state=merged_state if index == len(groups) - 1 else {}, commit=False)
            return []
        self.database.add_message(save_id, turn_id, "assistant", reply.reply, reply.tts_text, reply.mood, reply.expression, speaker_id, scene_id=SCENE_ID if story_mode else None)
        if is_teacher:
            aside_id = "arcueid" if speaker_id == "neco_arc" else "neco_arc"
            aside = reply.arcueid_reply if speaker_id == "neco_arc" else reply.neco_reply
            if aside:
                self.database.add_message(save_id, turn_id, "assistant", aside, speaker_id=aside_id)
        return self._maintain_memory(save_id, message) if speaker_id == "arcueid" and not story_mode and not is_teacher else []

    async def respond(self, save_id: str, message: str, turn_id: str) -> tuple[AssistantReply, list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
        prompt, canon, style, _timings = self.prepare_response(save_id, message, turn_id)
        reply = await complete(self.settings, prompt, client=self.llm_client)
        updates = self.finish_response(save_id, message, turn_id, reply)
        return reply, canon, style, updates

    def _maintain_memory(self, save_id: str, message: str) -> list[dict[str, Any]]:
        turns = self.database.user_turn_count(save_id)
        updates: list[dict[str, Any]] = []
        if turns % 4 == 0 and any(marker in message for marker in ("我叫", "喜欢", "不喜欢", "生日", "住在", "工作", "学校", "想要")):
            normalized = " ".join(message.split())
            existing = self.database.memories(save_id)
            if not any(normalized in row["content"] or row["content"] in normalized for row in existing):
                kind = "preference" if "喜欢" in message or "不喜欢" in message else "profile"
                updates.append(self.database.add_memory(save_id, kind, f"用户提到：{normalized}", 0.55, 0.65, [], "candidate"))
        if turns and turns % 12 == 0:
            messages = self.database.recent_character_messages(save_id, "arcueid", 24)
            if messages:
                compact = " ".join(f"{row['role']}：{row['display_text']}" for row in messages)[-1000:]
                self.database.add_summary(save_id, messages[0]["id"], messages[-1]["id"], compact)
        return updates

    async def synthesize(self, text: str, request_id: str = "", segment_index: int = -1, model_id: str = "arcueid_utf8_v2pro") -> SynthesisResult:
        started = perf_counter()
        cache_input = text if model_id == "arcueid_utf8_v2pro" else f"{model_id}:{text}"
        key = hashlib.sha256(cache_input.encode("utf-8")).hexdigest()
        target = self.audio_dir / f"{key}.wav"
        # Ciel's proxy key includes the resolved reference and inference profile.
        # Consult that cache rather than reusing an older text-only Core key.
        use_core_cache = model_id != VOICE_MODELS["ciel"]
        if use_core_cache and target.exists():
            result = SynthesisResult(key, True, 0.0, 0.0)
            self.latency.record("tts.core_cache_hit", request_id, segment_index=segment_index, total_ms=_ms(perf_counter() - started))
            return result
        slot_started = perf_counter()
        async with self.tts_slots:
            slot_wait_ms = _ms(perf_counter() - slot_started)
            if use_core_cache and target.exists():
                result = SynthesisResult(key, True, slot_wait_ms, 0.0)
                self.latency.record("tts.core_cache_hit", request_id, segment_index=segment_index, slot_wait_ms=slot_wait_ms, total_ms=_ms(perf_counter() - started))
                return result
            try:
                proxy_started = perf_counter()
                response = await self.voice_client.post(
                    f"{self.settings.voice_url}/api/tts",
                    json={"text": text, "request_id": request_id, "segment_index": segment_index, "model_id": model_id},
                )
                response.raise_for_status()
                proxy_http_ms = _ms(perf_counter() - proxy_started)
                if not use_core_cache:
                    profile_key = response.headers.get("x-arcueid-cache-key") or hashlib.sha256(response.content).hexdigest()
                    key = hashlib.sha256(f"{model_id}:{profile_key}".encode()).hexdigest()
                    target = self.audio_dir / f"{key}.wav"
                target.write_bytes(response.content)
                proxy_total = response.headers.get("x-arcueid-total-ms")
                backend_ms = response.headers.get("x-arcueid-backend-ms")
                result = SynthesisResult(
                    key,
                    response.headers.get("x-arcueid-cache", "miss") == "hit",
                    slot_wait_ms,
                    proxy_http_ms,
                    float(proxy_total) if proxy_total else None,
                    float(backend_ms) if backend_ms else None,
                )
                self.latency.record(
                    "tts.synthesized",
                    request_id,
                    segment_index=segment_index,
                    core_cache_hit=False,
                    proxy_cache_hit=result.cache_hit,
                    slot_wait_ms=slot_wait_ms,
                    proxy_http_ms=proxy_http_ms,
                    proxy_total_ms=result.proxy_total_ms,
                    gpt_sovits_ms=result.gpt_sovits_ms,
                    total_ms=_ms(perf_counter() - started),
                )
                return result
            except Exception as exc:
                result = SynthesisResult(None, False, slot_wait_ms, _ms(perf_counter() - started), error=type(exc).__name__)
                self.latency.record(
                    "tts.failed",
                    request_id,
                    segment_index=segment_index,
                    slot_wait_ms=slot_wait_ms,
                    total_ms=_ms(perf_counter() - started),
                    error=result.error,
                )
                return result


def create_app(settings: Settings | None = None) -> FastAPI:
    core = Core(settings or load_settings())
    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        parent_pid = int(os.environ.get("ARCUEID_PARENT_PID", "0"))
        task: asyncio.Task[None] | None = None
        if parent_pid:
            async def watch() -> None:
                while True:
                    await asyncio.sleep(3)
                    if not process_is_alive(parent_pid):
                        os._exit(0)

            task = asyncio.create_task(watch())
        try:
            yield
        finally:
            if task:
                task.cancel()
            await core.close()
            core.latency.close()

    app = FastAPI(title="Arcueid Core", version="2.0", lifespan=lifespan)
    app.state.core = core
    register_model_api(app, core)

    @app.get("/api/v2/health")
    async def health_v2() -> dict[str, Any]:
        return {"ok": True, "protocol_version": 3, "index_ready": core.index.ready, "records": len(core.index.rows), "models": core.index.model_mode, "voice_url": core.settings.voice_url}

    @app.get("/api/health")
    async def health_legacy() -> dict[str, Any]:
        return {"ok": True, "corpus_size": len(core.index.rows), "model": core.settings.model, "base_url": core.settings.base_url, "provider": core.settings.provider, "config_path": str(core.settings.runtime_config)}

    @app.post("/api/v2/saves")
    async def create_save(payload: SaveCreate) -> dict[str, Any]:
        try:
            return core.database.create_save(payload.name, payload.identity_mode, payload.user_name)
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc

    @app.get("/api/v2/saves")
    async def list_saves() -> list[dict[str, Any]]:
        return core.database.list_saves()

    @app.post("/api/v2/teacher/save")
    async def teacher_save() -> dict[str, Any]:
        return core.database.ensure_teacher_save(TEACHER_SAVE_NAME)

    def classroom_save_id(require_idle: bool = False) -> str:
        save_id = core.database.ensure_teacher_save(TEACHER_SAVE_NAME)["id"]
        if require_idle and save_id in core.teacher_busy:
            raise HTTPException(409, "请先停止或等待当前回答完成")
        return save_id

    def classroom_error(exc: Exception) -> HTTPException:
        return HTTPException(404 if isinstance(exc, KeyError) else 409, str(exc))

    @app.get("/api/v2/teacher/progress")
    async def teacher_progress() -> dict[str, Any]:
        return core.database.teacher_progress(classroom_save_id())

    @app.patch("/api/v2/teacher/progress")
    async def update_teacher_progress(payload: TeacherUI) -> dict[str, Any]:
        try:
            return core.database.update_teacher_progress(classroom_save_id(), payload.revision, payload.model_dump())
        except ValueError as exc:
            raise classroom_error(exc) from exc

    @app.get("/api/v2/teacher/checkpoints")
    async def teacher_checkpoints() -> list[dict[str, Any]]:
        return core.database.teacher_checkpoints()

    @app.put("/api/v2/teacher/checkpoints/{slot}")
    async def save_teacher_checkpoint(slot: int, payload: TeacherCheckpoint) -> dict[str, Any]:
        try:
            return core.database.save_teacher_checkpoint(classroom_save_id(True), slot, payload.name,
                                                         payload.revision, payload.model_dump())
        except (KeyError, ValueError) as exc:
            raise classroom_error(exc) from exc

    @app.post("/api/v2/teacher/checkpoints/{slot}/load")
    async def load_teacher_checkpoint(slot: int, payload: TeacherUI) -> dict[str, Any]:
        try:
            return core.database.restore_teacher_checkpoint(classroom_save_id(True), slot,
                                                            payload.revision, payload.model_dump())
        except (KeyError, ValueError) as exc:
            raise classroom_error(exc) from exc

    @app.post("/api/v2/teacher/new")
    async def new_classroom(payload: TeacherUI) -> dict[str, Any]:
        try:
            return core.database.restore_teacher_checkpoint(classroom_save_id(True), None,
                                                            payload.revision, payload.model_dump())
        except ValueError as exc:
            raise classroom_error(exc) from exc

    @app.delete("/api/v2/teacher/checkpoints/{slot}")
    async def delete_teacher_checkpoint(slot: int) -> dict[str, bool]:
        try:
            core.database.delete_teacher_checkpoint(slot)
            return {"ok": True}
        except (KeyError, ValueError) as exc:
            raise classroom_error(exc) from exc

    @app.post("/api/v2/teacher/stop")
    async def stop_classroom() -> dict[str, bool]:
        save_id = classroom_save_id()
        session = core.teacher_sessions.get(save_id)
        if session is not None and not session[0].done():
            task, closed = session
            task.cancel()
            try:
                await asyncio.wait_for(closed.wait(), timeout=5.0)
            except TimeoutError as exc:
                raise HTTPException(409, "回答正在停止，请稍后重试") from exc
        return {"ok": True}

    @app.patch("/api/v2/saves/{save_id}")
    async def update_save(save_id: str, payload: SavePatch) -> dict[str, Any]:
        try:
            if payload.identity_mode == "self":
                story = core.story.get(save_id)
                if story and story["active"]:
                    raise ValueError("剧情进行中不能切换为玩家本人身份")
            return core.database.update_save(save_id, payload.model_dump(exclude_unset=True))
        except KeyError as exc:
            raise HTTPException(404, str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc

    @app.get("/api/v2/saves/{save_id}/messages")
    async def messages(save_id: str, limit: int = 100) -> list[dict[str, Any]]:
        try:
            if core.database.get_save(save_id).get('module') == 'teacher':
                return core.database.classroom_messages(save_id, None if limit <= 0 else limit)
            return core.database.messages(save_id, None if limit <= 0 else limit)
        except KeyError as exc:
            raise HTTPException(404, str(exc)) from exc

    @app.get("/api/v2/saves/{save_id}/story")
    async def story_state(save_id: str) -> dict[str, Any]:
        try:
            return {"story": core.story.get(save_id)}
        except KeyError as exc:
            raise HTTPException(404, str(exc)) from exc

    @app.post("/api/v2/saves/{save_id}/story/start")
    async def start_story(save_id: str, payload: StoryStart) -> dict[str, Any]:
        try:
            return {"story": core.story.start(save_id, payload.restart)}
        except KeyError as exc:
            raise HTTPException(404, str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc

    @app.get("/api/v2/saves/{save_id}/memories")
    async def memories(save_id: str) -> list[dict[str, Any]]:
        try:
            core.database.get_save(save_id)
            return core.database.memories(save_id)
        except KeyError as exc:
            raise HTTPException(404, str(exc)) from exc

    @app.patch("/api/v2/memories/{memory_id}")
    async def patch_memory(memory_id: str, payload: MemoryPatch) -> dict[str, Any]:
        try:
            return core.database.update_memory(memory_id, payload.content, payload.status)
        except (KeyError, ValueError) as exc:
            raise HTTPException(404 if isinstance(exc, KeyError) else 400, str(exc)) from exc

    @app.delete("/api/v2/memories/{memory_id}")
    async def delete_memory(memory_id: str) -> dict[str, Any]:
        try:
            return core.database.update_memory(memory_id, status="deleted")
        except KeyError as exc:
            raise HTTPException(404, str(exc)) from exc

    @app.get("/api/v2/audio/{key}")
    async def audio(key: str) -> FileResponse:
        path = core.audio_dir / f"{key}.wav"
        if not path.exists():
            raise HTTPException(404, "audio not found")
        return FileResponse(path, media_type="audio/wav")

    @app.post("/api/v2/park/speech")
    async def park_speech(payload: ParkSpeech) -> dict[str, Any]:
        # Fixed staging lines use the existing profiles/cache without creating a chat turn.
        if payload.speaker_id not in {"arcueid", "ciel"}:
            raise HTTPException(400, "公园语音仅支持当前两位角色")
        speech_text = payload.tts_text.strip()
        if not speech_text:
            try:
                speech_text = await translate_to_japanese(
                    core.character_settings(payload.speaker_id), payload.text,
                    client=core.llm_client, speaker_id=payload.speaker_id,
                )
            except Exception:
                return {"voice_available": False, "speaker_id": payload.speaker_id, "reason": "translation_failed"}
        if not speech_text:
            return {"voice_available": False, "speaker_id": payload.speaker_id, "reason": "translation_failed"}
        synthesis = await core.synthesize(speech_text, payload.request_id, 0, VOICE_MODELS[payload.speaker_id])
        if not synthesis.key:
            return {"voice_available": False, "speaker_id": payload.speaker_id, "reason": "synthesis_failed"}
        return {"voice_available": True, "speaker_id": payload.speaker_id,
                "audio_path": f"/api/v2/audio/{synthesis.key}", "tts_text": speech_text}

    @app.post('/api/v2/park/speech/group')
    async def park_speech_group(payload: ParkSpeechGroup) -> dict[str,Any]:
        from .park_audio import simultaneous_wav
        if {line.speaker_id for line in payload.lines}!={'arcueid','ciel'}:
            raise HTTPException(400,'simultaneous interruption requires both current NPCs')
        async def synthesize_line(index, line):
            speech=line.tts_text.strip()
            if not speech:
                speech=await translate_to_japanese(core.character_settings(line.speaker_id),line.text,
                    client=core.llm_client,speaker_id=line.speaker_id)
            return await core.synthesize(speech,payload.request_id,index,VOICE_MODELS[line.speaker_id]) if speech else None
        try:
            results=await asyncio.gather(*(synthesize_line(i,line) for i,line in enumerate(payload.lines)))
            if any(not result or not result.key for result in results): return {'voice_available':False}
            key=hashlib.sha256(('simultaneous-v1:'+':'.join(result.key for result in results)).encode()).hexdigest()
            target=core.audio_dir/(key+'.wav')
            if not target.exists():
                audio=simultaneous_wav([(core.audio_dir/(result.key+'.wav')).read_bytes() for result in results])
                target.write_bytes(audio)
            return {'voice_available':True,'audio_path':f'/api/v2/audio/{key}','speaker_id':'both'}
        except Exception:
            return {'voice_available':False,'reason':'group_synthesis_failed'}

    @app.post("/api/v2/park/session/prepare")
    async def park_prepare(payload: ParkPrepare) -> dict[str,Any]:
        cues=park_dialogue.load_cues()
        if payload.cue_id not in cues: raise HTTPException(400,'unknown park cue')
        cue=cues[payload.cue_id]
        store=core.park_sessions
        async with store.prepare_lock:
            session=None
            parent=None
            cached_id=store.prepare_requests.get(payload.request_id)
            try:
                if cached_id:
                    session=store.get(cached_id)
                    if session['cue_id']!=payload.cue_id: raise HTTPException(409,'prepare id belongs to another cue')
                elif payload.session_id and not payload.rehearsal:
                    session=store.get(payload.session_id)
                    if session['cue_id']!=payload.cue_id: raise HTTPException(409,'session belongs to another cue')
                    if payload.discard_pending: store.cancel(session)
                elif payload.previous_session_id and not payload.rehearsal:
                    parent=store.get(payload.previous_session_id)
                    if parent['next_cue_id']!=payload.cue_id or parent['pending']:
                        raise HTTPException(409,'next cue has not been committed')
                    if parent.get('child_id'): session=store.get(parent['child_id'])
            except KeyError as exc: raise HTTPException(404,str(exc)) from exc
            if session is None:
                history=parent['history'][:] if parent else [{key:str(row[key])[:1200 if key=='tts_text' else 600 if key in {'content','semantic'} else 24] for key in ('role','content','speaker_id','mood','expression','semantic','tts_text') if key in row} for row in payload.history if row.get('role') in {'user','assistant'}]
                decisions=parent['decisions'] if parent else {k:v for k,v in payload.decisions.items() if k in {'D1','D2','D3'}}
                state=parent['state'] if parent else {}
                _,opening=park_dialogue.scene_view(cue,decisions)
                for unit in opening:
                    if unit['speaker'] in {'arcueid','ciel'} and not any(row.get('role')=='assistant' and row.get('content')==unit['text'] for row in history[-8:]):
                        history.append({'role':'assistant','speaker_id':unit['speaker'],'content':unit['text'],
                            'mood':unit.get('mood','neutral'),'expression':unit.get('expression','neutral'),'source':'fixed','tts_text':unit.get('tts_text','')})
                session=store.new(payload.cue_id,history,decisions,state,park_dialogue.preparation_fingerprint(cue,cues),parent['id'] if parent else '')
                if parent:
                    parent['child_id']=session['id']; store.write(parent)
            store.prepare_requests[payload.request_id]=session['id']
            fingerprint=park_dialogue.preparation_fingerprint(cue,cues)
            if session.get('fingerprint')!=fingerprint:
                session['prepared']=False; session['fingerprint']=fingerprint
                if park_dialogue.scripted_scene(cue): session['opening_logged']=False
            reused=bool(session['prepared'])
            if not reused:
                if park_dialogue.scripted_scene(cue):
                    session['plan']={'prepared_by':'scripted','lead':cue['conversation']['lead']}
                else:
                    try:
                        plan_reply=await complete(core.character_settings(cue['conversation']['lead']),
                            park_dialogue.prepare_messages(cue,session['history'],session['state'],cues,session['decisions']),client=core.llm_client)
                        session['plan']=park_dialogue.clean_plan(cue,plan_reply.reply)
                    except Exception: session['plan']=park_dialogue.clean_plan(cue,'')
                session['prepared']=True; store.write(session)
            return {'request_id':payload.request_id,'cue_id':payload.cue_id,'session_id':session['id'],
                    'revision':session['revision'],'ready':True,'reused':reused,
                    'prepared_by':session['plan']['prepared_by'],'state':session['state'],
                    'history':session['history'],
                    'opening_logged':session.get('opening_logged',False),
                    'progress':park_dialogue.progress_info(cue,satisfied=bool(session.get('goal_status',{}).get('satisfied')),exchanges=session['revision']),
                    'decisions':session['decisions'],'next_cue_id':session['next_cue_id'],'ended':session['ended']}

    @app.get('/api/v2/park/session/{session_id}/history')
    async def park_history(session_id: str) -> dict[str,Any]:
        try: entries,partial=core.park_sessions.transcript(session_id)
        except KeyError as exc: raise HTTPException(404,str(exc)) from exc
        return {'entries':entries,'partial_legacy':partial}

    @app.post('/api/v2/park/session/{session_id}/opening')
    async def park_opening(session_id: str) -> dict[str,bool]:
        try: session=core.park_sessions.get(session_id)
        except KeyError as exc: raise HTTPException(404,str(exc)) from exc
        cue=park_dialogue.load_cues()[session['cue_id']]
        _,units=park_dialogue.scene_view(cue,session['decisions'])
        core.park_sessions.log_opening(session,units)
        return {'logged':True}

    @app.post("/api/v2/park/session/{session_id}/commit")
    async def park_commit(session_id: str, payload: ParkCommit) -> dict[str,Any]:
        try:
            session=core.park_sessions.get(session_id)
            async with core.park_sessions.lock(session_id):
                return core.park_sessions.commit(session,payload.request_id,payload.revision)
        except KeyError as exc: raise HTTPException(404,str(exc)) from exc
        except ValueError as exc: raise HTTPException(409,str(exc)) from exc

    @app.post("/api/v2/park/session/{session_id}/cancel")
    async def park_cancel(session_id: str, payload: dict[str,str]) -> dict[str,bool]:
        try: session=core.park_sessions.get(session_id)
        except KeyError as exc: raise HTTPException(404,str(exc)) from exc
        core.park_sessions.cancel(session,str(payload.get('request_id','')))
        return {'cancelled':True}

    @app.post('/api/v2/park/session/{session_id}/script/complete')
    async def park_script_complete(session_id: str, payload: ParkCommit) -> dict[str,Any]:
        try:
            session=core.park_sessions.get(session_id)
            cues=park_dialogue.load_cues(); cue=cues[session['cue_id']]
            if not park_dialogue.scripted_scene(cue): raise HTTPException(400,'scene is not an automatic script')
            async with core.park_sessions.lock(session_id):
                if session['fingerprint']!=park_dialogue.preparation_fingerprint(cue,cues):
                    raise ValueError('script source changed; prepare again')
                return core.park_sessions.complete_script(session,payload.request_id,payload.revision,cue['conversation']['next_cue_id'])
        except KeyError as exc: raise HTTPException(404,str(exc)) from exc
        except ValueError as exc: raise HTTPException(409,str(exc)) from exc

    async def park_session_turn(payload: ParkTurn) -> dict[str,Any]:
        store=core.park_sessions
        try: session=store.get(payload.session_id)
        except KeyError as exc: raise HTTPException(404,str(exc)) from exc
        async with store.lock(session['id']):
            if payload.revision!=session['revision']: raise HTTPException(409,'stale scene revision')
            if session['ended'] or session['next_cue_id']: raise HTTPException(409,'scene already completed')
            if session.get('last_commit') and session['last_commit']['request_id']==payload.request_id:
                raise HTTPException(409,'request already committed')
            pending=session.get('pending')
            if pending:
                if pending['request_id']==payload.request_id and pending['message']==payload.message: return pending['result']
                raise HTTPException(409,'scene turn awaits playback commit')
            cues=park_dialogue.load_cues(); cue=cues[session['cue_id']]
            if park_dialogue.scripted_scene(cue): raise HTTPException(409,'automatic script does not accept player dialogue')
            if session['fingerprint']!=park_dialogue.preparation_fingerprint(cue,cues) or not session['prepared']:
                raise HTTPException(409,'scene needs preparation')
            generation=session.get('generation',0)
            session['active_request']=payload.request_id; store.write(session)
            repaired=False
            continuity_repaired=False
            pacing_repaired=False
            exchange_repaired=False
            try:
                reply=await complete(core.character_settings(cue['conversation']['lead']),
                    park_dialogue.director_messages(cue,cues,payload.message,session),client=core.llm_client)
                if generation!=session.get('generation',0):
                    return {'request_id':payload.request_id,'cue_id':session['cue_id'],'available':False,'reason':'scene_turn_cancelled'}
                if park_dialogue.needs_pacing_review(cue,session,reply):
                    reply=await complete(core.character_settings(cue['conversation']['lead']),
                        park_dialogue.pacing_repair_messages(cue,cues,payload.message,session,reply),client=core.llm_client)
                    pacing_repaired=True
                    if generation!=session.get('generation',0):
                        return {'request_id':payload.request_id,'cue_id':session['cue_id'],'available':False,'reason':'scene_turn_cancelled'}
                # Repairs may introduce another boundary error: validate the final
                # candidate again, with one rewrite budget for each error type.
                for _check in range(3):
                    issues=park_dialogue.npc_exchange_issues(cue,reply)
                    premature=park_dialogue.premature_fixed_text(cue,cues,session['decisions'],reply)
                    if issues and not exchange_repaired:
                        repair_messages=park_dialogue.exchange_repair_messages(cue,cues,payload.message,session,reply,issues)
                        exchange_repaired=True
                    elif premature and not continuity_repaired:
                        repair_messages=park_dialogue.continuity_repair_messages(cue,cues,payload.message,session)
                        continuity_repaired=True
                    else:
                        if issues: raise ValueError('incomplete NPC exchange')
                        if premature: raise ValueError('premature fixed text')
                        break
                    reply=await complete(core.character_settings(cue['conversation']['lead']),repair_messages,client=core.llm_client)
                    if generation!=session.get('generation',0):
                        return {'request_id':payload.request_id,'cue_id':session['cue_id'],'available':False,'reason':'scene_turn_cancelled'}
                try:
                    segments,proposal,action,notes=park_dialogue.directed_turn(cue,payload.message,reply)
                    needs_repair=proposal.get('park_certainty') in {'explicit','contextual'} and bool(proposal.get('park_action')) and not action
                except ValueError as error:
                    if str(error) not in {'missing semantic result','conflicting semantic results'} or not reply.segments: raise
                    needs_repair=True
                if needs_repair:
                    repair=await complete(core.character_settings(cue['conversation']['lead']),
                        park_dialogue.intent_repair_messages(cue,cues,payload.message,session),client=core.llm_client)
                    state=next((s.conversation_state for s in repair.segments if s.conversation_state.get('park_dialogue_act') in park_dialogue.SEMANTIC_ACTS),{})
                    semantic_keys=park_dialogue.SEMANTIC_KEYS
                    for segment in reply.segments:
                        for key in semantic_keys: segment.conversation_state.pop(key,None)
                    reply.segments[0].conversation_state.update({k:state[k] for k in semantic_keys if k in state})
                    segments,proposal,action,notes=park_dialogue.directed_turn(cue,payload.message,reply)
                    repaired=True
            except Exception as exc:
                session['active_request']=''; store.write(session)
                known={'invalid segment count','speaker outside scene','missing speaker','too many speaker turns','invalid dialogue length','conflicting semantic results','missing semantic result','premature fixed text','incomplete NPC exchange'}
                return {'request_id':payload.request_id,'cue_id':session['cue_id'],'available':False,'reason':'scene_generation_failed',
                        'validation':str(exc) if isinstance(exc,ValueError) and str(exc) in known else 'generation unavailable',
                        'exchange_diagnostics':{'issues':park_dialogue.npc_exchange_issues(cue,reply),
                            'routes':[{'speaker':s.speaker_id,'expects':s.conversation_state.get('park_expects_response',''),
                                       'response_to':s.conversation_state.get('park_response_to','')} for s in reply.segments]}
                            if isinstance(exc,ValueError) and str(exc)=='incomplete NPC exchange' else {}}
            if generation!=session.get('generation',0):
                return {'request_id':payload.request_id,'cue_id':session['cue_id'],'available':False,'reason':'scene_turn_cancelled'}
            goal=dict(session.get('goal_status',{'satisfied':False,'evidence':''}))
            if park_dialogue.goal_satisfied(cue,payload.message,proposal):
                goal={'satisfied':True,'evidence':proposal.get('park_evidence','')[:300]}
            result={'request_id':payload.request_id,'cue_id':session['cue_id'],'session_id':session['id'],
                'revision':session['revision'],'available':True,'segments':segments,**segments[0],
                'intent':{'source':'model_semantic','dialogue_act':proposal['park_dialogue_act'],
                          'certainty':proposal['park_certainty'],'evidence':proposal.get('park_evidence',''),'accepted':bool(action),'repaired':repaired,
                          'continuity_repaired':continuity_repaired,
                          'pacing_repaired':pacing_repaired,
                          'exchange_repaired':exchange_repaired,
                          'beat_status':proposal.get('park_beat_status',''),
                          'goal_status':proposal.get('park_goal_status',''),
                          'proposed_action':proposal.get('park_action','')},
                'action':action,'branch_id':cue['conversation']['branch_id'] if action and action!='leave' else '',
                'progress':park_dialogue.progress_info(cue,proposal,action,satisfied=goal['satisfied'],exchanges=session['revision']+1),
                'outro':cue.get('script_outro',[]) if action and action!='leave' else [],
                'next_cue_id':cue['conversation']['next_cue_id'] if action and action!='leave' else '',
                'ending':'leave' if action=='leave' else 'complete' if action and not cue['conversation']['next_cue_id'] else ''}
            state={**session['state'],**notes}
            result['branch_id']=park_dialogue.branch_for_action(cue,action)
            session['active_request']=''
            session['pending']={'request_id':payload.request_id,'message':payload.message,'result':result,'state':state,'goal_status':goal}
            store.write(session)
            return result

    @app.post("/api/v2/park/dialogue")
    async def park_turn(payload: ParkTurn) -> dict[str, Any]:
        if payload.session_id:
            return await park_session_turn(payload)
        cues = park_dialogue.load_cues()
        if payload.cue_id not in cues:
            raise HTTPException(400, "unknown park cue")
        cue = cues[payload.cue_id]
        if park_dialogue.scripted_scene(cue): raise HTTPException(409,'automatic script does not accept player dialogue')
        actor = park_dialogue.select_actor(cue, payload.message)
        # Client-local rehearsal context; never creates a normal chat/save/RAG turn.
        decisions = {k: {"choice": str(v.get("choice", ""))[:24], "text": str(v.get("text", ""))[:300]}
                     for k, v in payload.decisions.items() if k in {"D1", "D2", "D3"}}
        try:
            reply = await complete(core.character_settings(actor),
                park_dialogue.messages(cue, cues, payload.message, payload.history, decisions), client=core.llm_client)
        except Exception:
            return {"request_id": payload.request_id, "cue_id": payload.cue_id, "available": False}
        if park_dialogue.premature_fixed_text(cue,cues,decisions,reply):
            return {"request_id":payload.request_id,"cue_id":payload.cue_id,"available":False,"reason":"premature_fixed_text"}
        if not reply.reply.strip() or reply.reply == unavailable_reply().reply:
            return {"request_id": payload.request_id, "cue_id": payload.cue_id, "available": False}
        segment = reply.segments[0] if reply.segments else None
        if segment and segment.speaker_id not in {'', actor}:
            return {"request_id": payload.request_id, "cue_id": payload.cue_id, "available": False}
        proposal = segment.conversation_state if segment else {}
        if proposal.get('park_dialogue_act') not in park_dialogue.SEMANTIC_ACTS or proposal.get('park_certainty') not in {'explicit','contextual','unclear'}:
            return {"request_id": payload.request_id, "cue_id": payload.cue_id, "available": False, "reason": "invalid_semantic_result"}
        action = park_dialogue.decide(cue, payload.message, proposal)
        text = park_dialogue.clean_reply(segment.reply if segment else reply.reply, actor)
        if not text:
            return {"request_id": payload.request_id, "cue_id": payload.cue_id, "available": False}
        mood = segment.mood if segment else reply.mood
        if mood not in park_dialogue.MOODS:
            mood = 'neutral'
        return {"request_id": payload.request_id, "cue_id": payload.cue_id,
                "available": True, "speaker_id": actor, "reply": text,
                "tts_text": segment.tts_text if segment else reply.tts_text,
                "mood": mood,
                "intent": {"source": "model_semantic", "dialogue_act": str(proposal.get('park_dialogue_act', ''))[:24],
                           "beat_status": str(proposal.get('park_beat_status', ''))[:16],
                           "goal_status": str(proposal.get('park_goal_status', ''))[:16],
                           "certainty": str(proposal.get('park_certainty', ''))[:16],
                           "evidence": str(proposal.get('park_evidence', ''))[:300], "accepted": bool(action),
                           "validation": 'accepted' if action else 'rejected_action_or_evidence' if proposal.get('park_action') else 'stay'},
                "expression": segment.expression if segment else reply.expression, "action": action,
                "branch_id": park_dialogue.branch_for_action(cue,action),
                "outro": cue.get('script_outro',[]) if action and action != 'leave' else [],
                "progress": park_dialogue.progress_info(cue,proposal,action),
                "next_cue_id": cue['conversation']['next_cue_id'] if action and action != 'leave' else '',
                "ending": 'leave' if action == 'leave' else 'complete' if action and not cue['conversation']['next_cue_id'] else ''}

    @app.websocket("/api/v2/park/voice")
    async def park_voice(socket: WebSocket) -> None:
        """Use the classroom's PCM event protocol without a chat/database turn."""
        await socket.accept()
        base: dict[str, Any] = {}
        try:
            payload = ParkSpeech.model_validate(await socket.receive_json())
            if payload.speaker_id not in {'arcueid', 'ciel'}:
                await socket.send_json({'type': 'tts.failed', 'request_id': payload.request_id, 'segment_index': 0})
                return
            base = {'request_id': payload.request_id, 'segment_index': 0, 'speaker_id': payload.speaker_id}
            started = perf_counter()
            speech_text = payload.tts_text.strip()
            if not speech_text:
                speech_text = await translate_to_japanese(core.character_settings(payload.speaker_id), payload.text,
                    client=core.llm_client, speaker_id=payload.speaker_id)
            repair_ms = _ms(perf_counter() - started)
            if not speech_text:
                await socket.send_json({**base, 'type': 'tts.failed'})
                return
            decoder = WavPcmDecoder()
            announced = False
            sequence = 0
            queue_started = perf_counter()
            try:
                async with core.tts_slots:
                    queue_ms = _ms(perf_counter() - queue_started)
                    async with core.voice_client.stream('POST', f'{core.settings.voice_url}/api/tts/stream',
                            json={'text': speech_text, 'model_id': VOICE_MODELS[payload.speaker_id],
                                  'request_id': payload.request_id, 'segment_index': 0, 'bypass_cache': payload.bypass_cache}) as response:
                        response.raise_for_status()
                        async for chunk in response.aiter_bytes():
                            pcm = decoder.feed(chunk)
                            if not pcm:
                                continue
                            if not announced:
                                timing = {'translation_repair_ms': repair_ms, 'tts_queue_wait_ms': queue_ms,
                                          'first_pcm_ms': _ms(perf_counter() - started),
                                          'proxy_cache': response.headers.get('x-arcueid-cache', '')}
                                await socket.send_json({**base, 'type': 'tts.stream.started',
                                    'sample_rate': decoder.sample_rate, 'channels': decoder.channels,
                                    'format': 'pcm_s16le', 'timing': timing})
                                announced = True
                            for offset in range(0, len(pcm), 16384):
                                await socket.send_json({**base, 'type': 'tts.stream.chunk', 'sequence': sequence,
                                    'pcm': base64.b64encode(pcm[offset:offset+16384]).decode('ascii')})
                                sequence += 1
                        decoder.finish()
                await socket.send_json({**base, 'type': 'tts.stream.completed', 'chunks': sequence,
                    'frames': decoder.total_bytes // (decoder.channels * 2), 'failed': False,
                    'timing': {'total_ms': _ms(perf_counter() - started)}})
            except WebSocketDisconnect:
                return
            except Exception:
                if announced:
                    await socket.send_json({**base, 'type': 'tts.stream.completed', 'chunks': sequence,
                        'frames': decoder.total_bytes // (decoder.channels * 2), 'failed': True})
                else:
                    synthesis = await core.synthesize(speech_text, payload.request_id, 0, VOICE_MODELS[payload.speaker_id])
                    await socket.send_json({**base, 'type': 'tts.ready', 'audio_path': f'/api/v2/audio/{synthesis.key}'}
                        if synthesis.key else {**base, 'type': 'tts.failed'})
        except WebSocketDisconnect:
            pass
        except Exception:
            with suppress(Exception):
                await socket.send_json({**base, 'type': 'tts.failed'})
        finally:
            with suppress(Exception):
                await socket.close()

    @app.post("/api/retrieve")
    async def retrieve_legacy(payload: dict[str, Any]) -> dict[str, Any]:
        query = str(payload.get("query", "")).strip()
        rows = core.index.search(query, "style", int(payload.get("top_k", 5))).rows
        if not rows:
            rows = core.index.search(query, "canon", int(payload.get("top_k", 5))).rows
        return {"query": query, "hits": rows}

    @app.post("/api/chat")
    async def chat_legacy(payload: LegacyChat) -> dict[str, Any]:
        saves = core.database.list_saves()
        save = saves[0] if saves else core.database.create_save("Arcueid Stage", "self", "")
        turn_id = str(uuid.uuid4())
        reply, canon, style, _updates = await core.respond(save["id"], payload.message, turn_id)
        return {"reply": reply.reply, "tts_text": reply.tts_text, "display_seconds": max(4, min(12, len(reply.reply) // 6 + 4)), "is_speaking": True, "animation_hint": "talk", "mood_hint": reply.mood, "interrupt_policy": "replace_current", "retrieval_hits": style or canon, "messages": []}

    @app.websocket("/api/v2/chat")
    async def chat_socket(socket: WebSocket) -> None:
        await socket.accept()
        send_lock = asyncio.Lock()
        audio_queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
        publish_queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
        worker_count = 1

        async def send_event(event: dict[str, Any]) -> None:
            async with send_lock:
                await socket.send_json(event)

        async def stream_audio(job: dict[str, Any], speech_text: str, translation_ms: float) -> bool:
            """Return False only when no PCM was sent, allowing the WAV fallback."""
            started = perf_counter()
            decoder = WavPcmDecoder()
            announced = False
            sequence = 0
            base = {key: job[key] for key in ("request_id", "speaker_id", "segment_index", "reply", "mood", "expression")}
            try:
                async with core.tts_slots:
                    async with core.voice_client.stream(
                        "POST", f"{core.settings.voice_url}/api/tts/stream",
                        json={"text": speech_text, "request_id": job["request_id"],
                              "segment_index": job["segment_index"],
                              "model_id": VOICE_MODELS[job["speaker_id"]]},
                    ) as response:
                        response.raise_for_status()
                        async for chunk in response.aiter_bytes():
                            pcm = decoder.feed(chunk)
                            if not pcm:
                                continue
                            if not announced:
                                timing = {**job["timing"], "translation_repair_ms": translation_ms,
                                          "stream_first_pcm_ms": _ms(perf_counter() - started),
                                          "core_elapsed_ms": _ms(perf_counter() - job["turn_started"])}
                                await send_event({**base, "type": "tts.stream.started", "sample_rate": decoder.sample_rate,
                                                  "channels": decoder.channels, "format": "pcm_s16le", "timing": timing})
                                core.latency.record("tts.stream_first_pcm", job["request_id"], segment_index=job["segment_index"], **timing)
                                announced = True
                            # Bound each WebSocket packet and preserve complete PCM frames.
                            for offset in range(0, len(pcm), 16384):
                                await send_event({"type": "tts.stream.chunk", "request_id": job["request_id"],
                                                  "speaker_id": job["speaker_id"], "segment_index": job["segment_index"],
                                                  "sequence": sequence, "pcm": base64.b64encode(pcm[offset:offset + 16384]).decode("ascii")})
                                sequence += 1
                        decoder.finish()
                event = {**base, "type": "tts.stream.completed", "frames": decoder.total_bytes // (decoder.channels * 2),
                         "chunks": sequence, "failed": False,
                         "timing": {"stream_total_ms": _ms(perf_counter() - started)}}
            except (httpx.HTTPError, ValueError) as exc:
                core.latency.record("tts.stream_failed", job["request_id"], segment_index=job["segment_index"],
                                    pcm_started=announced, error=type(exc).__name__)
                if not announced:
                    return False
                event = {**base, "type": "tts.stream.completed", "failed": True, "chunks": sequence,
                         "frames": decoder.total_bytes // (decoder.channels * 2), "reason": "stream_interrupted"}
            await publish_queue.put({"kind": "segment", "event": event})
            return True

        async def audio_worker() -> None:
            while True:
                job = await audio_queue.get()
                if job is None:
                    audio_queue.task_done()
                    return
                if job["kind"] == "turn_end":
                    await publish_queue.put(job)
                    audio_queue.task_done()
                    continue
                request_id = job["request_id"]
                segment_index = job["segment_index"]
                queue_wait_ms = _ms(perf_counter() - job["queued_at"])
                await send_event({
                    "type": "tts.started",
                    "request_id": request_id,
                    "speaker_id": job["speaker_id"],
                    "segment_index": segment_index,
                    "timing": {"tts_queue_wait_ms": queue_wait_ms},
                })
                await asyncio.sleep(0)
                tts_started = perf_counter()
                translation_ms = 0.0
                speech_text = job["text"]
                if not speech_text:
                    translation_started = perf_counter()
                    translation_kwargs: dict[str, Any] = {"client": core.llm_client}
                    if job["speaker_id"] in {"neco_arc", "ciel"}:
                        translation_kwargs["speaker_id"] = job["speaker_id"]
                    speech_text = await translate_to_japanese(
                        core.character_settings(job["speaker_id"]),
                        job["reply"],
                        **translation_kwargs,
                    )
                    translation_ms = _ms(perf_counter() - translation_started)
                if speech_text and job.get("audio_streaming") and await stream_audio(job, speech_text, translation_ms):
                    audio_queue.task_done()
                    continue
                if not speech_text:
                    synthesis = SynthesisResult(None, False, 0.0, 0.0)
                elif job["speaker_id"] in {"neco_arc", "ciel"}:
                    synthesis = await core.synthesize(speech_text, request_id, segment_index, VOICE_MODELS[job["speaker_id"]])
                else:
                    synthesis = await core.synthesize(speech_text, request_id, segment_index)
                # Keep patched/third-party Core.synthesize implementations source-compatible.
                if isinstance(synthesis, SynthesisResult):
                    audio_key = synthesis.key
                    synthesis_timing = {
                        "core_audio_cache_hit": synthesis.cache_hit and synthesis.proxy_http_ms == 0.0,
                        "proxy_audio_cache_hit": synthesis.cache_hit and synthesis.proxy_http_ms > 0.0,
                        "tts_slot_wait_ms": synthesis.slot_wait_ms,
                        "proxy_http_ms": synthesis.proxy_http_ms,
                        "proxy_total_ms": synthesis.proxy_total_ms,
                        "gpt_sovits_ms": synthesis.gpt_sovits_ms,
                    }
                else:
                    audio_key = synthesis
                    synthesis_timing = {}
                timing = {
                    **job["timing"],
                    "tts_queue_wait_ms": queue_wait_ms,
                    "translation_repair_ms": translation_ms,
                    **synthesis_timing,
                    "tts_worker_total_ms": _ms(perf_counter() - tts_started),
                    "core_elapsed_ms": _ms(perf_counter() - job["turn_started"]),
                }
                if audio_key:
                    event = {
                        "type": "tts.ready",
                        "request_id": request_id,
                        "speaker_id": job["speaker_id"],
                        "segment_index": segment_index,
                        "audio_url": f"/api/v2/audio/{audio_key}",
                        "reply": job["reply"],
                        "mood": job["mood"],
                        "expression": job["expression"],
                        "tts_text": speech_text,
                        "timing": timing,
                    }
                else:
                    event = {
                        "type": "tts.failed",
                        "request_id": request_id,
                        "speaker_id": job["speaker_id"],
                        "segment_index": segment_index,
                        "reply": job["reply"],
                        "mood": job["mood"],
                        "expression": job["expression"],
                        "reason": "translation_failed" if not speech_text else "synthesis_failed",
                        "timing": timing,
                    }
                core.latency.record(
                    "tts.ready" if audio_key else "tts.unavailable",
                    request_id,
                    segment_index=segment_index,
                    **timing,
                )
                await publish_queue.put({"kind": "segment", "event": event})
                audio_queue.task_done()

        async def ordered_publisher() -> None:
            next_indices: dict[str, int] = {}
            buffers: dict[str, dict[int, dict[str, Any]]] = {}
            totals: dict[str, int] = {}
            while True:
                item = await publish_queue.get()
                if item is None:
                    return
                request_id = item["request_id"] if item["kind"] == "turn_end" else item["event"]["request_id"]
                if item["kind"] == "turn_end":
                    totals[request_id] = item["total"]
                else:
                    event = item["event"]
                    buffers.setdefault(request_id, {})[event["segment_index"]] = event

                next_index = next_indices.get(request_id, 0)
                request_buffer = buffers.setdefault(request_id, {})
                while next_index in request_buffer:
                    await send_event(request_buffer.pop(next_index))
                    next_index += 1
                next_indices[request_id] = next_index

                if request_id in totals and next_index >= totals[request_id]:
                    await send_event({"type": "tts.completed", "request_id": request_id})
                    next_indices.pop(request_id, None)
                    buffers.pop(request_id, None)
                    totals.pop(request_id, None)

        worker_tasks = [asyncio.create_task(audio_worker()) for _ in range(worker_count)]
        publisher_task = asyncio.create_task(ordered_publisher())
        session_task = asyncio.current_task()
        session_closed = asyncio.Event()
        pending_teacher_turn: tuple[str, str] | None = None
        try:
            while True:
                request = await socket.receive_json()
                turn_started = perf_counter()
                if request.get("type") != "chat.send":
                    await send_event({"type": "turn.error", "error": "unsupported message"})
                    continue
                request_id = str(request.get("request_id") or uuid.uuid4())
                save_id, message = str(request.get("save_id", "")), str(request.get("message", "")).strip()
                speaker_id = str(request.get("speaker_id") or "arcueid")
                if not message:
                    await send_event({"type": "turn.error", "request_id": request_id, "error": "message is required"})
                    continue
                if speaker_id not in {"arcueid", "ciel", "neco_arc", "auto"}:
                    await send_event({"type": "turn.error", "request_id": request_id, "error": "unknown speaker_id"})
                    continue
                story_scene: dict[str, Any] | None = None
                story_after: dict[str, Any] | None = None
                story_intent: str | None = None
                try:
                    turn_save = core.database.get_save(save_id)
                    if not request.get("speaker_id") and turn_save.get("module") == "teacher":
                        speaker_id = "auto"
                    if speaker_id in {"neco_arc", "auto"} and not ((turn_save.get("module") == "teacher" or turn_save["name"] == TEACHER_SAVE_NAME) and turn_save["identity_mode"] == "self"):
                        raise ValueError("automatic addressing and Neco-Arc are only available in the classroom")
                    active_story = core.story.get(save_id)
                    if core.story.was_processed(save_id, request_id):
                        await send_event({"type": "story.state", "request_id": request_id, "story": active_story})
                        await send_event({"type": "turn.completed", "request_id": request_id, "speaker_id": speaker_id, "audio_pending": False})
                        continue
                    if active_story and active_story["active"]:
                        story_scene, story_after, story_intent, duplicate = core.story.advance(save_id, request_id, speaker_id, message)
                        if duplicate:
                            await send_event({"type": "story.state", "request_id": request_id, "story": story_after})
                            await send_event({"type": "turn.completed", "request_id": request_id, "speaker_id": speaker_id, "audio_pending": False})
                            continue
                except (KeyError, ValueError) as exc:
                    await send_event({"type": "turn.error", "request_id": request_id, "error": str(exc)})
                    continue
                if turn_save.get("module") == "teacher":
                    if save_id in core.teacher_busy:
                        await send_event({"type": "turn.error", "request_id": request_id, "error": "课堂正在回答，请稍后再试"})
                        continue
                    core.teacher_sessions[save_id] = (session_task, session_closed)
                    core.teacher_busy.add(save_id)
                    pending_teacher_turn = (save_id, request_id)
                accept_ms = _ms(perf_counter() - turn_started)
                await send_event({"type": "turn.accepted", "request_id": request_id, "speaker_id": speaker_id, "timing": {"core_accept_ms": accept_ms}})
                core.latency.record("turn.accepted", request_id)
                segments = []
                voiced_segments = 0
                llm_started = perf_counter()
                try:
                    prompt, canon, style, prepare_timing = core.prepare_response(save_id, message, request_id, speaker_id, story_scene, story_intent)
                    prepare_timing["core_elapsed_ms"] = _ms(perf_counter() - turn_started)
                    await send_event({
                        "type": "retrieval.completed",
                        "request_id": request_id,
                        "canon_count": len(canon),
                        "style_count": len(style),
                        "retrieval_ms": prepare_timing["retrieval_ms"],
                        "timing": prepare_timing,
                    })
                    core.latency.record("retrieval.completed", request_id, **prepare_timing)
                    await asyncio.sleep(0)
                    segments = []
                    voiced_segments = 0
                    llm_started = perf_counter()
                    llm_ttft_ms: float | None = None

                    async def mark_first_token() -> None:
                        nonlocal llm_ttft_ms
                        if llm_ttft_ms is None:
                            llm_ttft_ms = _ms(perf_counter() - llm_started)
                            core.latency.record(
                                "llm.first_token",
                                request_id,
                                llm_ttft_ms=llm_ttft_ms,
                                core_elapsed_ms=_ms(perf_counter() - turn_started),
                            )

                    turn_save = core.database.get_save(save_id)
                    teacher_mode = speaker_id in {"arcueid", "neco_arc", "auto"} and (turn_save.get("module") == "teacher" or turn_save["name"] == TEACHER_SAVE_NAME) and turn_save["identity_mode"] == "self"
                    source = stream_segments(
                        core.character_settings(speaker_id), prompt,
                        on_first_token=mark_first_token, client=core.llm_client,
                    )
                    if teacher_mode:
                        _intent, boundary, target = core.classroom_intents[request_id]
                        source = route_classroom(source, target, {boundary} if boundary else None)
                    async for segment in source:
                        actor_id = segment.speaker_id if teacher_mode else speaker_id
                        story_fallback_segment = story_scene is not None and segment.reply == unavailable_reply().reply
                        if story_fallback_segment:
                            segment = AssistantSegment(fallback_reply(story_scene["node_id"], story_intent), "", "serious", "serious")
                        if not teacher_mode:
                            segment.neco_reply = ""
                            segment.arcueid_reply = ""
                        segment_index = len(segments)
                        segments.append(segment)
                        segment_ready_ms = _ms(perf_counter() - llm_started)
                        segment_timing = {
                            **prepare_timing,
                            "llm_ttft_ms": llm_ttft_ms,
                            "llm_segment_ready_ms": segment_ready_ms,
                            "first_segment_after_ttft_ms": round(segment_ready_ms - llm_ttft_ms, 1) if segment_index == 0 and llm_ttft_ms is not None else None,
                            "core_elapsed_ms": _ms(perf_counter() - turn_started),
                        }
                        await send_event({
                            "type": "assistant.segment.completed",
                            "request_id": request_id,
                            "speaker_id": actor_id,
                            "voice_available": actor_id in VOICE_MODELS and not story_fallback_segment,
                            "segment_index": segment_index,
                            "reply": segment.reply,
                            "tts_text": segment.tts_text,
                            "mood": segment.mood,
                            "expression": segment.expression,
                            "neco_reply": segment.neco_reply,
                            "timing": segment_timing,
                        })
                        core.latency.record("llm.segment_ready", request_id, segment_index=segment_index, **segment_timing)
                        if actor_id in VOICE_MODELS and not story_fallback_segment:
                            voiced_segments += 1
                            await audio_queue.put({
                                "kind": "segment",
                                "request_id": request_id,
                                "speaker_id": actor_id,
                                "segment_index": segment_index,
                                "text": segment.tts_text,
                                "audio_streaming": request.get("audio_streaming") is True,
                                "reply": segment.reply,
                                "mood": segment.mood,
                                "expression": segment.expression,
                                "queued_at": perf_counter(),
                                "turn_started": turn_started,
                                "timing": segment_timing,
                            })
                        await asyncio.sleep(0)
                    reply = combine_segments(segments)
                    if teacher_mode and not segments:
                        raise ValueError("model returned no valid classroom speaker")
                    updates = core.finish_response(save_id, message, request_id, reply, speaker_id, story_scene is not None)
                    pending_teacher_turn = None
                    core.teacher_busy.discard(save_id)
                except Exception as exc:
                    core.classroom_intents.pop(request_id, None)
                    if pending_teacher_turn:
                        core.database.discard_incomplete_teacher_turn(*pending_teacher_turn)
                        pending_teacher_turn = None
                        core.teacher_busy.discard(save_id)
                    if story_scene is None:
                        await send_event({"type": "turn.error", "request_id": request_id, "error": str(exc)})
                        continue
                    try:
                        if segments:
                            reply = combine_segments(segments)
                        else:
                            fallback_text = fallback_reply(story_scene["node_id"], story_intent)
                            reply = AssistantReply(fallback_text, "", "serious", "serious")
                            await send_event({"type": "assistant.segment.completed", "request_id": request_id, "speaker_id": speaker_id, "voice_available": False, "segment_index": 0, "reply": fallback_text, "tts_text": "", "mood": "serious", "expression": "serious"})
                        core.finish_response(save_id, message, request_id, reply, speaker_id, True)
                        updates = []
                    except Exception as recovery_error:
                        await send_event({"type": "turn.error", "request_id": request_id, "error": str(recovery_error)})
                        continue
                llm_total_ms = _ms(perf_counter() - llm_started)
                await send_event({"type": "assistant.text.completed", "request_id": request_id, "speaker_id": speaker_id, "reply": reply.reply, "tts_text": reply.tts_text, "mood": reply.mood, "expression": reply.expression, "timing": {"llm_total_ms": llm_total_ms, "core_elapsed_ms": _ms(perf_counter() - turn_started)}})
                for update in updates:
                    await send_event({"type": "memory.updated", "request_id": request_id, "memory": update})
                await audio_queue.put({"kind": "turn_end", "request_id": request_id, "total": voiced_segments})
                turn_timing = {"llm_total_ms": llm_total_ms, "core_text_total_ms": _ms(perf_counter() - turn_started)}
                await send_event({"type": "turn.completed", "request_id": request_id, "speaker_id": speaker_id, "audio_pending": voiced_segments > 0, "timing": turn_timing})
                if story_after is not None:
                    await send_event({"type": "story.state", "request_id": request_id, "story": story_after, "decision": story_intent})
                core.latency.record("turn.text_completed", request_id, segments=voiced_segments, **turn_timing)
        except (WebSocketDisconnect, asyncio.CancelledError):
            pass
        finally:
            if pending_teacher_turn:
                core.classroom_intents.pop(pending_teacher_turn[1], None)
                core.database.discard_incomplete_teacher_turn(*pending_teacher_turn)
            for teacher_id, (teacher_task, _closed) in list(core.teacher_sessions.items()):
                if teacher_task is session_task:
                    core.teacher_sessions.pop(teacher_id, None)
                    core.teacher_busy.discard(teacher_id)
            for _ in worker_tasks:
                await audio_queue.put(None)
            for worker_task in worker_tasks:
                worker_task.cancel()
                with suppress(asyncio.CancelledError, WebSocketDisconnect, RuntimeError):
                    await worker_task
            publisher_task.cancel()
            with suppress(asyncio.CancelledError, WebSocketDisconnect, RuntimeError):
                await publisher_task
            with suppress(RuntimeError, WebSocketDisconnect):
                await socket.close()
            session_closed.set()

    return app
