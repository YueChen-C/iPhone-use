import AppKit

enum ControlWindowUpdateReason {
    case discovery
    case userRequest
    case resumeDesktopMode
}

/// Tracks window identity independently of capture/Bluetooth sessions. A missing
/// phone keeps its window; a manually closed one stays closed until requested or
/// plugged in again (in `desktop` mode). Device names are deliberately never used as identity.
struct ControlWindowState {
    private(set) var mode: AppRunMode
    private(set) var deviceIDs: Set<String> = []
    private var dismissedDeviceIDs: Set<String> = []
    private var waitingWindowPresented = false

    init(mode: AppRunMode = .desktop) {
        self.mode = mode
    }

    var needsWaitingWindow: Bool {
        switch mode {
        case .desktop:
            return deviceIDs.isEmpty
        case .residentQuiet:
            return deviceIDs.isEmpty && waitingWindowPresented
        }
    }

    mutating func setMode(_ newMode: AppRunMode) {
        mode = newMode
    }

    mutating func update(connectedIDs: [String], reopenClosed: Bool = false) -> [String] {
        update(
            connectedIDs: connectedIDs,
            reason: reopenClosed ? .userRequest : .discovery)
    }

    mutating func update(
        connectedIDs: [String],
        reason: ControlWindowUpdateReason,
        canReplaceWaitingWindow: Bool = true
    ) -> [String] {
        dismissedDeviceIDs.formIntersection(connectedIDs)
        switch mode {
        case .desktop:
            if reason == .userRequest || reason == .resumeDesktopMode {
                dismissedDeviceIDs.removeAll()
            }
            let added = insertConnected(connectedIDs, respectingDismissed: true)
            waitingWindowPresented = deviceIDs.isEmpty
            return added

        case .residentQuiet:
            switch reason {
            case .userRequest:
                dismissedDeviceIDs.removeAll()
                let added = insertConnected(connectedIDs, respectingDismissed: false)
                waitingWindowPresented = deviceIDs.isEmpty
                return added
            case .discovery, .resumeDesktopMode:
                guard waitingWindowPresented, canReplaceWaitingWindow, !connectedIDs.isEmpty else {
                    return []
                }
                dismissedDeviceIDs.removeAll()
                let added = insertConnected(connectedIDs, respectingDismissed: false)
                waitingWindowPresented = deviceIDs.isEmpty
                return added
            }
        }
    }

    /// Returns whether the last window was closed and the application should exit.
    mutating func close(deviceID: String?) -> Bool {
        if let deviceID {
            deviceIDs.remove(deviceID)
            dismissedDeviceIDs.insert(deviceID)
        } else {
            waitingWindowPresented = false
        }
        return mode == .desktop && deviceIDs.isEmpty
    }

    private mutating func insertConnected(_ connectedIDs: [String], respectingDismissed: Bool) -> [String] {
        var added: [String] = []
        for id in connectedIDs where !respectingDismissed || !dismissedDeviceIDs.contains(id) {
            if deviceIDs.insert(id).inserted { added.append(id) }
        }
        return added
    }
}

/// Owns one controller per USB device on the main thread. Discovery is sampled
/// separately from the 30 Hz render timers and never takes over the registry's
/// capture-change callback, which is also needed for Bluetooth matching.
final class ControlWindowCoordinator {
    private let modeStore: AppRunModeStore
    private var state: ControlWindowState
    private var controllers: [String: ControlWindowController] = [:]
    private var waitingController: ControlWindowController?
    private var timer: Timer?
    private var modeObserver: NSObjectProtocol?
    private var cascadePoint: NSPoint?

    init(modeStore: AppRunModeStore = .shared) {
        self.modeStore = modeStore
        self.state = ControlWindowState(mode: modeStore.mode)
    }

    func start() {
        guard timer == nil else { return }
        state.setMode(modeStore.mode)
        modeObserver = NotificationCenter.default.addObserver(
            forName: AppRunModeStore.didChangeNotification, object: modeStore, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyMode(self.modeStore.mode)
        }
        refresh(reason: .discovery)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh(reason: .discovery)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
        modeObserver = nil
        timer?.invalidate()
        timer = nil
        waitingController?.stop()
        for controller in controllers.values { controller.stop() }
    }

    deinit {
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
        timer?.invalidate()
    }

