import AppKit
import Foundation

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Retain all device controllers for as long as their windows remain open.
    private let windows = ControlWindowCoordinator()
    private var quitItem: NSMenuItem?
    private var windowMenu: NSMenu?
    private var windowItem: NSMenuItem?
    private var showAllItem: NSMenuItem?
    private var minimizeItem: NSMenuItem?
    private var bringToFrontItem: NSMenuItem?
    private var languageItems: [NSMenuItem] = []
    private var languageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        windows.start()
        NSApp.activate(ignoringOtherApps: true)
        // Retitle items in place when the language changes. Swapping NSApp.mainMenu
        // or reassigning windowsMenu would dismiss the open menu and duplicate
        // AppKit-managed items; in-place title/state changes repaint live.
        languageObserver = NotificationCenter.default.addObserver(
            forName: AppLanguageStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshMenuTitles()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showAllDevices()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.stop()
        let stopResult = ScreenCaptureManager.shared.stop(waitTimeout: 1.5)
        if !stopResult.isClean {
            log(
                "capture shutdown incomplete: captureDrained=\(stopResult.captureDrained), usbRestored=\(stopResult.usbRestored)"
            )
        }
        HIDPeripheral.shared.stop()
    }

    @objc private func showAllDevices(_ sender: Any?) { windows.showAllDevices() }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard AppLanguage.allCases.indices.contains(sender.tag) else { return }
        AppLanguageStore.shared.set(AppLanguage.allCases[sender.tag])
    }

    private func installMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "iPhone Use")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)

        // The picker's own titles stay constant so it is readable in both modes.
        let languageMenu = NSMenu(title: "语言 / Language")
        let languageItem = NSMenuItem()
        languageItem.submenu = languageMenu
        appMenu.addItem(languageItem)
        for (index, language) in AppLanguage.allCases.enumerated() {
            let item = NSMenuItem(
                title: language.displayName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = language == AppLanguageStore.shared.language ? .on : .off
            languageMenu.addItem(item)
            languageItems.append(item)
        }
        appMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: StringsUI.current.quitApp, action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        quitItem = quit

        let windowMenu = NSMenu(title: StringsUI.current.windowMenu)
        let windowItem = NSMenuItem(title: StringsUI.current.windowMenu, action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        self.windowMenu = windowMenu
        self.windowItem = windowItem
        let showAll = NSMenuItem(
            title: StringsUI.current.showAllDevices, action: #selector(showAllDevices(_:)), keyEquivalent: "")
        showAll.target = self
        windowMenu.addItem(showAll)
        showAllItem = showAll
        windowMenu.addItem(.separator())
        let minimize = NSMenuItem(
            title: StringsUI.current.minimize, action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(minimize)
        minimizeItem = minimize
        let bringToFront = NSMenuItem(
            title: StringsUI.current.bringAllToFront,
            action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        bringToFront.target = NSApp
        windowMenu.addItem(bringToFront)
        bringToFrontItem = bringToFront
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    private func refreshMenuTitles() {
        let table = StringsUI.current
        quitItem?.title = table.quitApp
        windowMenu?.title = table.windowMenu
        windowItem?.title = table.windowMenu
        showAllItem?.title = table.showAllDevices
        minimizeItem?.title = table.minimize
        bringToFrontItem?.title = table.bringAllToFront
        let current = AppLanguageStore.shared.language
        for (index, item) in languageItems.enumerated() {
            item.state = AppLanguage.allCases[index] == current ? .on : .off
        }
    }
}

/// Owns the startup sequence shared by SwiftPM and the packaged application.
/// MCP mode bypasses this path entirely and never starts AppKit or hardware.
enum Application {
    static func run() {
        let port = UInt16(ProcessInfo.processInfo.environment["IPHONE_USE_PORT"] ?? "") ?? 7390

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // A packaged app uses its bundle icon; SwiftPM runs use the copied resource.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            app.applicationIconImage = icon
        }
        let appDelegate = AppDelegate()
        app.delegate = appDelegate

        DeviceRegistry.shared.start()
        HIDPeripheral.shared.start()
        ScreenCaptureManager.shared.start()
        let server = HTTPServer(port: port, handler: ControlAPI.handle)
        do {
            try server.start()
            log("listening on http://127.0.0.1:\(port)")
        } catch {
            log("http failed: \(error)")
            exit(1)
        }

        // NSApplication's delegate is weak. Retain both process-owned services until
        // the run loop exits, even when this entry point is optimized in release builds.
        let signalSources = installTerminationSignals(server: server)
        withExtendedLifetime((appDelegate, server, signalSources)) {
            app.run()
        }
    }

    private static func installTerminationSignals(server: HTTPServer) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                server.stop()
                let stopResult = ScreenCaptureManager.shared.stop(waitTimeout: 1.5)
                if !stopResult.isClean {
                    log(
                        "capture shutdown incomplete: captureDrained=\(stopResult.captureDrained), usbRestored=\(stopResult.usbRestored)"
                    )
                }
                HIDPeripheral.shared.stop()
                exit(0)
            }
            source.resume()
            return source
        }
    }
}
