from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from collections.abc import Iterable
from typing import Mapping
from urllib.parse import urlsplit


# These are the GBF Akamai hosts ACGPower itself routed through its local proxy.
# Keep this deliberately narrow: game/login/API/WebSocket domains are not here.
STATIC_HOST_RE = re.compile(
    r"^prd-game-a\d*-(?:gbf|granbluefantasy)\.akamaized\.net$", re.IGNORECASE
)

RESOURCE_EXTENSIONS = {
    ".js",
    ".css",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".avif",
    ".svg",
    ".woff",
    ".woff2",
    ".otf",
    ".ttf",
    ".mp3",
    ".m4a",
    ".aac",
    ".ogg",
    ".wav",
    ".mp4",
    ".webm",
    ".zip",
    ".bin",
}

SAFE_RESPONSE_HEADERS = {
    "cache-control",
    "content-encoding",
    "content-type",
    "etag",
    "expires",
    "last-modified",
    "access-control-allow-origin",
    "access-control-allow-credentials",
    "timing-allow-origin",
    "vary",
}


def is_static_host(host: str) -> bool:
    return bool(STATIC_HOST_RE.fullmatch((host or "").lower()))


def is_resource_path(path: str) -> bool:
    suffix = Path(urlsplit(path).path).suffix.lower()
    return suffix in RESOURCE_EXTENSIONS


def request_is_cacheable(method: str, url: str, headers: Mapping[str, str]) -> bool:
    parsed = urlsplit(url)
    if method.upper() != "GET" or parsed.scheme not in {"http", "https"}:
        return False
    if not is_static_host(parsed.hostname or ""):
        return False
    if not is_resource_path(parsed.path):
        return False
    lowered = {str(k).lower(): str(v) for k, v in headers.items()}
    if "range" in lowered or "authorization" in lowered:
        return False
    return True


def response_is_cacheable(status_code: int, url: str, headers: Mapping[str, str], body: bytes) -> bool:
    if status_code != 200 or not body:
        return False
    if not is_resource_path(urlsplit(url).path):
        return False
    h = {str(k).lower(): str(v) for k, v in headers.items()}
    cc = h.get("cache-control", "").lower()
    if "no-store" in cc or "private" in cc:
        return False
    if "content-range" in h:
        return False
    content_type = h.get("content-type", "").lower()
    if content_type.startswith("text/html") or content_type.startswith("application/json"):
        return False
    return True


def _safe_relative_path(path: str) -> Path | None:
    # Match ACGPower's host-independent layout while refusing path traversal.
    raw = (path or "").split("?", 1)[0].lstrip("/")
    if not raw or raw.endswith("/"):
        return None
    parts = raw.split("/")
    if any(part in {"", ".", ".."} or "\x00" in part for part in parts):
        return None
    # Keep percent-escapes intact. This is deterministic and safe on Linux.
    return Path(*parts)


def _query_suffix(query: str) -> str:
    if not query:
        return ""
    return ".__q_" + hashlib.sha256(query.encode("utf-8")).hexdigest()[:16]


@dataclass
class CacheMeta:
    last_modified: str | None = None
    etag: str | None = None
    at: int = 0
    md5: str | None = None
    content_encoding: str | None = None
    content_type: str | None = None
    cache_control: str | None = None
    version: int = 1
    url: str | None = None
    host: str | None = None
    headers: dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Mapping[str, object]) -> "CacheMeta":
        extra_headers: dict[str, str] = {}
        raw_headers = data.get("headers")
        if isinstance(raw_headers, Mapping):
            extra_headers = {
                str(k).lower(): str(v)
                for k, v in raw_headers.items()
                if str(k).lower() in SAFE_RESPONSE_HEADERS and v is not None
            }
        return cls(
            last_modified=_str_or_none(data.get("LastModified") or data.get("last_modified")),
            etag=_str_or_none(data.get("ETag") or data.get("etag")),
            at=_int_or_zero(data.get("at")),
            md5=_str_or_none(data.get("md5")),
            content_encoding=_str_or_none(data.get("ce") or data.get("content_encoding")),
            content_type=_str_or_none(data.get("ct") or data.get("content_type")),
            cache_control=_str_or_none(data.get("cc") or data.get("cache_control")),
            version=_int_or_zero(data.get("v")) or 1,
            url=_str_or_none(data.get("url")),
            host=_str_or_none(data.get("host")),
            headers=extra_headers,
        )

    def to_dict(self) -> dict[str, object]:
        # Keep the ACGPower field names so the format remains easy to inspect and
        # old tooling can still understand the important bits.
        return {
            "LastModified": self.last_modified,
            "ETag": self.etag,
            "at": self.at,
            "md5": self.md5,
            "ce": self.content_encoding,
            "ct": self.content_type,
            "cc": self.cache_control,
            "v": max(self.version, 2),
            "url": self.url,
            "host": self.host,
            "headers": self.headers,
        }


