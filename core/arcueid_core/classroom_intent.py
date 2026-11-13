"""Conservative, local dialogue-act hints for the teacher classroom."""
from __future__ import annotations

from dataclasses import dataclass
import re


CHARACTERS = {"爱尔奎特": "arcueid", "猫姬": "neco_arc"}
PEOPLE = ("爱尔奎特", "猫姬", "西耶尔", "希耶尔", "青子", "罗亚", "志贵", "秋叶", "诺艾尔")


@dataclass(frozen=True)
class ClassroomIntent:
    dialogue_act: str = "unknown"
    topic_action: str = "none"
    addressed_character: str = "auto"
    boundary_action: str = "none"
    boundary_character: str = ""
    closing: bool = False
    retrieval_query: str = ""
    certainty: str = "unclear"

    def next_boundary(self, current: str) -> str:
        if self.boundary_action == "clear":
            return ""
        if self.boundary_action == "solo" and self.boundary_character in CHARACTERS.values():
            return self.boundary_character
        if self.boundary_action == "mute" and self.boundary_character in CHARACTERS.values():
            return "neco_arc" if self.boundary_character == "arcueid" else "arcueid"
        return current if current in CHARACTERS.values() else ""

    def prompt_hint(self, boundary: str) -> str:
        notes: list[str] = []
        if self.boundary_action == "clear":
            notes.append("The player lifted the prior speaker restriction; both characters may participate again.")
        if self.topic_action == "switch":
            notes.append("The player explicitly changed topic; do not return to the previous topic unless asked.")
        if self.dialogue_act == "followup" and self.retrieval_query:
            notes.append("This is a follow-up to the current topic; use the supplied evidence only when it matches the player's actual referent.")
        elif self.dialogue_act == "clarification":
            notes.append("The referent of the short follow-up is unclear; ask one brief clarification instead of guessing a person or event.")
        elif self.dialogue_act == "knowledge_question":
            notes.append("The player asked for factual lore; answer the actual question using relevant supplied evidence and acknowledge gaps.")
        elif self.dialogue_act == "opinion_or_feeling":
            notes.append("Respond to the player's feeling or experience before offering lore or a new question.")
        if self.closing:
            notes.append("The player is ending this exchange; acknowledge it briefly and do not start another topic.")
        if boundary == "arcueid":
            notes.append("The player explicitly requested Arcueid alone; Neco-Arc must not speak until this boundary is lifted.")
        elif boundary == "neco_arc":
            notes.append("The player explicitly requested Neco-Arc alone; Arcueid must not speak until this boundary is lifted.")
        return " ".join(notes)


def _quoted_or_hypothetical(text: str) -> bool:
    return bool(re.search(r"^(如果|假如|假设|比如|举个例子|你觉得|你认为|我不是说|我没说|不是说|我说[‘'\"])", text))


def _explicit_boundary(text: str) -> tuple[str, str]:
    if _quoted_or_hypothetical(text) or re.search(r"(不要|别|并非|不是)(只|单独)(和|跟)", text):
        return "none", ""
    clear = bool(re.search(r"(你们(都|一起)(可以)?(说话|说|聊|回答)(了)?|恢复(一起|正常)(聊天|说话)|不用(再)?(单独|安静)|猫姬(可以|也能|继续)(说话|插话|回答)(了)?|爱尔奎特(可以|也能|继续)(说话|插话|回答)(了)?)(?=[，,。！!\s]|$)", text))
    matches: list[tuple[str, str]] = []
    if clear:
        matches.append(("clear", ""))
    for name, actor in CHARACTERS.items():
        escaped = re.escape(name)
        if re.search(rf"(只(想)?(和|跟){escaped}(说|聊)|单独(和|跟){escaped}(说|聊)|只(想)?听{escaped}(说|回答))", text):
            matches.append(("solo", actor))
        if re.search(rf"{escaped}(先|暂时)?(别|不要|先不要)(插话|说话|发言|回答)|{escaped}(先|暂时)?安静(一下)?|让{escaped}(先|暂时)?(别|不要)(插话|说话|发言|回答)", text):
            matches.append(("mute", actor))
    return matches[0] if len(matches) == 1 else ("none", "")


def _followup_query(text: str, state: dict) -> str:
    topic = str(state.get("current_topic") or "").strip()[:80]
    if not topic:
        return ""
    people = [name for name in PEOPLE if name in topic]
    if ("她" in text or "他" in text or "ta" in text.lower()) and len(people) != 1:
        return ""
    if len(people) > 1:
        return ""
    return f"{topic} {text}"[:120]


def classify_classroom_intent(message: str, state: dict | None = None) -> ClassroomIntent:
    """Only explicit controls change state; uncertain language remains model input."""
    text = " ".join(message.strip().split())[:500]
    if not text:
        return ClassroomIntent()
    state = state if isinstance(state, dict) else {}
    boundary_action, boundary_character = _explicit_boundary(text)
    addressed = "auto"
    for name, actor in CHARACTERS.items():
        if re.search(rf"^{re.escape(name)}[，,！!：:\s你]|^(我想问|请问|问问){re.escape(name)}[，,：:\s你]", text):
            addressed = actor
            break
    if boundary_action in {"solo", "mute"}:
        addressed = "auto"

    closing = bool(re.fullmatch(r"(先到这里|今天就到这(里|儿)?|先聊到这(里|儿)?|不聊了|再见|拜拜|下次再聊)[。！!~～\s]*", text))
    switch = not _quoted_or_hypothetical(text) and bool(re.search(r"换(个|一个)?话题|换点别的|说点别的|聊点别的|不(想)?聊.{1,20}(了|，|,|。|$)", text))
    topic_action = "switch" if switch else "none"
    short_followup = len(text) <= 24 and bool(re.fullmatch(r"(那|然后|所以|可是|但是)?(她|他|它|这|这个|那|那个)?(后来|之后|为什么|怎么了|是什么意思|呢|然后呢|是怎么回事)(呢)?[？?。\s]*", text))
    if short_followup:
        query = _followup_query(text, state)
        dialogue_act = "followup" if query else "clarification"
    elif re.search(r"(是什么|是谁|为什么|怎么|如何|讲讲|介绍一下|告诉我|能解释|吗[？?]|[？?])", text):
        query = text
        if boundary_action != "none" or switch:
            clauses = [part.strip() for part in re.split(r"[，,。；;]", text) if part.strip()]
            if len(clauses) > 1 and re.search(r"(是什么|是谁|为什么|怎么|如何|讲讲|介绍一下|告诉我|能解释|[？?])", clauses[-1]):
                query = clauses[-1]
        dialogue_act = "knowledge_question"
    elif re.search(r"(我(今天|现在|刚才|觉得|感觉|有点|很|不想|想)|今天(有点|很)|有点(累|难过|开心|害怕)|让我(难过|开心|害怕|累))", text):
        query = ""
        dialogue_act = "opinion_or_feeling"
    else:
        query = ""
        dialogue_act = "casual"
    certainty = "explicit" if boundary_action != "none" or closing or switch else "probable" if dialogue_act in {"knowledge_question", "followup"} else "unclear"
    return ClassroomIntent(dialogue_act, topic_action, addressed, boundary_action, boundary_character, closing, query, certainty)


def initial_speaker(requested: str, intent: ClassroomIntent, boundary: str) -> str:
    if boundary in CHARACTERS.values():
        return boundary
    return intent.addressed_character if intent.addressed_character != "auto" else requested
