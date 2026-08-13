# Codex Route Switcher（三合一版 / All-in-One Edition）

一键把 Codex 桌面版的 API 路由切换到第三方供应商，自动改写 `%USERPROFILE%\.codex\config.toml`，随后启动 Codex。支持三种供应商：

1. **OpenCode Go**（推荐 / 默认）— 直连 `https://opencode.ai/zen/go/v1`，DeepSeek / Kimi / GLM 等开源模型和 Luna，约 1.5 折。
2. **DeepSeek 官方 API** — 直连 `https://api.deepseek.com`，`deepseek-v4-flash` 与 `deepseek-v4-pro-0813`（官方正式版，1M 上下文，思考档位 low/high/max）。
3. **Fox**（可选）— 直连 `https://dm-fox.rjj.cc/codex/v1`，各类顶尖闭源模型，约 0.3 折。

A one-click tool that switches Codex Desktop's API route to third-party suppliers (OpenCode Go / DeepSeek official / Fox direct), rewrites `~/.codex/config.toml`, and launches Codex.

## 特点 / Features

- 不含任何 API Key：Key 只保存在你自己的 Windows 用户环境变量中（`OPENCODE_API_KEY` / `DEEPSEEK_API_KEY` / `FOX_API_KEY`），不会写进脚本或旁边的文件。
- 不需要本地代理，不需要看门狗。OpenCode / DeepSeek 官方 / Fox 均大陆直连（Cloudflare 线路偶尔抖动，失败重试即可）。
- 自动完全退出旧 Codex/ChatGPT 进程，切换路由后重新启动，并自动验证新会话格式，避免新聊天报 automation_update 错误。
- 选 DeepSeek 系列模型时自动设置 100 万（1M）上下文窗口，代码审核（Review）自动使用 `deepseek-v4-flash`。DeepSeek models get a 1M context window automatically; code review uses `deepseek-v4-flash`.
- 思考强度不用手动选：切换器按模型自动设置可用档位，打开 Codex 后可在聊天窗口里调节（只显示该模型支持的档位）。No manual reasoning-effort question; the app offers only the levels each model supports.
- 每次切换都会自动把所有旧聊天同步成你选的模型（先备份状态数据库），旧聊天不再停留在旧模型。Every switch automatically syncs all old chats to the model you pick (state database is backed up first).
- DeepSeek 官方选项会自动写入官方 Codex 模型目录（`~/.codex/route-switcher-deepseek-catalog.json`），确保 apply_patch 工具、1M 上下文和思考档位都正常；切回 OpenCode/Fox 时自动恢复你原来的模型目录设置。The DeepSeek option writes the official Codex model catalog automatically and restores your previous catalog setting when you switch back.
- 配置永久生效：重启电脑后直接打开 Codex 即可，无需再次运行。The config is permanent and survives reboots.

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
3. 输入 `1` 选 OpenCode Go（推荐 / 默认），`2` 选 DeepSeek 官方 API，`3` 选 Fox（可选）；输入 `4` 可测试连接，输入 `5` 可修复历史聊天供应商（只改供应商名字，聊天模型不变）。Enter `1` for OpenCode Go (recommended / default), `2` for DeepSeek official API, `3` for Fox (optional), `4` to test the connection, or `5` to repair old chat providers (name only, chat models kept).
4. 选择模型。切换后所有旧聊天也会自动变成你选的模型。Pick a model. After the switch, all old chats automatically use the model you picked.
5. 第一次使用会提示输入你自己的 API Key（只保存到 Windows 用户环境变量）。On first run, enter your own API key (stored in Windows user environment variables only).
6. 脚本改写 `config.toml` 并自动打开 Codex。The script rewrites the config and opens Codex.
7. 以后想换模型或供应商，重新双击运行即可，旧聊天会自动跟着换。Run again to change model or supplier; old chats follow automatically.

## 直连说明 / Direct connection

- OpenCode Go 直接连接 `https://opencode.ai/zen/go/v1`：不需要本地代理，不需要科学上网。
- DeepSeek 官方 API 直接连接 `https://api.deepseek.com`（Responses 格式，官方为 Codex 提供）。
- Fox 直连 `https://dm-fox.rjj.cc/codex/v1`。
- 配置是永久的：重启电脑、重开应用都有效。

All three suppliers connect directly - no local proxy or VPN needed. The config is permanent and survives reboots.

## DeepSeek 官方 API 说明 / DeepSeek official API

- 模型：菜单只提供 `deepseek-v4-flash` 和 `deepseek-v4-pro-0813`（官方最新正式版；官方 API 调用名仍是 `deepseek-v4-pro`，脚本会自动映射）。
- 上下文：两个模型都是 100 万（1M）Token，脚本自动设置。
- 思考强度：两个模型都支持 `low / high / max`，默认 `high`；切换后可在 Codex 聊天窗口里调节。
- 审核模型：自动固定为 `deepseek-v4-flash`。
- 模型目录：脚本自动写入 `~/.codex/route-switcher-deepseek-catalog.json`（内容来自 DeepSeek 官方 models.json），并在切回 OpenCode/Fox 时恢复你原来的 `model_catalog_json` 设置。

