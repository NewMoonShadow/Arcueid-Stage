from __future__ import annotations

import json
import re
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field, replace
from typing import Any

import httpx

from .config import Settings


TAG = re.compile(r"<(?P<name>reply|tts_text|meta|neco|arcueid|neco_tts_text|arcueid_tts_text)>(?P<value>.*?)</(?P=name)>", re.DOTALL)
SEGMENT = re.compile(r"<segment>(?P<body>.*?)</segment>", re.DOTALL)
NON_DIALOGUE = re.compile(
    r"<(tts_text|meta|neco|arcueid|neco_tts_text|arcueid_tts_text|think|analysis|reasoning)\b[^>]*>.*?(?:</\1\s*>|$)",
    re.DOTALL | re.IGNORECASE,
)


def _display_dialogue(content: str) -> str:
    """Keep dialogue only, including when a model leaves protocol tags unclosed."""
    value = NON_DIALOGUE.sub("", content)
    value = re.sub(r"<[^>]*(?:>|$)", "", value)
    return value.strip()


@dataclass
class AssistantSegment:
    reply: str
    tts_text: str
    mood: str = "neutral"
    expression: str = "neutral"
    neco_reply: str = ""
    arcueid_reply: str = ""
    neco_tts_text: str = ""
    arcueid_tts_text: str = ""
    speaker_id: str = ""
    conversation_state: dict[str, str] = field(default_factory=dict)


@dataclass
class AssistantReply:
    reply: str
    tts_text: str
    mood: str = "neutral"
    expression: str = "neutral"
    neco_reply: str = ""
    arcueid_reply: str = ""
    neco_tts_text: str = ""
    arcueid_tts_text: str = ""
    segments: list[AssistantSegment] = field(default_factory=list)


SPEAKER_PREFIX = re.compile(
    r"(?:\[|【)\s*(?P<label>[^\]\n】]{1,100})(?:\]|】)\s*[:：]?\s*"
    r"|(?:^|(?<=\n))\s*(?P<name>爱尔奎特|爱尔奎特老师|猫姬|Neco-Arc|Arcueid|アルクェイド|ネコアルク|玩家)\s*[:：]\s*",
    re.IGNORECASE,
)
SPEAKER_NAMES = {"爱尔奎特": "arcueid", "爱尔奎特老师": "arcueid", "arcueid": "arcueid",
                 "アルクェイド": "arcueid", "猫姬": "neco_arc", "neco-arc": "neco_arc",
                 "ネコアルク": "neco_arc", "玩家": "player"}


def recover_speaker_segments(segment: AssistantSegment) -> list[AssistantSegment]:
    """Recover explicit speaker headers, never infer identity from dialogue wording.

    A model may imitate an older transcript instead of using meta. Split mixed
    speaker replies before display/TTS; ambiguous bilingual alignment is repaired.
    Ordinary square brackets are left intact.
    """
    headers = []
    for match in SPEAKER_PREFIX.finditer(segment.reply):
        label = (match.group('label') or match.group('name') or '').strip()
        explicit = re.search(r'''\bspeaker_id\s*[:=]\s*["']?([a-z_]+)''', label, re.IGNORECASE)
        actor = explicit.group(1).lower() if explicit else SPEAKER_NAMES.get(label.lower())
        if actor:
            headers.append((match, actor))
    if not headers:
        return [segment]
    result = []
    if segment.reply[:headers[0][0].start()].strip():
        result.append(replace(segment, reply=segment.reply[:headers[0][0].start()].strip(),
                              tts_text='', conversation_state={}))
    for index, (match, actor) in enumerate(headers):
        end = headers[index + 1][0].start() if index + 1 < len(headers) else len(segment.reply)
        text = segment.reply[match.end():end].strip()
        if not text:
            continue
        if len(headers) == 1 and not result:
            # Keep the object identity for the existing stream-tail aside repair.
            segment.reply = text
            segment.speaker_id = actor
            segment.tts_text = SPEAKER_PREFIX.sub('', segment.tts_text).strip()
            return [segment]
        result.append(replace(segment, reply=text, tts_text='', speaker_id=actor,
                              neco_reply='', arcueid_reply='',
                              conversation_state=segment.conversation_state if index + 1 == len(headers) else {}))
    return result


