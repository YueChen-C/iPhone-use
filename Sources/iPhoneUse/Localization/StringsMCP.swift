import Foundation

/// Strings for the stdio MCP process: initialize instructions, tool catalog
/// descriptions, and MCP-layer errors. There is deliberately no `current` —
/// the MCP subprocess never reads AppLanguageStore (a different process); it
/// passes the language it fetched from GET /config explicitly. Tool and
/// parameter names stay English in both languages for client compatibility.
struct StringsMCP: LocalizedTable {
    let instructions: String
    let deviceParam: String
    let xPixels: String
    let yPixels: String
    let normalizedParam: String
    let normalizedBoolean: String
    let normalizedRange: (String) -> String
    let normalizedPoints: String
    let holdSeconds: String
    let swipePointsDesc: String
    let swipeDurationDesc: String

    // Tool descriptions (MCPTools.swift)
    let toolListDevices: String
    let toolScreenshot: String
    let toolOCRScreen: String
    let toolTapText: String
    let includeImage: String
    let toolMovePointer: String
    let toolAdjustPointer: String
    let toolClickPointer: String
    let toolTap: String
    let toolLongPress: String
    let toolSwipe: String
    let toolTypeText: String
    let toolPressKey: String
    let toolKeyboardSequence: String
    let toolHome: String

    // MCPToolRequest / MCPKeyboardSequence validation
    let unknownTool: (String) -> String
    let coordinateFinite: (String) -> String
    let hidCountRange: (String) -> String
    let parameterRequired: (String) -> String
    let keyboardSequenceRange: String
    let kbStepLabel: (Int) -> String
    let kbAscii: (String) -> String
    let kbExpected: (String) -> String
    let kbDelay: (String) -> String
    let booleanRequired: (String) -> String
    let typeAscii: String
    let kbUnknownModifier: (String) -> String

    // MCPServer
    let invalidDeviceList: String
    let expectedOneMatch: (Int) -> String
    let keyboardStopped: (Int, Int, String) -> String
    let actStopped: String
    let screenshotCaption: (String, String, String) -> String
    let noResponse: String
    let appNotRunning: (String) -> String

    // MCPAccess lock errors
    let lockStateDirAbsolute: String
    let lockOpenFailed: (Int32) -> String
    let lockAcquireFailed: (Int32) -> String
    let lockServiceBusy: String
    let lockDeviceBusy: String

