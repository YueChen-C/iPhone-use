import Foundation

struct StringsUSBSetup: LocalizedTable {
    let enable: String
    let consent: String
    let cancel: String
    let review: String
    let progress: (USBSetupPresentation) -> String

    static var current: Self { Self(language: AppLanguageStore.shared.language) }
    static let zh = Self(enable: "开启 USB 操控…",
        consent: "点击后将下载约 18 MB 的开发者镜像（DDI）至应用缓存，请保持联网和 USB 连接，并预留约 60 MB 空间。USB 操控需要安装（挂载）兼容镜像，安装可能替换当前镜像；下载完成后继续安装设置。不会升级 iOS 或抹除数据。",
        cancel: "取消", review: "继续安装设置…", progress: { state in
            switch state {
            case .inspecting: "正在检查设备；不会更改手机…"
            case let .downloading(received, total):
                "正在下载开发者镜像：" + amount(received, total)
            case .retrying: "下载未完成，正在尝试其他连接…"
            case .verifying: "正在校验并准备镜像；请稍候…"
            case .prepared: "镜像已下载并校验，尚未安装。继续核对候选、基线和恢复计划；停止全部输入并单独确认安装后，再重新选择 USB Touch。"
            case .cancelled: "已取消准备，手机镜像未更改。"
            case .failed: "镜像准备失败，手机镜像未更改。请检查连接、存储空间、信任和开发者模式后重试；也可使用已有的本地 DDI 计划与审阅。"
            }
        })
    static let en = Self(enable: "Enable USB control…",
        consent: "Click to download about 18 MB of Developer Disk Image (DDI) to the app cache. Keep the internet and USB connected, with about 60 MB free space. USB control needs a compatible image installed (mounted), which may replace the current image; continue installation setup after downloading. This does not upgrade iOS or erase data.",
        cancel: "Cancel", review: "Continue installation setup…", progress: { state in
            switch state {
            case .inspecting: "Inspecting this device; no phone changes…"
            case let .downloading(received, total): "Downloading developer image: " + amount(received, total)
            case .retrying: "Download incomplete; trying another connection…"
            case .verifying: "Verifying and preparing the image; please wait…"
            case .prepared: "Image downloaded and verified, not installed. Review the candidate, baseline and recovery plan, stop all input and separately confirm installation. Then reselect USB Touch."
            case .cancelled: "Preparation cancelled; phone image unchanged."
            case .failed: "Image preparation failed; phone image unchanged. Check connectivity, free space, trust and Developer Mode before retrying, or use an existing local DDI in Plan & Review."
            }
        })

    private static func amount(_ received: Int64, _ total: Int64) -> String {
        let done = Double(max(0, received)) / 1_000_000
        guard total > 0 else { return String(format: "%.1f MB", done) }
        return String(format: "%.1f / %.1f MB (%d%%)", done, Double(total) / 1_000_000,
                      Int(min(100, max(0, Double(received) / Double(total) * 100))))
    }
}
