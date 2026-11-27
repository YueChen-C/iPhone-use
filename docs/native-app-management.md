# 原生 App 管理 / Native App management

这组接口对**已信任、通过 USB 连接**的 iPhone 生效。运行已构建的 iPhone Use 不调用 Xcode、Command Line Tools、`devicectl` 或外部设备工具；iPhone 上也不用装伴侣 App。由 macOS 的 Apple MobileDevice 及设备上实际可用的服务决定兼容性。

| MCP | 本地 HTTP | 说明 |
| --- | --- | --- |
| `list_apps` | `GET/POST /list_apps` | 通过 Installation Proxy 读取 Bundle ID、名称，以及设备提供的版本、类型。设备可能不会列出所有系统 App。 |
| `get_foreground_app` | `GET/POST /get_foreground_app` | 用原生 AX 观察前台。`known:false` 时不可推定前台 App；部分系统只给出 PID，未必有 Bundle ID。旧系统的 AX Inspector 可能移动焦点。锁屏、服务不可用等情况下也可能返回错误。 |
| `launch_app` | `POST /launch_app` | 按 `bundle_id` 启动指定 App，可选传 `url` 给它。需 iOS 17+，以及设备上的 AppService；可能要求解锁、Developer Mode、兼容的开发者镜像等。不会自动安装或修改开发者镜像，也不会以 Spotlight 或坐标点击回退。 |
| `terminate_app` | `POST /terminate_app` | 按 `bundle_id` 强制结束指定 App 的主进程。依赖 iOS 17+ AppService，设备要求与 `launch_app` 相同。未保存的数据可能丢失，不等同于切到后台。 |

HTTP/MCP 的目标设备需已出现在 `/devices`。多台设备时显式传 `device`，推荐使用接口返回的完整 USB UDID。HTTP GET 使用同名查询参数；POST 和 MCP 使用 JSON 字段。

```sh
curl -s http://127.0.0.1:7390/devices
curl -s "http://127.0.0.1:7390/list_apps?device=$DEVICE"
curl -sS http://127.0.0.1:7390/launch_app \
  -H 'Content-Type: application/json' \
  -d "{\"device\":\"$DEVICE\",\"bundle_id\":\"com.apple.Preferences\"}"
curl -sS http://127.0.0.1:7390/launch_app \
  -H 'Content-Type: application/json' \
  -d "{\"device\":\"$DEVICE\",\"bundle_id\":\"com.apple.mobilesafari\",\"url\":\"https://example.com/\"}"
curl -s "http://127.0.0.1:7390/get_foreground_app?device=$DEVICE"
curl -sS http://127.0.0.1:7390/terminate_app \
  -H 'Content-Type: application/json' \
  -d "{\"device\":\"$DEVICE\",\"bundle_id\":\"com.apple.Preferences\"}"
```

`outcome: "acknowledged"` 与 `pid` 表示设备确认收到启动；`foreground_verified: true` 才表示后续 AX 观察匹配目标（不代表页面已可交互）。`foreground_verified: false` 并不否定启动回执。失败可能是 `not_sent` 或 `unknown`；尤其遇到 `unknown` 要先看设备当前状态，不要自动重发。接口不会自动截图。

`launch_app` 的 `url` 为可选参数；传入时 `bundle_id` 仍必填。HTTP 只接受 JSON 请求体中的 `url`，MCP 使用同名参数。不传时保持原有启动行为。首版要求绝对 `http://` 或 `https://` 地址、有主机名、无账号凭据，最多 4096 字节；路径和查询中的空格、非 ASCII 字符请先百分号编码。AppService 收到原始 URL 字符串；本机不访问目标网页。成功回执中的 `url_requested: true` 仅表示启动请求携带了 URL，不代表 App 接受了它、已导航或已加载页面。`foreground_verified` 也仅确认 App 在前台，不确认页面。接口不回显 URL，不因传入 URL 而主动结束已有进程。

