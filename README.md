# GBF Local Cache

《碧蓝幻想》（Granblue Fantasy）静态资源本地 HTTPS 缓存。项目目标是复刻 ACGPower 中最有价值、又完全可以本地独立实现的 **GBF 浏览器资源缓存**，但不接管游戏 API、登录、WebSocket 或其它网站流量。

## 它做什么

- PAC **只**代理 `prd-game-a*-gbf.akamaized.net` 与 `prd-game-a*-granbluefantasy.akamaized.net` 两组 GBF 静态 Akamai CDN 域名。
- `game.granbluefantasy.jp`、登录/API、WebSocket 和所有无关网站均 `DIRECT`。
- 只缓存 GET 静态资源；Range、Authorization、HTML/JSON、`no-store`/`private` 响应绕过缓存。
- 首次下载的新资源写入本地 primary cache；之后优先从本地磁盘返回。
- 可选读取已有 ACGPower `cache/gbf` 目录作为 **只读 legacy cache**，用 ETag / Last-Modified 验证后复用，无需运行 ACGPower 本体。
- 对 `/assets/<version>/...` 资源支持**跨版本复用**：新版本首次访问先用短 HEAD 验证 ETag 哈希、长度和编码，正文未变化时直接复用旧版本 body，不重新下载。
- primary body 使用 `.objects/md5/...` 内容寻址池 + hardlink 去重；不同版本/URL 若正文完全相同，只占一份磁盘数据。
- GBF CDN 的 PAC 规则包含 `DIRECT` fallback：本地缓存服务停掉时，静态资源仍可直接访问 CDN。

## 两种部署方式

两种方式使用完全相同的缓存核心、PAC 和 Chrome 配置，任选一种即可；**不要让两种运行时同时占用同一组端口**。

### A. Windows + WSL2（推荐给已有 WSL 的机器）

```bash
git clone <repo-url> gbf-local-cache
cd gbf-local-cache
cp .env.example .env
# 按本机情况编辑 .env；没有 ACGPower 旧缓存就把 GBF_LEGACY_CACHE_ROOTS 设为空。
./bin/install.sh
```

然后在 Windows PowerShell 中运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File "<repo-on-windows>\windows\enable.ps1"
```

第一次安装本项目的本地根 CA 时，Windows 可能弹出根证书信任确认。确认后，完全退出并重新打开 Chrome 一次即可。Chrome 默认跟随 Windows 系统 PAC，无需安装扩展、无需手动把浏览器全局代理设成 `127.0.0.1:18123`。

完整部署、企业环境已有 PAC 时的注意事项、自动启动和回滚方法见 [`docs/deployment.md`](docs/deployment.md)。

**如果 Chrome 已由 ZeroOmega / SwitchyOmega 控制代理，Windows 系统 PAC 不会接管该浏览器。** 此时不要关闭现有梯子，而是使用项目提供的 browser PAC：

```text
http://127.0.0.1:18124/browser-proxy.pac
```

例如原浏览器通过 Shadowsocks SOCKS5 `127.0.0.1:1080` 上网，可在 `.env` 中设置：

```bash
GBF_BROWSER_FALLBACK_PROXY="SOCKS5 127.0.0.1:1080; DIRECT"
```

此时 GBF 静态 CDN 会先走 `18123` 本地缓存，其余浏览器流量仍走原来的 `1080`。若 ZeroOmega 中还保留 PAC URL 为 `http://127.0.0.1:8123/proxy.pac` 的旧 ACGPower profile，也可以设置 `GBF_ACGPOWER_COMPAT_PAC_PORT=8123` 直接复用。见 [`docs/browser-proxy-integration.md`](docs/browser-proxy-integration.md)。

### B. 纯 Windows（不需要 WSL）

把仓库 clone 到普通 Windows 本地路径，例如 `C:\src\gbf-local-cache`。原生模式不要从 `\\wsl.localhost\...` UNC 路径运行，因为 Windows Python venv 不适合建在 WSL UNC 文件系统中。

PowerShell：

```powershell
git clone <repo-url> C:\src\gbf-local-cache
cd C:\src\gbf-local-cache
Copy-Item .env.windows.example .env.windows
# 按机器实际情况编辑 .env.windows；无 ACGPower 旧缓存就把 GBF_LEGACY_CACHE_ROOTS 设为空。

# 已有 Python 3.12+：
.\windows\install-native.ps1

# 没有兼容 Python，且机器有 winget：
.\windows\install-native.ps1 -InstallPython

.\windows\enable.ps1
```

默认 Windows primary cache：

```text
%LOCALAPPDATA%\GBFLocalCache\cache\gbf
```

原生模式的运行管理：

```powershell
.\windows\start-native.ps1
.\windows\status-native.ps1
.\windows\stop-native.ps1
```

登录自启动：

```powershell
.\windows\install-native-autostart.ps1
```

完整纯 Windows 说明见 [`docs/windows-native.md`](docs/windows-native.md)。这条路径已经在 Windows Python 3.12 + mitmproxy 12.2.3 上做过真实 CDN 与 legacy cache 端到端验证，并非仅文档级支持。

## 缓存目录配置

WSL 模式默认 primary cache：

