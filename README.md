# GBF Local Cache

《碧蓝幻想》（Granblue Fantasy）静态资源本地 HTTPS 缓存。项目目标是复刻 ACGPower 中最有价值、又完全可以本地独立实现的 **GBF 浏览器资源缓存**，但不接管游戏 API、登录、WebSocket 或其它网站流量。

## 它做什么

- PAC **只**代理 `prd-game-a*-gbf.akamaized.net` 与 `prd-game-a*-granbluefantasy.akamaized.net` 两组 GBF 静态 Akamai CDN 域名。
- `game.granbluefantasy.jp`、登录/API、WebSocket 和所有无关网站均 `DIRECT`。
- 只缓存 GET 静态资源；Range、Authorization、HTML/JSON、`no-store`/`private` 响应绕过缓存。
- 首次下载的新资源写入本地 primary cache；之后优先从本地磁盘返回。
- 可选读取已有 ACGPower `cache/gbf` 目录作为 **只读 legacy cache**，用 ETag / Last-Modified 验证后复用，无需运行 ACGPower 本体。
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

### B. 纯 Windows（不需要 WSL）

把仓库 clone 到普通 Windows 本地路径，例如 `C:\src\gbf-local-cache`。原生模式不要从 `\\wsl.localhost\...` UNC 路径运行，因为 Windows Python venv 不适合建在 WSL UNC 文件系统中。

PowerShell：

```powershell
git clone <repo-url> C:\src\gbf-local-cache
cd C:\src\gbf-local-cache
Copy-Item .env.windows.example .env.windows
# 按机器实际情况编辑 .env.windows；无 ACGPower 旧缓存就把 GBF_LEGACY_CACHE_ROOTS 设为空。

# 已有 Python 3.12/3.13：
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
- `X-GBF-Local-Cache: REVALIDATED`：旧/过期缓存经 CDN 条件请求确认后复用。
- `X-GBF-Local-Cache: MISS-STORED`：本次从 CDN 下载并写入 primary cache。

## ACGPower 兼容

ACGPower 的 GBF 缓存布局近似：

```text
cache/gbf/<scheme>/<absolute URL path>
```

正文旁的 `.ext` JSON 保存 `LastModified`、`ETag`、`at`、`md5`、`ce`、`ct`、`v` 等字段。本项目兼容这种布局，但不会修改旧目录。

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

## 测试

WSL：

```bash
.venv/bin/pytest -q
```

Windows 原生：

```powershell
.\.venv-windows\Scripts\python.exe -m pytest -q
```

开发机上的真实链路验证记录见 [`docs/validation-20260914.md`](docs/validation-20260914.md)。