def _str_or_none(value: object) -> str | None:
    if value is None:
        return None
    text = str(value)
    return text if text else None


def _int_or_zero(value: object) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


@dataclass
class CacheEntry:
    body_path: Path
    meta_path: Path
    meta: CacheMeta
    source: str  # "primary" or "legacy"

    @property
    def size(self) -> int:
        return self.body_path.stat().st_size


class CacheStore:
    def __init__(
        self,
        primary_root: Path,
        legacy_root: Path | Iterable[Path] | None = None,
    ):
        self.primary_root = Path(primary_root).expanduser()
        if legacy_root is None:
            self.legacy_roots: list[Path] = []
        elif isinstance(legacy_root, (str, os.PathLike)):
            self.legacy_roots = [Path(legacy_root).expanduser()]
        else:
            self.legacy_roots = [Path(root).expanduser() for root in legacy_root]
        self.primary_root.mkdir(parents=True, exist_ok=True)
        self._verified: dict[tuple[str, int, int, str | None], bool] = {}

    @property
    def legacy_root(self) -> Path | None:
        """Compatibility accessor for callers that only expect one legacy root."""
        return self.legacy_roots[0] if self.legacy_roots else None

    def _body_path(self, root: Path, url: str, *, include_query: bool) -> Path | None:
        parsed = urlsplit(url)
        rel = _safe_relative_path(parsed.path)
        if rel is None:
            return None
        path = root / parsed.scheme / rel
        if include_query and parsed.query:
            path = path.with_name(path.name + _query_suffix(parsed.query))
        return path

    def primary_path(self, url: str) -> Path | None:
        return self._body_path(self.primary_root, url, include_query=True)

    def legacy_path(self, url: str) -> Path | None:
        if not self.legacy_roots:
            return None
        # ACGPower keyed GBF static cache by scheme + absolute path and ignored
        # the Akamai hostname. Its layout did not distinguish query strings.
        return self._body_path(self.legacy_roots[0], url, include_query=False)

    def legacy_paths(self, url: str) -> list[Path]:
        return [
            path
            for root in self.legacy_roots
            if (path := self._body_path(root, url, include_query=False)) is not None
        ]

    def find(self, url: str) -> CacheEntry | None:
        primary = self.primary_path(url)
        entry = self._load(primary, "primary") if primary else None
        if entry:
            return entry
        # Multiple ACGPower installs may each contain a partial/older GBF cache.
        # Prefer the entry with the newest recorded validation/access timestamp;
        # correctness still comes from conditional revalidation before promotion.
        candidates = [
            entry
            for path in self.legacy_paths(url)
            if (entry := self._load(path, "legacy")) is not None
        ]
        if not candidates:
            return None
        return max(
            candidates,
            key=lambda item: (
                item.meta.at,
                item.meta_path.stat().st_mtime_ns if item.meta_path.exists() else 0,
            ),
        )

    def _load(self, body_path: Path, source: str) -> CacheEntry | None:
        if not body_path.is_file() or body_path.stat().st_size <= 0:
            return None
        meta_path = Path(str(body_path) + ".ext")
        if not meta_path.is_file():
            return None
        try:
            data = json.loads(meta_path.read_text(encoding="utf-8-sig"))
            if not isinstance(data, dict):
                return None
            meta = CacheMeta.from_dict(data)
        except (OSError, ValueError, UnicodeError):
            return None
        return CacheEntry(body_path=body_path, meta_path=meta_path, meta=meta, source=source)

    def verify(self, entry: CacheEntry) -> bool:
        try:
            stat = entry.body_path.stat()
        except OSError:
            return False
        key = (str(entry.body_path), stat.st_mtime_ns, stat.st_size, entry.meta.md5)
        if key in self._verified:
            return self._verified[key]
        ok = stat.st_size > 0
        if ok and entry.meta.md5:
            ok = _md5_file(entry.body_path).lower() == entry.meta.md5.lower()
        self._verified[key] = ok
        return ok

    @staticmethod
    def fresh(entry: CacheEntry, fresh_seconds: int, now: int | None = None) -> bool:
        if fresh_seconds <= 0 or entry.meta.at <= 0:
            return False
        now = int(time.time()) if now is None else int(now)
        age = now - int(entry.meta.at)
        return 0 <= age < fresh_seconds

    def store(self, url: str, body: bytes, headers: Mapping[str, str], now: int | None = None) -> CacheEntry:
        body_path = self.primary_path(url)
        if body_path is None:
            raise ValueError(f"URL has no cacheable path: {url}")
        body_path.parent.mkdir(parents=True, exist_ok=True)
        h = {str(k).lower(): str(v) for k, v in headers.items()}
        now = int(time.time()) if now is None else int(now)
        meta = CacheMeta(
            last_modified=h.get("last-modified"),
            etag=h.get("etag"),
            at=now,
            md5=hashlib.md5(body, usedforsecurity=False).hexdigest(),
            content_encoding=h.get("content-encoding"),
            content_type=h.get("content-type"),
            cache_control=h.get("cache-control"),
            version=2,
            url=url,
            host=urlsplit(url).hostname,
            headers={k: v for k, v in h.items() if k in SAFE_RESPONSE_HEADERS},
        )
        _atomic_write_bytes(body_path, body)
        meta_path = Path(str(body_path) + ".ext")
        _atomic_write_text(meta_path, json.dumps(meta.to_dict(), ensure_ascii=False, indent=2) + "\n")
        self._verified.clear()
        return CacheEntry(body_path=body_path, meta_path=meta_path, meta=meta, source="primary")

    def promote(
        self,
        url: str,
        entry: CacheEntry,
        now: int | None = None,
        validation_headers: Mapping[str, str] | None = None,
    ) -> CacheEntry:
        if entry.source == "primary":
            entry.meta.at = int(time.time()) if now is None else int(now)
            promoted = entry
        else:
            body = entry.body_path.read_bytes()
            headers = synthesized_headers(entry.meta, urlsplit(url).hostname or "", None)
            promoted = self.store(url, body, headers, now=now)
            # Preserve legacy representation details. Validator values may be
            # replaced immediately below if the 304 carries newer edge values.
            promoted.meta.last_modified = entry.meta.last_modified
            promoted.meta.etag = entry.meta.etag
            promoted.meta.at = int(time.time()) if now is None else int(now)
            promoted.meta.md5 = entry.meta.md5 or promoted.meta.md5
            promoted.meta.content_encoding = entry.meta.content_encoding
            promoted.meta.content_type = entry.meta.content_type
            promoted.meta.version = 2

        if validation_headers:
            h = {str(k).lower(): str(v) for k, v in validation_headers.items()}
            if h.get("etag"):
                promoted.meta.etag = h["etag"]
            if h.get("last-modified"):
                promoted.meta.last_modified = h["last-modified"]
            if h.get("cache-control"):
                promoted.meta.cache_control = h["cache-control"]
            for key, value in h.items():
                if key in SAFE_RESPONSE_HEADERS:
                    promoted.meta.headers[key] = value
            # A 304 usually omits representation headers. Only replace these
            # when the server actually supplied them.
            if h.get("content-type"):
                promoted.meta.content_type = h["content-type"]
            if h.get("content-encoding"):
                promoted.meta.content_encoding = h["content-encoding"]

        _atomic_write_text(
            promoted.meta_path,
            json.dumps(promoted.meta.to_dict(), ensure_ascii=False, indent=2) + "\n",
        )
        return promoted


