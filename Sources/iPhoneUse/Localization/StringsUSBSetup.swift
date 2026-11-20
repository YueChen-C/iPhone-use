import Foundation

struct StringsUSBSetup: LocalizedTable {
    let enable: String
    let consent: String
    let cancel: String
    let progress: (USBSetupPresentation) -> String

    static var current: Self { Self(language: AppLanguageStore.shared.language) }
    static let zh = Self(enable: "开启 USB 操控…",
        consent: "点击后会下载约 18 MB 的开发者镜像（DDI）至应用缓存，并自动安装；如已挂载不同镜像，会自动卸载并切换。请保持联网和 USB 连接，预留约 60 MB 空间。不会升级 iOS 或抹除数据。",
        cancel: "取消", progress: { state in
            switch state {
            case .inspecting: "正在检查设备；不会更改手机…"
            case let .downloading(received, total):
                "正在下载开发者镜像：" + amount(received, total)
            case .retrying: "下载未完成，正在尝试其他连接…"
            case .verifying: "正在校验并准备镜像；请稍候…"
            case .checkingImage: "正在检查已挂载的开发者镜像…"
            case .uninstalling: "正在卸载旧开发者镜像，请保持 USB 连接…"
            case .installing: "正在安装开发者镜像，请保持 USB 连接…"
            case .verifyingInstallation: "正在核验设备上的开发者镜像…"
            case .connecting: "正在验证 USB 操控…"
            case .complete: "USB 操控已就绪。"
            case .installFailed: "镜像安装或切换未能确认完成，旧镜像可能已卸载。请保持 USB 连接，检查信任和开发者模式后重试。"
            case .connectionFailed: "镜像已就绪，但 USB 操控未能连接。请重新准备 USB。"
            case .cancelled: "已取消准备，手机镜像未更改。"
            case .failed: "镜像准备失败，手机镜像未更改。请检查连接、存储空间、信任和开发者模式后重试。"
            }
        })
    static let en = Self(enable: "Enable USB control…",
        consent: "Downloads about 18 MB of developer image (DDI) to the app cache and installs it automatically, replacing a different mounted image. Keep USB and internet connected, with about 60 MB free. This does not upgrade iOS or erase data.",
        cancel: "Cancel", progress: { state in
            switch state {
            case .inspecting: "Inspecting this device; no phone changes…"
            case let .downloading(received, total): "Downloading developer image: " + amount(received, total)
            case .retrying: "Download incomplete; trying another connection…"
            case .verifying: "Verifying and preparing the image; please wait…"
            case .checkingImage: "Checking the mounted developer image…"
            case .uninstalling: "Uninstalling the old developer image. Keep USB connected…"
            case .installing: "Installing developer image. Keep USB connected…"
            case .verifyingInstallation: "Verifying the mounted developer image…"
            case .connecting: "Verifying USB control…"
            case .complete: "USB control is ready."
            case .installFailed: "Image setup could not be confirmed. The old image may have been unmounted. Keep USB connected, check trust and Developer Mode, then retry."
            case .connectionFailed: "The image is ready, but USB control could not connect. Try preparing USB again."
            case .cancelled: "Preparation cancelled; phone image unchanged."
            case .failed: "Image preparation failed; phone image unchanged. Check connectivity, free space, trust and Developer Mode before retrying."
            }
        })

    private static func amount(_ received: Int64, _ total: Int64) -> String {
        let done = Double(max(0, received)) / 1_000_000
        guard total > 0 else { return String(format: "%.1f MB", done) }
        return String(format: "%.1f / %.1f MB (%d%%)", done, Double(total) / 1_000_000,
                      Int(min(100, max(0, Double(received) / Double(total) * 100))))
    }
}
