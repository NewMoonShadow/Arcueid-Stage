from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np


TOKEN_RE = re.compile(r"[a-zA-Z0-9_]+|[\u4e00-\u9fff]|[\u3040-\u30ff]")
PROJECT_ROOT = Path(__file__).resolve().parents[2]
LOCAL_MODEL_ROOT = PROJECT_ROOT / "tools" / "runtime" / "models"


def model_reference(environment_name: str, local_name: str, hub_name: str) -> str:
    configured = os.environ.get(environment_name)
    if configured:
        return configured
    local_path = LOCAL_MODEL_ROOT / local_name
    return str(local_path) if local_path.exists() else hub_name


def tokenize(text: str) -> list[str]:
    tokens = TOKEN_RE.findall(text.lower())
    cjk = "".join(token for token in tokens if len(token) == 1)
    return tokens + [cjk[index:index + 2] for index in range(len(cjk) - 1)]


class HashEmbedder:
    """Deterministic development fallback. Production must use BGE-M3."""
    dimension = 1024
    name = "hash-fallback"

    def encode(self, texts: list[str]) -> np.ndarray:
        matrix = np.zeros((len(texts), self.dimension), dtype=np.float32)
        for row, text in enumerate(texts):
            for token in tokenize(text):
                digest = hashlib.blake2b(token.encode("utf-8"), digest_size=8).digest()
                index = int.from_bytes(digest[:4], "little") % self.dimension
                matrix[row, index] += 1.0 if digest[4] % 2 else -1.0
        norms = np.linalg.norm(matrix, axis=1, keepdims=True)
        return matrix / np.maximum(norms, 1e-8)


class BgeEmbedder:
    dimension = 1024
    name = "BAAI/bge-m3"

    def __init__(self) -> None:
        from FlagEmbedding import BGEM3FlagModel  # type: ignore[import-not-found]

        model_path = model_reference("ARCUEID_BGE_MODEL_DIR", "bge-m3", "BAAI/bge-m3")
        self.model = BGEM3FlagModel(model_path, use_fp16=True)

    def encode(self, texts: list[str]) -> np.ndarray:
        return self.model.encode(texts, batch_size=8, max_length=1024)["dense_vecs"]


class OptionalReranker:
    def __init__(self, enabled: bool) -> None:
        self.name = "lexical-fallback"
        self.model: Any | None = None
        if enabled:
            try:
                from FlagEmbedding import FlagReranker  # type: ignore[import-not-found]

                model_path = model_reference("ARCUEID_RERANKER_MODEL_DIR", "bge-reranker-v2-m3", "BAAI/bge-reranker-v2-m3")
                self.model = FlagReranker(model_path, use_fp16=True)
                self.name = "BAAI/bge-reranker-v2-m3"
            except Exception:
                pass

    def score(self, query: str, rows: list[dict[str, Any]]) -> list[float]:
        if self.model:
            return [float(value) for value in self.model.compute_score([[query, row["search_text"]] for row in rows], normalize=True)]
        query_terms = set(tokenize(query))
        return [len(query_terms.intersection(tokenize(row["search_text"]))) / max(len(query_terms), 1) for row in rows]


@dataclass
class SearchResult:
    rows: list[dict[str, Any]]
    mode: str


