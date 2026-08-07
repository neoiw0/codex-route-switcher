# Codex Route Switcher（朋友版 / Friend Edition）

一键把 Codex 桌面版的 API 路由切换到第三方供应商（Fox / OpenCode Go 直连），并自动改写 `%USERPROFILE%\.codex\config.toml`，随后启动 Codex。

A one-click tool that switches Codex Desktop's API route to third-party suppliers (Fox / OpenCode Go direct), rewrites `~/.codex/config.toml`, and launches Codex.

## 特点 / Features

- 不含任何 API Key：Key 只保存在你自己的 Windows 用户环境变量中（`FOX_API_KEY` / `OPENCODE_API_KEY`），不会写进脚本或旁边的文件。
- 不需要本地代理，不需要看门狗。
- OpenCode Go 大陆直连可用（Cloudflare 线路偶尔抖动，失败重试即可）。
- 自动完全退出旧 Codex/ChatGPT 进程，切换路由后重新启动，并自动验证新会话格式，避免新聊天报 utomation_update 错误。
- 配置永久生效：重启电脑后直接打开 Codex 即可，无需再次运行。

No API keys are bundled. Keys live only in your Windows user environment variables. No local proxy or watchdog is required.

## 文件清单 / Files

| 文件 / File | 作用 / Purpose |
|---|---|
| `Codex-RouteSwitcher-Friend.bat` | 双击运行这个 / double-click this one |
| `Codex-RouteSwitcher-Friend.ps1` | 切换逻辑，不要删 / switching logic, do not delete |
| `Start-Codex-Direct-Friend.ps1` | Codex 启动器，不要删 / Codex launcher, do not delete |

所有文件必须放在同一个文件夹里。Keep all files in the same folder.

## 国内下载方式 / Downloading from mainland China

打不开 GitHub 或下载太慢时，用下面两种方式之一（都不需要注册、不需要安装 Git）：

### 方式一：加速镜像下载（最简单）

把下面任一链接复制到浏览器打开，即可直接下载 ZIP：

- https://ghfast.top/https://github.com/neoiw0/codex-route-switcher/archive/refs/heads/main.zip
- https://ghproxy.net/https://github.com/neoiw0/codex-route-switcher/archive/refs/heads/main.zip

镜像站点偶尔会失效或限速，一个不行就换另一个。


> Mirror: prepend `https://ghfast.top/` or `https://ghproxy.net/` to the GitHub ZIP URL.


## 使用步骤 / Usage

1. 不用手动关：脚本会自动完全退出 Codex/ChatGPT，切换路由后再重新启动（耐心等它跑完提示）。No need to quit manually - the script fully quits Codex/ChatGPT, switches the route, and restarts it.
2. 双击 `Codex-RouteSwitcher-Friend.bat`。Double-click the `.bat` file.
3. 输入 `1` 选 CC - Fox（可选），或输入 `2` 选 CC - OpenCode Go（推荐 / 默认）；输入 `3` 可测试连接。Enter `1` for Fox (optional), `2` for OpenCode Go (recommended / default), or `3` to test the connection.
4. 选择模型，再选择思考强度。Pick a model and a reasoning effort.
5. 第一次使用会提示输入你自己的 API Key（只保存到 Windows 用户环境变量）。On first run, enter your own API key (stored in Windows user environment variables only).
6. 脚本改写 `config.toml` 并自动打开 Codex。The script rewrites the config and opens Codex.
7. 以后想换模型或强度，重新双击运行即可。Run again to change model or effort.

## 直连说明 / Direct connection

- OpenCode Go 直接连接 `https://opencode.ai/zen/go/v1`：不需要本地代理，不需要科学上网。
- Fox 直连 `https://dm-fox.rjj.cc/codex/v1`。
- 配置是永久的：重启电脑、重开应用都有效。

OpenCode Go connects directly to `https://opencode.ai/zen/go/v1` - no local proxy or VPN needed. The config is permanent and survives reboots.

## API Key 从哪里来 / Where to get keys

- OpenCode Go：在 <https://opencode.ai> 注册并创建 API Key。
- Fox：在 Fox 供应商平台注册并创建 API Key。
- 请勿共用别人的 Key，各用各的。Do not share keys.

## 邀请注册（可选，支持作者）/ Referral sign-up (optional)

用下面的邀请链接注册，你我都得奖励。Sign up via these links and we both get bonuses:

- OpenCode Go（DeepSeek、Kimi 等开源模型和 Luna，约 1.5 折）：https://opencode.ai/go?ref=PS30TF3NRR（双方多得 5 刀）
- Fox（各类顶尖闭源模型，约 0.3 折）：https://foxcode.rjj.cc/auth/register?aff=B8U1
## 常见问题 / FAQ

- **提示 `pwsh 不是内部或外部命令`**：请用最新版，新版只需要 Windows 自带的 PowerShell，无需安装任何东西。*"pwsh is not recognized"*: use the latest release; only built-in PowerShell is required.
- **一直卡在 thinking / 测试连接失败**：直连 opencode.ai 不稳定时，等几分钟重试，或换个时间段/网络再试。*Stuck at thinking / test failed*: retry after a few minutes or try another network.
- **窗口一闪而过**：把文件夹里的 `switch.log` 发给作者。*Window flashes and closes*: send `switch.log` to the author.
- **报 `reconnecting 5/5`**：旧版本遗留问题（旧版需要本地代理），新版直连不受影响。*"reconnecting 5/5"*: leftover from the old proxy-based version, not an issue in this edition.
- **旧聊天报 `tools... missing field name`**：旧会话用的是应用内置的旧供应商，新建聊天即可。*Old chats show this error*: create a new chat instead.
- **Codex 没有自动启动**：手动打开 Codex 即可，配置已经写好。*Codex did not auto-start*: open it manually; the config is already set.
- **新聊天第一条消息报 `Invalid schema for function 'automation_update'`**：说明上次切换后旧进程没有完全退出。先完全退出 Codex（任务栏右键 -> 退出），再双击 bat 重新切换一次，然后开【新的】聊天窗口；或者先复用已经正常的旧聊天窗口。本版已改为自动完全退出进程，正常流程不会再遇到。*New chat shows this error*: fully quit Codex, rerun the switcher, then open a new chat (or reuse a healthy old chat).
- **提示找不到 Codex**：启动器会自动识别 Codex、ChatGPT、GPT(beta)；仍失败就手动打开，并把窗口里列出的候选应用名发给作者。*Codex not found*: the launcher detects Codex, ChatGPT and GPT(beta) automatically; if it still fails, open Codex manually.

## 隐私说明 / Privacy

脚本里没有任何 API Key。你的 Key 只保存在本机 Windows 用户环境变量中，改 Key 只需重新运行并回答 `n` 再输入一次。`switch.log` 只记录运行时间和所选模型，用于排查问题。

No API key is embedded. Keys are stored only in Windows user environment variables. `switch.log` only records timestamps and selected models for troubleshooting.

## 开源许可 / License

MIT License. See [LICENSE](LICENSE).

## 免责声明 / Disclaimer

本工具与 OpenAI 无任何关联，供应商为第三方服务。使用前请自行确认供应商的条款、价格与数据政策。

This project is not affiliated with OpenAI. Suppliers are third-party services; please review their terms, pricing, and data policies before use.