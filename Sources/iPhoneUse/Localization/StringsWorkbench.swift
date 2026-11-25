import Foundation

struct StringsWorkbench: LocalizedTable {
    let title: String
    let subtitle: String
    let devices: String
    let search: String
    let connect: String
    let grid: String
    let focus: String
    let current: String
    let onlyCurrent: String
    let noDevice: String
    let waitingNativeCapture: String
    let guide: String
    let inputBackend: String
    let experimental: String
    let screenshot: String
    let screenshotIdentityUnverified: String
    let screenshotNotReady: String
    let record: String
    let recordingStop: String
    let recordingSaving: String
    let recordingSaved: String
    let recordingFailed: String
    let recordingIdentityUnverified: String
    let recordingNoFrames: String
    let recordingDestinationBusy: String
    let recordingEncodingFailed: String
    let independent: String
    let expand: String
    let closeIndependent: String
    let removeDeviceCard: String
    let textInput: String
    let send: String
    let pasteHint: String
    let ai: String
    let api: String
    let mcpHint: String
    let local: String
    let disconnected: String
    let waitingInput: String
    let usbPicture: String
    let noMatches: String
    let textSent: String
    let textCancelled: String
    let actionFailed: String
    let preview: String
    let backendHelp: String

    static var current: Self { Self(language: AppLanguageStore.shared.language) }
    static let zh = Self(
        title: "设备工作台", subtitle: "真实 iPhone，各自独立，也能一览全局。", devices: "已发现设备", search: "搜索设备名称或 ID…", connect: "连接设备",
        grid: "平铺", focus: "聚焦", current: "当前控制设备", onlyCurrent: "操作仅作用于此设备", noDevice: "连接你的第一台 iPhone",
        waitingNativeCapture: "iPhone 已通过 USB 连接，正在等待画面",
        guide: "USB 连接并信任此 Mac，允许相机权限用于投屏。iOS 17.3 及以上默认 USB 触控；旧系统默认蓝牙，需完成配对与辅助触控设置。", inputBackend: "输入后端", experimental: "USB Touch · 实验性",
        screenshot: "截图", screenshotIdentityUnverified: "画面与设备身份尚未确认，未保存截图；请先重新匹配原设备。",
        screenshotNotReady: "画面尚未就绪，未保存截图。",
        record: "录制", recordingStop: "结束录制", recordingSaving: "正在保存…", recordingSaved: "录制已保存", recordingFailed: "录制失败",
        recordingIdentityUnverified: "画面与设备身份尚未确认，暂时无法录制。", recordingNoFrames: "未收到可录制的视频帧。",
        recordingDestinationBusy: "另一段录制正在使用此保存位置。", recordingEncodingFailed: "无法完成视频编码。",
        independent: "独立窗口", expand: "扩大",
        closeIndependent: "关闭小窗口", removeDeviceCard: "移除设备卡片",
        textInput: "文本输入", send: "发送文本", pasteHint: "手机端粘贴发送 Cmd-V，不读取 Mac 剪贴板。",
        ai: "AI 接入", api: "脚本与 API", mcpHint: "通过外部 MCP 客户端使用截图、点击、滑动与输入工具。", local: "HTTP 仅监听本机回环地址",
        disconnected: "USB 已断开 · 等待原设备", waitingInput: "输入尚未就绪", usbPicture: "USB 画面", noMatches: "没有匹配的设备",
        textSent: "文本已发送", textCancelled: "本次输入已取消，草稿已保留；部分内容可能已输入，请先核对手机。",
        actionFailed: "操作失败；未自动重试", preview: "离线界面预览 · 不连接设备",
        backendHelp: "USB Touch 需 iOS 17+、兼容的 Apple Silicon 主机、开发者模式与 DDI；失败不会自动回退。")
    static let en = Self(
        title: "Device Workbench", subtitle: "Real iPhones. Independent control. One workspace.",
        devices: "Discovered devices", search: "Search devices or IDs…", connect: "Connect device", grid: "Grid",
        focus: "Focus", current: "Current device", onlyCurrent: "Actions target this device only",
        noDevice: "Connect your first iPhone",
        waitingNativeCapture: "iPhone connected over USB. Waiting for its display.",
        guide:
            "Connect via USB, trust this Mac and allow camera access for capture. iOS 17.3+ defaults to USB Touch; older systems default to Bluetooth, which needs pairing and AssistiveTouch.",
        inputBackend: "Input backend", experimental: "USB Touch · Experimental", screenshot: "Screenshot",
        screenshotIdentityUnverified: "Display identity is unverified. Screenshot not saved; rematch the original device first.",
        screenshotNotReady: "Display not ready. Screenshot not saved.",
        record: "Record", recordingStop: "Stop recording", recordingSaving: "Saving…",
        recordingSaved: "Recording saved", recordingFailed: "Recording failed",
        recordingIdentityUnverified: "Display identity is unverified. Match the device before recording.",
        recordingNoFrames: "No video frames were received.",
        recordingDestinationBusy: "Another recording is using this destination.",
        recordingEncodingFailed: "The video could not be encoded.",
        independent: "Separate window", expand: "Expand", closeIndependent: "Close separate window",
        removeDeviceCard: "Remove device card", textInput: "Text input", send: "Send text",
        pasteHint: "Phone paste sends Cmd-V; it does not read the Mac clipboard.", ai: "AI connection",
        api: "Scripts & API", mcpHint: "Use screenshots, taps, swipes and text through an external MCP client.",
        local: "HTTP listens on loopback only", disconnected: "USB disconnected · Waiting for original device",
        waitingInput: "Input not ready", usbPicture: "USB display", noMatches: "No matching devices",
        textSent: "Text sent", textCancelled: "Input cancelled; draft kept. Some text may already be entered; check the phone first.",
        actionFailed: "Action failed; not automatically retried",
        preview: "Offline UI preview · No device connection",
        backendHelp:
            "USB Touch requires iOS 17+, a compatible Apple Silicon host, developer mode and DDI. Failures never fall back automatically."
    )
}
