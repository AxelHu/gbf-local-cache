# Validation checkpoint — 2026-09-16

This checkpoint covers the normal Windows Chrome profile, proxy-extension
integration, watchdog behavior, cross-version reuse, CDN-family separation,
and content-hash deduplication.

## Windows Chrome and Shadowsocks

- The daily Chrome profile is controlled by ZeroOmega rather than the Windows
  system PAC.
- Its preserved ACGPower profile now resolves through the replacement's
  compatibility PAC on `127.0.0.1:8123`.
- Effective browser routing is:
  - GBF static CDN -> `PROXY 127.0.0.1:18123; SOCKS5 127.0.0.1:1080; DIRECT`
  - everything else -> `SOCKS5 127.0.0.1:1080; DIRECT`
- Local Shadowsocks 4.3.3.170 on port `1080` was verified to accept SOCKS5,
  HTTP proxy, and HTTPS CONNECT on the same listener.
- Cache MISS/revalidation traffic is explicitly chained through
  `GBF_UPSTREAM_PROXY=http://127.0.0.1:1080`.

## Hidden watchdog

The first watchdog implementation executed `wsl.exe` directly from Task
Scheduler every five minutes, which could briefly flash a console window.
The task now executes `wscript.exe` and a hidden VBS launcher. The VBS runs the
same `wsl.exe -d ... -u ...` command with window style `0`.

- Scheduled task action: `wscript.exe "%LOCALAPPDATA%\GBFLocalCache\watchdog.vbs"`
- Forced task execution returned `LastTaskResult = 0`.
- The WSL cache process remained owned by the repo's Linux user rather than
  `root`.

## Cross-version reuse

GBF's versioned static paths use `/assets/<timestamp>/...`. The current release
observed during this checkpoint was `1789531866`.

The replacement now searches older versions for the same logical tail, then
performs a HEAD request to the **current** URL. Reuse is allowed only when all
of these match the cached raw representation:

- 32-hex digest at the end of the current Akamai ETag;
- `Content-Length`;
- `Content-Encoding`;
- media type when both sides provide one.

Five real current-version resources were tested against an empty temporary
primary cache. All five were served as `X-GBF-Local-Cache: CROSS-VERSION`
without redownloading their bodies. After the first persistent-probe
connection, first-access times in this sample were roughly 0.26–0.46 s; the
first connection itself was about 1.08 s. Subsequent primary hits were in the
tens-of-milliseconds range.

A comparison of the current `granbluefantasy` primary cache with the immediately
previous ACGPower x64 version `1788931888` found:

- current entries: 541
- previous-version entries: 602
- same logical path in both: 374
- identical MD5: 364
- changed MD5: 10
- unchanged ratio among common paths: **97.33%**

This validates that cross-version reuse is a high-value optimization for GBF's
release pattern rather than a rare edge case.

## CDN-family separation

ACGPower omitted the CDN hostname from its cache key. Real validation showed
that collapsing the two families is unsafe. The exact same current-version
path `css/quest/index.css` returned:

- `prd-game-a-granbluefantasy.akamaized.net`: 39,668-byte gzip body,
  MD5 `631d46f9b7f7c21b1705874793ab04c7`;
- `prd-game-a-gbf.akamaized.net`: 39,575-byte gzip body,
  MD5 `91e70ddc5ecf6618f2a95df0b37330ab`.

Primary cache keys therefore separate `gbf` and `granbluefantasy`, while still
sharing `a/a1/a2/...` Akamai aliases inside one family. Hostless ACGPower legacy
entries remain read-only candidates and must validate against the current host
before promotion.

Live verification after migration showed the `granbluefantasy` CSS as a
~16–31 ms `HIT-PRIMARY`. The `gbf` variant correctly performed one
`MISS-STORED` with its different MD5, then became a ~16 ms `HIT-PRIMARY` on the
second request.

## Content-addressed deduplication and migration

New primary bodies are installed through `.objects/md5/<prefix>/<md5>` and URL
paths are hardlinks to the content object. A migration of the existing home
primary cache completed with:

- migrated: 1007
- bad: 0
- processed body bytes: 21,306,186
- unscoped old-layout bodies remaining: 0
- `granbluefantasy` URL bodies: 996
- `gbf` URL bodies: 11
- content objects after migration: 986 (987 after the later live family test)

Existing real data already demonstrated deduplication: multiple objects had
more than one URL hardlink, with the highest observed link count at 11.

## Regression

- Linux/WSL pytest: 14 passed.
- Windows Python 3.12 on NTFS pytest: 14 passed, including hardlink dedup tests.
- `pip check`: clean.
- All shell launchers passed `bash -n`.
- All PowerShell scripts parsed successfully under Windows PowerShell 5.1.
