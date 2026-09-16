from __future__ import annotations

import gzip
import hashlib
import json
from pathlib import Path

from tools.pac_server import chained_pac, pac

from gbf_cache.core import (
    CacheMeta,
    CacheStore,
    conditional_request_matches,
    is_static_host,
    request_is_cacheable,
    synthesized_headers,
)


URL = "https://prd-game-a-gbf.akamaized.net/assets/js/require-config.js"


def test_host_scope_is_narrow() -> None:
    assert is_static_host("prd-game-a-gbf.akamaized.net")
    assert is_static_host("prd-game-a6-gbf.akamaized.net")
    assert is_static_host("prd-game-a5-granbluefantasy.akamaized.net")
    assert not is_static_host("game.granbluefantasy.jp")
    assert not is_static_host("ws.game.granbluefantasy.jp")
    assert not is_static_host("example.com")


def test_only_get_static_resources_are_cacheable() -> None:
    assert request_is_cacheable("GET", URL, {})
    assert not request_is_cacheable("POST", URL, {})
    assert not request_is_cacheable("GET", "https://example.com/a.js", {})
    assert not request_is_cacheable("GET", URL, {"Range": "bytes=0-10"})
    assert not request_is_cacheable("GET", URL, {"Authorization": "x"})


def test_acgpower_legacy_layout_and_metadata(tmp_path: Path) -> None:
    legacy = tmp_path / "legacy" / "gbf"
    body = legacy / "https/assets/js/require-config.js"
    body.parent.mkdir(parents=True)
    raw = gzip.compress(b"console.log('legacy')")
    body.write_bytes(raw)
    md5 = hashlib.md5(raw, usedforsecurity=False).hexdigest()
    Path(str(body) + ".ext").write_text(
        json.dumps(
            {
                "LastModified": "Thu, 16 Jan 2025 16:40:21 GMT",
                "ETag": '"abc"',
                "at": 100,
                "md5": md5,
                "ce": "gzip",
                "ct": "text/javascript; charset=UTF-8",
                "v": 1,
            }
        ),
        encoding="utf-8",
    )
    store = CacheStore(tmp_path / "primary" / "gbf", legacy)
    entry = store.find(URL)
    assert entry is not None
    assert entry.source == "legacy"
    assert entry.body_path == body
    assert entry.meta.etag == '"abc"'
    assert entry.meta.content_encoding == "gzip"
    assert store.verify(entry)


def test_query_gets_separate_primary_key_but_legacy_stays_compatible(tmp_path: Path) -> None:
    store = CacheStore(tmp_path / "primary", tmp_path / "legacy")
    a = store.primary_path(URL + "?v=1")
    b = store.primary_path(URL + "?v=2")
    assert a != b
    assert store.legacy_path(URL + "?v=1") == store.legacy_path(URL + "?v=2")


def test_multiple_legacy_roots_choose_newest_validation(tmp_path: Path) -> None:
    roots = [tmp_path / "x64", tmp_path / "old"]
    for root, at, payload in [(roots[0], 200, b"newer"), (roots[1], 100, b"older")]:
        body = root / "https/assets/js/require-config.js"
        body.parent.mkdir(parents=True)
        body.write_bytes(payload)
        Path(str(body) + ".ext").write_text(
            json.dumps(
                {
                    "ETag": f'"{at}"',
                    "at": at,
                    "md5": hashlib.md5(payload, usedforsecurity=False).hexdigest(),
                    "ct": "text/javascript",
                    "v": 1,
                }
            ),
            encoding="utf-8",
        )
    store = CacheStore(tmp_path / "primary", roots)
    entry = store.find(URL)
    assert entry is not None
    assert entry.body_path.read_bytes() == b"newer"
    assert entry.meta.at == 200


def test_store_and_promote(tmp_path: Path) -> None:
    primary = tmp_path / "primary"
    legacy = tmp_path / "legacy"
    old = legacy / "https/assets/a.png"
    old.parent.mkdir(parents=True)
    raw = b"png-ish"
    old.write_bytes(raw)
    md5 = hashlib.md5(raw, usedforsecurity=False).hexdigest()
    Path(str(old) + ".ext").write_text(
        json.dumps({"ETag": '"v1"', "at": 1, "md5": md5, "ct": "image/png", "v": 1}),
        encoding="utf-8",
    )
    url = "https://prd-game-a2-gbf.akamaized.net/assets/a.png"
    store = CacheStore(primary, legacy)
    entry = store.find(url)
    assert entry and entry.source == "legacy"
    promoted = store.promote(
        url,
        entry,
        now=200,
        validation_headers={
            "ETag": '"edge-v2"',
            "Last-Modified": "Tue, 02 Jan 2024 00:00:00 GMT",
            "Cache-Control": "public, max-age=31536000, immutable",
        },
    )
    assert promoted.source == "primary"
    assert promoted.body_path.read_bytes() == raw
    assert promoted.meta.at == 200
    assert promoted.meta.etag == '"edge-v2"'
    assert promoted.meta.last_modified == "Tue, 02 Jan 2024 00:00:00 GMT"
    assert promoted.meta.cache_control == "public, max-age=31536000, immutable"
    assert store.find(url).source == "primary"


def test_conditional_and_cors_synthesis() -> None:
    meta = CacheMeta(
        etag='"abc"',
        last_modified="Mon, 01 Jan 2024 00:00:00 GMT",
        content_type="font/woff2",
    )
    assert conditional_request_matches(meta, {"If-None-Match": '"abc"'})
    h = synthesized_headers(meta, "prd-game-a-granbluefantasy.akamaized.net", None)
    assert h["access-control-allow-origin"] == "https://game.granbluefantasy.jp"


def test_system_pac_only_intercepts_gbf_static_hosts() -> None:
    script = pac(18123)
    assert 'return "PROXY 127.0.0.1:18123; DIRECT"' in script
    assert script.count('return "DIRECT"') == 1


def test_browser_proxy_pac_preserves_existing_socks_route() -> None:
    script = chained_pac(18123, "SOCKS5 127.0.0.1:1080; DIRECT")
    assert 'return "PROXY 127.0.0.1:18123; SOCKS5 127.0.0.1:1080; DIRECT"' in script
    assert 'return "SOCKS5 127.0.0.1:1080; DIRECT"' in script


def test_browser_proxy_pac_rejects_source_injection() -> None:
    import pytest

    with pytest.raises(ValueError):
        chained_pac(18123, 'DIRECT"; alert(1); "DIRECT')
