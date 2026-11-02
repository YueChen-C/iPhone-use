# iPhone Use

**在 Mac 上操控你的 iPhone，无需越狱。**

简体中文 | [English](README.en.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

通过 **USB** 将真实 iPhone 的画面实时显示在 Mac 上，再通过 **蓝牙** 使用 Mac 的鼠标和键盘操作手机。接入 MCP 后，AI Agent 也能查看屏幕、执行操作并检查结果。

https://github.com/user-attachments/assets/278a8808-1211-4155-b481-5f721c5ca62e

https://github.com/user-attachments/assets/e4aa9473-3236-4573-9841-bfbf83e248e1





**无需越狱，无需在 iPhone 安装应用，无需 Apple 开发者账号。**

[下载 Release](https://github.com/YueChen-C/iPhone-use/releases) · [功能亮点](#功能亮点) · [快速开始](#快速开始) · [接入 AI Agent](#接入-ai-agent) · [文档](#文档)

## 功能亮点

- 📱 **实时投屏** — 通过 USB 有线连接，在 Mac 原生窗口中查看 iPhone 画面。
- 🖱️ **鼠标与键盘控制** — 通过 Bluetooth LE HID 点击、拖动、输入文字和发送快捷键，让 Mac 充当手机的蓝牙输入设备。
- 🤖 **AI Agent 集成** — 为 Codex 等 MCP 客户端提供截图、点击、滑动和输入工具，让 Agent 操作手机并检查结果。
- 🌏 **中英文界面** — 主菜单一键切换中文 / English，窗口、浏览器预览页与 MCP 描述即时跟随，默认跟随系统语言。
- 🔌 **多台 iPhone** — 每台手机拥有独立窗口，MCP 和 HTTP API 均可通过设备 ID 选择目标手机。
- 🔑 **不受同一账户限制** — 核心投屏与控制不要求 Mac 和 iPhone 登录同一 Apple 账户，也不要求开启双重认证。
- 🛠️ **脚本自动化** — 通过本地 HTTP API 编写自动化流程、获取截图和管理设备。

## 为什么选择 iPhone Use？

从日常操作、App 测试到现场演示和 AI 自动化，iPhone Use 将真实手机接入 Mac 工作流程，无需部署 WebDriverAgent（WDA）、签名安装 iPhone 应用或加入 Apple Developer Program。

你可以连接登录不同 Apple 账户的手机，同时使用多台测试设备，也可以让手机保持解锁，在 Mac 操作与手机触屏操作之间自由切换。

与 Apple 的 [iPhone 镜像](https://support.apple.com/zh-cn/120421)不同，本项目通过 USB 传输画面，通过蓝牙传输输入。每台手机都需要完成 USB 信任、蓝牙配对，并开启辅助触控。

## 工作原理

```text
iPhone 画面 ───── USB ─────────────→ Mac 窗口 / 截图
iPhone 输入 ←──── Bluetooth LE HID ─ Mac 鼠标、键盘或自动化指令
```

Mac 使用 AVFoundation 采集 USB 画面，通过 Bluetooth LE HID 提供鼠标和键盘输入。HTTP API、MCP 工具和桌面窗口共用设备控制逻辑，无需在 iPhone 上安装软件。

## 快速开始

### 环境要求

| 项目 | 要求 |
| --- | --- |
| Mac | macOS 14 或更高版本，支持并开启 Bluetooth LE |
| iPhone | 保持解锁，使用可传输数据的 USB 线连接 |
| 权限与设置 | Mac 授予相机和蓝牙权限；iPhone 信任此 Mac 并开启辅助触控 |

### 方式一：下载 Release 安装包（推荐）

**无需安装 Xcode 或 Swift，也无需下载源码或自行编译。**

1. 打开 [GitHub Releases](https://github.com/YueChen-C/iPhone-use/releases)，在目标版本的 **Assets** 中下载 `iPhoneUse-v<版本号>-macOS-universal.zip`。同一个 ZIP 支持 Apple Silicon 和 Intel Mac；`Source code` 是源码归档，不是应用安装包。
2. 解压 ZIP，将 `iPhoneUse.app` 拖入“应用程序”（`/Applications`）。
3. 双击打开应用。当前自动构建使用临时签名，未经过 Apple 公证；如 macOS 阻止打开，确认下载来源后，按“系统设置 → 隐私与安全性”的提示允许打开。
4. 按下方[连接并配对 iPhone](#连接并配对-iphone)完成 USB 信任、相机与蓝牙授权、辅助触控配对，即可使用鼠标和键盘操作手机。

如需校验安装包，将该版本的 ZIP 和 `SHA256SUMS.txt` 下载到同一目录，在该目录运行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

以后使用时，连接并解锁 iPhone，打开 `iPhoneUse.app` 即可。日常操作无需终端；需要让 AI 操作手机时，继续阅读[接入 AI Agent](#接入-ai-agent)。

### 方式二：从源码运行

需要 Swift 6.0 或更高版本，可通过 Xcode 或兼容的 Command Line Tools 安装。Swift 主程序使用系统框架，没有第三方 Swift 包依赖。

```sh
git clone https://github.com/YueChen-C/iPhone-use.git
cd iPhone-use
./scripts/run.sh
```

脚本会编译 Release 版本、打开控制窗口，并在 `http://127.0.0.1:7390` 启动本地 HTTP 服务。本地运行无需手动签名，也无需先打包 `.app`。

### 连接并配对 iPhone

1. 用 USB 线连接并解锁 iPhone，选择**信任此电脑**；如 Mac 提示允许配件连接，请选择允许。
2. 按 macOS 提示授予**相机**和**蓝牙**权限。相机权限用于读取 USB 视频画面。
3. 在 iPhone 打开**设置 → 辅助功能 → 触控 → 辅助触控**，开启 **AssistiveTouch（辅助触控）**。
4. 在该页面进入**设备 → 蓝牙设备**，选择 **iPhone Use** 或控制窗口提示的 Mac 名称，并按两端提示确认配对。
5. 等待画面与控制连接就绪，即可在手机窗口内使用 Mac 的鼠标和键盘。

使用 MCP 或 API 时，请保持主程序运行。默认模式下，关闭最后一个窗口会退出程序并停止服务；如希望关闭窗口后继续保留后台服务，且在无等待窗口时启动或插线不自动弹窗（已打开且未最小化的等待窗口会在接入手机时就地切换为设备窗口），可在菜单 **iPhone Use → 后台静默常驻** 开启（或使用 `--resident-quiet` 启动）。

## 接入 AI Agent

### Codex

安装 Codex CLI 后，如果使用下载版应用，执行：

```sh
codex mcp add iphone-use -- /Applications/iPhoneUse.app/Contents/MacOS/iphone-use mcp
```

如果从源码运行，在另一个终端进入仓库根目录，执行：

```sh
./scripts/install-codex-mcp.sh
./scripts/install-codex-skill.sh
```

源码安装中的第一个脚本编译并注册本地 MCP 服务，第二个脚本安装可选的 `$iphone-use` 技能，用于复用手机操作流程。下载版可直接使用 MCP 工具；技能与自动恢复目前依赖源码构建目录。两种方式都需保持主程序运行，再打开新的 Codex 聊天或重启 Codex，加载工具。

试着输入任务；如果已安装可选技能，可以在任务前加上 `$iphone-use`：

```text
打开设置 → 通用 → 关于本机，读取 iOS 版本。
```

也可以直接让 Agent 列出已连接的 iPhone、截图，再按你的指示操作。在 Codex 内置浏览器或其他本机浏览器打开 `http://127.0.0.1:7390/viewer`，即可查看只读实时预览。

### 其他 MCP 客户端

下载版应用安装到“应用程序”后，在客户端的 MCP 配置中添加以下 stdio 服务：

```json
{
  "mcpServers": {
    "iphone-use": {
      "command": "/Applications/iPhoneUse.app/Contents/MacOS/iphone-use",
      "args": ["mcp"]
    }
  }
}
```

源码用户先执行 `swift build -c release`，再将 `command` 改为本机仓库中 `.build/release/iphone-use` 的绝对路径。

MCP 模式将请求转发给已运行的主程序，不会自行启动屏幕采集或蓝牙。主程序与 MCP 服务都需要运行在连接 iPhone 的 Mac 上。

## HTTP API

保持主程序运行，即可从脚本调用本地 API：

```sh
# 列出已连接设备
curl -s http://127.0.0.1:7390/devices

# 查询当前界面语言
curl -s http://127.0.0.1:7390/config

# 保存截图
curl -s http://127.0.0.1:7390/screenshot -o screen.jpg

# 使用 0～1 的相对坐标点击屏幕中心
curl -s http://127.0.0.1:7390/tap \
  -H 'Content-Type: application/json' \
  -d '{"x":0.5,"y":0.5,"fraction":true}'
```

连接多台手机时，请指定完整设备 ID：GET 请求使用 `?device=<id>`，POST 请求在 JSON 中添加 `"device"` 字段。服务仅监听本机回环地址。完整接口与坐标说明见 [API 参考](docs/user-guide.md#http-api)。

## 界面语言

在主菜单 **iPhone Use → 语言 / Language** 中选择 **中文** 或 **English** 即可切换，立即生效并记住选择；未手动选择时跟随 macOS 系统语言。

- **覆盖范围**：控制窗口、连接指引、浏览器预览页（`/viewer`）、MCP 工具描述与错误信息、HTTP API 错误信息。MCP 工具名与参数名保持英文，不影响客户端调用。
- **预览页**：默认跟随应用语言，也可用 `http://127.0.0.1:7390/viewer?lang=en`（或 `zh`）为某个浏览器标签锁定语言；已打开且未锁定的页面约 2 秒内自动刷新。
- **MCP 会话**：MCP 服务按会话启动时的语言返回工具描述，切换后新建的会话（或重启客户端）即生效。

## 使用须知

- **设备状态**：iPhone 需要保持解锁；当前主要支持竖屏流程，未保证横屏与动态旋转行为。
- **指针精度**：部分设备需要[指针校准](docs/user-guide.md#指针校准)，定位效果会受机型、iOS 版本和指针设置影响。
- **文字输入**：直接输入使用 US 键盘布局，仅支持 ASCII。其他文字需要借助手机已配置的输入法或 Apple 通用剪贴板；剪贴板共享仍需满足 Apple 的相关条件。
- **连接排查**：有画面但不能操作时，先检查蓝牙配对和辅助触控，再通过 `/status` 查看连接状态，或阅读[故障排查](docs/user-guide.md#常见问题与限制)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [完整使用手册](docs/user-guide.md) | 窗口操作、MCP 配置、API 参考、校准、多设备配对、录屏与故障排查 |
| [架构说明](docs/architecture.md) | 模块职责、共享状态、队列与维护约束 |
| [Agent 技能](codex/skills/iphone-use/SKILL.md) | 在 Codex 中复用手机操作流程 |
| [发布指南](docs/releasing.md) | 自动发布 Releases、Universal 打包、版本与签名说明 |

## 开发

```sh
swift test
swift build -c release
python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'
python3 -B scripts/check-mcp.py
```

硬件相关修改还需在真机上检查配对、USB 重连、指针落点和窗口交互。格式化与维护约定见[架构说明](docs/architecture.md)。

## 许可

[MIT](LICENSE)
