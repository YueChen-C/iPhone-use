import Foundation

/// AppKit control-window strings: menus, window titles, sidebar, connection
/// overlay, and the canvas waiting message.
struct StringsUI: LocalizedTable {
    // Main menu (Application.swift)
    let quitApp: String
    let windowMenu: String
    let showAllDevices: String
    let minimize: String
    let bringAllToFront: String

    // Window titles (ControlWindow.swift)
    let waitingWindowTitle: String
    let usbDisconnectedSubtitle: String

    // Sidebar groups and status (ControlSidebar.swift)
    let groupNavigation: String
    let groupInput: String
    let groupVolume: String
    let statusInitial: String

    // Shortcut buttons (ControlShortcut in ControlSidebar.swift)
    let shortcutHome: String
    let shortcutSearch: String
    let shortcutPaste: String
    let shortcutEnter: String
    let shortcutVolumeUp: String
    let shortcutVolumeDown: String
    let helpHome: String
    let helpSearch: String
    let helpPaste: String
    let helpEnter: String
    let helpVolumeUp: String
    let helpVolumeDown: String

    // Sidebar status line (PhoneControlView.swift)
    let statusWaitingDevice: String
    let statusWaitingBluetooth: String
    let statusVerifyingScreen: String
    let statusConnected: String
    let statusPointerNotReady: String
    let statusCalibrationRequired: String
    let statusAutomaticallyCalibrating: String
    let sendingShortcut: (String) -> String
    let sentShortcut: (String) -> String
    let shortcutDisconnected: String
    let shortcutNotReady: String
    let shortcutFailed: String

    // Connection overlay (ControlConnectionOverlay.swift)
    let overlayAccessibility: String
    let overlayWaitingTitle: String
    let overlayWaitingMessage: String
    let overlayNotConnectedTitle: String
    let overlayDisconnectedTitle: String
    let overlayBluetoothMessage: String
    let overlayConnectingTitle: String
    let overlayConnectingMessage: String
    let overlayUnmatchedTitle: String
    let overlayUnmatchedMessage: String
    /// Full pairing card. Arguments: advertised Bluetooth name, and the Mac's
    /// controller name when iOS may show it instead of the advertised name.
    let pairingInstructions: (String, String?) -> String
    let overlayHelp: String

    // Canvas waiting message (PhoneControlView.swift)
    let canvasWaitingText: String

    static var current: StringsUI { StringsUI(language: AppLanguageStore.shared.language) }

    static let zh = StringsUI(
        quitApp: "退出 iPhone Use",
        windowMenu: "窗口",
        showAllDevices: "显示所有设备",
        minimize: "最小化",
        bringAllToFront: "全部置于前台",
        waitingWindowTitle: "iPhone Use — 等待 iPhone",
        usbDisconnectedSubtitle: "USB 已断开，等待原设备重新连接",
        groupNavigation: "导航",
        groupInput: "输入",
        groupVolume: "音量",
        statusInitial: "等待连接",
        shortcutHome: "Home",
        shortcutSearch: "搜索",
        shortcutPaste: "粘贴",
        shortcutEnter: "回车",
        shortcutVolumeUp: "音量 +",
        shortcutVolumeDown: "音量 −",
        helpHome: "返回 iPhone 主屏幕",
        helpSearch: "打开 iPhone 搜索（⌘ Space）",
        helpPaste: "在手机上粘贴（⌘ V）；粘贴 Mac 内容需启用通用剪贴板",
        helpEnter: "发送回车键",
        helpVolumeUp: "提高 iPhone 音量",
        helpVolumeDown: "降低 iPhone 音量",
        statusWaitingDevice: "等待 iPhone 连接",
        statusWaitingBluetooth: "等待蓝牙连接",
        statusVerifyingScreen: "蓝牙已连接，画面身份待确认",
        statusConnected: "已连接",
        statusPointerNotReady: "指针尚未就绪",
        statusCalibrationRequired: "蓝牙已连接，需要指针校准",
        statusAutomaticallyCalibrating: "正在自动适配指针，请保持手机画面静止",
        sendingShortcut: { "正在发送\($0)…" },
        sentShortcut: { "已发送\($0)" },
        shortcutDisconnected: "连接已断开，请重试",
        shortcutNotReady: "连接未就绪，请重试",
        shortcutFailed: "操作失败，请重试",
        overlayAccessibility: "连接提示",
        overlayWaitingTitle: "等待 iPhone 画面",
        overlayWaitingMessage: "当前无法操作。请通过 USB 连接并解锁一台 iPhone，确认信任此 Mac。",
        overlayNotConnectedTitle: "蓝牙未连接",
        overlayDisconnectedTitle: "蓝牙已断开",
        overlayBluetoothMessage: "当前无法操作 iPhone，请先连接蓝牙。",
        overlayConnectingTitle: "蓝牙连接尚未就绪",
        overlayConnectingMessage: "当前无法操作 iPhone，正在等待连接完成。",
        overlayUnmatchedTitle: "蓝牙连接尚未匹配",
        overlayUnmatchedMessage: "已检测到候选蓝牙连接，尚未确认与这台 iPhone 的画面对应。请保持手机解锁并开启辅助触控。",
        pairingInstructions: { advertisedName, controllerName in
            let deviceNames =
                if let controllerName, !controllerName.isEmpty, controllerName != advertisedName {
                    "选择「\(advertisedName)」；也可能显示为本机名称「\(controllerName)」。"
                } else {
                    "选择「\(advertisedName)」；也可能显示为这台 Mac 的蓝牙名称。"
                }
            return """
                1. 在 Mac 和 iPhone 上开启蓝牙。

                2. 在 iPhone 打开「设置 → 辅助功能 → 触控 → 辅助触控」，开启辅助触控。

                3. 进入「设备 → 蓝牙设备」，\(deviceNames)

                4. 在两端按提示确认配对；已配对时在此页面点按重新连接。蒙层消失后即可操作。
                """
        },
        overlayHelp:
            "连接失败时，可打开 Mac「系统设置 → 蓝牙」检查状态及配对提示，再从 iPhone 重试。若找不到设备，请检查 Mac「隐私与安全性 → 蓝牙」中 iPhone Use 的权限。",
        canvasWaitingText: "等待 iPhone 画面…\n请解锁手机并确认已配对 Bluetooth")