@dataclass
class SegmentParseEvent:
    kind: str
    segment_index: int
    segment: AssistantSegment


def unavailable_reply() -> AssistantReply:
    return AssistantReply(
        "……刚才的思绪断了一下。你再对我说一次，好吗？",
        "……今、少し考えが途切れちゃった。もう一度、私に話してくれる？",
        "serious",
        "serious",
    )


def _parse_values(content: str) -> AssistantSegment:
    values = {match.group("name"): match.group("value").strip() for match in TAG.finditer(content)}
    meta: dict[str, Any] = {}
    try:
        parsed_meta = json.loads(values.get("meta", "{}"))
        if isinstance(parsed_meta, dict):
            meta = parsed_meta
    except json.JSONDecodeError:
        pass
    reply_match = re.search(r"<reply>(.*?)(?:</reply>|$)", content, re.DOTALL)
    reply = _display_dialogue(reply_match.group(1) if reply_match else content)
    tts_text = values.get("tts_text", "").strip()
    return AssistantSegment(
        reply=reply,
        tts_text=tts_text if is_valid_japanese_tts(tts_text) else "",
        mood=str(meta.get("mood", "neutral")),
        expression=str(meta.get("expression", "neutral")),
        neco_reply=_display_dialogue(values.get("neco", "")),
        arcueid_reply=_display_dialogue(values.get("arcueid", "")),
        neco_tts_text=values.get("neco_tts_text", "") if is_valid_japanese_tts(values.get("neco_tts_text", "")) else "",
        arcueid_tts_text=values.get("arcueid_tts_text", "") if is_valid_japanese_tts(values.get("arcueid_tts_text", "")) else "",
        speaker_id=str(meta.get("speaker_id", "")),
        conversation_state=meta.get("conversation_state", {}) if isinstance(meta.get("conversation_state"), dict) else {},
    )


def is_valid_japanese_tts(text: str) -> bool:
    """Reject malformed or wrong-language text before it reaches the voice model."""
    value = text.strip()
    if not value or "<" in value or ">" in value:
        return False
    return any("\u3040" <= char <= "\u30ff" or "\u31f0" <= char <= "\u31ff" for char in value)


def _clean_translation(content: str) -> str:
    value = content.strip()
    tagged = re.search(r"<(?:tts_text|translation)>(.*?)</(?:tts_text|translation)>", value, re.DOTALL)
    if tagged:
        value = tagged.group(1).strip()
    value = value.strip('"\'` \r\n')
    return value if is_valid_japanese_tts(value) else ""


