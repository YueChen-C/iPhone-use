# 代码结构与维护约束

本项目通过 USB 采集 iPhone 画面，通过 Bluetooth LE HID 发送输入。窗口、HTTP API 和 MCP 最终使用同一个手机输入队列；重构或扩展功能时，应以这一共享状态为基础。

## 入口与模块

| 目录 | 主要文件与职责 |
| --- | --- |
| 根目录、`App/` | `main.swift` 选择启动模式；`Application.swift` 持有应用级对象，协调启动顺序、设备窗口与应用菜单 |
| `UI/` | `ControlWindow.swift` 管理多设备窗口生命周期与单窗布局；`PhoneControlView.swift` 按固定设备 ID 协调画面、设备与交互；`ControlInput.swift` 集中坐标/鼠标/键盘转换；侧栏和连接蒙层分别维护 |
| `Devices/` | `DeviceRegistry.swift` 管理设备模型、配对与会话输入缓存；`DevicePairing.swift` 集中配对文件和探测评分 |
| `Capture/` | `ScreenCapture.swift` 管理设备发现和帧采集；`CaptureIdentityVerifier.swift` 比较物理 USB 身份与视频源；`USBIdentityScreenshot.swift` 在隔离工作进程中调用系统 MobileDevice 服务，无外部截图命令依赖 |
| `Bluetooth/` | `HIDPeripheral.swift` 管理 GATT；`HIDConnectionState.swift` 管理连接和背压；`HIDReports.swift` 定义描述符与报告字节 |
| `Input/` | `DeviceInput.swift` 管理每台手机的输入队列；`KeyboardMap.swift` 定义键盘映射；`RelativePointerCalibration.swift` 定义模型和位移算法，`+Storage.swift` 处理文件兼容与迁移 |
| `API/` | `HTTPServer.swift` 包含传输及请求/响应编解码；`ControlAPI.swift` 包含路由与坐标换算；`WebPreview.swift` 提供 `/viewer` 只读实时预览页，供 Codex 右侧浏览器显示 |
| `MCP/` | `MCPServer.swift` 包含 JSON-RPC 分派和私有 HTTP 客户端；`MCPTools.swift` 定义工具目录与参数映射；`MCPKeyboardSequence.swift` 校验键盘组合；`MCPAccess.swift` 协调不同 stdio 进程的设备访问和主程序恢复 |
| `Localization/` | `AppLanguage.swift` 定义语言枚举与线程安全的当前语言存储（UserDefaults 持久化 + 变更通知）；`StringsUI` / `StringsAPI` / `StringsWeb` / `StringsMCP` 四个表以存储属性同时给出中英文文案，编译期保证两语言键一致 |

以上目录位于 `Sources/iPhoneUse/`。`scripts/calibrate-pointer.py` 负责通过 Safari 测量指针曲线。

## 界面语言

应用进程在 `AppLanguageStore`（NSLock 保护）持有当前语言：应用菜单「语言 / Language」切换，UserDefaults 持久化，未选择时跟随系统语言；变更通过通知广播，菜单原地改写标题、窗口与侧栏/蒙层调用各自的 `refreshLocalization()`，侧栏状态行和画布等待文字随 30 Hz 刷新自然跟随。MCP 是独立 stdio 进程，读不到应用 UserDefaults，因而在 initialize/tools/list 时通过 `GET /config` 获取语言并缓存，失败保持英文（兼容旧版主程序）。`/viewer` 按当前语言生成页面，JS 文案以 JSON 字典注入；页面轮询 `/config` 在语言变化时自动刷新，`?lang=zh|en` 可锁定。MCP 工具名、参数名和 schema 键永远保持英文；HTTP 状态码与 reason 短语不随语言变化。

## 多设备窗口

窗口按完整 USB 设备 ID 管理，每台已连接手机自动创建一个窗口。设备名称仅用于显示，不能作为窗口、画面或输入路由的标识；同名手机必须保持独立。每个窗口的渲染尺寸、鼠标坐标换算、输入绑定与快捷按钮都只使用对应设备的数据。