Models: `deepseek-v4-flash` and `deepseek-v4-pro-0813` (the official stable build; the API id remains `deepseek-v4-pro` and the script maps it automatically). Both have a 1M context window and support `low/high/max` reasoning effort (default `high`). Review model is fixed to `deepseek-v4-flash`.

## API Key 从哪里来 / Where to get keys

- OpenCode Go：在 <https://opencode.ai> 注册并创建 API Key（GitHub 账号登录）。
- DeepSeek 官方：在 <https://platform.deepseek.com> 注册，在 API Keys 里创建 Key（以 `sk-` 开头）。
- Fox：在 Fox 供应商平台注册并创建 API Key。
- 请勿共用别人的 Key，各用各的。Do not share keys.

## 邀请注册（可选，支持作者）/ Referral sign-up (optional)

用下面的邀请链接注册，你我都得奖励。Sign up via these links and we both get bonuses:

- OpenCode Go（DeepSeek、Kimi 等开源模型和 Luna，约 1.5 折）：https://opencode.ai/go?ref=PS30TF3NRR（双方多得 5 刀）
- Fox（各类顶尖闭源模型，约 0.3 折）：https://foxcode.rjj.cc/auth/register?aff=B8U1

## 常见问题 / FAQ

- **提示 `pwsh 不是内部或外部命令`**：请用最新版，新版只需要 Windows 自带的 PowerShell，无需安装任何东西。*"pwsh is not recognized"*: use the latest release; only built-in PowerShell is required.
- **一直卡在 thinking / 测试连接失败**：直连不稳定时，等几分钟重试，或换个时间段/网络再试。*Stuck at thinking / test failed*: retry after a few minutes or try another network.
- **窗口一闪而过**：把文件夹里的 `switch.log` 发给作者。*Window flashes and closes*: send `switch.log` to the author.
- **报 `reconnecting 5/5`**：旧版本遗留问题（旧版需要本地代理），新版直连不受影响。*"reconnecting 5/5"*: leftover from the old proxy-based version, not an issue in this edition.
- **旧聊天报 `tools... missing field name`**：旧会话用的是应用内置的旧供应商，新建聊天即可。*Old chats show this error*: create a new chat instead.
- **Codex 没有自动启动**：手动打开 Codex 即可，配置已经写好。*Codex did not auto-start*: open it manually; the config is already set.
- **旧聊天记录打不开 / 消失（之前用 Fox 等供应商）**：运行切换器输入 `5`，脚本会备份状态数据库，把数据库和所有旧会话的供应商改写成 CC（只改名字，聊天模型不变），然后完全退出重开 Codex 即可。*Old chats fail to open / disappear*: run the switcher and enter `5`; it backs up the state database and rewrites only the provider to CC (chat models are kept), then fully quit and reopen Codex.
- **旧聊天仍显示旧模型（如 luna）**：正常切换一次即可——每次切换时脚本都会自动把所有旧聊天同步成你选的模型，不用单独操作。*Old chats still show a stale model (e.g. luna)*: just run a normal switch; every switch automatically syncs all old chats to the model you picked.
- **新聊天第一条消息报 `Invalid schema for function 'automation_update'`**：说明上次切换后旧进程没有完全退出。先完全退出 Codex（任务栏右键 -> 退出），再双击 bat 重新切换一次，然后开【新的】聊天窗口；或者先复用已经正常的旧聊天窗口。本版已改为自动完全退出进程，正常流程不会再遇到。*New chat shows this error*: fully quit Codex, rerun the switcher, then open a new chat (or reuse a healthy old chat).
- **提示找不到 Codex**：启动器会自动识别 Codex、ChatGPT、GPT(beta)；仍失败就手动打开，并把窗口里列出的候选应用名发给作者。*Codex not found*: the launcher detects Codex, ChatGPT and GPT(beta) automatically; if it still fails, open Codex manually.

## 隐私说明 / Privacy

脚本里没有任何 API Key。你的 Key 只保存在本机 Windows 用户环境变量中（`OPENCODE_API_KEY` / `DEEPSEEK_API_KEY` / `FOX_API_KEY`），改 Key 只需重新运行并回答 `n` 再输入一次。`switch.log` 只记录运行时间、供应商和所选模型，用于排查问题。

No API key is embedded. Keys are stored only in Windows user environment variables. `switch.log` only records timestamps, suppliers and selected models for troubleshooting.

## 开源许可 / License

MIT License. See [LICENSE](LICENSE).

## 免责声明 / Disclaimer

本工具与 OpenAI、DeepSeek 均无任何关联，供应商为第三方服务。使用前请自行确认供应商的条款、价格与数据政策。

This project is not affiliated with OpenAI or DeepSeek. Suppliers are third-party services; please review their terms, pricing, and data policies before use.
