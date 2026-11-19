import AppKit

/// Explicit local CLI rendering. This entry runs before DDI/BLE/capture/HTTP startup.
enum WorkbenchPreview {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 1 else { return 64 }
        let output = URL(fileURLWithPath: arguments[0])
        let language: AppLanguage = arguments.contains("--en") ? .en : .zh
        // A process-local override must not persist a UI-preview language choice.
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var previewArguments = previousArguments
        previewArguments[AppLanguageStore.defaultsKey] = language.rawValue
        defaults.setVolatileDomain(previewArguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let root = WorkbenchRootView(
            frame: NSRect(
                x: 0, y: 0, width: arguments.contains("--narrow") ? 1080 : 1680,
                height: arguments.contains("--narrow") ? 700 : 980), preview: true)
        let initialFixture =
            arguments.contains("--empty")
            ? []
            : [
                WorkbenchDevice(
                    id: "preview-phone-a", name: "chenpeijie 的 iPhone", connected: true,
                    backend: .ble, status: language == .zh ? "蓝牙输入已就绪 · 示例" : "Bluetooth ready · Sample",
                    shortcuts: Set(ControlShortcut.allCases), detail: "iPhone 15 Pro · iOS 18.2"),
                WorkbenchDevice(
                    id: "preview-phone-b", name: "iPhone 16 Pro", connected: true,
                    backend: .usb,
                    status: language == .zh ? "USB Touch · 实验性 · 示例" : "USB Touch · Experimental · Sample",
                    shortcuts: Set(ControlShortcut.allCases), detail: "iOS 18.2 · USB"),
                WorkbenchDevice(
                    id: "preview-phone-c", name: "iPhone 15", connected: true,
                    backend: .ble, status: StringsWorkbench.current.waitingInput, detail: "iOS 17.7 · USB"),
            ]
        var fixture = initialFixture
        if let index = arguments.firstIndex(of: "--devices"), arguments.indices.contains(index + 1),
            let count = Int(arguments[index + 1]), (1...30).contains(count), !fixture.isEmpty {
            let samples = fixture
            fixture = (0..<count).map { i in
                let device = samples[i % samples.count]
                return WorkbenchDevice(
                    id: String(format: "preview-phone-%02d", i + 1), name: "iPhone \(i + 1)", connected: true,
                    backend: device.backend, status: device.status, shortcuts: device.shortcuts,
                    detail: device.detail)
            }
        }
        var images: [String: NSImage] = [:]
        if let index = arguments.firstIndex(of: "--assets"), arguments.indices.contains(index + 1) {
            let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            for (i, device) in fixture.enumerated() {
                images[device.id] = NSImage(contentsOf: folder.appendingPathComponent("phone-\(i % 3 + 1).png"))
            }
        }
        let rawScreens = arguments.contains("--raw-screens")
        if rawScreens {
            for i in fixture.indices { fixture[i].screenSize = images[fixture[i].id]?.size }
            if let index = arguments.firstIndex(of: "--product-types"), arguments.indices.contains(index + 1) {
                let types = arguments[index + 1].split(separator: ";").map(String.init)
                for i in fixture.indices where types.indices.contains(i) { fixture[i].productType = types[i] }
            }
        }
        root.loadPreview(
            fixture, images: images, rawScreens: rawScreens,
            connectionStatuses: arguments.contains("--connection-guidance")
                ? Dictionary(uniqueKeysWithValues: fixture.map { ($0.id, ControlConnectionStatus.unmatched) }) : [:])
        if arguments.contains("--focus"), let id = fixture.first?.id {
            root.select(id)
            root.setLayout(.focus)
        }
        if let index = arguments.firstIndex(of: "--page"), arguments.indices.contains(index + 1),
            let page = Int(arguments[index + 1]), page > 1 {
            for _ in 1..<min(page, 31) { root.changePage(1) }
        }
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root
        if let index = arguments.firstIndex(of: "--dialog"), arguments.indices.contains(index + 1),
           let kind = WorkbenchInfoKind(rawValue: arguments[index + 1]) {
            root.showInfo(kind)
        }
        window.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
        root.layoutSubtreeIfNeeded()
        for view in root.subviews { view.layoutSubtreeIfNeeded() }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        root.layoutSubtreeIfNeeded()
        func prepare(_ view: NSView) {
            view.needsDisplay = true
            view.layoutSubtreeIfNeeded()
            for child in view.subviews { prepare(child) }
            view.displayIfNeeded()
        }
        prepare(root)
        window.displayIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return 70 }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return 70 }
        do {
            try data.write(to: output, options: .atomic)
            print("NATIVE_PREVIEW=\(output.path)")
            print("SIZE=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            print("DEVICE_SERVICES_STARTED=false")
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 73
        }
    }
}