    static let zh = StringsMCP(
        instructions:
            "控制真实 iPhone。先截图，再按该手机最新截图的像素坐标点按；使用每轴 0...1000 坐标时须传 normalized=true。截图长边最多 1000 像素。连接多台手机时，先调用 list_devices 并给每个工具传入 device。各会话连接独立。每一步操作及其确认截图按手机串行执行；其他会话可能在两次调用之间改变屏幕。",
        deviceParam: "目标 iPhone（list_devices 返回的 id 或名称）。device_id 是 device 的别名；同时提供时优先 device。连接多台时才需要传入。",
        xPixels: "X：截图像素；normalized=true 时为 0...1000",
        yPixels: "Y：截图像素；normalized=true 时为 0...1000",
        normalizedParam: "设为 true 时，每轴坐标使用 0...1000（0 为起点，1000 为终点）；默认 false，使用截图像素。",
        normalizedBoolean: "normalized 必须是布尔值",
        normalizedRange: { "\($0) 必须是 0...1000 内的有限数值" },
        normalizedPoints: "points 必须至少包含两个具有数值 x/y 的对象",
        holdSeconds: "长按时长（秒，默认 1）",
        swipePointsDesc: "滑动路径的有序点（默认截图像素；normalized=true 时每轴为 0...1000）",
        swipeDurationDesc: "整条路径的移动时长（秒，默认 0.3）",
        toolListDevices: "列出当前连接的 iPhone。",
        toolScreenshot: "截取 iPhone 当前屏幕，附带 OCR 文字中心点（左上角原点像素坐标）。include_image=false 时仅返回文字。OCR 可能遗漏或误识别。",
        toolOCRScreen: "识别屏幕文字，仅返回文字与左上角原点像素坐标，不含图片。maxEdge 默认为 1000。",
        toolTapText:
            "识别并点按匹配文字的中心。默认不区分大小写的包含匹配；exact=true 为区分大小写的完全匹配。index 从 0 开始，按从上到下、从左到右排序；默认点按首项。hold 默认为 0.08 秒，maxEdge 默认为 1000。返回确认截图；include_image=false 时仅返回文字。",
        includeImage: "是否返回图片（默认 true；false 仅返回文字与 OCR）",
        toolMovePointer:
            "移动指针但不点击，随后返回截图以便检查实际落点。默认使用最新截图像素；normalized=true 时每轴使用 0...1000。校准后的点按出现偏移时有用。",
        toolAdjustPointer:
            "在不点击的前提下微调当前指针并返回截图。dx/dy 是相对 HID 计数而非像素；请小幅修正并检查实际落点。不会修改已保存的校准。",
        toolClickPointer:
            "在当前指针位置点击（不移动指针），随后返回截图。请先用 move_pointer 或 adjust_pointer 确认指针位于目标上。其他会话可能在两次调用之间移动指针。",
        toolTap: "点按 iPhone 屏幕上的一个点。默认使用最新截图像素；normalized=true 时每轴使用 0...1000。",
        toolLongPress: "长按某个点，例如打开上下文菜单。",
        toolSwipe: "沿至少两个点的有序路径持续拖动，直到最后一个点才抬起。默认使用最新截图像素；normalized=true 时每轴使用 0...1000。",
        toolTypeText:
            "通过蓝牙键盘输入 ASCII 或中文（中文转拼音并以空格选择首个候选词）。clear_before 先全选清空；commit_ime 在文字后按空格提交输入法候选词；press_enter 最后按回车；ensure_chinese_ime 使用屏幕 OCR 尝试切换中文输入法。",
        toolPressKey:
            "按下按键，可带修饰键。按键：enter、escape、backspace、tab、space、up、down、left、right 或单个字符。修饰键：cmd、shift、alt、ctrl。cmd+space 打开聚焦搜索。",
        toolKeyboardSequence:
            "在当前应用中执行一段简短、已知的键盘序列，最后返回一张截图。所有步骤在输入前完成校验；同一手机的 MCP 锁覆盖整个序列。出错即停止且不会重放。需要查看中间画面时请拆分为多次调用。支持 steps/actions 别名、可选 type 字段及 0...5 秒的 delay/wait 步骤。文字步骤支持 clear_before、commit_ime、press_enter、ensure_chinese_ime。最多 16 步、文字总量 256 字符；中文转拼音并选择首个候选词。",
        toolHome: "回到主屏幕。",
        unknownTool: { "未知工具 \($0)" },
        coordinateFinite: { "\($0) 必须是有限且非负的截图坐标" },
        hidCountRange: { "\($0) 必须是 -32...32 内的整数 HID 计数" },
        parameterRequired: { "缺少 \($0)" },
        keyboardSequenceRange: "keyboard_sequence 需要 1...16 个 steps/actions 步骤和可选的 device/device_id；同时提供的步骤数组必须相同",
        kbStepLabel: { "keyboard_sequence 第 \($0) 步" },
        kbAscii: { "\($0)：文字必须可转换为美式 ASCII 按键或中文拼音；文字总量上限 256" },
        kbExpected: { "\($0)：需要文字、受支持的按键（可带修饰键）或 delay/wait 延时" },
        kbDelay: { "\($0)：延时必须是 0...5 秒内的非布尔有限数值" },
        booleanRequired: { "\($0) 必须是布尔值" },
        typeAscii: "文字必须可转换为美式 ASCII 按键或中文拼音",
        kbUnknownModifier: { "\($0)：未知的修饰键" },
        invalidDeviceList: "应用返回的设备列表无效",
        expectedOneMatch: { "期望匹配到一台 iPhone，实际 \($0) 台。请调用 list_devices 并传入完整 device ID。" },
        keyboardStopped: { step, count, error in
            "键盘序列在第 \(step)/\(count) 步停止：\(error)。之前的输入可能已执行；继续前请重新截图。"
        },
        actStopped: "已完成的步骤已生效，请勿重放；失败步骤可能部分生效，继续前请重新截图。",
        screenshotCaption: { "\($0) 的截图，\($1)x\($2) 像素。默认使用这些像素坐标；每轴 0...1000 坐标须传 normalized=true。" },
        noResponse: "无响应",
        appNotRunning: { "iPhone Use 应用未运行（\($0)）" },
        lockStateDirAbsolute: "IPHONE_USE_STATE_DIR 必须是所有客户端共享的绝对路径。",
        lockOpenFailed: { "无法打开 MCP 协调锁：\($0)" },
        lockAcquireFailed: { "无法获取 MCP 协调锁：\($0)" },
        lockServiceBusy: "另一个会话正在恢复服务；恢复后请重试。",
        lockDeviceBusy: "设备正被其他会话占用；继续前请重新截图。")

