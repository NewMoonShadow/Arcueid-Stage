from __future__ import annotations

import json
from threading import Lock
from typing import Any

from .database import StageDatabase, now


SCENE_ID = "park_confrontation_01"
NODES: dict[str, dict[str, Any]] = {
    "ciel_warning": {
        "speaker_id": "ciel",
        "title": "公园前的阻拦",
        "situation": "赴南口公园见爱尔奎特前，西耶尔坚持同行。你担心两人相遇会发生冲突。",
        "goal": "回应西耶尔为何不该继续同行。",
        "suggestions": ["请你先回去，别再跟着我。", "你们见面会激化冲突，先让我独自去解释。"],
    },
    "arc_confrontation": {
        "speaker_id": "arcueid",
        "title": "公园里的对峙",
        "situation": "西耶尔仍来到公园。两人对立升级，爱尔奎特正逼近她。",
        "goal": "用话语阻止爱尔奎特继续逼近。",
        "suggestions": ["再往前，我会无法接受你这样做。", "请停下，伤害西耶尔也会伤害我，我们先说清楚。"],
    },
    "ciel_followup": {
        "speaker_id": "ciel",
        "title": "西耶尔的短后续",
        "situation": "西耶尔挡在你身前。争执后，爱尔奎特离开公园；西耶尔暂时安全，正在确认你的情况与立场。",
        "goal": "和西耶尔说一句话，结束这段短后续。",
        "suggestions": ["你受伤了吗？我们先离开这里。"],
    },
    "arc_followup": {
        "speaker_id": "arcueid",
        "title": "爱尔奎特的短后续",
        "situation": "西耶尔挡在你身前。争执后，爱尔奎特离开公园；西耶尔暂时安全。稍后，爱尔奎特再次联系你。",
        "goal": "和爱尔奎特说一句话，结束这段短后续。",
        "suggestions": ["刚才我想保护你们两个，能听我解释吗？"],
    },
    "complete": {
        "speaker_id": "",
        "title": "公园前的阻拦 · 已完成",
        "situation": "这段样机剧情已结束。两次决定已保存在当前存档中。",
        "goal": "可以继续自由对话，或重玩这段剧情。",
        "suggestions": [],
    },
}


def classify(node_id: str, message: str) -> str | None:
    text = "".join(message.lower().split())
    if node_id == "ciel_warning":
        direct = ("别跟", "不要跟", "别来", "回去", "离开", "别同行", "不许跟")
        reasoned = ("冲突", "误会", "危险", "激化", "解释", "冷静", "说清", "先让我")
        if any(term in text for term in direct):
            return "direct_refusal"
        if any(term in text for term in reasoned):
            return "reasoned_warning"
    if node_id == "arc_confrontation":
        boundary = ("讨厌你", "不喜欢你", "无法接受", "不能接受", "我会离开", "我会恨", "我会失望", "我会对你失望", "让我失望")
        reasoned = ("伤害", "冷静", "停下", "别动手", "别伤", "说清", "听我解释", "先谈")
        if any(term in text for term in boundary):
            return "emotional_boundary"
        if any(term in text for term in reasoned):
            return "reasoned_appeal"
    return None


def fallback_reply(node_id: str, intent: str | None) -> str:
    if intent is None and node_id in {"ciel_warning", "arc_confrontation"}:
        return "你希望我怎么做？请说得更明确一些。"
    return {
        "ciel_warning": "我明白你的意思，但我仍会去公园确认情况。",
        "arc_confrontation": "……我听到了。先停一下。",
        "ciel_followup": "我没事。先离开这里，再慢慢说。",
        "arc_followup": "我会听你解释，但刚才的事还没有过去。",
    }.get(node_id, "我听到了。")


