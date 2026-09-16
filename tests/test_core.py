from __future__ import annotations

import gzip
import hashlib
import json
from pathlib import Path

from tools.pac_server import chained_pac, pac

from gbf_cache.core import (
    CacheMeta,
    CacheStore,
    RESOURCE_EXTENSIONS,
    conditional_request_matches,
    etag_content_md5,
    is_static_host,
    representation_matches,
    request_is_cacheable,
    synthesized_headers,
    versioned_asset_parts,
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


def test_resource_extensions_match_acgpower_gbf_scope() -> None:
    assert RESOURCE_EXTENSIONS == {
        ".mp3", ".swf", ".png", ".jpg", ".flv", ".js", ".css",
        ".gif", ".woff", ".otf", ".mp4", ".zip",
    }


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


def test_versioned_asset_cross_version_lookup_and_validation(tmp_path: Path) -> None:
    primary = tmp_path / "primary"
    old_url = "https://prd-game-a-gbf.akamaized.net/assets/1000000001/js/view/demo.js"
    new_url = "https://prd-game-a-gbf.akamaized.net/assets/1000000002/js/view/demo.js"
    raw = gzip.compress(b"console.log('same across versions')")
    digest = hashlib.md5(raw, usedforsecurity=False).hexdigest()
    store = CacheStore(primary)
    old = store.store(
        old_url,
        raw,
        {
            "ETag": f'"1700000000-{digest}"',
            "Content-Encoding": "gzip",
            "Content-Type": "text/javascript; charset=UTF-8",
            "Content-Length": str(len(raw)),
        },
        now=1,
    )
    candidate = store.find_cross_version(new_url)
    assert candidate is not None
    assert candidate.body_path == old.body_path
    assert versioned_asset_parts(new_url) == ("1000000002", Path("js/view/demo.js"))
    assert versioned_asset_parts(new_url + "?v=2") is None
    assert etag_content_md5(f'"1700000001-{digest}"') == digest

    head = {
        "ETag": f'"1700000001-{digest}"',
        "Content-Encoding": "gzip",
        "Content-Type": "text/javascript;charset=UTF-8",
        "Content-Length": str(len(raw)),
    }
    assert representation_matches(candidate, head)
    assert not representation_matches(candidate, {**head, "Content-Encoding": ""})
    assert not representation_matches(candidate, {**head, "Content-Length": str(len(raw) + 1)})

    promoted = store.promote(new_url, candidate, now=2, validation_headers=head)
    assert promoted.body_path != candidate.body_path
    assert promoted.body_path.read_bytes() == raw
    assert promoted.meta.etag == head["ETag"]
    # Both version URLs point at the same content-addressed inode.
    assert promoted.body_path.samefile(candidate.body_path)


def test_primary_store_hash_deduplicates_different_urls(tmp_path: Path) -> None:
    store = CacheStore(tmp_path / "primary")
    body = b"same bytes under two unrelated static URLs"
    headers = {"Content-Type": "application/octet-stream"}
    a = store.store(
        "https://prd-game-a-gbf.akamaized.net/assets/1000000001/bin/a.bin",
        body,
        headers,
    )
    b = store.store(
        "https://prd-game-a-gbf.akamaized.net/assets/1000000002/bin/b.bin",
        body,
        headers,
    )
    assert a.body_path != b.body_path
    assert a.body_path.samefile(b.body_path)
    digest = hashlib.md5(body, usedforsecurity=False).hexdigest()
    assert (store.primary_root / ".objects" / "md5" / digest[:2] / digest).is_file()


def test_primary_cache_separates_gbf_cdn_families(tmp_path: Path) -> None:
    store = CacheStore(tmp_path / "primary")
    path = "/assets/1000000001/css/quest/index.css"
    gbf_url = "https://prd-game-a-gbf.akamaized.net" + path
    granblue_url = "https://prd-game-a-granbluefantasy.akamaized.net" + path
    gbf = store.store(gbf_url, b"mobage variant", {"Content-Type": "text/css"})
    granblue = store.store(granblue_url, b"granblue variant", {"Content-Type": "text/css"})
    assert gbf.body_path != granblue.body_path
    assert "/gbf/assets/" in gbf.body_path.as_posix()
    assert "/granbluefantasy/assets/" in granblue.body_path.as_posix()
    assert store.find(gbf_url).body_path.read_bytes() == b"mobage variant"
    assert store.find(granblue_url).body_path.read_bytes() == b"granblue variant"


def test_unscoped_primary_requires_matching_family_metadata(tmp_path: Path) -> None:
    root = tmp_path / "primary"
    url = "https://prd-game-a-gbf.akamaized.net/assets/1000000001/js/a.js"
    old_body = root / "https/assets/1000000001/js/a.js"
    old_body.parent.mkdir(parents=True)
    old_body.write_bytes(b"wrong family")
    Path(str(old_body) + ".ext").write_text(
        json.dumps(
            {
                "md5": hashlib.md5(b"wrong family", usedforsecurity=False).hexdigest(),
                "host": "prd-game-a-granbluefantasy.akamaized.net",
                "ct": "text/javascript",
                "v": 2,
            }
        ),
        encoding="utf-8",
    )
    assert CacheStore(root).find(url) is None


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