    static let en = StringsMCP(
        instructions:
            "Controls real iPhones. Take a screenshot first, then tap using pixel coordinates from the most recent screenshot of that phone. For per-axis 0...1000 coordinates, pass normalized=true. Screenshots have a maximum long edge of 1000 pixels. With several phones connected, call list_devices and pass device to every tool. Sessions have independent connections. Each action and its confirmation screenshot are serialized per phone; other sessions can change the screen between calls.",
        deviceParam:
            "Which iPhone (id or name from list_devices). device_id aliases device; device takes precedence. Only needed when several are connected.",
        xPixels: "X in screenshot pixels, or 0...1000 when normalized=true",
        yPixels: "Y in screenshot pixels, or 0...1000 when normalized=true",
        normalizedParam: "When true, each axis uses 0...1000 (start to end); default false uses screenshot pixels.",
        normalizedBoolean: "normalized must be a boolean",
        normalizedRange: { "\($0) must be a finite number in 0...1000" },
        normalizedPoints: "points must contain at least two objects with numeric x and y",
        holdSeconds: "How long to hold (default 1)",
        swipePointsDesc: "Ordered swipe points in screenshot pixels, or 0...1000 per axis when normalized=true",
        swipeDurationDesc: "Movement duration in seconds for the entire path (default 0.3)",
        toolListDevices: "List the connected iPhones.",
        toolScreenshot:
            "Capture the screen with OCR text centers in top-left pixel coordinates. Set include_image=false for text only. OCR may miss or misread text.",
        toolOCRScreen:
            "Recognize screen text with top-left pixel coordinates; returns text only, no image. maxEdge defaults to 1000.",
        toolTapText:
            "Recognize and tap a text center. Default: case-insensitive substring; exact=true uses case-sensitive equality. index is zero-based in top-to-bottom, left-to-right order, default first match. hold defaults to 0.08 seconds; maxEdge to 1000. Returns a confirmation screenshot; include_image=false returns text only.",
        includeImage: "Return the image (default true; false returns text and OCR only)",
        toolMovePointer:
            "Move the pointer without clicking, then return a screenshot to inspect the actual landing. Coordinates default to pixels of the latest screenshot; normalized=true uses 0...1000 per axis. Useful when a calibrated tap drifts.",
        toolAdjustPointer:
            "Nudge the current pointer without clicking and return a screenshot. dx and dy are relative HID counts, not pixels; use small corrections and inspect the actual landing. Does not change the saved calibration.",
        toolClickPointer:
            "Click at the current pointer position without moving it, then return a screenshot. First verify the pointer over the intended target with move_pointer or adjust_pointer. Other sessions may move it between calls.",
        toolTap:
            "Tap a point on the iPhone screen. Coordinates default to pixels of the latest screenshot; normalized=true uses 0...1000 per axis.",
        toolLongPress: "Press and hold a point, e.g. to open a context menu.",
        toolSwipe:
            "Drag continuously through an ordered path of at least two points, keeping contact until the last point. Coordinates default to pixels of the latest screenshot; normalized=true uses 0...1000 per axis.",
        toolTypeText:
            "Type ASCII or Chinese with the Bluetooth keyboard (Hanzi becomes pinyin and selects the first candidate). clear_before selects all and deletes first; commit_ime presses space after text; press_enter presses enter last; ensure_chinese_ime uses screen OCR to attempt switching to a Chinese IME.",
        toolPressKey:
            "Press a key, optionally with modifiers. Keys: enter, escape, backspace, tab, space, up, down, left, right, or a character. Modifiers: cmd, shift, alt, ctrl. cmd+space opens Spotlight.",
        toolKeyboardSequence:
            "Run a short, known keyboard sequence in the current app with one final screenshot. All steps are validated before input; the same-phone MCP lock covers the whole sequence. Stops on error without replay. Use separate calls when an intermediate screen needs inspection. Accepts steps/actions aliases, optional type tags and delay/wait steps of 0...5 seconds. Text steps accept clear_before, commit_ime, press_enter and ensure_chinese_ime. Up to 16 steps and 256 total characters; Hanzi becomes pinyin and selects the first candidate.",
        toolHome: "Go to the Home Screen.",
        unknownTool: { "unknown tool \($0)" },
        coordinateFinite: { "\($0) must be a finite, nonnegative screenshot coordinate" },
        hidCountRange: { "\($0) must be an integer HID count in -32...32" },
        parameterRequired: { "\($0) is required" },
        keyboardSequenceRange:
            "keyboard_sequence requires 1...16 steps/actions and optional device/device_id; both arrays must match when supplied",
        kbStepLabel: { "keyboard_sequence step \($0)" },
        kbAscii: { "\($0): text must be representable as US ASCII keys or Chinese pinyin; total text limit is 256" },
        kbExpected: { "\($0): expected text, a supported key with optional modifiers, or delay/wait" },
        kbDelay: { "\($0): delay must be a finite, non-boolean number in 0...5 seconds" },
        booleanRequired: { "\($0) must be a boolean" },
        typeAscii: "Text must be representable as US ASCII keys or Chinese pinyin",
        kbUnknownModifier: { "\($0): unknown keyboard modifier" },
        invalidDeviceList: "Invalid device list from the app",
        expectedOneMatch: {
            "Expected one matching iPhone, found \($0). Call list_devices and pass its full device ID."
        },
        keyboardStopped: { step, count, error in
            "Keyboard sequence stopped at step \(step)/\(count): \(error). Earlier input may have executed; take a fresh screenshot before continuing."
        },
        actStopped:
            "Completed steps have executed; do not replay them. The failed step may have partially executed; take a fresh screenshot before continuing.",
        screenshotCaption: {
            "Screenshot of \($0), \($1)x\($2) px. Use these pixels for tap and swipe, or pass normalized=true for 0...1000 per axis."
        },
        noResponse: "no response",
        appNotRunning: { "iPhone Use app is not running (\($0))" },
        lockStateDirAbsolute: "IPHONE_USE_STATE_DIR must be an absolute path shared by all clients.",
        lockOpenFailed: { "Cannot open MCP coordination lock: \($0)" },
        lockAcquireFailed: { "Cannot acquire MCP coordination lock: \($0)" },
        lockServiceBusy: "Another session is recovering the service; retry after recovery.",
        lockDeviceBusy: "Device busy in another session; take a fresh screenshot before continuing.")
}
