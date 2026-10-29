import AppKit

/// Tracks window identity independently of capture/Bluetooth sessions. A missing
/// phone keeps its window; a manually closed one stays closed until requested or
/// plugged in again. Device names are deliberately never used as identity.
struct ControlWindowState {
    private(set) var deviceIDs: Set<String> = []
    private var dismissedDeviceIDs: Set<String> = []

    var needsWaitingWindow: Bool { deviceIDs.isEmpty }

    mutating func update(connectedIDs: [String], reopenClosed: Bool = false) -> [String] {
        dismissedDeviceIDs.formIntersection(connectedIDs)
        if reopenClosed { dismissedDeviceIDs.removeAll() }
        var added: [String] = []
        for id in connectedIDs where !dismissedDeviceIDs.contains(id) {
            if deviceIDs.insert(id).inserted { added.append(id) }
        }
        return added
    }

    /// Returns whether the last window was closed and the application should exit.
    mutating func close(deviceID: String?) -> Bool {
        if let deviceID {
            deviceIDs.remove(deviceID)
            dismissedDeviceIDs.insert(deviceID)
        }
        return deviceIDs.isEmpty
    }
}

/// Owns one controller per USB device on the main thread. Discovery is sampled
/// separately from the 30 Hz render timers and never takes over the registry's
/// capture-change callback, which is also needed for Bluetooth matching.
final class ControlWindowCoordinator {
    private var state = ControlWindowState()
    private var controllers: [String: ControlWindowController] = [:]
    private var waitingController: ControlWindowController?
    private var timer: Timer?
    private var cascadePoint: NSPoint?

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        waitingController?.stop()
        for controller in controllers.values { controller.stop() }
    }

    func showAllDevices() {
        refresh(reopenClosed: true)
        let windows = controllers.sorted { $0.key < $1.key }.compactMap { $0.value.window }
        for window in windows {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFront(nil)
        }
        (windows.first ?? waitingController?.window)?.makeKeyAndOrderFront(nil)
    }

    private func refresh(reopenClosed: Bool = false) {
        let devices = DeviceRegistry.shared.all().sorted {
            $0.screen.name == $1.screen.name ? $0.id < $1.id : $0.screen.name < $1.screen.name
        }
        let connected = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let shouldActivate = controllers.isEmpty
        let added = state.update(connectedIDs: devices.map(\.id), reopenClosed: reopenClosed)
        for id in added {
            guard let device = connected[id] else { continue }
            let controller = ControlWindowController(deviceID: id, name: device.screen.name)
            controller.onClose = { [weak self] in self?.windowClosed(deviceID: id) }
            controllers[id] = controller
            present(controller)
        }
        for (id, controller) in controllers {
            controller.updateDevice(connected[id])
        }

        if state.needsWaitingWindow {
            if waitingController == nil {
                let controller = ControlWindowController(deviceID: nil)
                controller.onClose = { [weak self] in self?.windowClosed(deviceID: nil) }
                waitingController = controller
                controller.showWindow(nil)
            }
        } else if let waitingController {
            // Replacing the startup placeholder is not a user closing the last
            // window. Disconnects later keep the original device windows intact.
            waitingController.onClose = nil
            waitingController.close()
            self.waitingController = nil
        }
        if shouldActivate, let id = added.first {
            controllers[id]?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func present(_ controller: ControlWindowController) {
        guard let window = controller.window else { return }
        if let cascadePoint {
            self.cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        } else {
            cascadePoint = NSPoint(x: window.frame.minX + 24, y: window.frame.maxY - 24)
        }
        // A newly connected phone must not steal focus during another phone's drag.
        window.orderFront(nil)
    }

    private func windowClosed(deviceID: String?) {
        if let deviceID {
            controllers.removeValue(forKey: deviceID)
        } else {
            waitingController = nil
        }
        if state.close(deviceID: deviceID) { NSApplication.shared.terminate(nil) }
    }
}

final class ControlWindowController: NSWindowController, NSWindowDelegate {
    let deviceID: String?
    private let controlView: PhoneControlView
    private let sidebar: ControlSidebar
    private let content: ControlWindowContent
    private var lastKnownDevice: Device?
    private var languageObserver: NSObjectProtocol?
    var onClose: (() -> Void)?

    init(deviceID: String?, name: String? = nil) {
        self.deviceID = deviceID
        controlView = PhoneControlView(deviceID: deviceID, frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        sidebar = ControlSidebar(frame: .zero)
        let content = ControlWindowContent(phoneView: controlView, sidebar: sidebar)
        self.content = content
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = deviceID.map { "\(name ?? "iPhone") — \($0)" } ?? StringsUI.current.waitingWindowTitle
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.acceptsMouseMovedEvents = true
        window.contentMinSize = NSSize(width: 240 + ControlSidebar.width, height: 460)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.initialFirstResponder = controlView
        window.makeFirstResponder(controlView)
        sidebar.onAction = { [weak controlView] shortcut in
            controlView?.performShortcut(shortcut)
        }
        controlView.onShortcutStateChanged = { [weak sidebar] available, status in
            sidebar?.update(available: available, status: status)
        }
        controlView.onConnectionStateChanged = { [weak content] status in
            content?.updateConnectionState(status)
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: AppLanguageStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshLocalization()
        }
        controlView.start()
    }

    func updateDevice(_ device: Device?) {
        lastKnownDevice = device.flatMap { $0.id == deviceID ? $0 : nil }
        applyWindowStrings()
    }

    /// The coordinator's timer re-runs updateDevice for device windows, but never
    /// for the waiting window, so both paths share this and the language observer.
    private func applyWindowStrings() {
        if let device = lastKnownDevice {
            window?.title = "\(device.screen.name) — \(device.id)"
            window?.subtitle = ""
        } else if deviceID != nil {
            // A bound window keeps its last device title so it stays clear which
            // phone is being waited for; only the subtitle explains the disconnect.
            window?.subtitle = StringsUI.current.usbDisconnectedSubtitle
        } else {
            window?.title = StringsUI.current.waitingWindowTitle
            window?.subtitle = ""
        }
    }

    private func refreshLocalization() {
        applyWindowStrings()
        sidebar.refreshLocalization()
        content.refreshLocalization()
    }

    func stop() { controlView.stop() }

    func windowDidResignKey(_ notification: Notification) {
        controlView.cancelInteraction()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controlView.cancelInteraction()
    }

    func windowWillClose(_ notification: Notification) {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        languageObserver = nil
        stop()
        onClose?()
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Keeps the phone geometry separate from the sidebar and places the connection
/// overlay above both so disconnected input cannot reach either control surface.
private final class ControlWindowContent: NSView {
    private let phoneView: NSView
    private let connectionOverlay = ControlConnectionOverlay(frame: .zero)

    init(phoneView: NSView, sidebar: ControlSidebar) {
        self.phoneView = phoneView
        super.init(frame: NSRect(x: 0, y: 0, width: 390 + ControlSidebar.width, height: 700))
        phoneView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phoneView)
        addSubview(sidebar)
        connectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        // Last sibling receives hit testing first while the overlay is visible.
        addSubview(connectionOverlay)
        NSLayoutConstraint.activate([
            phoneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            phoneView.topAnchor.constraint(equalTo: topAnchor),
            phoneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            phoneView.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: ControlSidebar.width),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            connectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            connectionOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            connectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            connectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func updateConnectionState(_ status: ControlConnectionStatus) {
        connectionOverlay.update(status)
        window?.makeFirstResponder(status.showsOverlay ? connectionOverlay : phoneView)
    }

    func refreshLocalization() {
        connectionOverlay.refreshLocalization()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
