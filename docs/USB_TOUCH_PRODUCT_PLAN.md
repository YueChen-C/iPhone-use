# USB 原生触控产品化与集成计划

状态：进行中；[Draft PR #14](https://github.com/YueChen-C/iPhone-use/pull/14)。
所有后续修改、提交、验证直接在 `codex/coredevice-usb-touch-experiment` 完成，
不另建分支或 worktree。早先实验提交已撤销；本轮按授权分阶段提交真实集成进度。

## 1. 产品目标与验收边界

让 iphone-use 的同一台已验证物理设备，可以显式选择 **蓝牙控制** 或 **USB 原生触控**。
选 USB 后，触控不要求蓝牙 host、蓝牙订阅、指针配对或相对指针校准；既有 USB 画面采集、
OCR、AX、HTTP/MCP 工具和多窗口设备选择继续使用，不为 USB 触控重新设计屏幕采集。

MVP 的 USB 能力为单指 tap、长按、swipe 和窗口按下/拖动/释放，均需逐项真机验收。
USB 原生触屏不是鼠标：悬停不发送 contact，移动到按钮上不能意外点击。
键盘、中文输入、Home、Power、相对鼠标 nudge **不因有 HID socket 就视为支持**；
USB 模式明确禁用未实现操作并返回 unsupported，用户可主动切回 BLE。后续验证后才扩展。

兼容性按实测 host/DDI/iOS/机型登记；当前只有 MobileDevice1827.100.17.100.1/arm64、
CoreDevice397.24、iPhone12/iOS26.5 与 DDI27B52/651.32 的实验结果。
AssistiveTouch 关闭、连续手势、旋转、拔插、多设备都不是已有支持承诺。
当前阶段 portrait-only；旋转时暂停 USB 手势，不能复用旧坐标。

约束：Swift 原生；不引入 Python/第三方运行挂载程序；不打包 Apple DDI；不升级 iOS、
替换主机框架或关闭 BLE。应用自身的隔离 worker 是同一可执行文件的入口，不是外部工具。

## 2. 已确认现状与需要解耦的真实代码点

| 现有入口 | 当前限制 | 集成调整 |
| --- | --- | --- |
| `Sources/iPhoneUse/Devices/DeviceRegistry.swift` 的 `input(for device:)` | 返回 `DeviceInput` 必须有 matched BLE host；inputs按host缓存 | 新增按完整physicalID缓存的控制router；保留原方法给BLE配对/校准内部使用 |
| `Sources/iPhoneUse/Input/DeviceInput.swift` 的 `isBluetoothReady/isPointerReady` | keyboard/consumer订阅和指针校准参与就绪 | BLE adapter复用现有语义；USB使用独立capability/readiness，不伪造host UUID |
| `Sources/iPhoneUse/API/ControlAPI.swift` 的 `perform/tapTextPoint/waitForWake` | 所有动作先取BLE input；wake等待host | 各动作按capability解析同一router；tap_text/act同路由；等待对应后端而非host |
| `Sources/iPhoneUse/UI/PhoneControlView.swift` | `DeviceInput?`、host绑定、蓝牙就绪门禁、悬停定位 | 改为通用控制会话；键盘与触控分别门禁；USB无contact悬停；手势结束显式release |
| `Sources/iPhoneUse/UI/ControlConnectionOverlay.swift` | 状态和提示均解释为蓝牙连接 | USB显示信任/开发者模式/DDI/兼容/身份/断线原因；不提示蓝牙配对或校准 |
| `Sources/iPhoneUse/MCP/MCPTools.swift` / `MCPServer.swift` | 翻译工具到既有HTTP动作 | 保留名称和坐标约定，经HTTP路由统一；状态和错误携带后端及能力 |
| `Sources/iPhoneUse/main.swift` 与 `Capture/USBIdentityScreenshot.swift` | 已有同可执行文件worker隔离阻塞系统调用 | 复用该模式；新USB worker先分流，不启动AppKit/BLE/HTTP，不放全局alarm进GUI |

CodeGraph未建立索引；上述代码点已用当前源文件核对，不根据另一个上游同名产品猜测。

## 3. 目标结构

```text
GUI / HTTP / MCP / tap_text / act
    -> 每物理设备 DeviceControlSession（显式选择、代际、能力、串行排队）
        -> BLEInputBackend -> 既有 DeviceInput -> HIDPeripheral
        -> USBTouchBackend -> 应用自身 USB worker
            -> Swift broker注册/设备快照/usage assertion
            -> deviceinfo检查 + 原生RemoteXPC + universalhidservice
            -> DDI内 dtuhidd -> 单触点report -> release -> PING

本地用户授权的镜像管理 -> 同一应用自身DDI worker -> Apple MobileDevice.framework
屏幕采集/身份验证 -> 既有 ScreenCaptureManager（独立于输入后端）
```

模块边界：

- `InputBackend.swift`：纯策略契约，包括后端、动作能力、readiness、完整物理身份、
  session/generation租约和执行阶段。不得调用Bluetooth或触发探测/挂载。
- `DeviceControlSession`：一个physicalID一个调度器，串行化GUI/API/MCP动作与切换。
  BLE adapter包裹现有DeviceInput；不复制相对指针校准逻辑。
- USB wire、broker、触控session、DDI管理分文件；搬移实验代码时移除占位AXDTX、
  全局emit、命令行alarm和硬编码surface，保留MIT归属并使用有界原生codec。
- Apple ABI只启用已验证dialect。设备快照必须把 CoreDevice UUID 与完整USB UDID
  对应；不能只校验UUID存在、按名称或首台设备回退。屏幕身份代际也参与执行租约。

## 4. 安全状态机与输入语义

USB状态：disabled -> preparing -> ready；失败细分 requiresTrust、requiresDeveloperMode、
requiresDDI、unsupportedHost、unsupportedDevice、identityUnverified、disconnected、failed。
“已插线”“DDI返回0”“HID socket可用”和“画面已经变化”是不同证据层，不能混写。

准备过程只读：精确设备身份 -> 已有信任/开发者条件 -> broker和displayinfo ->
HID/触屏surface能力 -> 屏幕物理身份和方向一致 -> 发布含session的ready快照。
正常手势不得自动配对、挂载/更新DDI、切换后端、探测其他手机或恢复历史动作。

每次动作获得不可变租约：`physicalDeviceID + backend + sessionID + generation + capability`。
执行前与发送每阶段检查当前租约；拔插、屏幕重建、DDI变化、worker退出及后端切换立即
使旧租约失效、取消队列。丢失reply只能尽力release，不重发contact/tap。
PING ACK只表示transport确认，不代表UI生效；`mayHaveExecuted`不能表示可安全重试。

切换后端：停止接收旧动作 -> 取消排队动作 -> 旧会话尽力release -> generation更新 ->
准备并激活新会话。初期不提供auto模式，不静默混用“USB触控+BLE键盘”；新动作能力不足
直接拒绝，不借另一条链路执行。BLE保持默认，切回BLE后原配对/校准文件不丢失。

## 5. 产品入口与兼容契约

拟新增 `POST /input/backend`：`device`沿用现有选择器，在公共边界解析后必须固定完整ID，
`backend`只能`ble|usb`。返回切换结果和新的状态代际；仅影响所选设备。
`GET /devices`、`/status`增加`input`对象，保留既有bluetooth/pointer字段兼容老客户端：

```json
{
  "input": {
    "backend": "usb",
    "state": "ready",
    "sessionCurrent": true,
    "capabilities": ["tap", "swipe", "drag"],
    "requiresCalibration": false
  }
}
```

以上是目标schema示例，不是目前已经输出的状态。未就绪也返回明确reason，而不是复用
“蓝牙未连接”。能力不足返回`unsupported_capability`，就绪不足返回`input_not_ready`，
旧会话返回`stale_session`；保持现有HTTP错误外形兼容并补机器可读字段。
操作成功只声明已接受/已发送阶段，不声称已完成UI结果。API/MCP坐标转换仍只在现有边界
做一次；内部用0...1，拒绝非有限值/越界，先验证整条路径再发送contact。

UI每设备显示“蓝牙控制 / USB原生（实验性）”、真实readiness及受限能力；USB ready时
不要求BLE连接overlay。切换与DDI管理必须显式操作，不在30Hz刷新时触发阻塞探测。
旧版API调用不带backend时使用已选偏好；未配置的设备继续BLE，初期不自动迁移。

## 6. DDI生命周期、来源与恢复

DDI管理与日常输入分离；**HTTP/MCP的tap或prepare不得自动挂载镜像**。本地UI选择目录并
显示当前/候选版本、哈希、来源和影响范围，二次确认后执行；headless管理通过应用自身
显式本地CLI确认，网络API不开放任意路径挂载。

在卸载前完成：验证已信任的精确USB设备、当前镜像回读、旧载荷备份、已知清单/载荷/
trustcache路径与digest校验、包内路径不越界、候选兼容预检、恢复入口和状态持久化。
镜像包含可执行代码，哈希匹配不能替代来源/许可/签名审查；当前固定镜像来自第三方镜像
提交，不称其为直接Apple CDN下载，不自动下载或再分发。正式启用须通过来源策略。

状态记录：preflight -> unmounted -> mounted -> independentlyVerified；每步写入恢复记录。
失败返回实际阶段和恢复选项，不能一边出错一边无提示自动重复；仅关闭自有资源。
旧镜像恢复与源码回滚是两件事；旧版无HID是预期对照，不等同恢复失败。
实验阶段完整restore脚本尚未整体执行，后续该项必须单独验收。

## 7. 性能、可观测性和本地验证

正常视频路径不新增日志、哈希或逐帧broker探测；readiness按设备生命周期事件刷新并缓存。
进程内调度器/worker按设备复用，不为每个鼠标move编译或启动工具；触控不依赖媒体流。
有界消息、IO超时、退出清理、仅管理自有FD/listener/assertion，诊断记录阶段和匿名关联ID，
不向公开PR提交UDID、个人绝对路径、原始设备日志、截图、DDI和签名票据。

只在相关行为变化时跑最小筛选用例和构建；不每轮跑全量测试。既有PR CI保留。
真机输入前读取并查看新截图，选安全落点，再取新截图证明结果；断开/取消不能隐藏重放。

## 8. 分阶段交付与可观察验收

| 里程碑 | 交付与完成条件 | 当前 |
| --- | --- | --- |
| M0 | 创建/关联Draft PR；原生结果和边界可追溯；当前分支分阶段提交 | PR #14已有，推送首阶段后恢复Draft |
| M1 | 产品设计；纯后端策略契约；同设备/会话/能力/不回退的小范围验证 | 已实现并有策略检查，见第9节 |
| M2 | 拆分Swift原生wire/broker；同可执行文件隔离worker；绑定完整USB身份和surface；只读探测进入ready | 进行中，见第9节与未完成项 |
| M3 | BLE adapter + USB adapter + 每设备router；HTTP tap/tap_text/act与MCP接入；关闭BLE也能执行USB安全tap并观察画面 | 进行中，见第9节与未完成项 |
| M4 | GUI后端选择、独立连接提示、窗口按下/拖动/释放；swipe/长按；输入错误和取消释放验证 | 进行中，见第9节与未完成项 |
| M5 | 授权DDI管理、完整性与来源门禁、真实旧版恢复及新版重挂、掉线中断恢复记录 | 进行中，见第9节与未完成项 |
| M6 | BLE回归、关USB回退、多设备身份隔离、portrait/旋转拒绝、连续手势、资源清理；文档/发布边界齐备 | 进行中，见第9节与未完成项 |

目标完成事件：M0..M6全部有实际结果；API/MCP/GUI在同一选定设备使用USB且不依赖BLE，
DDI恢复与禁用USB回退均实际验证。若未验证机型/方向/能力则明确不可用，不扩大支持声明。
在此之前PR保持Draft，集成工作目标保持active，不以“只有设计/能取FD/编译成功”标完成。

下一步：M1验证通过后，先抽离wire和worker，保持实验入口及原四角色仍可复现；
再以只读身份与capability探测打通M2，之后才接产品输入，不一次重写BLE代码。

## 9. 当前集成进度（2026-11-13）

- M0/M1：已在原分支推送设计与策略契约，PR 保持 Draft。
- M2：应用自身 `--usb-touch-worker`、原生 wire/broker、完整 USB UDID → CoreDevice UUID、
  动态触屏 surface、capture 物理身份与尺寸门禁已接入。私有 host ABI 仍只支持实测版本。
- M3：HTTP `/input/backend`、tap/swipe、OCR/act 复用路由和 MCP 后端选择已接入。
  在蓝牙管理器不启动、host 为空时，HTTP 点击实际打开设置；USB 键盘明确返回 unsupported。
- M4：窗口后端选择、鼠标点击、按住拖动/释放、滚轮转 swipe 已接入且有真机前后画面。
  悬停不发送触点。滚轮一次最多一个待执行/执行中手势，丢弃积压而非停止后继续重放。
- 切换安全：先失效代际并阻止两条后端输入，取消旧队列，等待 USB release/PING + worker
  退出及 BLE 队列释放排空，再启用下一后端。释放无法确认则保持 failed，不绕过门禁。
  5 秒 HTTP 长按在切换时约 0.365 秒返回 uncertain/replayAllowed=false，旧 worker 退出；
  显式切回无连接的 BLE 后点击被拒绝，重新选择 USB 可以重新准备。
- 相关检查新增 unsigned NSNumber 尺寸解码、非法尺寸/方向/灭屏拒绝、代际切换、释放失败
  关闭门禁、滚轮背压和 BLE 旧输入释放。一次扩展筛选 106 项中发现 1 项 transport-readiness
  回归：误把屏幕门禁计入 BLE 连接就绪；已恢复原契约，修正后 62 项筛选通过，最终变更后
  29 项最小筛选通过。未运行全量用例，不将这些筛选表述为完整产品验收。
- 按用户要求暂不添加子目录独立许可证文件及打包资源，保留源码出处与原根目录 LICENSE；
  正式分发前仍需完成许可整理，不视为法律/来源审查已完成。

未完成：M5 的产品内原生 DDI 授权管理、来源/完整性门禁与整段恢复入口验收；
M6 的实际 BLE 已连接设备回归、拔插/旋转/多设备动作隔离、AssistiveTouch 关闭验证、
长期连续输入、MCP 端到端和发布文档。旧实验 DDI 恢复证据不替代产品管理入口。
