"""Incrementally decode GPT-SoVITS WAV headers and aligned PCM16 frames."""
from __future__ import annotations

import struct


class WavPcmDecoder:
    def __init__(self) -> None:
        self.buffer = bytearray()
        self.riff = False
        self.ready = False
        self.sample_rate = 0
        self.channels = 0
        self.remaining: int | None = None
        self.total_bytes = 0

    def feed(self, chunk: bytes) -> bytes:
        self.buffer.extend(chunk)
        if not self.riff:
            if len(self.buffer) < 12:
                return b""
            if self.buffer[:4] != b"RIFF" or self.buffer[8:12] != b"WAVE":
                raise ValueError("voice stream is not a WAV")
            del self.buffer[:12]
            self.riff = True
        while not self.ready:
            if len(self.buffer) < 8:
                return b""
            kind, length = bytes(self.buffer[:4]), struct.unpack_from("<I", self.buffer, 4)[0]
            if kind == b"data":
                if not self.channels:
                    raise ValueError("WAV data precedes format")
                del self.buffer[:8]
                # Live WAV headers have zero/unknown lengths until inference ends.
                self.remaining = length if length not in (0, 0xFFFFFFFF) else None
                self.ready = True
                break
            if length > 65536:
                raise ValueError("oversized WAV header")
            padded = length + (length % 2)
            if len(self.buffer) < 8 + padded:
                return b""
            if kind == b"fmt ":
                if length < 16:
                    raise ValueError("truncated WAV format")
                fmt, channels, rate, _, alignment, bits = struct.unpack_from("<HHIIHH", self.buffer, 8)
                if fmt != 1 or bits != 16 or channels not in (1, 2) or alignment != channels * 2 or not 8000 <= rate <= 96000:
                    raise ValueError("stream requires mono/stereo PCM16")
                self.channels, self.sample_rate = channels, rate
            del self.buffer[:8 + padded]
        available = len(self.buffer) if self.remaining is None else min(len(self.buffer), self.remaining)
        size = available - available % (self.channels * 2)
        pcm = bytes(self.buffer[:size])
        del self.buffer[:size]
        if self.remaining is not None:
            self.remaining -= size
        self.total_bytes += size
        if self.total_bytes > self.sample_rate * self.channels * 2 * 120:
            raise ValueError("voice segment exceeds 120 seconds")
        return pcm

    def finish(self) -> None:
        if not self.ready or not self.total_bytes:
            raise ValueError("empty or incomplete voice stream")
        if self.remaining not in (None, 0) or (self.remaining is None and self.buffer):
            raise ValueError("truncated PCM frames")
