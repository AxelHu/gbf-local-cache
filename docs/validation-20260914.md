# Validation checkpoint — 2026-09-14

## Isolation

- Windows `AutoConfigURL`: `http://127.0.0.1:18124/proxy.pac`.
- Existing `ProxyEnable=0` and `ProxyServer=http://localhost:10809` were left untouched.
- Windows normal web stack fetched a GBF static resource with `X-GBF-Local-Cache: HIT-PRIMARY`.
- The same stack fetched `https://example.com/` successfully with no request appearing in local proxy logs.
- An independent Chrome temporary profile fetched a GBF static resource and produced a local-cache HIT in the proxy log.
- An independent Chrome temporary profile fetched `https://example.com/` and added zero proxy-log lines.
- `disable.ps1` restored the previous empty `AutoConfigURL`; re-enabling restored the GBF-only PAC.

## Cache behavior

- Unit tests: 7 passed at this checkpoint.
- Legacy cache integrity is checked against stored MD5 when present.
- 304 promotion and changed-resource refresh were both exercised against the real GBF CDN.
- CurrentUser root CA was explicitly verified and trusted on this machine. The deployment CA SHA-1 at this checkpoint is `963C0708D7643868E59016A28509E4426BED9C06`.

## Small-resource latency sample

Five fresh curl processes per mode were used, so each local number still includes a new local proxy/TLS connection.

| Resource | Direct median | Local-cache median | Ratio |
| --- | ---: | ---: | ---: |
| `assets/js/require-config.js` | ~0.503 s | ~0.01055 s | ~47.7x |
| `assets/font/basic_alphabet.woff` | ~0.678 s | ~0.01087 s | ~62.4x |

This ratio is a per-request round-trip comparison, not a claim that a complete GBF page becomes 48–62 times faster. A page mixes parallel requests, browser parsing/rendering, and dynamic API/server work. It does show why eliminating repeated remote static-resource checks is perceptible for GBF's many small assets.