async def translate_to_japanese(
    settings: Settings,
    text: str,
    client: httpx.AsyncClient | None = None,
    speaker_id: str = "arcueid",
) -> str:
    """Repair missing or invalid TTS text without blocking the main reply stream."""
    if not settings.api_key or not settings.model or not text.strip():
        return ""
    translation_prompt = (
        "Translate the supplied Chinese character dialogue into natural spoken Japanese. "
        "Preserve meaning, attitude, names, and emotional tone. Return Japanese dialogue only, "
        "with no explanation, labels, Markdown, quotation marks, or XML."
    )
    if speaker_id == "neco_arc":
        translation_prompt += (
            " For Neco-Arc, keep a playful, impish rhythm. Where the Chinese line calls for it, "
            "use one short reaction such as にゃははっ, むむっ, えっ, or うにゃー, and a natural "
            "cat-like ending such as にゃ, にゃー, or にゅ. Match the line's emotion and pauses; "
            "do not add unrelated content or force every particle into every sentence."
        )
    payload: dict[str, Any] = {
        "model": settings.model,
        "messages": [
            {
                "role": "system",
                "content": translation_prompt,
            },
            {"role": "user", "content": text.strip()},
        ],
        "temperature": 0.2,
        "top_p": 0.9,
        "stream": False,
    }
    if settings.provider.lower() == "deepseek" or "api.deepseek.com" in settings.base_url.lower():
        payload["thinking"] = {"type": "disabled"}
    headers = {"Authorization": f"Bearer {settings.api_key}", "Content-Type": "application/json"}
    active_client = client
    owns_client = active_client is None
    if active_client is None:
        active_client = httpx.AsyncClient(
            timeout=httpx.Timeout(45.0, connect=10.0),
            trust_env=False,
        )
    try:
        response = await active_client.post(
                f"{settings.base_url}/chat/completions",
                headers=headers,
                json=payload,
        )
        response.raise_for_status()
        content = str(response.json()["choices"][0]["message"]["content"])
        return _clean_translation(content)
    except (httpx.HTTPError, json.JSONDecodeError, KeyError, IndexError, TypeError, ValueError):
        return ""
    finally:
        if owns_client:
            await active_client.aclose()


def parse_reply(content: str) -> AssistantReply:
    segments = [_parse_values(match.group("body")) for match in SEGMENT.finditer(content)]
    if not segments:
        segments = [_parse_values(content)]
    return combine_segments(segments)


def combine_segments(segments: list[AssistantSegment]) -> AssistantReply:
    if not segments:
        return unavailable_reply()
    return AssistantReply(
        reply="".join(segment.reply for segment in segments),
        tts_text="".join(segment.tts_text for segment in segments),
        mood=segments[-1].mood,
        expression=segments[-1].expression,
        neco_reply="\n".join(segment.neco_reply for segment in segments if segment.neco_reply),
        arcueid_reply="\n".join(segment.arcueid_reply for segment in segments if segment.arcueid_reply),
        neco_tts_text="".join(segment.neco_tts_text for segment in segments),
        arcueid_tts_text="".join(segment.arcueid_tts_text for segment in segments),
        segments=list(segments),
    )


class SegmentStreamParser:
    def __init__(self) -> None:
        self.buffer = ""
        self.emitted = 0
        self.segment_index = 0
        self.last_segment: AssistantSegment | None = None

    def feed_events(self, content: str) -> list[SegmentParseEvent]:
        self.buffer += content
        events: list[SegmentParseEvent] = []
        opening = "<segment>"
        closing = "</segment>"
        while True:
            start = self.buffer.find(opening)
            if start < 0:
                break
            if start:
                self.buffer = self.buffer[start:]
            end = self.buffer.find(closing, len(opening))
            if end < 0:
                break
            body = self.buffer[len(opening):end]
            segment = _parse_values(body)
            if segment.reply:
                events.append(SegmentParseEvent("segment_completed", self.segment_index, segment))
                self.last_segment = segment
                self.emitted += 1
            self.buffer = self.buffer[end + len(closing):]
            self.segment_index += 1
        return events

    def feed(self, content: str) -> list[AssistantSegment]:
        return [event.segment for event in self.feed_events(content) if event.kind == "segment_completed"]

    def finish_events(self) -> list[SegmentParseEvent]:
        if not self.buffer.strip():
            return []
        body = self.buffer.strip()
        # Models sometimes close the segment before emitting its metadata/aside.
        # Those trailing fields belong to the previous segment, never to dialogue.
        if self.last_segment is not None and not body.startswith(("<segment>", "<reply>")):
            values = {match.group("name"): match.group("value") for match in TAG.finditer(body)}
            if values.get("neco"):
                self.last_segment.neco_reply = _display_dialogue(values["neco"])
            if values.get("arcueid"):
                self.last_segment.arcueid_reply = _display_dialogue(values["arcueid"])
            for name in ("neco_tts_text", "arcueid_tts_text"):
                if is_valid_japanese_tts(values.get(name, "")):
                    setattr(self.last_segment, name, values[name].strip())
            self.buffer = ""
            return []
        if body.startswith("<segment>"):
            body = body[len("<segment>"):]
        segment = _parse_values(body)
        # An unclosed final segment may still be shown, but must never be spoken.
        segment.tts_text = ""
        events: list[SegmentParseEvent] = []
        if segment.reply:
            events.append(SegmentParseEvent("segment_completed", self.segment_index, segment))
            self.emitted += 1
        self.buffer = ""
        return events

    def finish(self) -> list[AssistantSegment]:
        return [event.segment for event in self.finish_events() if event.kind == "segment_completed"]