    func showAllDevices() {
        refresh(reason: .userRequest)
        let windows = controllers.sorted { $0.key < $1.key }.compactMap { $0.value.window }
        for window in windows {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFront(nil)
        }
        if let waitingWindow = waitingController?.window, waitingWindow.isMiniaturized {
            waitingWindow.deminiaturize(nil)
        }
        (windows.first ?? waitingController?.window)?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyMode(_ mode: AppRunMode) {
        guard mode != state.mode else { return }
        let hadOpenWindow = !controllers.isEmpty || waitingController != nil
        state.setMode(mode)
        if mode == .desktop {
            refresh(reason: hadOpenWindow ? .discovery : .resumeDesktopMode)
        }
    }

    private func refresh(reason: ControlWindowUpdateReason) {
        let devices = DeviceRegistry.shared.all().sorted {
            $0.screen.name == $1.screen.name ? $0.id < $1.id : $0.screen.name < $1.screen.name
        }
        let connected = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let hadDeviceWindows = !controllers.isEmpty
        let existingWaitingWindow = waitingController?.window
        let waitingWindowWasKey = existingWaitingWindow?.isKeyWindow == true
        let canReplaceWaiting = existingWaitingWindow.map { !$0.isMiniaturized } ?? true

        let added = state.update(
            connectedIDs: devices.map(\.id),
            reason: reason,
            canReplaceWaitingWindow: canReplaceWaiting)
        for id in added {
            guard let device = connected[id] else { continue }
            let controller = ControlWindowController(deviceID: id, name: device.screen.name)
            controller.onClose = { [weak self] in self?.windowClosed(deviceID: id) }
            controllers[id] = controller
            present(
                controller,
                reason: reason,
                relativeToBackgroundWindow: (state.mode == .residentQuiet && reason == .discovery
                    && !waitingWindowWasKey)
                    ? existingWaitingWindow : nil,
                waitingWindowWasKey: waitingWindowWasKey)
        }
        for (id, controller) in controllers {
            controller.updateDevice(connected[id])
        }

        if state.needsWaitingWindow {
            if waitingController == nil {
                let controller = ControlWindowController(deviceID: nil)
                controller.onClose = { [weak self] in self?.windowClosed(deviceID: nil) }
                controller.onDeminiaturize = { [weak self] in
                    guard let self, self.state.mode == .residentQuiet else { return }
                    self.refresh(reason: .discovery)
                }
                waitingController = controller
                if state.mode == .desktop || reason != .discovery {
                    controller.showWindow(nil)
                }
            }
        } else if let waitingController {
            // Replacing the startup placeholder is not a user closing the last
            // window. Disconnects later keep the original device windows intact.
            waitingController.onClose = nil
            waitingController.onDeminiaturize = nil
            waitingController.close()
            self.waitingController = nil
        }

        let shouldMakeFirstAddedKey: Bool
        switch reason {
        case .userRequest:
            shouldMakeFirstAddedKey = false
        case .resumeDesktopMode:
            shouldMakeFirstAddedKey = !hadDeviceWindows
        case .discovery:
            shouldMakeFirstAddedKey = state.mode == .desktop ? !hadDeviceWindows : waitingWindowWasKey
        }
        if shouldMakeFirstAddedKey, let id = added.first {
            controllers[id]?.window?.makeKeyAndOrderFront(nil)
        } else if reason == .resumeDesktopMode, added.isEmpty, !hadDeviceWindows {
            waitingController?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func present(
        _ controller: ControlWindowController,
        reason: ControlWindowUpdateReason,
        relativeToBackgroundWindow backgroundWindow: NSWindow?,
        waitingWindowWasKey: Bool
    ) {
        guard let window = controller.window else { return }
        if let cascadePoint {
            self.cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        } else {
            cascadePoint = NSPoint(x: window.frame.minX + 24, y: window.frame.maxY - 24)
        }
        if let backgroundWindow {
            // Keep background placeholder replacement at its existing z-order so
            // USB connection in quiet mode never jumps above the active app.
            window.order(.above, relativeTo: backgroundWindow.windowNumber)
        } else if state.mode == .desktop || reason != .discovery || waitingWindowWasKey {
            // A newly connected phone must not steal focus during another phone's drag.
            window.orderFront(nil)
        }
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
    var onDeminiaturize: (() -> Void)?

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
        controlView.onLockStateChanged = { [weak content] state in
            content?.updateLockState(state)
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
            let lockState = device.lockState
            window?.subtitle = lockState.showsNotice ? lockState.title : ""
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

    func windowDidDeminiaturize(_ notification: Notification) {
        onDeminiaturize?()
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
    private let lockNotice = ControlLockNotice(frame: .zero)

    init(phoneView: NSView, sidebar: ControlSidebar) {
        self.phoneView = phoneView
        super.init(frame: NSRect(x: 0, y: 0, width: 390 + ControlSidebar.width, height: 700))
        phoneView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phoneView)
        addSubview(sidebar)
        lockNotice.translatesAutoresizingMaskIntoConstraints = false
        connectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        // Last sibling receives hit testing first while the overlay is visible.
        addSubview(connectionOverlay)
        // The advisory remains visible over pairing guidance, and passes events
        // through to the existing overlay or phone without changing either gate.
        addSubview(lockNotice)
        NSLayoutConstraint.activate([
            phoneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            phoneView.topAnchor.constraint(equalTo: topAnchor),
            phoneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            phoneView.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: ControlSidebar.width),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            lockNotice.centerXAnchor.constraint(equalTo: phoneView.centerXAnchor),
            lockNotice.bottomAnchor.constraint(equalTo: phoneView.bottomAnchor, constant: -24),
            lockNotice.widthAnchor.constraint(equalTo: phoneView.widthAnchor, constant: -24),
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
        lockNotice.refreshLocalization()
    }

    func updateLockState(_ state: DeviceLockState) {
        lockNotice.update(state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