`terminate_app` 先从同一台 iPhone 的 Installation Proxy 读取指定 App 的安装路径和主可执行文件，再与 AppService 的运行进程做完整路径匹配，不按 App 名称、前台状态或用户提供的 PID 猜测。匹配后只发送一次 `SIGKILL`，不递归处理扩展或子进程。信号协议以 PID 为目标，不提供对 PID 复用的原子保护。

- `terminated`（带 `pid`）：设备回执与目标 PID、信号匹配，且后续进程快照确认该 PID 和 App 主进程均已消失。App 仍可能在快照后被重新启动。
- `already_stopped`（无 `pid`）：已确认目标 App 存在，但其主可执行文件不在进程列表中；未发送信号。
- `not_sent` / `unknown`（HTTP 503）：前者表示未发送结束信号，例如 App 未安装、设备不支持或进程无法确认；后者表示信号回执或进程退出无法确认（worker 超时也可能返回此状态）。`replayAllowed: false`，先重新观察设备，不要自动重试。

验收应分别记录：干净 Mac（未装 Xcode/CLT）首次信任、开发者镜像未准备与已准备、设备锁屏、两部 iPhone 同时连接时的目标隔离，以及启动回执、前台状态与结束后的进程读回。不能用设置 `DEVELOPER_DIR` 代替干净 Mac 验收。原生服务属于 Apple 私有接口，不能把某个 iOS/macOS 版本的结果外推到所有设备。

## 本次分支真机验证

在仍安装了 Xcode 的 macOS 15.1.1 主机上，用 `PATH=/nonexistent` 和 `DEVELOPER_DIR=/nonexistent` 启动构建好的二进制与 MCP。两台 USB iPhone 分别读回 176、263 个条目；省略设备时报歧义。旧设备的启动请求返回 `not_sent`，不回退到按键或点击。现代设备从 Settings 切到 Calculator，设备确认了启动，MCP 返回 `foreground_verified: true`，随后通过 HTTP 独立读回同一个 PID。这些结果验证运行时不需要查找 Xcode 工具；未验证全新 Mac 上的首次信任与 DDI 准备。

同一双设备环境下，用 HTTP 启动 Calculator，经 AX 核对前台 PID 后，用 MCP `terminate_app` 结束了该 PID；再用 HTTP 独立读回确认前台已不是该 PID。重复结束返回 `already_stopped`；未安装的 Bundle ID、旧设备均返回 `not_sent`。省略设备时拒绝执行；GET 不开放此接口。

## URL 真机验收与能力边界

在同一双设备环境、同样屏蔽 `PATH` 和 `DEVELOPER_DIR` 的条件下，先独立确认 Safari 已停止，再通过 HTTP 以 HTTPS 链接冷启动；随后通过 MCP 交付 HTTP 链接，Safari 保持同一 PID。两次均独立通过 AX 核对了实际域名和 `Example Domain` 页面内容；另用 HTTPS 回显页核对了完整请求路径和查询（含 `%2B`、`%2F`）。片段 `#fragment` 不随 HTTP 请求发送，本次由序列化单测核对，未做真机地址栏读回。不传 `url` 仍正常启动，不出现 `url_requested`。无效 URL、无 Bundle ID、设备选择歧义及不支持的旧设备均未执行启动。

该实现使用 `launchapplication` 的 `payloadURL` 选项，**只向指定 App 传 URL**，不让 iOS 选择默认浏览器或其他处理 App；其他 App 是否处理传入链接取决于 App 自身。未提供通用 `open_url`，也未声称支持自定义 Scheme 或按 Universal Link 选择 App。[Poki 真机路径](https://github.com/JosssphZhou/poki/blob/e20f28f3af8278359cf7fb12b5a592d3d1e15af9/src/platform.mjs#L479-L485) 调用 `devicectl device process openURL`，不符合本项目的运行时约束。真机 RSD 枚举尚未找到已验证的系统级 URL 派发入口。
