# Deployment guide

本文档面向另一台 Windows 机器上的人或自动化 Agent。目标是部署 GBF 静态资源本地缓存，同时保证其它网站流量不经过本项目代理。

项目支持两种运行方式：

- **WSL2 模式**：服务运行在 WSL，适合已经长期使用 WSL 的机器；
- **Windows native 模式**：服务直接运行在 Windows Python 中，不需要 WSL，详见 [`windows-native.md`](windows-native.md)。

两种方式只选一种即可；默认都占用 `18123/18124`，不要同时启动。

## 1. WSL2 模式前提

推荐环境：

- Windows 10/11
- WSL2（Ubuntu 或其它常见 Linux 发行版）
- Google Chrome / Chromium（Windows 版）
- WSL 内可用 `git`、`curl`、Python 3
- 推荐安装 `uv`；没有 `uv` 时需要 `python3 -m venv` 可用
- Windows PowerShell 5.1+

服务运行在 WSL 中，Windows Chrome 通过系统 PAC 只把 GBF 静态 CDN 请求送到 WSL 的 localhost proxy。

如果目标环境不方便使用 WSL，直接跳到 [`windows-native.md`](windows-native.md)，无需安装 WSL。

## 2. Clone 与配置

```bash
git clone <repo-url> gbf-local-cache
cd gbf-local-cache
cp .env.example .env
```

编辑 `.env`。

### 没有 ACGPower 旧缓存

```bash
GBF_LEGACY_CACHE_ROOTS=""
```

这是完全支持的模式；项目本身并不依赖 ACGPower。

### 有 ACGPower 旧缓存

例如 Windows `F:` 盘上有：

```text
F:\Programs\acgpower-x64\cache\gbf
F:\Programs\acgpower\cache\gbf
```

WSL 配置写成：

```bash
GBF_LEGACY_CACHE_ROOTS="/mnt/f/Programs/acgpower-x64/cache/gbf;/mnt/f/Programs/acgpower/cache/gbf"
```

可以填写 1 个或多个目录，使用分号 `;` 分隔。目录不存在也不会阻止启动，只是不会被使用。

legacy cache 只读；不要把几十 GB 的旧缓存复制进 Git 仓库。项目只需要目录路径。

### Primary cache

默认：

```bash
GBF_CACHE_ROOT="$HOME/.cache/gbf-local-cache/gbf"
```

建议留在 WSL/ext4，而不是 `/mnt/c`、`/mnt/d` 等 NTFS mount，因为 GBF 缓存会产生大量小文件。

## 3. 安装 Python 依赖并启动

```bash
./bin/install.sh
```

脚本会：

1. 若缺少 `.env`，从 `.env.example` 创建；
2. 创建 `.venv`；
3. 安装 `requirements.txt`；
4. 启动 PAC server + mitmproxy；
5. 生成本机独立 CA；
6. 在 WSL/Windows interop 可用时，把公钥证书复制到 `%LOCALAPPDATA%\GBFLocalCache\mitmproxy-ca-cert.cer`。

检查：

```bash
./bin/status.sh
curl -fsS http://127.0.0.1:18124/proxy.pac
```

## 4. Windows 安装 CA 并启用 PAC

从 Windows PowerShell 执行仓库中的：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\enable.ps1
```

默认行为：

- 检查 `http://127.0.0.1:18124/proxy.pac` 是否可达；
- 从 `%LOCALAPPDATA%\GBFLocalCache\mitmproxy-ca-cert.cer` 安装当前用户根证书；
- 只修改当前用户的 `AutoConfigURL`；
- 不修改 `ProxyEnable` / `ProxyServer`；
- 备份原来的 `AutoConfigURL`，用于回滚。

第一次安装根 CA 时 Windows 可能显示安全确认。应确认这是当前安装刚生成的本地 mitmproxy CA；不要接受来源不明的证书。

### 已有公司/系统 PAC

如果目标机器已经配置了非空 `AutoConfigURL`，`enable.ps1` **默认拒绝覆盖**，以免破坏公司网络设置。

先人工/Agent 评估现有 PAC。确实要替换时才使用：

```powershell
.\windows\enable.ps1 -ForceReplacePac
```

`disable.ps1` 会恢复启用前保存的 `AutoConfigURL`。

## 5. Chrome

Windows Chrome 默认遵循系统 PAC，因此通常不需要浏览器扩展或 Chrome 内单独设置代理。

启用后建议把 Chrome **全部退出并重新打开一次**，让现有进程重新读取 PAC 和受信任 CA。

验证时打开 DevTools → Network，检查一个 GBF 静态资源的响应头：

```text
X-GBF-Local-Cache: HIT-PRIMARY
```

也可能首先看到：

```text
X-GBF-Local-Cache: MISS-STORED
X-GBF-Local-Cache: REVALIDATED
```

随后重复访问应逐步转为 `HIT-PRIMARY`。

## 6. 登录自启动（可选）

先查 WSL distro：

```powershell
wsl.exe -l -q
```

然后传入仓库在 WSL 中的绝对路径：

```powershell
.\windows\install-autostart.ps1 `
  -Distro Ubuntu-24.04 `
  -RepoPath /home/user/src/gbf-local-cache
```

如果省略 `-Distro`，脚本会尝试选择 `wsl.exe -l -q` 返回的第一个发行版。

它只在当前用户 Startup 目录创建一个静默 VBS；不会创建系统服务。

移除：

```powershell
.\windows\uninstall-autostart.ps1
```

## 7. 回滚

停止 WSL 服务：

```bash
./bin/stop.sh
```

恢复 Windows PAC：

```powershell
.\windows\disable.ps1
```

连同本项目 CA 一起移除：

```powershell
.\windows\disable.ps1 -RemoveCertificate
```

注意：删除代码前先执行回滚比较干净；legacy ACGPower cache 目录本身从未被本项目修改。

## 8. Agent 部署验收清单

部署 Agent 至少应给出这些可验证结果：

1. WSL 模式 `./bin/status.sh` 或 native 模式 `.\windows\status-native.ps1` 显示 running；
2. `18123` 和 `18124` 正在监听；
3. PAC 对 `prd-game-a-gbf.akamaized.net` 返回 `PROXY 127.0.0.1:18123; DIRECT`；
4. PAC 对 `game.granbluefantasy.jp`、`ws.game.granbluefantasy.jp`、普通网站返回 `DIRECT`；
5. Windows CurrentUser Root 中存在当前安装生成的 CA；
6. Chrome/Windows 普通网络栈请求 GBF 静态资源能看到 `X-GBF-Local-Cache`；
7. 访问普通网站时本地 proxy 日志不应出现对应请求；
8. WSL 的 `.env` 或 native 的 `.env.windows` 中 legacy cache 路径符合目标机器，不应照抄示例而不检查实际磁盘；
9. `.state/`、`.env`、`.env.windows`、`.venv-windows/`、实际缓存、CA 私钥不可提交到 Git。

## 9. 端口和其它参数

`.env` 可改：

```bash
GBF_CACHE_PROXY_PORT=18123
GBF_CACHE_PAC_PORT=18124
GBF_CACHE_FRESH_SECONDS=21600
```

如果改 PAC 端口，Windows `enable.ps1` 也需要传对应 URL：

```powershell
.\windows\enable.ps1 -PacUrl http://127.0.0.1:19124/proxy.pac
```

如果证书没有放在默认目录：

```powershell
.\windows\enable.ps1 -CertPath C:\path\to\mitmproxy-ca-cert.cer
```