def synthesized_headers(meta: CacheMeta, request_host: str, request_origin: str | None) -> dict[str, str]:
    h = {str(k).lower(): str(v) for k, v in meta.headers.items() if v is not None}
    if meta.content_type:
        h["content-type"] = meta.content_type
    if meta.content_encoding:
        h["content-encoding"] = meta.content_encoding
    if meta.etag:
        h["etag"] = meta.etag
    if meta.last_modified:
        h["last-modified"] = meta.last_modified
    if meta.cache_control:
        h["cache-control"] = meta.cache_control
    else:
        h.setdefault("cache-control", "public, max-age=3600")

    # ACGPower's legacy .ext files do not retain CORS headers. Current GBF CDN
    # responses use the corresponding game origin, so reconstruct only for the
    # two known GBF origins and never echo an arbitrary origin.
    if "access-control-allow-origin" not in h:
        known = {
            "https://game.granbluefantasy.jp",
            "https://gbf.game.mbga.jp",
        }
        if request_origin in known:
            h["access-control-allow-origin"] = request_origin
        elif "-granbluefantasy.akamaized.net" in request_host.lower():
            h["access-control-allow-origin"] = "https://game.granbluefantasy.jp"
        elif "-gbf.akamaized.net" in request_host.lower():
            h["access-control-allow-origin"] = "https://gbf.game.mbga.jp"
    return h


def validators(meta: CacheMeta) -> dict[str, str]:
    out: dict[str, str] = {}
    if meta.etag:
        out["if-none-match"] = meta.etag
    if meta.last_modified:
        out["if-modified-since"] = meta.last_modified
    return out


def conditional_request_matches(meta: CacheMeta, headers: Mapping[str, str]) -> bool:
    h = {str(k).lower(): str(v) for k, v in headers.items()}
    inm = h.get("if-none-match")
    if inm and meta.etag:
        values = {v.strip() for v in inm.split(",")}
        if "*" in values or meta.etag in values:
            return True
    ims = h.get("if-modified-since")
    if ims and meta.last_modified and ims.strip() == meta.last_modified.strip():
        return True
    return False


def _md5_file(path: Path) -> str:
    md5 = hashlib.md5(usedforsecurity=False)
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            md5.update(chunk)
    return md5.hexdigest()


def _atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def _atomic_write_text(path: Path, data: str) -> None:
    _atomic_write_bytes(path, data.encode("utf-8"))
