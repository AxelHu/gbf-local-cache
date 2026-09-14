# ACGPower GBF cache compatibility notes

These notes record the local interoperability findings used by this project. No ACGPower source code is included.

## Local installs observed on 2026-09-14

- `F:\Programs\acgpower-x64`
  - This was the currently running GUI (`ACGPower.exe`), launched from Explorer on 2026-09-13.
  - `appsettings.config` has GBF store/local-cache switches enabled and proxy port `8123`.
  - GBF cache: 62,919 body files + 62,919 `.ext` files, about 1.61 GiB of bodies.
  - Newest observed cache write: 2026-09-10.
- `F:\Programs\acgpower`
  - Older install referenced by an old desktop shortcut.
  - GBF cache: 636,178 body files (about 16.78 GiB) + 592,649 `.ext` metadata files.
  - Not every old body has metadata; this project intentionally ignores an unindexed legacy body because it cannot be safely validated without downloading it again.

The two trees are independent files, not hard links. Some bodies are identical while metadata/validation times differ; other resources are newer in the x64 tree. The replacement therefore treats both as read-only candidate stores and selects the candidate with the newest recorded `at` timestamp before online validation.

## PAC and TLS behavior

The installed ACGPower PAC used local proxy `127.0.0.1:8123` for configured game hosts and returned `DIRECT` for unrelated hosts. Its GBF rules include the two current static Akamai families:

- `prd-game-a[0-9]*-gbf.akamaized.net`
- `prd-game-a[0-9]*-granbluefantasy.akamaized.net`

ACGPower installed a local root certificate and performed HTTPS interception for cached resources. This replacement follows the same broad HTTPS-forward-proxy architecture, but narrows PAC interception to those two GBF static CDN families only. `game.granbluefantasy.jp`, login/API traffic, WebSocket traffic, and unrelated websites are not sent to the replacement proxy.

## Disk layout

For GBF static resources, ACGPower stores bodies at approximately:

`cache/gbf/<scheme>/<absolute URL path>`

The CDN hostname is omitted, allowing the `a`, `a1`, `a2`, etc. Akamai aliases to share one cached object. A sibling `<body>.ext` JSON contains fields observed locally such as:

```json
{
  "LastModified": "...",
  "ETag": "...",
  "at": 1783998058,
  "md5": "...",
  "ce": "gzip",
  "ct": "text/javascript; charset=UTF-8",
  "v": 1
}
```

The body can be stored in its original compressed representation. `ce` and `ct` are therefore required when reconstructing a response.

## Validation behavior and replacement differences

Observed ACGPower behavior includes a local-trust window and later validator checks using `ETag` / `Last-Modified`, plus MD5 integrity metadata. The old implementation can use a HEAD-style revalidation path.

This replacement uses a conditional **GET** when a legacy/stale object needs validation:

- `304 Not Modified`: no response body is downloaded; the legacy body is promoted to fast WSL/ext4 primary storage and current edge validators are retained.
- `200 OK`: the new body has already arrived in the same request, so it is stored directly; this avoids a HEAD-then-GET double round trip when the resource changed.

New primary-cache keys additionally hash query strings. ACGPower's legacy lookup remains path-compatible so old data can be reused, but new data avoids aliasing two distinct query-versioned URLs.

## Verified examples

- `assets/font/basic_alphabet.woff`: an old ACGPower body revalidated with HTTP 304; legacy, served, and promoted primary copies had identical MD5 `fc870bc11fe7ed65195a5d74af82e114`.
- `assets/js/require-config.js`: an older legacy copy was recognized as stale and refreshed from the CDN; a second request was served entirely from primary cache without a CDN connection.

These examples intentionally exercise both major compatibility paths: reuse-without-redownload and changed-resource refresh.
