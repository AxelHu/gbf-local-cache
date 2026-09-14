# GBF Local Cache

本地《碧蓝幻想》静态资源 HTTPS 缓存，目标是替代 ACGPower 的 GBF 本地缓存功能，而不接管其它网站流量。

## 边界

- PAC **只**代理 `prd-game-a*-gbf.akamaized.net` 与 `prd-game-a*-granbluefantasy.akamaized.net`。
- `game.granbluefantasy.jp`、登录、API、WebSocket 以及所有其它网站均 `DIRECT`。
- GBF CDN 规则带 `DIRECT` fallback：本地服务停止时，浏览器仍可直接访问 CDN。
- 只缓存 GET 静态资源；Range、Authorization、HTML/JSON、`no-store`/`private` 响应绕过缓存。

## ACGPower 兼容

ACGPower 的 GBF 缓存布局为 `cache/gbf/<scheme>/<absolute path>`，旁边的 `.ext` JSON 保存 `LastModified`、`ETag`、`at`、`md5`、`ce`、`ct`、`v`。本项目直接读取现有两套缓存：

1. `F:\Programs\acgpower-x64\cache\gbf`：62,919 个正文，约 1.61 GiB；最近写入 2026-09-10。
2. `F:\Programs\acgpower\cache\gbf`：636,178 个正文，约 16.78 GiB；另有约 59 万 `.ext` 元数据。

两套都视为 **只读 legacy 层**。同一路径若两边都有，优先使用 `.ext` 中最近一次校验/访问时间较新的版本；随后仍会按 ETag/Last-Modified 对当前 CDN 做条件请求。仍有效则按需提升到 WSL ext4 的 primary cache，避免长期在 `/mnt/f` 上承受大量小文件 I/O。新/更新资源只写：

`~/.cache/gbf-local-cache/gbf`

默认 6 小时内的已验证 primary cache 直接本地命中，之后再条件校验一次。

## 运行

```bash
./bin/start.sh
./bin/status.sh
./bin/stop.sh
```

端口：HTTPS forward proxy `18123`；PAC HTTP server `18124`。

mitmproxy CA 位于 `.state/mitmproxy/mitmproxy-ca-cert.cer`。Windows 启用脚本使用复制到 `F:\Programs\gbf-local-cache\mitmproxy-ca-cert.cer` 的证书，并只修改当前用户的 `AutoConfigURL`。原值会备份，`disable.ps1` 可恢复。

当前机器的 Windows CurrentUser Root 已安装本项目独立 CA；PAC 为 `http://127.0.0.1:18124/proxy.pac`。PAC 仅对 GBF 静态 Akamai 域名返回本地代理，其余全部 `DIRECT`，并为 GBF 本地代理配置 `DIRECT` fallback。

可选的登录自启动：

```powershell
F:\Programs\gbf-local-cache\windows\install-autostart.ps1
```

它只在当前用户 Startup 目录写一个静默 VBS，启动 WSL 中的缓存服务；`uninstall-autostart.ps1` 可移除。PAC/证书不依赖这个启动项，服务若未启动时静态 CDN 会自动回退直连。

## 测试

```bash
.venv/bin/pytest -q
```

真实 CDN 首次请求应显示 `X-GBF-Local-Cache: MISS-STORED` 或 `REVALIDATED`；紧接着第二次请求应为 `HIT-PRIMARY`。

已在本机完成三层真实验证：WSL `curl`、Windows `Invoke-WebRequest`、独立 Chrome profile。GBF 静态资源出现 `HIT-PRIMARY`；同一 Windows/Chrome 环境访问 `example.com` 时本地代理日志无请求，验证了非 GBF 流量不经过 18123。