    static let en = StringsUI(
        quitApp: "Quit iPhone Use",
        windowMenu: "Window",
        showAllDevices: "Show All Devices",
        minimize: "Minimize",
        bringAllToFront: "Bring All to Front",
        waitingWindowTitle: "iPhone Use — Waiting for iPhone",
        usbDisconnectedSubtitle: "USB disconnected, waiting for the original device to reconnect",
        groupNavigation: "Navigation",
        groupInput: "Input",
        groupVolume: "Volume",
        statusInitial: "Waiting to connect",
        shortcutHome: "Home",
        shortcutSearch: "Search",
        shortcutPaste: "Paste",
        shortcutEnter: "Return",
        shortcutVolumeUp: "Vol +",
        shortcutVolumeDown: "Vol −",
        helpHome: "Go to the iPhone Home Screen",
        helpSearch: "Open iPhone Search (⌘ Space)",
        helpPaste: "Paste on the phone (⌘ V); pasting Mac content requires Universal Clipboard",
        helpEnter: "Send the Return key",
        helpVolumeUp: "Turn the iPhone volume up",
        helpVolumeDown: "Turn the iPhone volume down",
        statusWaitingDevice: "Waiting for iPhone",
        statusWaitingBluetooth: "Waiting for Bluetooth",
        statusVerifyingScreen: "Bluetooth connected; verifying screen identity",
        statusConnected: "Connected",
        statusPointerNotReady: "Pointer not ready yet",
        statusCalibrationRequired: "Bluetooth connected; pointer calibration required",
        statusAutomaticallyCalibrating: "Adapting pointer automatically; keep the phone screen still",
        sendingShortcut: { "Sending \($0)…" },
        sentShortcut: { "Sent \($0)" },
        shortcutDisconnected: "Connection lost, please retry",
        shortcutNotReady: "Connection not ready, please retry",
        shortcutFailed: "Action failed, please retry",
        overlayAccessibility: "Connection guide",
        overlayWaitingTitle: "Waiting for iPhone Screen",
        overlayWaitingMessage:
            "Control is unavailable. Connect an iPhone over USB, unlock it, and tap Trust on the Mac prompt.",
        overlayNotConnectedTitle: "Bluetooth not connected",
        overlayDisconnectedTitle: "Bluetooth disconnected",
        overlayBluetoothMessage: "The iPhone cannot be controlled yet; connect Bluetooth first.",
        overlayConnectingTitle: "Bluetooth connection not ready",
        overlayConnectingMessage:
            "The iPhone cannot be controlled yet; waiting for the connection to finish.",
        overlayUnmatchedTitle: "Bluetooth connection not matched",
        overlayUnmatchedMessage:
            "A candidate Bluetooth connection has not been matched to this iPhone's screen. Keep it unlocked with AssistiveTouch enabled.",
        pairingInstructions: { advertisedName, controllerName in
            let deviceNames =
                if let controllerName, !controllerName.isEmpty, controllerName != advertisedName {
                    "choose \"\(advertisedName)\"; it may also appear as this Mac's name \"\(controllerName)\"."
                } else {
                    "choose \"\(advertisedName)\"; it may also appear as this Mac's Bluetooth name."
                }
            return """
                1. Turn Bluetooth on, on both the Mac and the iPhone.

                2. On the iPhone open Settings → Accessibility → Touch → AssistiveTouch and turn AssistiveTouch on.

                3. Under Devices → Bluetooth Devices, \(deviceNames)

                4. Confirm pairing on both sides when prompted; if already paired, tap reconnect on this screen. The overlay disappears once connected.
                """
        },
        overlayHelp:
            "If pairing fails, open the Mac's System Settings → Bluetooth to check its state and pairing prompts, then retry from the iPhone. If the device is missing, check iPhone Use's Bluetooth permission in System Settings → Privacy & Security.",
        canvasWaitingText: "Waiting for iPhone screen…\nUnlock the phone and confirm Bluetooth is paired")
}
