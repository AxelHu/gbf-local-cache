# Native Windows deployment

这条部署路径完全不需要 WSL。缓存核心仍是 `gbf_cache/`，Windows Python 直接运行 PAC server 与 mitmproxy。

## 1. 前提

- Windows 10/11；
- Windows PowerShell 5.1+；
- Google Chrome / Chromium；
- Git；
- Python **3.12 或 3.13**。mitmproxy 12.2.3 要求 Python >=3.12；当前脚本暂不自动选择 3.14+。

如果没有兼容 Python，但机器有 `winget`，安装脚本可以使用官方 `Python.Python.3.12` 包：

```powershell
.\windows\install-native.ps1 -InstallPython
```

## 2. 仓库必须位于 Windows 本地文件系统

推荐：

```text
C:\src\gbf-local-cache
D:\Tools\gbf-local-cache
```

不要直接从：

```text
\\wsl.localhost\Ubuntu\home\...\gbf-local-cache
```

运行 native installer。Windows Python 在 WSL UNC 路径创建 venv 会失败；安装脚本会主动检测并给出错误。

## 3. 配置

```powershell
Copy-Item .env.windows.example .env.windows
notepad .env.windows
```

默认配置：

```text
GBF_CACHE_ROOT="%LOCALAPPDATA%\GBFLocalCache\cache\gbf"
GBF_LEGACY_CACHE_ROOTS="F:\Programs\acgpower-x64\cache\gbf;F:\Programs\acgpower\cache\gbf"
GBF_CACHE_FRESH_SECONDS=21600
GBF_CACHE_PROXY_PORT=18123
GBF_CACHE_PAC_PORT=18124
GBF_WINDOWS_STATE_ROOT="%LOCALAPPDATA%\GBFLocalCache"
```

没有 ACGPower 时：

```text
GBF_LEGACY_CACHE_ROOTS=""
```

有旧缓存时直接写普通 Windows 路径；多个目录仍用分号 `;` 分隔。legacy cache 始终只读。

`.env.windows` 被 `.gitignore` 排除，不会进入仓库。

## 4. 安装和启动

已有 Python 3.12/3.13：

```powershell
.\windows\install-native.ps1
```

需要自动安装 Python 3.12：

```powershell
.\windows\install-native.ps1 -InstallPython
```

installer 会：

1. 创建 `.venv-windows`；
2. 安装 `requirements.txt`；
3. 启动 Windows 原生 PAC server 与 mitmproxy；
4. 在 `%LOCALAPPDATA%\GBFLocalCache\mitmproxy` 生成该机器自己的 CA；
5. 检查 proxy/PAC 端口真正 ready 后才返回成功。

状态管理：

```powershell
.\windows\status-native.ps1
.\windows\stop-native.ps1
.\windows\start-native.ps1
```

`start-native.ps1` 会拒绝占用已被其它程序使用的端口，因此 WSL 版和 native 版默认不能同时使用 18123/18124。

## 5. 安装 CA 和启用 GBF-only PAC

默认端口/默认 state root 时：

```powershell
.\windows\enable.ps1
```

如果 `.env.windows` 改了端口或 state root，`install-native.ps1` 会输出应使用的完整 `enable.ps1 -PacUrl ... -CertPath ...` 命令。

第一次加入本地根 CA 时 Windows 可能弹出 **Security Warning**。只应确认本次安装刚生成的 mitmproxy CA。

`enable.ps1`：

- 不修改 `ProxyEnable` / `ProxyServer`；
- 只设置 `AutoConfigURL`；
- 如果已经存在其它非空 PAC，默认拒绝覆盖；
- 会保存之前的 PAC 值供 `disable.ps1` 回滚。

Chrome 完全退出再打开一次后即可使用，无需浏览器扩展。

## 6. 登录自启动

```powershell
.\windows\install-native-autostart.ps1
```

它在当前用户 Startup 目录建立一个静默 VBS，调用仓库中的 `start-native.ps1`。

移除：

```powershell
.\windows\uninstall-native-autostart.ps1
```

## 7. 验收

```powershell
.\windows\status-native.ps1
.\.venv-windows\Scripts\python.exe -m pytest -q
```

再用 Chrome DevTools 或其它支持系统代理的 Windows HTTP 客户端验证：

- 第一次静态资源可以是 `MISS-STORED` / `REVALIDATED`；
- 第二次相同资源应出现 `HIT-PRIMARY`；
- 普通网站和 `game.granbluefantasy.jp` 不应进入本地 proxy。

开发机在 2026-09-14 做过真实 Windows-native 端到端验证：

- Windows Python 3.12.10；
- native mitmproxy 12.2.3；
- `require-config.js`：第一次 `MISS-STORED`，第二次 `HIT-PRIMARY`，正文 MD5 相同；
- ACGPower legacy `basic_alphabet.woff`：条件验证后 `REVALIDATED`，正文 MD5 与旧缓存一致；
- native Windows venv 下 `pytest`: 7 passed；
- native startup 脚本完成过安装→存在检查→卸载测试。

## 8. 回滚

```powershell
.\windows\stop-native.ps1
.\windows\uninstall-native-autostart.ps1
.\windows\disable.ps1
```

如果连本项目 CA 一起移除：

```powershell
.\windows\disable.ps1 -RemoveCertificate
```

primary cache、旧 ACGPower cache 和代码目录不会因为关闭 PAC 而被删除。
