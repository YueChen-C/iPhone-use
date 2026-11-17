import Foundation

struct StringsUSBControl: LocalizedTable {
    let title: String
    let status: (ControlUSBPresentation) -> String
    let guidance: (ControlUSBPresentation.Recovery) -> String
    let viewOnly: String
    let pill: String
    let showGuidance: String
    let shortcutAcknowledged: (String) -> String
    let shortcutFailed: String
    let requiresiOS17: (String) -> String
    let versionUnavailable: String
    let acknowledge: String

    static var current: Self { Self(language: AppLanguageStore.shared.language) }
    static let zh = Self(title: "USB 原生控制（实验性）", status: { value in
        status(value, language: .zh)
    }, guidance: { recovery in
        switch recovery {
        case .wait: "正在准备或释放旧会话；请等待。不会自动重放输入。"
        case .connect: "连接并解锁这台原设备，确认画面身份；就绪前无法输入。"
        case .identity: "确认这台原设备的画面与身份；不要根据名称或列表顺序选择其他手机。确认后重新选择 USB Touch。"
        case .display: "将这台 iPhone 解锁、亮屏并保持竖屏。确认画面后重新选择 USB Touch；不会重放之前的输入。"
        case .services: "检查开发者服务和当前 DDI 的 HID 能力。此错误不能确定是信任、开发者模式还是 DDI 原因；不会自动更换镜像。"
        case .host: "当前主机框架或私有 ABI 未受支持。请核对兼容性记录，不要替换系统框架来绕过检查。"
        case .device: "此设备尚不受支持。核对兼容性记录；不会切换到其他手机。"
        case .trust: "在这台 iPhone 上核对并明确确认信任此 Mac，再重新选择 USB Touch。不会自动配对。"
        case .developerMode: "核对这台 iPhone 的开发者模式要求，处理后重新选择 USB Touch。应用不会自动更改系统设置。"
        case .ddi: "使用本地 DDI 计划与审阅核对镜像、来源和恢复记录。挂载需单独授权；输入准备不会更换镜像。"
        case .select: "先检查当前画面，再重新选择 USB Touch。释放未确认时仍会阻止输入；不会重放。也可明确选择 Bluetooth，需其独立就绪。"
        }
    }, viewOnly: "仅查看画面", pill: "USB 控制未就绪 · 仅查看画面", showGuidance: "显示指引",
       shortcutAcknowledged: { "USB 已确认发送\($0)；请检查画面" },
       shortcutFailed: "USB 快捷键未确认完成；请检查画面，勿重放",
       requiresiOS17: { "USB 操控需要 iOS 17 或更高版本。当前设备为 iOS \($0)，请使用蓝牙操控。" },
       versionUnavailable: "无法确认这台 iPhone 的系统版本，未切换到 USB。请确认设备已解锁并信任此 Mac 后重试。",
       acknowledge: "知道了")

    static let en = Self(title: "Native USB Control (Experimental)", status: { value in
        status(value, language: .en)
    }, guidance: { recovery in
        switch recovery {
        case .wait: "Preparing or releasing the previous session. Please wait; input is never replayed automatically."
        case .connect: "Connect and unlock this original device and verify its screen identity. Input remains unavailable until ready."
        case .identity: "Verify this original device's screen and identity, not its name or list order. Then explicitly reselect USB Touch."
        case .display: "Unlock this iPhone, keep its screen on and in portrait. Inspect the screen before reselecting USB Touch; earlier input is not replayed."
        case .services: "Check developer services and the current DDI's HID capability. This error does not identify trust, Developer Mode or DDI as the cause. No image is changed automatically."
        case .host: "The host framework or private ABI is unsupported. Check the compatibility record; do not replace system frameworks to bypass this gate."
        case .device: "This device is not supported. Check the compatibility record; no other phone will be selected."
        case .trust: "Review and explicitly confirm Trust This Mac on this iPhone, then reselect USB Touch. Pairing is not automatic."
        case .developerMode: "Review this iPhone's Developer Mode requirements, then reselect USB Touch. The app does not change system settings automatically."
        case .ddi: "Use local DDI Plan & Review to inspect the image, source and recovery record. Mounting needs separate authorization; input preparation does not change images."
        case .select: "Inspect the screen, then explicitly reselect USB Touch. Unconfirmed release still blocks input; no replay. You may explicitly select Bluetooth, which must be independently ready."
        }
    }, viewOnly: "View screen only", pill: "USB control unavailable · View only", showGuidance: "Show guidance",
       shortcutAcknowledged: { "USB acknowledged \($0); inspect screen" },
       shortcutFailed: "USB shortcut not confirmed; inspect screen, do not replay",
       requiresiOS17: { "USB control requires iOS 17 or later. This device runs iOS \($0); use Bluetooth control instead." },
       versionUnavailable: "Could not verify this iPhone's iOS version; USB was not selected. Unlock the device, confirm trust in this Mac, then retry.",
       acknowledge: "Got it")
    private static func status(_ value: ControlUSBPresentation, language: AppLanguage) -> String {
        func text(_ zh: String, _ en: String) -> String { "USB · " + (language == .zh ? zh : en) }
        if !value.hasScreen { return text("等待原设备", "Waiting for original device") }
        if value.reason == .displayUnavailable { return text("画面条件不符", "Display unavailable") }
        if value.reason == .touchscreenUnavailable { return text("触屏能力不可用", "Touch surface unavailable") }
        if value.reason == .serviceUnavailable { return text("服务不可用", "Service unavailable") }
        if value.reason == .timedOut { return text("准备超时", "Preparation timed out") }
        if value.reason == .workerProtocol { return text("无效的服务响应", "Invalid service reply") }
        return switch value.state {
        case .ready:
            if value.buttonsReady {
                value.keyboardReady ? text("鼠标、键盘与按键已就绪", "Mouse, keyboard and buttons ready")
                    : text("鼠标与按键已就绪", "Mouse and buttons ready")
            } else {
                value.keyboardReady ? text("鼠标与键盘已就绪", "Mouse and keyboard ready") : text("仅鼠标已就绪", "Mouse only ready")
            }
        case .preparing: text("正在准备", "Preparing")
        case .identityUnverified: text("设备身份待确认", "Device identity unverified")
        case .unsupportedHost: text("主机版本不支持", "Unsupported host")
        case .unsupportedDevice: text("设备不支持", "Unsupported device")
        case .requiresTrust: text("需要信任 Mac", "Trust required")
        case .requiresDeveloperMode: text("需要开发者模式", "Developer Mode required")
        case .requiresDDI: text("需要开发者镜像", "Developer image required")
        case .disconnected: text("会话已断开", "Session disconnected")
        case .disabled: text("未启用", "Disabled")
        case .failed: text("准备失败", "Preparation failed")
        }
    }

}