USB 断开后保留原窗口，清除旧画面与输入绑定并显示等待状态；原设备重新连接后恢复，不允许改绑其他手机。用户主动关闭窗口时停止该窗口的刷新和输入交互，但不停止设备采集或 API/MCP 服务，也不应在下一次刷新时自动重新打开。菜单“窗口 → 显示所有设备”和 Dock 重新激活可以恢复已关闭的已连接设备窗口。关闭最后一个窗口仍退出应用。

窗口通过 `DeviceRegistry` 异步获取对应的共享 `DeviceInput`，避免配对探测或输入对象初始化阻塞主线程。异步结果返回时应重新检查窗口生命周期与设备连接，丢弃已关闭窗口或已断开设备的结果。窗口、HTTP 和 MCP 不创建各自独立的输入状态。

## 文件组织原则

同一业务职责中一起变化的小型类型放在同一文件：例如窗口内容容器跟随窗口控制器、画面渲染器跟随手机视图、HTTP 消息模型跟随服务器。仅单文件使用的实现声明为 private；需要独立测试的纯模型保留模块内可见性。

文件按职责拆分，不要求每个类型都有独立文件。状态复杂或有明确独立边界的模块继续分开，例如蓝牙连接状态与 CoreBluetooth 传输、校准计算与配置持久化。类型名描述具体角色，使用 `DeviceRegistry`、`DeviceInput`、`ScreenCaptureManager` 和 `ScreenCaptureSession` 区分管理器、输入执行器和采集会话。

测试位于 `Tests/iPhoneUseTests/`，按 UI、Devices、Bluetooth、Input、API、MCP、Localization 分目录。密切相关的小型测试类共享文件，输入跟踪和校准等较大的测试套件保留独立文件。

## 队列和状态归属

- **AppKit 主线程**管理设备窗口并处理各窗口事件与 30 Hz 刷新。设备输入绑定异步获取，键盘和快捷操作异步交给对应设备的输入队列，避免一台设备的探测或操作阻塞其他窗口。
- **每个 DeviceInput 的串行队列**拥有按钮状态、窗口拖拽状态和估计位置。HTTP 手势同步执行，窗口事件异步执行。不要把队列内部操作再次同步派发到同一队列。
- **运动序号的锁**用于让新目标打断旧的鼠标跟随。取消的是未发送的轨迹，已发送报告产生的位置必须保留。
- **Bluetooth 队列**拥有 GATT 对象、订阅、会话令牌和待发送报告。DeviceInput 中保存的令牌必须与当前连接匹配，防止重连后发送旧操作。
- **DeviceRegistry 的状态锁**保护配对关系和延迟匹配标记；**输入缓存锁**单独保护 DeviceInput 创建，因为创建过程中会同步读取 Bluetooth 队列。不能把两把锁随意合并。
- **设备匹配队列**串行执行探测。尚未确认的候选屏幕不能绑定旧校准文件。
- **采集队列**写入单个 ScreenCaptureSession 的最新帧，读取方同步取得帧后再渲染；设备发现使用独立锁，变更通知在解锁后发出。
- **MCP 跨进程锁**先按端口持有服务共享锁，再按完整设备 ID 持有排他锁，覆盖动作、等待和结果截图；不同手机使用不同锁。恢复脚本持有同一服务文件的排他锁，不能在 MCP 调用期间重启主程序。锁文件不能删除，以免并发进程锁住不同 inode。此协调限于 MCP 客户端，不隔离两次工具调用之间的页面状态或 HTTP/手动输入。

`codex/skills/iphone-use/scripts/mcp_call.py` 在原生工具未加载或传输关闭时，通过仓库启动器新建独立 MCP 连接。每次调用严格先握手再执行工具，截图落盘为唯一文件；出错不重放动作，也不终止其他 MCP 进程。`ensure_service.py` 只处理 GUI/设备恢复，复用健康服务，不为缺失的单台手机重启仍能操作其他手机的共享主程序。

