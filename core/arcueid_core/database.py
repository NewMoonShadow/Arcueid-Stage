from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .llm import AssistantSegment, recover_speaker_segments


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


class StageDatabase:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA foreign_keys=ON")
        self._create_schema()

    def _create_schema(self) -> None:
        self.connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS saves (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, identity_mode TEXT NOT NULL CHECK(identity_mode IN ('self','shiki')),
              user_name TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
              id TEXT PRIMARY KEY, save_id TEXT NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
              turn_id TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('user','assistant')),
              display_text TEXT NOT NULL, tts_text TEXT NOT NULL DEFAULT '', mood TEXT NOT NULL DEFAULT 'neutral',
              expression TEXT NOT NULL DEFAULT 'neutral', created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_save_created ON messages(save_id, created_at);
            CREATE TABLE IF NOT EXISTS conversation_summaries (
              id TEXT PRIMARY KEY, save_id TEXT NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
              from_message_id TEXT NOT NULL, to_message_id TEXT NOT NULL, summary TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS memories (
              id TEXT PRIMARY KEY, save_id TEXT NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, content TEXT NOT NULL, importance REAL NOT NULL, confidence REAL NOT NULL,
              status TEXT NOT NULL CHECK(status IN ('candidate','active','pinned','deleted')),
              source_message_ids TEXT NOT NULL, embedding BLOB, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
              last_accessed_at TEXT
            );
            CREATE INDEX IF NOT EXISTS memories_save_status ON memories(save_id, status, updated_at);
            CREATE TABLE IF NOT EXISTS story_states (
              save_id TEXT PRIMARY KEY REFERENCES saves(id) ON DELETE CASCADE,
              scene_id TEXT NOT NULL, node_id TEXT NOT NULL, ciel_approach TEXT, arc_appeal TEXT,
              followup_path TEXT, revision INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS story_turns (
              save_id TEXT NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
              request_id TEXT NOT NULL, result_json TEXT NOT NULL,
              PRIMARY KEY (save_id, request_id)
            );
            CREATE TABLE IF NOT EXISTS teacher_progress (
              save_id TEXT PRIMARY KEY REFERENCES saves(id) ON DELETE CASCADE,
              revision INTEGER NOT NULL DEFAULT 0, ui_json TEXT NOT NULL DEFAULT '{}', updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS teacher_checkpoints (
              slot INTEGER PRIMARY KEY CHECK(slot BETWEEN 0 AND 6), name TEXT NOT NULL,
              updated_at TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1,
              save_json TEXT NOT NULL, messages_json TEXT NOT NULL, ui_json TEXT NOT NULL
            );
            """
        )
        columns = {row["name"] for row in self.connection.execute("PRAGMA table_info(messages)")}
        if "speaker_id" not in columns:
            self.connection.execute("ALTER TABLE messages ADD COLUMN speaker_id TEXT")
        if "recipient_id" not in columns:
            self.connection.execute("ALTER TABLE messages ADD COLUMN recipient_id TEXT")
        if "scene_id" not in columns:
            self.connection.execute("ALTER TABLE messages ADD COLUMN scene_id TEXT")
        if "conversation_state" not in columns:
            self.connection.execute("ALTER TABLE messages ADD COLUMN conversation_state TEXT NOT NULL DEFAULT '{}'")
        save_columns = {row["name"] for row in self.connection.execute("PRAGMA table_info(saves)")}
        if "module" not in save_columns:
            self.connection.execute("ALTER TABLE saves ADD COLUMN module TEXT NOT NULL DEFAULT 'stage'")
        self.connection.execute("CREATE UNIQUE INDEX IF NOT EXISTS saves_teacher_module ON saves(module) WHERE module='teacher'")
        self.connection.commit()

    def create_save(self, name: str, identity_mode: str, user_name: str, module: str = "stage") -> dict[str, Any]:
        if identity_mode not in {"self", "shiki"}:
            raise ValueError("identity_mode must be self or shiki")
        if module not in {"stage", "teacher"}:
            raise ValueError("unknown save module")
        save_id, timestamp = str(uuid.uuid4()), now()
        self.connection.execute(
            "INSERT INTO saves (id, name, identity_mode, user_name, created_at, updated_at, module) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (save_id, name.strip() or "新的记录", identity_mode, user_name.strip(), timestamp, timestamp, module),
        )
        self.connection.commit()
        return self.get_save(save_id)

    def ensure_teacher_save(self, name: str) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT id FROM saves WHERE module='teacher' OR (name=? AND identity_mode='self') ORDER BY (module='teacher') DESC, updated_at DESC LIMIT 1",
            (name,),
        ).fetchone()
        if row:
            self.connection.execute("UPDATE saves SET module='teacher', identity_mode='self' WHERE id=?", (row["id"],))
            self.connection.commit()
            return self.get_save(row["id"])
        return self.create_save(name, "self", "", module="teacher")

    def list_saves(self) -> list[dict[str, Any]]:
        rows = self.connection.execute("SELECT * FROM saves ORDER BY updated_at DESC").fetchall()
        return [dict(row) for row in rows]

    def _teacher_progress_row(self, save_id: str) -> dict[str, Any]:
        if self.get_save(save_id)["module"] != "teacher":
            raise ValueError("only classroom saves support checkpoints")
        self.connection.execute(
            "INSERT OR IGNORE INTO teacher_progress (save_id, updated_at) VALUES (?, ?)", (save_id, now())
        )
        self.connection.commit()
        return dict(self.connection.execute("SELECT * FROM teacher_progress WHERE save_id=?", (save_id,)).fetchone())

    def _teacher_messages(self, save_id: str) -> list[dict[str, Any]]:
        # An interrupted user prompt is not a completed checkpoint. Preserve old paired history.
        messages = self.classroom_messages(save_id, None)
        completed = {row["turn_id"] for row in messages if row["role"] == "assistant"}
        return [row for row in messages if row['turn_id'] in completed and row.get('scene_id') is None]

    def classroom_messages(self, save_id: str, limit: int | None = 100) -> list[dict[str, Any]]:
        """Repair historical speaker headers for presentation without rewriting archives."""
        messages = self.messages(save_id, limit)
        result = []
        for row in messages:
            if row['role'] == 'user':
                result.append(row)
                continue
            for segment in recover_speaker_segments(AssistantSegment(row['display_text'], row['tts_text'], speaker_id=row.get('speaker_id') or 'arcueid')):
                if segment.speaker_id in {'arcueid', 'neco_arc'}:
                    result.append({**row, 'display_text': segment.reply, 'tts_text': segment.tts_text, 'speaker_id': segment.speaker_id})
        return result

    def teacher_progress(self, save_id: str) -> dict[str, Any]:
        progress = self._teacher_progress_row(save_id)
        messages = self._teacher_messages(save_id)
        lines: dict[str, str] = {}
        for row in messages:
            if row["role"] == "assistant":
                lines[row.get("speaker_id") or "arcueid"] = row["display_text"]
        return {"save": self.get_save(save_id), "revision": progress["revision"],
                "ui_state": json.loads(progress["ui_json"]), "updated_at": progress["updated_at"],
                "recent_messages": messages[-12:], "last_lines": lines,
                "completed_turns": len({row["turn_id"] for row in messages if row["role"] == "user"})}

    @staticmethod
    def _teacher_ui(ui_state: dict[str, Any]) -> dict[str, str]:
        speaker = ui_state.get("selected_speaker_id", "auto")
        if speaker not in {"auto", "arcueid", "neco_arc"}:
            raise ValueError("unknown classroom speaker")
        return {"selected_speaker_id": speaker, "draft": str(ui_state.get("draft", ""))[:2000]}

    def update_teacher_progress(self, save_id: str, revision: int, ui_state: dict[str, Any]) -> dict[str, Any]:
        progress = self._teacher_progress_row(save_id)
        if revision != progress["revision"]:
            raise ValueError("classroom progress changed; reload before saving")
        ui_state = self._teacher_ui(ui_state)
        self.connection.execute("UPDATE teacher_progress SET ui_json=?, updated_at=? WHERE save_id=?",
                                (json.dumps(ui_state, ensure_ascii=False), now(), save_id))
        self.connection.commit()
        return {"revision": revision, "ui_state": ui_state}

    def teacher_checkpoints(self) -> list[dict[str, Any]]:
        rows = self.connection.execute("SELECT * FROM teacher_checkpoints ORDER BY slot").fetchall()
        result = []
        for row in rows:
            messages = json.loads(row["messages_json"])
            users = [message for message in messages if message["role"] == "user"]
            result.append({"slot": row["slot"], "name": row["name"], "updated_at": row["updated_at"],
                           "completed_turns": len({message["turn_id"] for message in users}),
                           "preview": users[-1]["display_text"][:80] if users else "还没有对话",
                           "selected_speaker_id": json.loads(row["ui_json"]).get("selected_speaker_id", "arcueid")})
        return result

    def _write_teacher_checkpoint(self, slot: int, name: str, save_id: str, ui_state: dict[str, Any]) -> None:
        self.connection.execute(
            """INSERT INTO teacher_checkpoints (slot, name, updated_at, save_json, messages_json, ui_json)
               VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(slot) DO UPDATE SET name=excluded.name,
               updated_at=excluded.updated_at, version=1, save_json=excluded.save_json,
               messages_json=excluded.messages_json, ui_json=excluded.ui_json""",
            (slot, name, now(), json.dumps(self.get_save(save_id), ensure_ascii=False),
             json.dumps(self._teacher_messages(save_id), ensure_ascii=False), json.dumps(ui_state, ensure_ascii=False)),
        )

    def save_teacher_checkpoint(self, save_id: str, slot: int, name: str, revision: int,
                                ui_state: dict[str, Any]) -> dict[str, Any]:
        if not 1 <= slot <= 6:
            raise ValueError("manual checkpoint slot must be between 1 and 6")
        progress = self._teacher_progress_row(save_id)
        if revision != progress["revision"]:
            raise ValueError("classroom progress changed; reload before saving")
        ui_state = self._teacher_ui(ui_state)
        previous = self.connection.execute("SELECT name FROM teacher_checkpoints WHERE slot=?", (slot,)).fetchone()
        name = name.strip()[:80] or (previous["name"] if previous else f"课堂存档 {slot:02d}")
        with self.connection:
            self._write_teacher_checkpoint(slot, name, save_id, ui_state)
            self.connection.execute("UPDATE teacher_progress SET ui_json=?, updated_at=? WHERE save_id=?",
                                    (json.dumps(ui_state, ensure_ascii=False), now(), save_id))
        return next(row for row in self.teacher_checkpoints() if row["slot"] == slot)

    def restore_teacher_checkpoint(self, save_id: str, slot: int | None, revision: int,
                                   ui_state: dict[str, Any]) -> dict[str, Any]:
        progress = self._teacher_progress_row(save_id)
        if revision != progress["revision"]:
            raise ValueError("classroom progress changed; reload before loading")
        ui_state = self._teacher_ui(ui_state)
        checkpoint = None
        if slot is not None:
            checkpoint = self.connection.execute("SELECT * FROM teacher_checkpoints WHERE slot=?", (slot,)).fetchone()
            if checkpoint is None:
                raise KeyError("checkpoint not found")
            if checkpoint["version"] != 1:
                raise ValueError("unsupported checkpoint version")
        # Decode before backing up: slot 0 is itself the recovery checkpoint.
        messages = json.loads(checkpoint["messages_json"]) if checkpoint else []
        restored_ui = json.loads(checkpoint["ui_json"]) if checkpoint else {"selected_speaker_id": "auto", "draft": ""}
        restored_save = json.loads(checkpoint["save_json"]) if checkpoint else self.get_save(save_id)
        with self.connection:
            self._write_teacher_checkpoint(0, "读档／新课堂前的自动备份", save_id, ui_state)
            for table in ("messages", "conversation_summaries", "memories"):
                self.connection.execute(f"DELETE FROM {table} WHERE save_id=?", (save_id,))
            for row in messages:
                self.connection.execute(
                    """INSERT INTO messages (id, save_id, turn_id, role, display_text, tts_text, mood,
                       expression, created_at, speaker_id, recipient_id, scene_id, conversation_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (str(uuid.uuid4()), save_id, row["turn_id"], row["role"], row["display_text"], row["tts_text"],
                     row["mood"], row["expression"], row["created_at"], row.get("speaker_id"), row.get("recipient_id"), None, row.get("conversation_state", "{}")),
                )
            self.connection.execute("UPDATE saves SET name=?, user_name=?, updated_at=? WHERE id=?",
                                    (restored_save["name"], restored_save["user_name"], now(), save_id))
            self.connection.execute("UPDATE teacher_progress SET revision=revision+1, ui_json=?, updated_at=? WHERE save_id=?",
                                    (json.dumps(restored_ui, ensure_ascii=False), now(), save_id))
        return self.teacher_progress(save_id)

    def delete_teacher_checkpoint(self, slot: int) -> None:
        if not 1 <= slot <= 6:
            raise ValueError("automatic checkpoint cannot be deleted")
        with self.connection:
            cursor = self.connection.execute("DELETE FROM teacher_checkpoints WHERE slot=?", (slot,))
            if not cursor.rowcount:
                raise KeyError("checkpoint not found")

    def discard_incomplete_teacher_turn(self, save_id: str, turn_id: str) -> None:
        if self.get_save(save_id)["module"] != "teacher":
            return
        with self.connection:
            self.connection.execute("""DELETE FROM messages WHERE save_id=? AND turn_id=?
                AND NOT EXISTS (SELECT 1 FROM messages WHERE save_id=? AND turn_id=? AND role='assistant')""",
                (save_id, turn_id, save_id, turn_id))

    def get_save(self, save_id: str) -> dict[str, Any]:
        row = self.connection.execute("SELECT * FROM saves WHERE id=?", (save_id,)).fetchone()
        if not row:
            raise KeyError("save not found")
        return dict(row)

    def update_save(self, save_id: str, updates: dict[str, Any]) -> dict[str, Any]:
        existing = self.get_save(save_id)
        name = updates.get("name") or existing["name"]
        identity_mode = updates.get("identity_mode", existing["identity_mode"])
        user_name = updates.get("user_name")
        if user_name is None:
            user_name = existing["user_name"]
        if identity_mode not in {"self", "shiki"}:
            raise ValueError("identity_mode must be self or shiki")
        if existing.get("module") == "teacher" and identity_mode != "self":
            raise ValueError("课堂问答使用玩家本人身份")
        self.connection.execute(
            "UPDATE saves SET name=?, identity_mode=?, user_name=?, updated_at=? WHERE id=?",
            (str(name).strip() or existing["name"], identity_mode, str(user_name).strip(), now(), save_id),
        )
        self.connection.commit()
        return self.get_save(save_id)

    def add_message(self, save_id: str, turn_id: str, role: str, display_text: str, tts_text: str = "", mood: str = "neutral", expression: str = "neutral", speaker_id: str | None = None, recipient_id: str | None = None, scene_id: str | None = None, conversation_state: dict | None = None, commit: bool = True) -> dict[str, Any]:
        message_id, timestamp = str(uuid.uuid4()), now()
        self.connection.execute(
            "INSERT INTO messages (id, save_id, turn_id, role, display_text, tts_text, mood, expression, created_at, speaker_id, recipient_id, scene_id, conversation_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (message_id, save_id, turn_id, role, display_text, tts_text, mood, expression, timestamp, speaker_id if role == "assistant" else None, recipient_id if role == "user" else None, scene_id, json.dumps(conversation_state or {}, ensure_ascii=False)),
        )
        self.connection.execute("UPDATE saves SET updated_at=? WHERE id=?", (timestamp, save_id))
        if commit:
            self.connection.commit()
        return self.get_message(message_id)

    def classroom_state(self, save_id: str) -> dict:
        row = self.connection.execute(
            "SELECT conversation_state FROM messages WHERE save_id=? AND role='assistant' AND scene_id IS NULL AND conversation_state!='{}' ORDER BY created_at DESC, rowid DESC LIMIT 1",
            (save_id,),
        ).fetchone()
        return json.loads(row[0]) if row else {}

    def get_message(self, message_id: str) -> dict[str, Any]:
        row = self.connection.execute("SELECT * FROM messages WHERE id=?", (message_id,)).fetchone()
        return dict(row)

    def messages(self, save_id: str, limit: int | None = 100) -> list[dict[str, Any]]:
        if limit is None or limit <= 0:
            rows = self.connection.execute(
                "SELECT * FROM messages WHERE save_id=? ORDER BY created_at ASC, rowid ASC", (save_id,)
            ).fetchall()
        else:
            rows = self.connection.execute(
                "SELECT * FROM messages WHERE save_id=? ORDER BY created_at DESC, rowid DESC LIMIT ?", (save_id, limit)
            ).fetchall()
            rows.reverse()
        return [dict(row) for row in rows]

    def recent_messages(self, save_id: str, limit: int = 8) -> list[dict[str, Any]]:
        return self.messages(save_id, limit)

    def recent_character_messages(self, save_id: str, character_id: str, limit: int = 8) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            """SELECT * FROM messages WHERE save_id=? AND scene_id IS NULL AND (
                 (role='user' AND (recipient_id=? OR (?='arcueid' AND recipient_id IS NULL)))
                 OR (role='assistant' AND COALESCE(speaker_id, 'arcueid')=?))
               ORDER BY created_at DESC, rowid DESC LIMIT ?""",
            (save_id, character_id, character_id, character_id, limit),
        ).fetchall()
        return [dict(row) for row in reversed(rows)]

    def latest_summary(self, save_id: str) -> str:
        row = self.connection.execute(
            "SELECT summary FROM conversation_summaries WHERE save_id=? ORDER BY created_at DESC LIMIT 1", (save_id,)
        ).fetchone()
        return str(row["summary"]) if row else ""

    def add_summary(self, save_id: str, from_message_id: str, to_message_id: str, summary: str) -> None:
        self.connection.execute(
            "INSERT INTO conversation_summaries VALUES (?, ?, ?, ?, ?, ?)",
            (str(uuid.uuid4()), save_id, from_message_id, to_message_id, summary.strip(), now()),
        )
        self.connection.commit()

    def user_turn_count(self, save_id: str, character_id: str = "arcueid") -> int:
        return int(self.connection.execute("SELECT COUNT(*) FROM messages WHERE save_id=? AND scene_id IS NULL AND role='user' AND (recipient_id=? OR (?='arcueid' AND recipient_id IS NULL))", (save_id, character_id, character_id)).fetchone()[0])

    def add_memory(self, save_id: str, kind: str, content: str, importance: float, confidence: float, source_message_ids: list[str], status: str = "candidate") -> dict[str, Any]:
        memory_id, timestamp = str(uuid.uuid4()), now()
        self.connection.execute(
            "INSERT INTO memories VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, NULL)",
            (memory_id, save_id, kind, content.strip(), importance, confidence, status, json.dumps(source_message_ids), timestamp, timestamp),
        )
        self.connection.commit()
        return self.get_memory(memory_id)

    def get_memory(self, memory_id: str) -> dict[str, Any]:
        row = self.connection.execute("SELECT * FROM memories WHERE id=?", (memory_id,)).fetchone()
        if not row:
            raise KeyError("memory not found")
        return self._memory_payload(row)

    def memories(self, save_id: str, include_deleted: bool = False) -> list[dict[str, Any]]:
        query = "SELECT * FROM memories WHERE save_id=?"
        args: list[Any] = [save_id]
        if not include_deleted:
            query += " AND status != 'deleted'"
        query += " ORDER BY CASE status WHEN 'pinned' THEN 0 WHEN 'active' THEN 1 ELSE 2 END, updated_at DESC"
        return [self._memory_payload(row) for row in self.connection.execute(query, args).fetchall()]

    def update_memory(self, memory_id: str, content: str | None = None, status: str | None = None) -> dict[str, Any]:
        if status is not None and status not in {"candidate", "active", "pinned", "deleted"}:
            raise ValueError("invalid memory status")
        existing = self.get_memory(memory_id)
        self.connection.execute(
            "UPDATE memories SET content=?, status=?, updated_at=? WHERE id=?",
            (content.strip() if content is not None else existing["content"], status or existing["status"], now(), memory_id),
        )
        self.connection.commit()
        return self.get_memory(memory_id)

    def _memory_payload(self, row: sqlite3.Row) -> dict[str, Any]:
        payload = dict(row)
        payload["source_message_ids"] = json.loads(payload.pop("source_message_ids"))
        payload.pop("embedding", None)
        return payload
