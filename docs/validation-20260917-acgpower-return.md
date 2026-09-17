# Operational checkpoint — 2026-09-17 ACGPower return

ACGPower service availability returned, so the home GBF browser was switched
back to the original ACGPower runtime. The replacement remains installed as a
standby implementation; no primary or legacy cache data was deleted.

## Home runtime switch

- Replacement `gbf-local-cache.service`: `inactive` and `disabled`.
- Replacement ports `18123` / `18124`: free.
- Replacement Windows Startup entry: removed.
- Replacement Windows `AutoConfigURL`: restored to the pre-install value
  (empty on this machine).
- ACGPower x64 runtime: `F:\Programs\acgpower-x64\ACGPower.exe`.
- ACGPower proxy/PAC listener: `127.0.0.1:8123`.
- ACGPower GBF `Enable`, `Store`, and `LocalCache` settings remain enabled.

The existing ZeroOmega `acgpower` profile was refreshed with its own
`updateProfile(..., "bypass_cache")` path before being applied. Chrome's
effective PAC then contained `127.0.0.1:8123`, GBF static/main-site rules and
the ACGPower SOCKS5 WebSocket rule, and no longer contained the replacement's
`127.0.0.1:18123` route.

## Real browser proof

Before the switch validation, this ACGPower x64 cache object did not exist:

```text
cache/gbf/https/assets/1789531866/js/view/quest/list-sub.js
```

The already-running normal Windows Chrome was then opened to the corresponding
real GBF CDN URL. ACGPower created the body and sibling `.ext` metadata in its
cache. The stored body was 15,032 bytes with MD5:

```text
0a62c9a1c2f4dca9faf400312014c83a
```

The metadata contained the matching MD5 and the live ETag/Last-Modified values.
This proves the daily Windows Chrome was actually routed through ACGPower, not
merely configured with a PAC that looked correct.

A direct Windows client probe through ACGPower also returned the real
`require-config.js` successfully; the second request completed in roughly
21 ms in that small validation sample.

## Standby posture

Keep the replacement repository, WSL primary cache, ACGPower-compatible legacy
readers, systemd unit file, Windows-native deployment path, cross-version reuse
and content-addressed deduplication intact. They are retained as a tested
fallback if ACGPower becomes unavailable again. Do not enable the replacement
systemd service while ACGPower owns port `8123` unless the ACGPower-compat PAC
port is changed or ACGPower is stopped first.

ACGPower's own Windows autostart behavior was not changed during this switch;
the application was started explicitly for this session.
