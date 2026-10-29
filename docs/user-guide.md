# iPhone Use 使用手册

本手册收录控制窗口、HTTP API、MCP、指针校准、多设备配对和故障排查的详细说明。首次使用可先读项目首页（[简体中文](../README.md) / [English](../README.en.md)）；代码模块与维护约束见[架构说明](architecture.md)。

## 目录

- [工作方式](#工作方式)
- [环境要求与快速开始](#环境要求)
- [使用控制窗口](#使用控制窗口)
- [界面语言](#界面语言)
- [接入 AI Agent：MCP](#接入-ai-agentmcp)
- [HTTP API](#http-api)
- [指针校准](#指针校准)
- [多设备与配对](#多设备与配对)
- [配置、数据与录屏](#配置数据与录屏)
- [常见问题与限制](#常见问题与限制)
- [开发与验证](#开发与验证)

---

在 Mac 上查看并操作真实 iPhone，也可以通过 MCP 让 AI Agent 使用手机。

项目通过 **USB 采集屏幕**，通过 **Bluetooth LE HID 发送鼠标和键盘输入**。手机端无需安装应用，无需越狱，也不需要 Apple 开发者账号。

**本地使用直接运行 Swift 可执行文件即可，无需先打包 `.app`，无需开发者证书或手动签名。** 相机与蓝牙权限仍需按 macOS 提示授权。

## 相较于 Apple「iPhone 镜像」的优势

本项目在投屏与操控方面，主要适合不同账号的手机、多台测试设备，以及需要直接在手机上参与操作的场景。

| 核心优势 | iPhone Use | Apple「iPhone 镜像」 |
| --- | --- | --- |
| **不要求同一 Apple 账户或双重认证** | 核心投屏与控制通过 USB 信任和蓝牙配对建立连接，不要求两端使用同一 Apple 账户，也不要求开启 Apple 双重认证 | 两端必须登录同一 Apple 账户，并开启双重认证 |
| **支持多台 iPhone 连接与控制** | 同一 Mac 可为多台手机分别打开控制窗口，同时显示各自画面，也可通过 API/MCP 按设备 ID 分别截图和控制 | 一次只能与一台 Mac 和一台 iPhone 配合使用 |
| **方便手机端与 Mac 端交替操作** | 手机保持解锁，可直接查看和触摸手机，再继续通过 Mac 操作，适合现场演示和联调 | 手机保持锁定，解锁手机会停止镜像 |

本项目使用 **USB 传输画面、蓝牙传输输入**，需要数据线、USB“信任此电脑”、蓝牙配对和 AssistiveTouch；部分手机还需要指针校准。
每台手机都需完成连接与配对；通用剪贴板等 Apple 连续互通功能仍需满足其账户与设置要求。

Apple 侧的使用条件参见 [官方「iPhone 镜像」说明](https://support.apple.com/zh-cn/120421)。

## 工作方式

```text
Mac 控制窗口 ─────────────┐
                        ├── iphone-use ── Bluetooth LE HID ──→ iPhone 输入
脚本 ── HTTP API ────────┤        ↑
                        │        └──────── USB ────────────── iPhone 画面
AI Agent ── MCP ── HTTP ─┘
```

- **控制窗口**：每台手机独立窗口，显示实时画面，支持鼠标点击与拖动、键盘输入，以及 Home、搜索、粘贴、回车和音量快捷按钮。
- **HTTP API**：截图、点击、长按、滑动、移动指针、输入文字和设备管理，默认监听 `127.0.0.1:7390`。
- **MCP**：通过标准输入输出连接 Agent，将工具调用转发给本机 HTTP API。
- **指针校准**：首次发现需要相对模式且缺少配置时，通过 USB 画面自动测量并保存曲线；Safari 脚本保留作诊断工具。
- **多设备**：多个窗口可同时显示不同手机，HTTP API 和 MCP 支持指定手机；每台手机有独立的采集会话和输入队列。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Mac | macOS 14 或更高版本，支持 Bluetooth LE，并开启蓝牙 |
| Swift | Swift 6.0 或更高版本，可使用包含该工具链的 Xcode 或 Command Line Tools |
| iPhone | 保持解锁，信任此 Mac，并开启辅助触控（AssistiveTouch） |
| 连接 | 可传输数据的 USB 线；蓝牙负责控制，USB 负责画面 |
| 可选工具 | Python 3 用于网页指针诊断；`ffmpeg` 用于录屏 |

Swift 主程序使用系统框架，没有第三方 Swift 包依赖。不同 iPhone、iOS 版本和指针设置的定位效果可能不同；项目未声明覆盖所有机型的兼容性。

## 快速开始

### 1. 获取代码并启动

```sh
git clone https://github.com/YueChen-C/iPhone-use.git
cd iPhone-use
swift run -c release iphone-use
```

也可以使用仓库提供的启动脚本，默认同样采用 Release 配置：

```sh
./scripts/run.sh
```

首次启动会编译项目，随后打开控制窗口并启动 HTTP 服务。保持进程运行；在启动它的终端按 `Ctrl-C`，或关闭最后一个窗口，即可退出。

如果希望先编译再运行：

```sh
swift build -c release
.build/release/iphone-use
```

以上是三种启动方式，选择一种即可。不要同时启动多个使用相同端口的主程序。

### 2. 连接手机并授权

1. 用 USB 数据线连接 iPhone，解锁并选择“信任此电脑”。如果 Mac 提示允许配件连接，选择允许。
2. 按 macOS 提示允许**相机**和**蓝牙**访问。相机权限用于通过 AVFoundation 读取 iPhone 的 USB 画面。
3. 在 Mac 和 iPhone 上开启蓝牙，并在 iPhone 的“设置 → 辅助功能 → 触控 → 辅助触控”中开启 **AssistiveTouch**。
4. 在该页面进入“设备 → 蓝牙设备”，选择 **iPhone Use**，并按两端提示确认配对。完整路径为“设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → 蓝牙设备”。iOS 也可能显示 Mac 的蓝牙名称，控制窗口的连接提示会列出该名称。
5. 等待画面与控制连接就绪。若能看到画面但无法操作，继续检查蓝牙、辅助触控和指针状态。

从终端启动时，权限可能归属于启动进程的终端应用，以系统提示显示的名称为准。拒绝过权限时，在“系统设置 → 隐私与安全性 → 相机 / 蓝牙”中检查对应应用，再重新启动。

### 3. 检查状态

在另一个终端执行：

```sh
curl -s http://127.0.0.1:7390/status
curl -s http://127.0.0.1:7390/devices
```

`/status` 包含整体蓝牙状态、`devices` 和尚未匹配的 `unmatchedHosts`。重点检查：

| 字段 | 含义 |
| --- | --- |
| `bluetoothHosts[]` | 每个已连接蓝牙 host 的明细：`host` UUID、`subscribed` 已订阅的报告通道、`session` 会话令牌、`screen` 已配对的 USB 屏幕 |
| `devices[].id` | USB 设备 ID，供 API、MCP 和校准脚本选择手机 |
| `devices[].bluetooth` | 手机已匹配到当前连接的蓝牙 host；不代表所有控制报告都已就绪 |
| `capture.identityState` | 画面身份校验状态；`partiallyVerified` 表示只有部分手机已确认，可逐台查看 `capture.screens[].permitsPointerAssociation` |
| `devices[].bluetoothState` | `connected` 已匹配；`unmatched` 该手机的已保存连接在线或有未知候选连接，尚未确认画面；`disconnected` 没有该手机的在线连接或未知候选。其他已知手机在线不影响此状态 |
| `devices[].width` / `height` | USB 画面的原始像素尺寸 |
| `devices[].pointer.ready` | 当前是否具备坐标定位条件，不代表已验证实际落点精度 |
| `devices[].pointer.needsCalibration` | 蓝牙可以已连接，但当前缺少有效的指针校准；键盘输入仍可使用 |
| `devices[].pointer.calibration.mode` | `absolute`、`relative-calibrated` 或 `calibration-unavailable` |

排查“输入发到另一台手机”时，对比各 `bluetoothHosts[].screen` 与手机实际画面是否一致；`screen` 缺失说明该 host 尚未与任何 USB 屏幕配对。

一台已连接蓝牙、另一台仅插 USB 时，两台分别显示各自的状态。拔掉 USB 的旧手机可能继续保持蓝牙在线；已知属于旧手机的连接不会让新手机一直显示等待匹配。插拔另一台手机后，只要原手机的 USB 和蓝牙会话仍在，就保留其已确认的蓝牙关联。未变化的视频源沿用原窗口输入对象；视频源变化则重新绑定画面，蓝牙关联仍跟随原物理手机。画面身份复核期间暂缓输入，侧栏显示“蓝牙已连接，画面身份待确认”，不弹出蓝牙未匹配提示；状态接口保留 `bluetooth: true`，并以 `pointer.state: "screen-unverified"`、`pointer.ready: false` 表示输入暂停。复核完成后直接恢复；原手机 USB 断开、蓝牙重连或系统独立截图能力不可用时仍需重新验证关联。

画面身份校验直接使用 macOS 自带的设备服务，无需安装 `libimobiledevice`、`idevicescreenshot` 或 Homebrew。USB UDID 用于选定物理手机，蓝牙 UUID 不能直接换算成 USB UDID，仍需运动证据关联输入。部分系统不提供独立截图服务，此时不会将未验证画面标记为身份已确认。

仅插 USB 的手机随后连上蓝牙时，程序会为新会话自动重试尚未完成的画面校验，再关联输入，无需重新插 USB。操作另一台已经关联的手机不会中止它的匹配。

USB 拔插后若某条采集流一直没有首帧，程序会对该空流自动重启一次并重新校验画面。部分画面缺失时，其他已经独立确认的画面仍可继续关联与控制；无法确认的画面保持输入暂停。

## 使用控制窗口

连接多台 iPhone 后，每台手机会自动打开独立窗口，分别显示画面并接收输入。窗口标题包含设备名称与完整 USB 设备 ID，便于区分同名手机；点击要操作的窗口后即可使用鼠标、键盘与右侧快捷按钮。

鼠标在手机画面内移动、点击或拖动时，会转发为手机输入；窗口黑边和右侧按钮区域不参与坐标换算。窗口获得焦点后，可以输入 ASCII 字符和常用功能键。

右侧提供 **Home、搜索、粘贴、回车、音量 +、音量 −**。`Command+V` 和“粘贴”按钮发送的是手机端原生粘贴快捷键；如需粘贴 Mac 剪贴板里的内容，需要配置两端的 Handoff 与通用剪贴板。项目本身不传输剪贴板内容。

同一手机的窗口与 API 共用输入队列和指针位置状态。该窗口拖拽尚未结束时，针对该手机的 API 坐标操作返回 HTTP `409`；释放后即可继续，其他手机不受影响。鼠标离开手机画面时会取消待执行的悬停目标；窗口失焦、关闭或取消交互时会释放按钮。

每个窗口固定对应一台手机。拔掉 USB 后，窗口保留并等待原设备；重新连接同一手机后恢复画面，不会自动切换到其他设备。

关闭一个窗口不会中断其他窗口或该手机的 API/MCP 访问。主程序仍在运行时，可通过菜单“窗口 → 显示所有设备”或点击 Dock 中的应用图标，重新打开已关闭的已连接设备窗口。**关闭最后一个窗口会退出整个程序**；此后需重新启动，API/MCP 才能继续使用。

## 界面语言

主菜单 **iPhone Use → 语言 / Language** 提供 **中文** 与 **English** 两个选项，选择后立即生效（窗口标题、快捷按钮、连接指引、等待提示全部当场切换）并持久保存；未手动选择时跟随 macOS 系统语言。

语言同样作用于：

- **浏览器预览页**：`/viewer` 按当前语言生成；已打开的未锁定页面约 2 秒内自动刷新。可为单个标签页追加 `?lang=zh` 或 `?lang=en` 锁定语言。
- **MCP 工具描述与错误信息**：MCP 服务在会话启动时通过 `/config` 获取语言。切换后重启 MCP 客户端（或开启新会话）即按新语言返回；工具名与参数名保持英文，调用方式不受影响。
- **HTTP API 错误信息**：校验与设备匹配错误按当前语言返回，便于直接阅读。

## 接入 AI Agent：MCP

同一个可执行文件有两个运行模式：

| 命令 | 作用 |
| --- | --- |
| `iphone-use` | 启动控制窗口、USB 采集、蓝牙控制和 HTTP 服务 |
| `iphone-use mcp` | 启动 stdio MCP 服务，连接已经运行的 HTTP 服务 |

**先启动主程序，再让 MCP 客户端启动 `mcp` 进程。** MCP 模式不会自动启动控制窗口或连接硬件。建议先用 `swift build -c release` 生成可执行文件，再配置客户端直接使用它。

### Codex 桌面端、CLI 和 IDE

安装 Codex CLI 后，在仓库根目录执行一次：

```sh
./scripts/install-codex-mcp.sh
```

脚本会编译 Release 版本，通过 `codex mcp add` 将名为 `iphone-use` 的 **stdio MCP** 注册到本机 Codex 配置，并读回结果。重复执行会更新同名条目；可用 `--name iphone-use-dev` 注册另一份。它不改动其他 MCP 条目。

然后启动主程序并保持运行：

```sh
./scripts/run.sh
```

按上面的步骤完成 USB 信任、相机/蓝牙授权与 AssistiveTouch 配对后，重启 Codex 或打开新聊天，让客户端加载新工具。可以直接发出：

> 列出连接的 iPhone，给我截图，然后根据我的指示操作手机。

Codex 的 CLI 中也可以使用 `/mcp` 查看连接状态。此 MCP 需要运行在连接 iPhone 的 Mac 上；云端执行环境无法直接访问本机 USB 和蓝牙。

#### 用快捷指令执行任务

MCP 提供手机操作工具，Skill 提供可复用的任务入口。在仓库根目录执行一次：

```sh
./scripts/install-codex-skill.sh
```

然后在 Codex 输入框中输入 `$iphone-use`，选择该技能并附上任务，例如：

```text
$iphone-use 打开设置，进入通用 → 关于本机，读取 iOS 版本。
$iphone-use 测试指定 App，从首页进入个人中心再返回，重复 5 次，出现异常时停止并截图。
```

技能会通过 MCP 查询设备、截图、操作并检查结果。主程序退出或设备列表为空时，技能会自动调用恢复脚本：后台启动主程序，必要时重启一次并等待设备重新出现，然后继续原任务。恢复不会终止 MCP 转发进程。若 USB、信任或系统授权仍阻止连接，才会提示用户处理。首次安装后如果看不到技能，打开新聊天或重启 Codex。

也可手动执行恢复（不会点击或输入手机内容）：

```sh
python3 codex/skills/iphone-use/scripts/ensure_service.py
# 自定义端口或固定要恢复的设备
IPHONE_USE_PORT=7400 python3 codex/skills/iphone-use/scripts/ensure_service.py --device <完整设备ID>
```

恢复脚本使用现有的 `.build/release/iphone-use`（`CONFIG=debug` 可改用 Debug），输出 JSON 状态，并将主程序日志写入 `~/Library/Logs/iPhoneUse/service-<端口>.log`。恢复会等正在执行的 MCP 调用结束，跨会话的启动/重启至少间隔 60 秒；运行正常时直接复用，目标手机缺失但其他手机可用时保留主程序。MCP 自身仍是转发进程，直接调用 MCP 的其他客户端需要自行启动主程序。

#### 连接断开与多会话

遇到 `iphone-use/list_devices: Transport closed`，技能会使用独立 MCP 连接继续任务。该错误表示当前传输已断开，不一定是手机或主程序出了问题；无需因此重启其他会话的服务。也可手动验证：

```sh
python3 codex/skills/iphone-use/scripts/mcp_call.py list_devices
python3 codex/skills/iphone-use/scripts/mcp_call.py screenshot --arguments '{"device":"完整设备ID"}'
```

该入口每次调用独立启动 stdio MCP 并握手，工具参数保持一致，输出 JSON；截图保存为唯一的绝对文件路径。动作发出后断线不会自动重发，`may_have_executed: true` 时先截图核实。它绕过失效的连接，不会修复 Codex 缓存的原通道。自定义配置时传入相同的 `CONFIG`、`IPHONE_USE_PORT` 和可选 `IPHONE_USE_STATE_DIR`。

多个 Codex 聊天可连接同一个主程序：不同手机并行操作，同一手机按“动作 → 等待 → 结果截图”串行执行。设备 ID、名称和前缀先解析为完整 ID，再使用同一把跨进程锁；名称或前缀有歧义时拒绝操作。单个会话断开不会关闭其他会话的连接。

排队以单次工具调用为单位；手机的屏幕由各会话共享。两次调用之间可能被其他会话改变页面，继续操作前需重新截图。需要独立执行多个完整流程时，使用不同手机，或将同一手机的流程按顺序执行。直接 HTTP 调用和手动窗口输入不参与 MCP 锁。

Codex 使用 **`$iphone-use`** 调用技能；注册 MCP 不会自动创建 `/iphone-use` 斜杠命令。CLI 也可从 `/skills` 中选择技能。官方旧版 `/prompts:名称` 自定义提示词已弃用，不作为本项目的入口。

安装脚本在 `${CODEX_HOME:-$HOME/.codex}/skills/iphone-use` 创建指向仓库 `codex/skills/iphone-use` 的符号链接；重复安装可直接执行，有不同的同名技能时会保留并报错。移动仓库后，先移除旧符号链接再安装。卸载只需删除该符号链接，不会移除 MCP 配置。

参见 [OpenAI 官方 Skill 文档](https://developers.openai.com/codex/skills)。

#### 在 Codex 右侧显示手机画面

主程序运行后，在 Codex 桌面端的内置浏览器打开：

**[iPhone Use 实时画面](http://127.0.0.1:7390/viewer)**

也可以在聊天中说“在右侧浏览器打开 `http://127.0.0.1:7390/viewer`”。若面板被隐藏，可用 `Command+Shift+B` 切换聊天与网页并排显示。

右侧是实时预览页，点击、滑动和键盘操作继续通过 MCP 在聊天中发出。页面顶部可选择手机和暂停画面；设备名称旁显示完整 ID，断开后等待原手机重连，不会自动显示另一台手机。也可用 `/viewer?device=<完整设备ID>` 固定初始设备。

预览长边最多 1200 像素、每秒最多 5 帧，隐藏网页或暂停后停止获取画面。自定义 `IPHONE_USE_PORT` 时，将地址中的端口一并修改。原来的 `/` 和 `/status` 仍返回 JSON 状态。

参见 [OpenAI 官方内置浏览器说明](https://developers.openai.com/codex/browser)。

#### 配置与自检

Codex 使用 `~/.codex/config.toml`（或可信项目的 `.codex/config.toml`）配置 MCP；不会直接将仓库根目录的 `.mcp.json` 当作上述配置。若只使用桌面端，也可在 MCP 设置中手动添加 STDIO 服务，将命令设为 **仓库绝对路径下的 `scripts/mcp.sh`**，参数留空。等价的 TOML 示例：

```toml
[mcp_servers.iphone-use]
command = "/absolute/path/to/iPhone-use/scripts/mcp.sh"

[mcp_servers.iphone-use.env]
CONFIG = "release"
IPHONE_USE_PORT = "7390"
```

启动脚本会自行定位仓库，不依赖 Codex 的工作目录，且 stdout 只输出 MCP JSON-RPC。构建在安装阶段完成，避免首次连接时编译超时；移动仓库后请重新执行安装脚本。更新代码后重新安装即可更新构建，也可用 `--skip-build` 注册已有构建。

自定义端口时，安装与主程序使用相同的值：

```sh
IPHONE_USE_PORT=7400 ./scripts/install-codex-mcp.sh
IPHONE_USE_PORT=7400 ./scripts/run.sh
```

协议自检只需要 Python 3 标准库，不会发送手机输入：

```sh
# 不需要主程序或手机：检查握手、工具发现、通知、ping 和 stdout
python3 -B scripts/check-mcp.py

# 额外通过主程序查询设备列表；需要先启动主程序
python3 -B scripts/check-mcp.py --live

# 自定义端口，或指定另一份服务命令
IPHONE_USE_PORT=7400 python3 -B scripts/check-mcp.py --live
python3 -B scripts/check-mcp.py -- .build/release/iphone-use mcp
```

工具可见但调用失败时，先确认主程序仍在运行、两端端口一致，再检查 `/status` 和手机连接状态。没有构建时启动脚本会在 stderr 提示构建命令。卸载 Codex 配置使用 `codex mcp remove iphone-use`，不会删除项目或配对数据。

Codex 配置说明参见 [OpenAI 官方 MCP 文档](https://developers.openai.com/codex/mcp)。

### 其他 MCP 客户端

通用 MCP 配置示例，将路径替换为本机仓库的绝对路径：

```json
{
  "mcpServers": {
    "iphone-use": {
      "command": "/absolute/path/to/iPhone-use/.build/release/iphone-use",
      "args": ["mcp"]
    }
  }
}
```

Claude Code 可在仓库根目录执行：

```sh
claude mcp add iphone-use -- "$PWD/.build/release/iphone-use" mcp
```

### 工具与使用约束

| 工具 | 参数 | 用途 |
| --- | --- | --- |
| `list_devices` | 无 | 列出已连接的手机 |
| `screenshot` | 无必填参数 | 获取截图 |
| `move_pointer` | `x`, `y` | 只移动指针，截图检查实际落点 |
| `adjust_pointer` | `dx`, `dy`，均为 `-32...32` 的整数 | 用相对 HID 计数微调指针，不点击 |
| `click_pointer` | 无必填参数 | 在当前指针位置点击，不重新定位 |
| `tap` | `x`, `y` | 点击 |
| `long_press` | `x`, `y`；可选 `seconds`，默认 `1` | 长按 |
| `swipe` | `points` 坐标对象数组；可选 `duration`，默认 `0.3` 秒 | 连续多点滑动 |
| `type_text` | `text` | 输入 US 键盘布局支持的 ASCII 文字 |
| `press_key` | `key`；可选 `modifiers` | 发送按键或组合键 |
| `keyboard_sequence` | `steps`，每步为 `text` 或 `key` 加可选 `modifiers` | 连续执行已知键盘步骤，最后返回一张截图 |
| `home` | 无必填参数 | 返回主屏幕 |

除 `list_devices` 外，每个工具都可传 `device`，值为设备 ID 或名称；连接多台手机时必须指定，建议使用完整 ID。

MCP 截图为 JPEG，长边最多 **1200 像素**。点击、长按和滑动坐标使用该手机最近一次 MCP 截图的像素坐标。动作成功后等待约 **0.6 秒**再获取截图并返回，供 Agent 检查结果。

点击偏移时，先用 `move_pointer` 查看实际落点，必要时用 `adjust_pointer` 小幅修正，确认后再 `click_pointer`。微调单位是 HID 计数，不能按屏幕像素计算，也不会修改校准文件。三个工具分别持有设备锁，其他会话或手动操作仍可能在调用之间移动指针；页面或指针改变时应重新检查。

`keyboard_sequence` 最多 16 步，文本合计最多 256 个 US 键盘支持的 ASCII 字符。所有步骤会在操作前完成校验；执行期间持有同一手机的 MCP 锁，步骤间等待 0.15 秒，最后等待 0.6 秒并截图。中途失败会停止，已执行的输入不会回滚或自动重放。仅在当前页面已确认、无需中间检查时使用，例如 Safari 中 `{"steps":[{"key":"l","modifiers":["cmd"]},{"text":"https://www.baidu.com"},{"key":"enter"}]}`。网页仍在加载时需继续截图确认。

`swipe` 在 MCP 和 HTTP 中都使用 `points` 与 `duration`，例如：

```json
{
  "points": [
    {"x": 200, "y": 800},
    {"x": 240, "y": 500},
    {"x": 400, "y": 300}
  ],
  "duration": 0.6
}
```

至少提供两个点，每个点包含数值型 `x`、`y`，各点必须位于画面范围内。两点表示直线滑动，多点按数组顺序连接成折线；全程保持按下，经过最后一点后释放。`duration` 必须大于 `0`，表示整条路径的移动等待时长，各段按屏幕像素距离分配。按下与释放前后的固定等待、蓝牙传输和校准移动可能增加实际耗时。原来的四坐标参数和 MCP `swipe.seconds` 已移除。

`press_key` 支持 `enter`、`escape`、`backspace`、`tab`、`space`、方向键或单个字符；修饰键为 `cmd`、`shift`、`alt`、`ctrl`。例如 `space` + `cmd` 可打开 Spotlight，然后输入应用名并回车。

`type_text` 发送 ASCII 键盘输入，实际文字受手机当前输入法影响。中文输入可在手机已配置简体拼音时，用 `ctrl+space` 切换并检查输入法，再输入拼音、核对候选词并上屏；不能直接传入中文或假定候选词总是正确。应用导航、搜索、输入及提交检查的通用方法见 [iPhone Use 技能](../codex/skills/iphone-use/SKILL.md)。

## HTTP API

默认地址为 `http://127.0.0.1:7390`。POST 请求体使用 JSON；针对单台手机的请求可在请求体传 `device`，GET 请求使用 `?device=<id>`。

### 常用示例

```sh
# 保存原始尺寸截图；默认 JPEG，也可使用 ?format=png
curl -s http://127.0.0.1:7390/screenshot -o screen.jpg

# 点击画面中心，使用 0～1 的相对坐标
curl -s http://127.0.0.1:7390/tap \
  -H 'Content-Type: application/json' \
  -d '{"x":0.5,"y":0.5,"fraction":true}'

# 从下向上滑动
curl -s http://127.0.0.1:7390/swipe \
  -H 'Content-Type: application/json' \
  -d '{"points":[{"x":0.5,"y":0.8},{"x":0.5,"y":0.2}],"fraction":true,"duration":0.4}'

# 输入文字 / 打开 Spotlight / 返回主屏幕
curl -s http://127.0.0.1:7390/type \
  -H 'Content-Type: application/json' -d '{"text":"hello"}'
curl -s http://127.0.0.1:7390/key \
  -H 'Content-Type: application/json' -d '{"key":"space","modifiers":["cmd"]}'
curl -s -X POST http://127.0.0.1:7390/home
```

### 接口与坐标

| 方法 | 路径 | 参数 / 行为 |
| --- | --- | --- |
| GET | `/status`，或 `/` | 蓝牙、设备与指针状态 |
| GET | `/devices` | 设备列表 |
| GET | `/config` | 当前界面语言（`language`: `zh` 或 `en`） |
| GET | `/viewer` | 浏览器只读预览页；可选 `lang=zh`/`en` 锁定语言、`device=<id>` 指定手机 |
| GET | `/screenshot` | 可选 `format=png`、`maxEdge`、`maxWidth`、`device` |
| POST | `/tap` | `x`, `y`；可选 `hold`，按住秒数，默认 `0.08`；长按也使用此接口 |
| POST | `/swipe` | `points: [{"x":数值,"y":数值}, ...]`，至少两个点；可选 `duration`，默认 `0.3` 秒 |
| POST | `/move` | `x`, `y`，仅移动指针 |
| POST | `/nudge` | `dx`, `dy`，原始 HID 相对位移；可选 `click`，默认 `false` |
| POST | `/type` | `text`，ASCII 文字 |
| POST | `/key` | `key`；可选 `modifiers` 数组 |
| POST | `/home` | 返回主屏幕 |
| POST | `/match` | 可选 `force`、`probe`，重新匹配屏幕与蓝牙连接 |
| POST | `/pair` | `device`, `host`，手动指定对应关系 |
| POST | `/calibration/auto` | 重试缺少配置的手机；省略 `device` 时处理所有连接设备；`verifyOnly:true` 只测量验证，不保存 |
| POST | `/calibration/reload` | 热加载指定手机的配置 |

`/tap`、`/move`、`/swipe` 支持以下坐标方式，原点均为画面左上角：

- 默认使用原始屏幕像素坐标。
- 若基于缩放图片选点，传入该图片的 `width`、`height`；也可传入截图时相同的 `maxEdge`。使用 `maxWidth` 缩放时，请传回图片的宽高。
- 使用 `"fraction": true` 时，坐标为 `0`～`1` 的相对位置，无需传图片尺寸。

`swipe.points` 中的所有点共用请求顶层的坐标设置，点内只填写 `x`、`y`。使用 MCP 时直接传截图像素；使用 HTTP 的缩放截图时，需要传入对应尺寸或 `maxEdge`。

截图响应头包含 `X-Device`、`X-Screen-Width`、`X-Screen-Height`、`X-Image-Width` 和 `X-Image-Height`，用于区分原始画面与返回图片的尺寸。

HTTP 动作成功时返回 `{"ok":true,"device":"..."}`，**不会自动附带截图**。`/nudge` 的数值不是屏幕像素，它会使已有指针位置估计失效，主要供校准使用。

## 指针校准

默认定位模式为 `absolute`。首次匹配发现手机需要相对模式、且缺少有效配置时，主程序会自动通过 USB 画面测量 HID 位移与屏幕位移的关系，通过往返、垂直和实际目标落点检查后保存。手机保持解锁、画面静止即可，无需逐台打开网页。窗口和 API 共用该校准，重连后按手机身份复用。

自动测量状态可在 `/status` 的 `pointer.automaticCalibration` 查看。窗口鼠标、键盘或 API 的实际输入会中止后台探测或测量，优先处理用户操作；尚无有效曲线时，精确坐标操作仍会提示尚未就绪。背景动画、指针隐藏或变形、屏幕边缘裁切等可能使测量失败；失败不会保存新配置，也不会在同一会话中无限重测。保持画面静止后，可统一重试：`curl -s -X POST http://127.0.0.1:7390/calibration/auto -d '{}'`。已有配置不会被自动替换。

网页脚本可用于额外诊断、验证候选模板或重新测量已有曲线：`python3 scripts/calibrate-pointer.py --auto --device '<完整设备ID>'`。只有检查不通过才重新测量。公共换算公式、自动适配和稳定模板的说明见[跨设备指针模型](pointer-model.md)。以下为可选的网页诊断步骤：

1. 保持主程序运行，确认 USB 画面可用且手机已匹配蓝牙连接。
2. 让 iPhone 能通过局域网访问 Mac，通常将两者连接到同一 Wi-Fi。
3. 在仓库根目录运行以下脚本，仅依赖 Python 标准库：

   ```sh
   python3 scripts/calibrate-pointer.py
   ```

4. 在 iPhone 的 **Safari** 打开终端打印的完整网址。保持手机竖屏、关闭页面缩放，并开启辅助触控。
5. 等待终端提示保存成功；测量期间不要移动 Mac 鼠标或操作手机。脚本只发送移动，不执行点击。
6. 脚本热加载并验证新配置，无需重启蓝牙；再次查看 `/status`。验证失败会恢复原配置。

成功加载时，`pointer.calibration.mode` 为 `relative-calibrated`，`loaded`、`screenMatches` 与 `pointer.ready` 应为 `true`。

多设备、指定网络地址或自定义 API 端口时：

```sh
python3 scripts/calibrate-pointer.py \
  --device '<完整设备ID>' \
  --address '<Mac的局域网IP>' \
  --api http://127.0.0.1:7400
```

`--device` 必须是 `/devices` 返回的完整 ID。脚本默认连接 API 端口 `7390`，**不读取 `IPHONE_USE_PORT`**，自定义端口需使用 `--api`。临时校准网页默认使用端口 `7391`，可通过 `--listen-port` 修改；测量结束或失败后关闭网页服务。

相对定位是近似估计，可能积累误差。首次定位、重连或原始位移使估计失效后，会先归到左上角恢复原点。改变跟踪速度、指针设置或显示缩放后，应重新校准。窗口控制仍要求有效的坐标映射；API/MCP 在校准不可用时还可以尝试下面的截图反馈路径。

#### 校准不可用时的截图反馈

已匹配的手机若有当前 USB 画面及可用的相对鼠标通道，API/MCP 的移动、点击、长按和滑动会尝试截图反馈。每次操作重新观察指针，并用反向分轴移动检查观察到的物体是否响应输入；定位完成后才允许按下。已有有效校准的设备继续使用原路径。

这需要清楚可见的圆形指针和足够稳定的画面。动画、指针吸附或形变、裁边，以及过多画面变化都可能导致操作报错；不会在观察失败后继续猜测位置并点击。请先读取新截图，再决定是否重试。反馈操作有效期为 40 秒，到期拒绝继续发送移动或按下；这不是排队或系统调度暂停时的响应时限保证。反馈路径中的长按最多 10 秒、滑动时长最多 5 秒。

`pointer.visualFeedback.available` 表示此路径的传输前提可用，不证明当前页面一定能定位。`observedTargetTolerancePixels` 表示图像中观察到的位置容差，不是实际触点误差的保证。此路径不保存校准曲线，也不会将 `pointer.ready` 改为校准成功。滑动只观察按下起点，之后使用本次测得的增益估算拖动路径，完成后仍应通过页面变化核验结果。

蓝牙发送队列清空只表示 CoreBluetooth 接受了报告，不代表手机已经执行。服务端会拒绝过期或设备变更后的待发送移动与按下；HTTP 客户端断开本身不会取消已经进入服务端的操作，避免立即叠加重试。

## 多设备与配对

每台手机都需要 USB 连接、蓝牙配对并开启辅助触控。USB 换机不会自动连接新手机的蓝牙，也不会断开旧手机的蓝牙。某台手机缺少独立截图服务时，会继续确认其他手机；无法完整确认时只开放已验证手机的输入。建立新的屏幕与蓝牙关联时，通过移动指针并比较画面变化确认对应设备，包括只有一台手机的场景。绝对坐标探测失败后会尝试不依赖校准曲线的相对移动；通过后记录该手机需要相对校准。结果保存到本机，已有的有效关联可以继续复用。同一组 USB 捕获和蓝牙会话最多安排一次延迟探测重试，用户输入会取消当前探测和待执行重试；再次尝试需重新连接或显式调用匹配。

更换手机或 USB 设备后，系统可能保留旧的蓝牙 host。程序会在单个 USB 屏幕场景下检查已保存且有效的校准身份：如果当前屏幕与旧 host 的校准身份明确不一致，并且检测到新的未匹配 host，程序会分别探测旧、新 host；对于旧版本留下的、没有校准身份的当前映射，程序会先探测未匹配 host，只有唯一 host 命中后才检查当前映射。新 host 必须唯一命中，其他候选必须明确未命中，当前 host 也不能同时命中，才自动更新配对。证据不足时保留原映射；完全未配对的新 USB 屏幕仍可独立探测，避免被已断开手机的历史记录阻塞。不会删除或迁移不匹配的校准文件；可使用下面的 `/match` 或 `/pair` 手动处理。

控制窗口按手机分别打开；通过 API/MCP 操作时，先用 `list_devices` 或 `/devices` 获取 ID，再为操作指定 `device`。窗口标题中的完整 ID 与接口返回的设备 ID 一致。

需要重新匹配时：

```sh
# 重新匹配当前屏幕，并强制通过指针探测确认对应关系
curl -s http://127.0.0.1:7390/match \
  -H 'Content-Type: application/json' -d '{"force":true,"probe":true}'

# 手动关联：host 取自 /status 的 unmatchedHosts
curl -s http://127.0.0.1:7390/pair \
  -H 'Content-Type: application/json' \
  -d '{"device":"<完整设备ID>","host":"<蓝牙host UUID>"}'
```

`force` 会重新尝试匹配当前屏幕，并非清空全部历史数据；没有找到新匹配的屏幕会保留原映射。

## 配置、数据与录屏

| 配置 | 默认值 | 用途 |
| --- | --- | --- |
| `IPHONE_USE_PORT` | `7390` | 主程序、MCP 和录屏脚本使用的 HTTP 端口 |
| `IPHONE_USE_TRACE_POINTER` | 未开启 | 设为 `1` 输出指针调试日志 |
| `CONFIG` | `release` | 启动、打包与 Codex MCP 安装脚本的构建配置；MCP 启动脚本选择对应构建 |
| `IPHONE_USE_STATE_DIR` | `~/Library/Logs/iPhoneUse` | MCP 跨进程锁及恢复脚本日志/状态目录；自定义时填写绝对路径，连接同一服务的客户端应使用相同目录 |

例如 `IPHONE_USE_PORT=7400 ./scripts/run.sh`。使用自定义端口时，MCP 进程也必须获得相同环境变量；可在 MCP 配置的 `iphone-use` 对象中添加 `"env": {"IPHONE_USE_PORT": "7400"}`。

持久化数据位于 `~/Library/Application Support/iPhoneUse/`：

- `pairings.json`：USB 设备与蓝牙 host 的映射。
- `pointer-calibration/<host>.json`：绑定 USB 设备身份与分辨率的校准文件。同一手机重新配对后可复用匹配的校准，不按机型共享。
- `pointer-calibration/by-screen/<USB ID 的 UTF-8 十六进制>.json`：最近成功测量的稳定模板；优先于旧蓝牙身份下的历史曲线，重新配对后按 USB 身份复用。

录屏需要安装 `ffmpeg`，并保持主程序运行：

```sh
brew install ffmpeg
./scripts/record.sh demo.mp4
# 可选参数：输出文件、采样帧率、设备 ID
./scripts/record.sh demo.mp4 8 '<完整设备ID>'
```

按 `Ctrl-C` 结束采集后生成 MP4。脚本默认以约 8 FPS 请求最大宽度为 590 像素的截图，按实际收到的帧率生成视频，不录制音频。

## 可选：打包为 macOS 应用

直接运行可执行文件已经包含完整的控制窗口、HTTP 和蓝牙功能。需要 `.app` 目录结构及独立的应用标识、权限用途说明，或希望通过 Finder 启动时，再执行：

```sh
./scripts/build-app.sh
open build/iPhoneUse.app
```

该脚本会复制可执行文件与 `Resources/Info.plist`，然后执行代码签名。默认尝试使用本机的 Apple Development 或 Developer ID Application 身份；没有可用身份或签名失败时退回临时签名（ad hoc）。可以通过 `CODESIGN_IDENTITY` 指定签名身份。脚本不执行公证。

因此，**“无需额外签名”不等于“二进制一定没有签名”**：Apple Silicon 上的 Swift 工具链通常会为可执行文件自动生成链接器临时签名。日常本地运行无需手动执行 `codesign`，也无需购买开发者账号。`.app` 打包不是使用前置步骤。

## 常见问题与限制

| 现象 | 检查方式 |
| --- | --- |
| 没有手机画面 | 确认数据线可传输数据、手机已解锁并信任 Mac、Mac 已允许配件连接和相机访问 |
| 有画面但不能操作 | 检查蓝牙配对、两端确认提示、辅助触控，以及 `/status` 的指针状态 |
| 找不到 “iPhone Use” | 在 iPhone“辅助触控 → 设备 → 蓝牙设备”中查看 Mac 名称，并对照窗口提示；必要时打开 Mac 蓝牙设置检查连接 |
| 蓝牙刚连接就断开 | 先按下文保存诊断，再重启主程序并从 iPhone 重连；区分系统配对拒绝与已连接后的链路超时 |
| API 返回 `409` | 查看错误：结束窗口拖拽；若调用校准热加载接口，需等待当前自动测量结束 |
| API 返回 `503` | 查看响应错误：可能尚无画面，或鼠标订阅、校准尚未就绪 |
| MCP 提示主程序未运行 | 先启动不带 `mcp` 参数的主程序，确认 `/status` 可访问，并检查两端端口配置 |
| 校准网页打不开 | 检查 iPhone 到 Mac 的局域网连通性、`--address` 和网页端口，注意防火墙是否允许访问 |
| 校准后点击仍偏移 | 保持校准时的方向、跟踪速度和显示设置；相对定位不能保证逐像素精度 |

### 蓝牙连接后立即断开

复发时，先在主程序仍运行的情况下保存诊断，再尝试重连：

```sh
# 最近 10 分钟的系统配对/连接事件，以及当前程序和设备状态
./scripts/diagnose-bluetooth.sh > /tmp/iphone-use-bluetooth.txt 2>&1

# 可指定 1–60 分钟；自定义 HTTP 端口时与主程序保持一致
IPHONE_USE_PORT=7390 ./scripts/diagnose-bluetooth.sh 20 > /tmp/iphone-use-bluetooth.txt 2>&1
```

脚本只读取状态，不会重启服务、修改配对或发送手机输入。主程序不可访问时仍继续采集系统日志，并以非零退出码表示采集不完整。系统日志可能包含其他蓝牙设备，分析时需按时间、host UUID 和蓝牙地址关联。保留启动终端中的服务发布、`subscribe` / `unsubscribe` 日志，也有助于判断断开发生在哪一层。

同样的“秒断”可能对应不同阶段，不能只看 iPhone 蓝牙列表短暂显示“已连接”：

| 日志或状态 | 能确认的情况 |
| --- | --- |
| `Denying pairing request … no one to handle the request`，随后 `Pairing failed … 4815` | Mac 系统拒绝了新的配对请求，日志指明没有可处理该请求的配对处理程序 |
| `Encryption is now enabled`，随后 `Connection timed out to device` | 链路已经加密，之后发生连接超时；需结合断开前的连接事件分析 |
| `Controller reported a duplicate connection` / `Disconnecting duplicate` | 控制器报告同一设备的重复连接，系统拒绝了重复链路；不能仅凭此判断是哪一端先失去同步 |
| `/status` 显示 `advertising as iPhone Use` | 仅表示应用的广播状态，不能证明配对成功 |
| `bluetooth: true` 且 `pointer.ready: true` | 已匹配控制连接且具备指针定位条件；加密状态仍以系统日志为准，实际操控还需在窗口验证 |

保存证据后，可退出并重新启动主程序，等启动终端显示 `advertising as iPhone Use`，再从 iPhone“设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → 蓝牙设备”点按连接。重启会中断所有设备的控制窗口和 HTTP/MCP 服务。本机曾通过该操作恢复，但重启后的首次连接仍可能失败，后续重连才恢复；这属于恢复办法，不能据此认为原因已经消除。打开 Mac 蓝牙设置可以检查配对提示，但不保证解决系统拒绝配对的问题。

若仍复发，需同时保留失败和成功重连的日志，区分新配对、已有绑定恢复加密、HID 订阅以及后续链路断开。仅凭连接超时或错误编号不足以认定密钥损坏或 GATT 缓存失效；删除配对也不是默认处理步骤。

### 其他使用边界

- 手机需要保持解锁；长时间操作时请自行调整自动锁定设置。
- 文字输入使用 US 键盘布局，直接输入仅支持 ASCII；中文等内容可借助已配置的通用剪贴板粘贴。
- iOS 没有通用 Back 键，请使用应用内返回按钮，或在支持的页面执行从左缘向右的返回手势。
- 当前使用与校准流程以竖屏为主，未保证横屏和动态旋转行为。
- HTTP API 只监听本机回环地址，没有提供认证或远程访问配置。

## 开发与验证

业务代码位于 `Sources/iPhoneUse/`，按 App、UI、Devices、Capture、Bluetooth、Input、API 和 MCP 分目录。Swift 测试按对应职责组织在 `Tests/iPhoneUseTests/`，校准脚本测试位于 `Tests/PythonTests/`。

模块边界、队列归属和维护约束见 [架构说明](architecture.md)。Swift 格式由 [.swift-format](../.swift-format) 统一配置：4 空格缩进、120 字符目标行宽。

```sh
# 格式化与检查
swift format format --in-place --recursive Package.swift Sources Tests/iPhoneUseTests
swift format lint --strict --recursive Package.swift Sources Tests/iPhoneUseTests

# 测试与 Release 构建
swift test
swift build -c release
python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'
python3 -B scripts/check-mcp.py
```

自动化测试覆盖输入、连接状态、校准、设备匹配、HTTP/MCP 协议与窗口输入模型。Python 的 MCP 集成测试默认使用 Debug 可执行文件，也可设置 `IPHONE_USE_TEST_CONFIG=release`；通过真实 stdio 进程与模拟 HTTP 服务验证工具转发、错误、截图和多会话排队，不操作手机。涉及硬件行为的修改仍需在真机上验证配对、USB 重连、实际落点和窗口交互。

## 许可
采用 [MIT License](../LICENSE)。
