import Foundation

/// Error strings the app returns over HTTP, localized at their source so the MCP
/// bridge passes the app's language through unchanged.
struct StringsAPI: LocalizedTable {
    // ControlAPI endpoint validation
    let pairHostRequired: String
    let noFrameFromDevice: (String) -> String
    let pointerNotReady: String
    let textRequired: String
    let keyRequired: String

    // SwipeRequest validation (ControlAPI.swift)
    let swipePointsMin: String
    let swipePointFinite: (Int) -> String
    let swipeDurationInvalid: String
    let swipeSizeKeyInvalid: (String) -> String
    let swipeMaxEdgeRange: String
    let swipeInvalidDimensions: String

    // RequestCoordinates (ControlAPI.swift)
    let coordinatesRequired: (String, String) -> String
    let noFrameFromScreen: (String) -> String

    // DeviceRegistry device matching
    let noPhoneMatches: (String, String) -> String
    let noScreen: String
    let multiplePhones: (Int, String) -> String
    let noBluetoothConnection: (String, String) -> String
    let ambiguousBluetooth: (String) -> String
    let screenIdentityUnverified: (String) -> String
    let describeEmpty: String
    let describePrefix: String

    // DeviceInput.InputError
    let untypeable: (String) -> String
    let unknownKey: (String) -> String
    let pointerBusy: String
    let calibrationMismatch: String
    let invalidSwipePrefix: (String) -> String
    let pairingProbeUnavailable: String
    let swipeReasonPoints: String
    let swipeReasonDuration: String
    let swipeReasonReportCount: String

    // ClipboardQRCode errors
    let qrTextTooLong: String
    let qrGenerationFailed: String

    static var current: StringsAPI { StringsAPI(language: AppLanguageStore.shared.language) }

    static let zh = StringsAPI(
        pairHostRequired: "缺少 host（应为 unmatchedHosts 中的 UUID）",
        noFrameFromDevice: { "尚未收到来自 \($0) 的画面：请先解锁" },
        pointerNotReady: "指针未就绪：请等待蓝牙鼠标订阅与有效校准",
        textRequired: "缺少 text",
        keyRequired: "缺少 key",
        swipePointsMin: "points 必须包含至少两个带数值 x、y 的对象",
        swipePointFinite: { "points[\($0)].x 与 points[\($0)].y 必须是有限数值" },
        swipeDurationInvalid: "duration 必须是大于零的有限数值",
        swipeSizeKeyInvalid: { "\($0) 必须是大于零的有限数值" },
        swipeMaxEdgeRange: "maxEdge 必须大于等于 1 且小于 \(Int.max)",
        swipeInvalidDimensions: "滑动坐标需要有效且非零的画面尺寸",
        coordinatesRequired: { "缺少 \($0) 与 \($1)" },
        noFrameFromScreen: { "尚未收到来自 \($0) 的画面" },
        noPhoneMatches: { "没有匹配 \"\($0)\" 的手机。\($1)" },
        noScreen: "未发现 iPhone 画面：请用 USB 连接 iPhone 并解锁",
        multiplePhones: { "已连接 \($0) 台手机，请传入 device。\($1)" },
        noBluetoothConnection: { name, peripheral in
            "\(name) 没有蓝牙连接：请开启辅助触控，然后在「设置 > 辅助功能 > 触控 > 辅助触控 > 设备 > 蓝牙设备」中配对 \"\(peripheral)\""
        },
        ambiguousBluetooth: { "无法确定哪条蓝牙连接对应 \($0)：请解锁手机、确认辅助触控已开启，然后 POST /match" },
        screenIdentityUnverified: { "\($0) 的蓝牙已连接，画面身份尚未确认：请等待画面校验完成后重试" },
        describeEmpty: "当前没有连接手机。",
        describePrefix: "手机：",
        untypeable: { "美式键盘无法输入字符 \($0)" },
        unknownKey: { "未知按键 \($0)" },
        pointerBusy: "鼠标拖动进行中：请先松开窗口中的鼠标再执行坐标手势",
        calibrationMismatch: "指针校准缺失、无效或与当前屏幕不匹配；请先重新校准再进行坐标控制",
        invalidSwipePrefix: { "无效的滑动：\($0)" },
        pairingProbeUnavailable: "蓝牙指针探测不可用",
        swipeReasonPoints: "points 必须包含至少两个 0...1 内的有限坐标",
        swipeReasonDuration: "duration 必须是有限的正数",
        swipeReasonReportCount: "duration 与上报间隔产生了无效的上报次数",
        qrTextTooLong: "文字超过单个二维码容量（约 2.8 KB），请分段发送",
        qrGenerationFailed: "无法生成文字二维码，请重试")

    static let en = StringsAPI(
        pairHostRequired: "host is required (a UUID from unmatchedHosts)",
        noFrameFromDevice: { "no frame yet from \($0): unlock it" },
        pointerNotReady: "pointer is not ready: wait for Bluetooth mouse subscription and a valid calibration",
        textRequired: "text is required",
        keyRequired: "key is required",
        swipePointsMin: "points must contain at least two objects with numeric x and y",
        swipePointFinite: { "points[\($0)].x and points[\($0)].y must be finite numbers" },
        swipeDurationInvalid: "duration must be a finite number greater than zero",
        swipeSizeKeyInvalid: { "\($0) must be a finite number greater than zero" },
        swipeMaxEdgeRange: "maxEdge must be at least 1 and smaller than \(Int.max)",
        swipeInvalidDimensions: "swipe coordinates require valid, nonzero image dimensions",
        coordinatesRequired: { "\($0) and \($1) are required" },
        noFrameFromScreen: { "no frame yet from \($0)" },
        noPhoneMatches: { "no phone matches \"\($0)\". \($1)" },
        noScreen: "no iPhone screen: plug the iPhone in over USB and unlock it",
        multiplePhones: { "\($0) phones are connected, pass device. \($1)" },
        noBluetoothConnection: { name, peripheral in
            "\(name) has no Bluetooth connection: enable AssistiveTouch, then pair \"\(peripheral)\" in Settings > Accessibility > Touch > AssistiveTouch > Devices > Bluetooth Devices"
        },
        ambiguousBluetooth: {
            "could not tell which Bluetooth connection is \($0): unlock it, check AssistiveTouch is on, then POST /match"
        },
        screenIdentityUnverified: {
            "Bluetooth is connected for \($0), but its screen identity is unconfirmed; retry after verification"
        },
        describeEmpty: "No phones are plugged in.",
        describePrefix: "Phones: ",
        untypeable: { "cannot type \($0) with a US keyboard" },
        unknownKey: { "unknown key \($0)" },
        pointerBusy: "mouse drag in progress: release the window mouse before a coordinate gesture",
        calibrationMismatch:
            "pointer calibration is missing, invalid, or does not match the current screen; recalibrate before coordinate control",
        invalidSwipePrefix: { "invalid swipe: \($0)" },
        pairingProbeUnavailable: "Bluetooth pointer probe is unavailable",
        swipeReasonPoints: "points must contain at least two finite coordinates in 0...1",
        swipeReasonDuration: "duration must be a finite positive number",
        swipeReasonReportCount: "duration and report interval produce an invalid report count",
        qrTextTooLong: "Text exceeds a single QR code's capacity (about 2.8 KB); send it in chunks",
        qrGenerationFailed: "Could not generate a text QR code; try again")
}