## 保持现有行为时需要核对的边界

1. HTTP 返回字段、错误文案、状态码、默认参数和校验先后顺序都属于接口行为。错误文案会随界面语言本地化，但字段结构、状态码与校验顺序不变。坐标支持完整屏幕尺寸、缩放截图尺寸以及 fraction；显式 width/height 的覆盖顺序必须保留。
   `swipe` 的 HTTP/MCP 参数统一为至少两个 `{x, y}` 对象的 `points` 数组与可选 `duration`（默认 0.3 秒）。`SwipeRequest` 在发送输入前校验整条路径，并用同一画面尺寸转换所有点；底层在一次串行手势中按下、经过全部点、释放，段间不能松手。分段移动等待时长按屏幕像素距离分配，总和为 duration，额外准备、释放及校准耗时不计入该值。
2. MCP 成功执行动作后等待 0.6 秒再截图。`keyboard_sequence` 在任何 HTTP 请求前校验全部步骤，整组持有设备锁，步骤间等待 0.15 秒，只在最后截图；任一步失败即停止且不重放。组合不改动底层 HID 报告间隔，不能替代网页加载检查。工具目录、参数映射、截图尺寸说明及错误封装都需要兼容现有客户端。
   `move_pointer`、`adjust_pointer`、`click_pointer` 分别复用 `/move` 和 `/nudge`，同样通过 MCP 锁和结果截图执行。前两者不点击，后者只发零位移点击；微调限制为每轴 -32...32 的整数 HID 计数，参数在任何 HTTP 请求前完成校验。这些工具用于检查实际落点，不改变指针校准和 BLE 报告间隔，也不隔离多次调用之间的其他输入。
3. GATT 服务/特征的发布顺序、UUID、权限、描述符及 HID 字节布局涉及手机端缓存，不能当作普通内部实现任意调整。
4. 蓝牙背压只能合并相邻、同设备、同按钮状态的绝对位置报告；按键、按钮变化和相对位移必须按顺序发送。
5. 拖拽期间，针对同一手机的 API 坐标手势返回冲突，其他设备的输入不受影响。失焦、释放、取消、窗口关闭和设备重连时，要保留原有的按钮释放及位置失效顺序；不得释放其他窗口对应设备的按钮。
6. 校准计算中的取整、候选遍历顺序、单轴/向量模型、报告间隔和归位条件都会影响真实落点。修改结构时应保持这些表达式与顺序。
7. `pairings.json` 和指针校准 JSON 属于用户已有数据。手机 USB 身份、Bluetooth host、分辨率与迁移规则必须一起检查。

## Swift 代码风格

使用 Swift 工具链自带的 `swift format`，配置统一保存在仓库根目录 `.swift-format`：4 空格缩进、120 字符目标行宽、最多一个连续空行，其余采用工具默认 Swift 规则。格式化覆盖 Package.swift、业务源码和 Swift 测试，不扫描构建产物。

```sh
swift format format --in-place --recursive Package.swift Sources Tests/iPhoneUseTests
swift format lint --strict --recursive Package.swift Sources Tests/iPhoneUseTests
```

## 验证

```sh
swift test
swift build -c release
python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'
```

Swift 测试通过注入报告发送器和纯状态模型覆盖输入时序、断线重连、位置追踪、校准迁移和窗口几何，并覆盖多设备窗口生命周期、过期输入绑定、焦点与遮挡判断、跨设备拖拽取消，以及协议解析、键盘映射与配对文件兼容性。Python 测试使用模拟移动和页面事件，避免控制真实手机。

自动化测试不能替代真机验收。涉及硬件的改动还需要检查配对/重连、USB 拔插、窗口点击拖拽和失焦释放、HTTP/MCP 手势，以及校准后的实际落点。