def _stream_delta(line: str) -> str:
    if not line.startswith("data:"):
        return ""
    data = line[5:].strip()
    if not data or data == "[DONE]":
        return ""
    payload = json.loads(data)
    return str(payload["choices"][0].get("delta", {}).get("content") or "")


async def stream_segments(
    settings: Settings,
    messages: list[dict[str, str]],
    on_speech_ready: Callable[[int, AssistantSegment], Awaitable[None]] | None = None,
    on_first_token: Callable[[], Awaitable[None]] | None = None,
    client: httpx.AsyncClient | None = None,
) -> AsyncIterator[AssistantSegment]:
    if not settings.api_key or not settings.model:
        fallback = unavailable_reply()
        yield AssistantSegment(fallback.reply, fallback.tts_text, fallback.mood, fallback.expression)
        return

    payload = {
        "model": settings.model,
        "messages": messages,
        "temperature": settings.temperature,
        "top_p": settings.top_p,
        "stream": True,
    }
    if settings.provider.lower() == "deepseek" or "api.deepseek.com" in settings.base_url.lower():
        payload["thinking"] = {"type": "enabled" if settings.thinking_enabled else "disabled"}
    headers = {"Authorization": f"Bearer {settings.api_key}", "Content-Type": "application/json"}
    parser = SegmentStreamParser()
    raw_lines: list[str] = []
    yielded = 0
    first_token_reported = False
    active_client = client
    owns_client = active_client is None
    if active_client is None:
        active_client = httpx.AsyncClient(
            timeout=httpx.Timeout(90.0, connect=10.0),
            trust_env=False,
        )
    try:
        async with active_client.stream("POST", f"{settings.base_url}/chat/completions", headers=headers, json=payload) as response:
            response.raise_for_status()
            async for line in response.aiter_lines():
                raw_lines.append(line)
                delta = _stream_delta(line)
                if not delta:
                    continue
                if not first_token_reported:
                    first_token_reported = True
                    if on_first_token:
                        await on_first_token()
                for event in parser.feed_events(delta):
                    if event.kind == "segment_completed":
                        if on_speech_ready:
                            await on_speech_ready(event.segment_index, event.segment)
                        yielded += 1
                        yield event.segment
        for event in parser.finish_events():
            if event.kind == "segment_completed":
                if on_speech_ready:
                    await on_speech_ready(event.segment_index, event.segment)
                yielded += 1
                yield event.segment
        if not yielded and raw_lines:
            body = json.loads("".join(raw_lines))
            content = str(body["choices"][0]["message"]["content"])
            reply = parse_reply(content)
            yield AssistantSegment(reply.reply, reply.tts_text, reply.mood, reply.expression, reply.neco_reply, reply.arcueid_reply)
    except (httpx.HTTPError, json.JSONDecodeError, KeyError, IndexError, TypeError, ValueError):
        if not yielded:
            fallback = unavailable_reply()
            yield AssistantSegment(fallback.reply, fallback.tts_text, fallback.mood, fallback.expression)
    finally:
        if owns_client:
            await active_client.aclose()


async def complete(
    settings: Settings,
    messages: list[dict[str, str]],
    client: httpx.AsyncClient | None = None,
) -> AssistantReply:
    segments = [segment async for segment in stream_segments(settings, messages, client=client)]
    return combine_segments(segments)