class HybridIndex:
    def __init__(self, directory: Path, enabled_local_models: bool) -> None:
        self.directory = directory
        self.rows: list[dict[str, Any]] = []
        self.positions: dict[str, int] = {}
        self.namespace_rows: dict[str, list[dict[str, Any]]] = {}
        self.namespace_positions: dict[str, dict[str, int]] = {}
        self.namespace_vectors: dict[str, np.ndarray] = {}
        self.db: sqlite3.Connection | None = None
        self.vectors: np.ndarray | None = None
        self.index_embedding = "unknown"
        manifest_path = directory / "manifest.json"
        if manifest_path.exists():
            try:
                self.index_embedding = str(json.loads(manifest_path.read_text(encoding="utf-8")).get("embedding", "unknown"))
            except (json.JSONDecodeError, OSError):
                pass
        self.embedder: Any = HashEmbedder()
        if enabled_local_models and self.index_embedding == BgeEmbedder.name:
            try:
                self.embedder = BgeEmbedder()
            except Exception:
                pass
        self.reranker = OptionalReranker(enabled_local_models)
        self._load()
        if self.index_embedding != self.embedder.name:
            self.vectors = None
            self.namespace_vectors = {}

    @property
    def ready(self) -> bool:
        return bool(self.rows)

    @property
    def model_mode(self) -> str:
        dense_state = "ready" if self.vectors is not None else "disabled"
        cache_state = "ram" if self.namespace_vectors else "none"
        return f"index={self.index_embedding}; query={self.embedder.name}; dense={dense_state}; vector_cache={cache_state}; reranker={self.reranker.name}"

    def _load(self) -> None:
        records_path = self.directory / "records.jsonl"
        database_path = self.directory / "index.sqlite3"
        vectors_path = self.directory / "vectors.npy"
        if not records_path.exists() or not database_path.exists():
            return
        self.rows = [json.loads(line) for line in records_path.read_text(encoding="utf-8").splitlines() if line.strip()]
        self.positions = {row["id"]: index for index, row in enumerate(self.rows)}
        namespace_indices: dict[str, list[int]] = {}
        for index, row in enumerate(self.rows):
            namespace = str(row.get("namespace", ""))
            self.namespace_rows.setdefault(namespace, []).append(row)
            namespace_indices.setdefault(namespace, []).append(index)
        self.namespace_positions = {
            namespace: {row["id"]: index for index, row in enumerate(rows)}
            for namespace, rows in self.namespace_rows.items()
        }
        self.db = sqlite3.connect(database_path)
        self.db.row_factory = sqlite3.Row
        if vectors_path.exists():
            self.vectors = np.load(vectors_path, mmap_mode="r")
            if len(self.vectors) == len(self.rows):
                for namespace, indices in namespace_indices.items():
                    self.namespace_vectors[namespace] = np.ascontiguousarray(
                        np.asarray(self.vectors[indices], dtype=np.float32)
                    )

    def encode_query(self, query: str) -> np.ndarray | None:
        if self.vectors is None:
            return None
        return self.embedder.encode([query])[0].astype(np.float32, copy=False)

    def search_many(self, query: str, limits: dict[str, int]) -> dict[str, SearchResult]:
        query_vector = self.encode_query(query)
        return {
            namespace: self.search(query, namespace, limit, query_vector)
            for namespace, limit in limits.items()
        }

    def search(self, query: str, namespace: str, limit: int, query_vector: np.ndarray | None = None) -> SearchResult:
        candidates = self.namespace_rows.get(namespace, [])
        if not candidates:
            return SearchResult([], self.model_mode)
        lexical = self._lexical(query, namespace)
        dense = self._dense(query_vector, namespace)
        fused = self._rrf(lexical, dense)
        ordered = [candidates[index] for index in fused[:24]]
        scores = self.reranker.score(query, ordered)
        for row, score in zip(ordered, scores):
            row["retrieval_score"] = round(float(score), 4)
        ordered.sort(key=lambda row: row["retrieval_score"], reverse=True)
        return SearchResult(self._diverse(ordered, limit), self.model_mode)

    def _lexical(self, query: str, namespace: str) -> list[int]:
        if not self.db:
            return []
        positions = self.namespace_positions.get(namespace, {})
        tokens = " OR ".join(tokenize(query)[:24])
        try:
            rows = self.db.execute(
                "SELECT id, bm25(records_fts) AS score FROM records_fts WHERE records_fts MATCH ? AND namespace=? ORDER BY score LIMIT 40",
                (tokens, namespace),
            ).fetchall()
        except sqlite3.OperationalError:
            rows = []
        return [positions[row["id"]] for row in rows if row["id"] in positions]

    def _dense(self, query_vector: np.ndarray | None, namespace: str) -> list[int]:
        vectors = self.namespace_vectors.get(namespace)
        if query_vector is None or vectors is None or not len(vectors):
            return []
        scores = vectors @ query_vector
        count = min(40, len(scores))
        top_indices = np.argpartition(scores, -count)[-count:]
        ordered = top_indices[np.argsort(scores[top_indices])[::-1]]
        return [int(index) for index in ordered]

    @staticmethod
    def _rrf(lexical: list[int], dense: list[int]) -> list[int]:
        scores: Counter[int] = Counter()
        for weight, values in ((0.45, lexical), (0.55, dense)):
            for rank, index in enumerate(values, 1):
                scores[index] += weight / (60 + rank)
        return [index for index, _ in scores.most_common()]

    @staticmethod
    def _diverse(rows: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
        selected, scenes = [], set()
        for row in rows:
            scene = row.get("scene_id")
            if scene in scenes:
                continue
            selected.append(row)
            scenes.add(scene)
            if len(selected) == limit:
                break
        if len(selected) < limit:
            selected_ids = {row["id"] for row in selected}
            for row in rows:
                if row["id"] in selected_ids:
                    continue
                selected.append(row)
                if len(selected) == limit:
                    break
        return selected