```text
~/.cache/gbf-local-cache/gbf
```

建议 primary cache 放在 WSL/ext4 上，因为 GBF 会产生大量小文件。

纯 Windows 模式则使用 `.env.windows`，默认：

```text
%LOCALAPPDATA%\GBFLocalCache\cache\gbf
```

如果有较快的本地 SSD，也可以把 `GBF_CACHE_ROOT` 改到其它 Windows 本地目录。

ACGPower legacy cache 完全可选。`.env.example` 中保留了常见目录作为**示例**：

```bash
GBF_LEGACY_CACHE_ROOTS="/mnt/f/Programs/acgpower-x64/cache/gbf;/mnt/f/Programs/acgpower/cache/gbf"
```

多目录使用分号 `;` 分隔；没有旧缓存时写：

```bash
GBF_LEGACY_CACHE_ROOTS=""
```

legacy cache 永远只读。验证成功的资源会按需提升到 primary cache，新资源也只写 primary cache。

primary cache 会区分 `gbf` 与 `granbluefantasy` 两个 CDN family，但同一 family 内的 `a/a1/a2/...` 节点仍共享缓存。这样避免继承 ACGPower “完全忽略 host” 后可能把两个 family 的不同正文混在一起。

旧版 primary cache 可以一次性迁移到新的 family 分区和内容寻址 hardlink 布局：

```bash
PYTHONPATH="$PWD" .venv/bin/python tools/migrate_primary.py \
  --root "$HOME/.cache/gbf-local-cache/gbf"

# 确认 dry-run 结果后：
PYTHONPATH="$PWD" .venv/bin/python tools/migrate_primary.py \
  --root "$HOME/.cache/gbf-local-cache/gbf" --apply
```

该工具只操作 primary，不会修改 ACGPower legacy 目录。

仓库中的 [`examples/acgpower-cache`](examples/acgpower-cache) 只包含自制的最小目录/元数据样例，不包含任何真实游戏资源。

## 运行与状态

```bash
./bin/start.sh
./bin/status.sh
./bin/stop.sh
```

默认端口：

- HTTPS forward proxy：`18123`
- PAC HTTP server：`18124`

这些值以及 cache 根目录、校验窗口在 WSL 模式使用 `.env`，Windows 原生模式使用 `.env.windows` 修改。

响应头可用于确认缓存状态：

- `X-GBF-Local-Cache: HIT-PRIMARY`：primary cache 直接命中。
- `X-GBF-Local-Cache: CROSS-VERSION`：当前版本正文经 HEAD 强校验后直接复用旧版本 body。
- `X-GBF-Local-Cache: REVALIDATED`：旧/过期缓存经 CDN 条件请求确认后复用。
- `X-GBF-Local-Cache: MISS-STORED`：本次从 CDN 下载并写入 primary cache。

## ACGPower 兼容

ACGPower 的 GBF 缓存布局近似：

```text
cache/gbf/<scheme>/<absolute URL path>
```

正文旁的 `.ext` JSON 保存 `LastModified`、`ETag`、`at`、`md5`、`ce`、`ct`、`v` 等字段。本项目兼容这种布局，但不会修改旧目录。

ACGPower 的 legacy 路径不记录 CDN host。实测发现 `-gbf` 与 `-granbluefantasy` 两个 family 在少数相同 URL path 上可能返回不同正文，因此本项目不会仅凭 legacy 的 `at` 时间直接信任它：legacy 必须先对当前 host 做在线验证，新的 primary 则按 family 分开保存。

更多逆向兼容记录见 [`docs/acgpower-compat.md`](docs/acgpower-compat.md)。

## 隔离边界

PAC 对以下域名返回本地代理：

```text
prd-game-a-gbf.akamaized.net
prd-game-a1-gbf.akamaized.net
prd-game-a2-gbf.akamaized.net
...
prd-game-a-granbluefantasy.akamaized.net
prd-game-a1-granbluefantasy.akamaized.net
...
```

而以下请求始终 `DIRECT`：

```text
game.granbluefantasy.jp
ws.game.granbluefantasy.jp
example.com
以及其它所有非上述静态 CDN 域名
```

因此它是一个“GBF 静态资源本地 CDN”，不是线路加速器。动态游戏请求的跨境网络质量仍由用户自己的网络/其它加速方案决定。

如果静态 CDN 本身也需要经过已有的本地网络代理，在 `.env` 或 `.env.windows` 中设置：

```text
GBF_UPSTREAM_PROXY="http://127.0.0.1:1080"
```

该代理只用于缓存 MISS 和过期/legacy 资源的条件校验；`HIT-PRIMARY` 不会连接上游。留空时直接连接 CDN。这里需要填写 HTTP CONNECT 代理地址；PAC 把请求交给本地缓存后，不会自动串联 Windows 的 `ProxyServer`。

## 测试

WSL：

```bash
.venv/bin/pytest -q
```

Windows 原生：

```powershell
.\.venv-windows\Scripts\python.exe -m pytest -q
```

开发机上的真实链路验证记录见 [`docs/validation-20260914.md`](docs/validation-20260914.md) 与 [`docs/validation-20260916.md`](docs/validation-20260916.md)。
