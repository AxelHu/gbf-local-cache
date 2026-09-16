from __future__ import annotations

import asyncio
import os
import time
from pathlib import Path

import httpx

from mitmproxy import ctx, http

from gbf_cache.core import (
    CacheEntry,
    CacheStore,
    conditional_request_matches,
    etag_content_md5,
    representation_matches,
    request_is_cacheable,
    response_is_cacheable,
    synthesized_headers,
    validators,
)


class Stats:
    def __init__(self) -> None:
        self.hit_primary = 0
        self.hit_legacy = 0
        self.revalidated = 0
        self.cross_version = 0
        self.cross_version_probe = 0
        self.miss = 0
        self.stored = 0
        self.bytes_saved = 0
        self.bad_cache = 0


class GBFLocalCache:
    def __init__(self) -> None:
        primary = Path(os.environ.get("GBF_CACHE_ROOT", "~/.cache/gbf-local-cache/gbf")).expanduser()
        legacy_values = os.environ.get("GBF_LEGACY_CACHE_ROOTS", "")
        legacy = [Path(value).expanduser() for value in legacy_values.split(";") if value]
        self.store = CacheStore(primary, legacy)
        self.fresh_seconds = int(os.environ.get("GBF_CACHE_FRESH_SECONDS", "21600"))
        self.cross_version_reuse = os.environ.get("GBF_CROSS_VERSION_REUSE", "1").lower() not in {
            "0",
            "false",
            "no",
            "off",
        }
        self.cross_version_probe_timeout = float(
            os.environ.get("GBF_CROSS_VERSION_PROBE_TIMEOUT", "3")
        )
        self.upstream_proxy = os.environ.get("GBF_UPSTREAM_PROXY", "").strip()
        self._probe_client: httpx.AsyncClient | None = None
        self.pending: dict[str, CacheEntry] = {}
        self.stats = Stats()

    def running(self) -> None:
        legacy = ", ".join(str(root) for root in self.store.legacy_roots) or "disabled"
        ctx.log.info(
            f"GBF local cache ready: primary={self.store.primary_root}, legacy={legacy}, "
            f"fresh={self.fresh_seconds}s, cross_version={self.cross_version_reuse}"
        )

    async def request(self, flow: http.HTTPFlow) -> None:
        req = flow.request
        if not request_is_cacheable(req.method, req.pretty_url, req.headers):
            return

        entry = self.store.find(req.pretty_url)
        if entry is None:
            if self.cross_version_reuse:
                candidate = self.store.find_cross_version(req.pretty_url)
                if candidate is not None and self.store.verify(candidate):
                    self.stats.cross_version_probe += 1
                    ctx.log.info(
                        f"GBF cache cross-version probe ({candidate.source}): "
                        f"{candidate.body_path} -> {req.pretty_url}"
                    )
                    head_headers = await self._head_probe(req.pretty_url, req.headers)
                    matched = None
                    if head_headers:
                        if representation_matches(candidate, head_headers):
                            matched = candidate
                        else:
                            digest = etag_content_md5(head_headers.get("etag"))
                            if digest:
                                matched = self.store.find_cross_version(
                                    req.pretty_url,
                                    content_md5=digest,
                                    content_encoding=head_headers.get("content-encoding", ""),
                                )
                                if matched is not None and (
                                    not self.store.verify(matched)
                                    or not representation_matches(matched, head_headers)
                                ):
                                    matched = None
                    if matched is not None:
                        promoted = self.store.promote(
                            req.pretty_url,
                            matched,
                            now=int(time.time()),
                            validation_headers=head_headers,
                        )
                        status = (
                            304
                            if conditional_request_matches(promoted.meta, req.headers)
                            else 200
                        )
                        flow.response = self._response_from_entry(
                            flow,
                            promoted,
                            status_code=status,
                            marker="CROSS-VERSION",
                        )
                        flow.metadata["gbf_local_cache_served"] = True
                        self.stats.cross_version += 1
                        self.stats.bytes_saved += promoted.size
                        ctx.log.info(
                            f"GBF cache cross-version reused {promoted.size} bytes: "
                            f"{matched.body_path} -> {promoted.body_path}"
                        )
                        return
            self.stats.miss += 1
            return
        if not self.store.verify(entry):
            self.stats.bad_cache += 1
            ctx.log.warn(f"GBF cache integrity check failed: {entry.body_path}")
            return

        # Legacy ACGPower files do not record which GBF CDN family produced the
        # body, so never trust their age alone. Primary entries include host
        # metadata and are safe to serve inside the normal freshness window.
        if entry.source == "primary" and self.store.fresh(entry, self.fresh_seconds):
            if conditional_request_matches(entry.meta, req.headers):
                flow.response = self._response_from_entry(flow, entry, status_code=304)
            else:
                flow.response = self._response_from_entry(flow, entry)
            flow.metadata["gbf_local_cache_served"] = True
            self._record_hit(entry)
            return

        check_headers = validators(entry.meta)
        if check_headers:
            # Validate the exact current URL, including query parameters. This is
            # especially important for ACGPower's host/query-independent legacy key.
            req.headers.pop("If-None-Match", None)
            req.headers.pop("If-Modified-Since", None)
            for name, value in check_headers.items():
                req.headers[name] = value
            self.pending[flow.id] = entry
            ctx.log.info(f"GBF cache revalidate ({entry.source}): {req.pretty_url}")
        else:
            self.stats.miss += 1

    def response(self, flow: http.HTTPFlow) -> None:
        req = flow.request
        if flow.metadata.pop("gbf_local_cache_served", False):
            return
        if not request_is_cacheable(req.method, req.pretty_url, req.headers):
            self.pending.pop(flow.id, None)
            return

        pending = self.pending.pop(flow.id, None)
        res = flow.response
        if res is None:
            return

        if pending is not None and res.status_code == 304:
            promoted = self.store.promote(
                req.pretty_url,
                pending,
                now=int(time.time()),
                validation_headers=res.headers,
            )
            flow.response = self._response_from_entry(flow, promoted, marker="REVALIDATED")
            flow.metadata["gbf_local_cache_served"] = True
            self.stats.revalidated += 1
            self.stats.bytes_saved += promoted.size
            ctx.log.info(f"GBF cache revalidated -> local: {req.pretty_url}")
            return

        raw = res.raw_content or b""
        if response_is_cacheable(res.status_code, req.pretty_url, res.headers, raw):
            stored = self.store.store(req.pretty_url, raw, res.headers, now=int(time.time()))
            res.headers["X-GBF-Local-Cache"] = "MISS-STORED"
            self.stats.stored += 1
            ctx.log.info(f"GBF cache stored {len(raw)} bytes: {stored.body_path}")

    def error(self, flow: http.HTTPFlow) -> None:
        self.pending.pop(flow.id, None)

    async def done(self) -> None:
        if self._probe_client is not None:
            await self._probe_client.aclose()
            self._probe_client = None

    async def _head_probe(self, url: str, request_headers: object) -> dict[str, str] | None:
        headers: dict[str, str] = {}
        for name in ("Accept-Encoding", "Accept", "User-Agent"):
            try:
                value = request_headers.get(name)  # type: ignore[attr-defined]
            except AttributeError:
                value = None
            if value:
                headers[name] = str(value)

        if self._probe_client is None:
            self._probe_client = httpx.AsyncClient(
                proxy=self.upstream_proxy or None,
                http2=True,
                trust_env=False,
                follow_redirects=False,
                timeout=httpx.Timeout(self.cross_version_probe_timeout),
            )
        try:
            response = await asyncio.wait_for(
                self._probe_client.head(url, headers=headers),
                timeout=self.cross_version_probe_timeout,
            )
            if response.status_code != 200:
                return None
            return {str(k).lower(): str(v) for k, v in response.headers.items()}
        except (httpx.HTTPError, TimeoutError) as exc:
            ctx.log.info(f"GBF cache cross-version probe skipped: {exc}")
            return None

    def _record_hit(self, entry: CacheEntry) -> None:
        if entry.source == "primary":
            self.stats.hit_primary += 1
        else:
            self.stats.hit_legacy += 1
        self.stats.bytes_saved += entry.size
        ctx.log.info(f"GBF cache HIT ({entry.source}, {entry.size} bytes): {entry.body_path}")

    def _response_from_entry(
        self,
        flow: http.HTTPFlow,
        entry: CacheEntry,
        *,
        status_code: int = 200,
        marker: str | None = None,
    ) -> http.Response:
        origin = flow.request.headers.get("Origin")
        headers = synthesized_headers(entry.meta, flow.request.host, origin)
        headers["X-GBF-Local-Cache"] = marker or f"HIT-{entry.source.upper()}"

        if status_code == 304:
            # A local 304 lets the browser reuse its own cache without even copying
            # the body from disk.
            for name in ("content-type", "content-encoding"):
                headers.pop(name, None)
            return http.Response.make(304, b"", headers)

        raw = entry.body_path.read_bytes()
        response = http.Response.make(200, b"", headers)
        # Preserve ACGPower's raw compressed body. mitmproxy's .content property
        # transparently decodes it when needed, while the client receives the
        # exact encoding advertised in Content-Encoding.
        response.raw_content = raw
        response.headers["Content-Length"] = str(len(raw))
        return response


addons = [GBFLocalCache()]