class StoryDirector:
    def __init__(self, database: StageDatabase) -> None:
        self.database = database
        self.lock = Lock()

    def get(self, save_id: str) -> dict[str, Any] | None:
        self.database.get_save(save_id)
        row = self.database.connection.execute("SELECT * FROM story_states WHERE save_id=?", (save_id,)).fetchone()
        return self._payload(dict(row)) if row else None

    def was_processed(self, save_id: str, request_id: str) -> bool:
        return self.database.connection.execute(
            "SELECT 1 FROM story_turns WHERE save_id=? AND request_id=?", (save_id, request_id)
        ).fetchone() is not None

    def start(self, save_id: str, restart: bool = False) -> dict[str, Any]:
        with self.lock:
            save = self.database.get_save(save_id)
            if save["identity_mode"] != "shiki":
                raise ValueError("此剧情样机需要将存档身份设为远野志贵")
            existing = self.get(save_id)
            if existing and existing["node_id"] != "complete":
                return existing
            if existing and not restart:
                return existing
            if existing:
                self.database.connection.execute("DELETE FROM story_turns WHERE save_id=?", (save_id,))
            self.database.connection.execute(
                """INSERT INTO story_states (save_id, scene_id, node_id, ciel_approach, arc_appeal, followup_path, revision, updated_at)
                   VALUES (?, ?, 'ciel_warning', NULL, NULL, NULL, 0, ?)
                   ON CONFLICT(save_id) DO UPDATE SET node_id='ciel_warning', ciel_approach=NULL,
                   arc_appeal=NULL, followup_path=NULL, revision=revision+1, updated_at=excluded.updated_at""",
                (save_id, SCENE_ID, now()),
            )
            self.database.connection.commit()
            return self.get(save_id)  # type: ignore[return-value]

    def advance(self, save_id: str, request_id: str, speaker_id: str, message: str) -> tuple[dict[str, Any], dict[str, Any], str | None, bool]:
        with self.lock:
            previous = self.get(save_id)
            prior_turn = self.database.connection.execute(
                "SELECT result_json FROM story_turns WHERE save_id=? AND request_id=?", (save_id, request_id)
            ).fetchone()
            if prior_turn:
                assert previous is not None
                return previous, previous, None, True
            if previous is None or previous["node_id"] == "complete":
                raise ValueError("story is not active")
            if self.database.get_save(save_id)["identity_mode"] != "shiki":
                raise ValueError("此剧情样机只能以远野志贵身份继续")
            node_id = previous["node_id"]
            if NODES[node_id]["speaker_id"] != speaker_id:
                raise ValueError("当前剧情应先与指定角色对话")
            intent = classify(node_id, message)
            next_node = node_id
            changes: dict[str, Any] = {}
            if node_id == "ciel_warning" and intent:
                next_node = "arc_confrontation"
                changes["ciel_approach"] = intent
            elif node_id == "arc_confrontation" and intent:
                next_node = "ciel_followup" if intent == "emotional_boundary" else "arc_followup"
                changes["arc_appeal"] = intent
                changes["followup_path"] = next_node
            elif node_id in {"ciel_followup", "arc_followup"}:
                next_node = "complete"
                intent = "followup_completed"
            if next_node != node_id:
                self.database.connection.execute(
                    """UPDATE story_states SET node_id=?, ciel_approach=COALESCE(?, ciel_approach),
                       arc_appeal=COALESCE(?, arc_appeal), followup_path=COALESCE(?, followup_path),
                       revision=revision+1, updated_at=? WHERE save_id=?""",
                    (next_node, changes.get("ciel_approach"), changes.get("arc_appeal"), changes.get("followup_path"), now(), save_id),
                )
            result = self.get(save_id)
            assert result is not None
            self.database.connection.execute(
                "INSERT INTO story_turns (save_id, request_id, result_json) VALUES (?, ?, ?)",
                (save_id, request_id, json.dumps(result, ensure_ascii=False)),
            )
            self.database.connection.commit()
            return previous, result, intent, False

    @staticmethod
    def _payload(row: dict[str, Any]) -> dict[str, Any]:
        node = NODES[row["node_id"]]
        return {**row, "active": row["node_id"] != "complete", **node}
