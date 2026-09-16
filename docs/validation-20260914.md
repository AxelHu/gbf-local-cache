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

## Native Windows path

The non-WSL path was subsequently exercised on the same Windows machine without replacing the existing WSL service. A temporary native instance used ports `28123/28124` while the production WSL instance remained on `18123/18124`.

- Installed Python 3.12.10 side-by-side with the pre-existing Python 3.8 using `winget`.
- Created a Windows-local `.venv-windows` and installed mitmproxy 12.2.3.
- Native `status-native.ps1` reported both PAC and mitmproxy processes healthy.
- Real `require-config.js` request: first response `MISS-STORED`, second response `HIT-PRIMARY`; both bodies MD5 `41098DDDF050C2E32D12A223C3C1E0A3` (991 bytes).
- Real legacy `basic_alphabet.woff`: `REVALIDATED`; served MD5 `FC870BC11FE7ED65195A5D74AF82E114` (16,176 bytes), matching the legacy body.
- Windows-native test suite: 7 passed.
- Native Startup VBS was installed, verified to exist, then uninstalled successfully.
- The original WSL service remained running throughout the native test.

One expected constraint was confirmed: Windows Python cannot create the native venv when the repository itself is addressed through `\\wsl.localhost\...`. Native deployments therefore require a normal Windows local-drive clone such as `C:\src\gbf-local-cache`; the installer now rejects WSL UNC roots with a clear error.

## 2026-09-16 daily Windows Chrome / ZeroOmega follow-up

The normal Windows Chrome profile was found to be controlled by ZeroOmega rather than the Windows system PAC. Its active profile used local Shadowsocks SOCKS5 `127.0.0.1:1080`, so the configured Windows `AutoConfigURL` did not affect the real browser. This explained why isolated temporary Chrome tests had passed while normal gameplay still felt uncached.

The existing old ACGPower ZeroOmega profile was reused through a compatibility PAC. Chrome's effective PAC became:

- GBF static Akamai hosts: `PROXY 127.0.0.1:18123; SOCKS5 127.0.0.1:1080; DIRECT`
- everything else: `SOCKS5 127.0.0.1:1080; DIRECT`

An actual request from the already-running daily Windows Chrome then appeared in the local proxy log. A controlled hot-path test first prewarmed a URL that Chrome had never seen; the first Chrome access produced a primary-cache hit from client connect at `11:13:50.468` to the hit log at `11:13:50.479`, about 11 ms.

The original WSL Startup helper also proved insufficient for long-lived machines because it runs only at login, and Windows `wsl.exe` used the distro's default `root` user on the validation machine. Startup and the new watchdog were corrected to run explicitly as the repo's Linux owner. A forced service stop followed by Task Scheduler execution recovered the service in about 2 seconds with `LastTaskResult = 0`, restored 18123/18124/8123, and produced an `axelhu`-owned PID/runtime rather than a root-owned one.
