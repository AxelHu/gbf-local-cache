# Browser proxy extension integration

如果 Chrome 没有代理扩展控制 `chrome.proxy`，推荐继续使用 Windows 系统 PAC：

```text
http://127.0.0.1:18124/proxy.pac
```

该 PAC 只把 GBF 静态 CDN 送到本地缓存，其余全部 `DIRECT`。

但 ZeroOmega / SwitchyOmega 等扩展一旦选择 `FixedProfile` / `PacProfile`，扩展的 `chrome.proxy` 设置会优先于 Windows `AutoConfigURL`。此时即使系统 PAC 配置完全正确，真实 Chrome 请求也可能完全不经过 `18123`。

## 保留现有 SOCKS 代理

例如原 Chrome 路径是：

```text
Chrome -> ZeroOmega -> SOCKS5 127.0.0.1:1080 -> Shadowsocks
```

配置：

```bash
GBF_BROWSER_FALLBACK_PROXY="SOCKS5 127.0.0.1:1080; DIRECT"
```

然后让 ZeroOmega 的 PAC profile 使用：

```text
http://127.0.0.1:18124/browser-proxy.pac
```

生成的 PAC 逻辑是：

```javascript
function FindProxyForURL(url, host) {
    host = (host || "").toLowerCase();
    if (/^prd-game-a[0-9]*-(gbf|granbluefantasy)\.akamaized\.net$/.test(host)) {
        return "PROXY 127.0.0.1:18123; SOCKS5 127.0.0.1:1080; DIRECT";
    }
    return "SOCKS5 127.0.0.1:1080; DIRECT";
}
```

因此只有 GBF 静态资源被插入本地缓存层；动态 GBF 请求和其它浏览器流量仍保持原有代理路径。

## 复用旧 ACGPower ZeroOmega profile

一些旧机器的 ZeroOmega / SwitchyOmega 中仍保留：

```text
http://127.0.0.1:8123/proxy.pac
```

可配置：

```bash
GBF_ACGPOWER_COMPAT_PAC_PORT=8123
```

本项目会额外监听 8123，并在 `/proxy.pac` 返回 browser PAC。这样旧 ACGPower profile 不需要修改 URL，ACGPower 程序本体也不需要运行。

## cache miss 的上游路径

`GBF_BROWSER_FALLBACK_PROXY` 只决定浏览器中 **非 GBF 静态资源** 的 fallback。GBF 静态请求进入 `18123` 后，如果发生 cache miss / revalidate，mitmproxy 自己仍需要访问 CDN。

若现有上游是 HTTP CONNECT proxy，可以设置：

```bash
GBF_UPSTREAM_PROXY="http://127.0.0.1:PORT"
```

mitmproxy 12 的 upstream mode 不直接接受 SOCKS5 upstream。因此纯 SOCKS5 环境中，cache hit 仍完全本地；miss/revalidate 默认由缓存服务自身访问 CDN。动态 GBF 请求仍按 browser PAC fallback 走原 SOCKS5。

## 验收必须用真实 Chrome

不要只用 `curl -x 127.0.0.1:18123` 代替浏览器验收。至少让实际日常 Chrome 请求一次 GBF 静态资源，并检查 `service.log`：

```text
[...][127.0.0.1:PORT] client connect
[...] GBF cache HIT (primary, ... bytes): ...
```

如果 Windows `AutoConfigURL` 看起来正确，但实际 Chrome 请求完全不出现在 `18123` 日志中，应优先检查拥有 `proxy` 权限的浏览器扩展以及当前 ZeroOmega / SwitchyOmega profile。
