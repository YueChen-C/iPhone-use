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
    var automaticPresentationEnabled = true
    var hasCompanionWindow: () -> Bool = { false }
    var onDeviceWindowClosed: (() -> Void)?
    var hasOpenWindows: Bool { !controllers.isEmpty || waitingController != nil }
    var openDeviceIDs: Set<String> { Set(controllers.keys) }

    func showDevice(_ device: Device) {
        _ = state.update(connectedIDs: [device.id], reason: .userRequest)
        if controllers[device.id] == nil {
            let controller = ControlWindowController(deviceID: device.id, name: device.screen.name)
            controller.onClose = { [weak self] in self?.windowClosed(deviceID: device.id) }
            controllers[device.id] = controller
        }
        controllers[device.id]?.window?.deminiaturize(nil)
        controllers[device.id]?.window?.makeKeyAndOrderFront(nil)
        QuietModeActivityController.shared.setOpenWindows(true)
    }

    func closeDevice(id: String) {
        controllers[id]?.window?.close()
    }

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
            guard !QuietModeActivityController.shared.isSuspended else { return }
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
        QuietModeActivityController.shared.setOpenWindows(true)
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
        guard automaticPresentationEnabled else { return }
        if mode == .desktop {
            refresh(reason: hadOpenWindow ? .discovery : .resumeDesktopMode)
        }
    }

    private func refresh(reason: ControlWindowUpdateReason) {
        let devices = DeviceRegistry.shared.all().sorted {
            $0.screen.name == $1.screen.name ? $0.id < $1.id : $0.screen.name < $1.screen.name
        }
        let connected = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        if !automaticPresentationEnabled, reason == .discovery {
            for (id, controller) in controllers { controller.updateDevice(connected[id]) }
            return
        }
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

        QuietModeActivityController.shared.setOpenWindows(hasOpenWindows || hasCompanionWindow())

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
        QuietModeActivityController.shared.setOpenWindows(hasOpenWindows || hasCompanionWindow())
        if state.close(deviceID: deviceID), !hasCompanionWindow() { NSApplication.shared.terminate(nil) }
        if deviceID != nil { onDeviceWindowClosed?() }
    }
}

final class ControlWindowController: NSWindowController, NSWindowDelegate {
    let deviceID: String?
    let controlView: PhoneControlView
    private let sidebar: ControlSidebar
    private let content: ControlWindowContent
    private var lastKnownDevice: Device?
    private var languageObserver: NSObjectProtocol?
    private var setupDownload: DDIDownload?
    private var setupGeneration = UUID()
    private var installingDDI = false
    private var awaitingUSBReadiness = false
    private var lastUSBPresentation: ControlUSBPresentation?
    private var setupConnectionRequest: USBBackendSelectionRequest?
    var onPresentationChanged: (() -> Void)?
    private(set) var availableShortcuts: Set<ControlShortcut> = []
    private(set) var inputStatus = StringsWorkbench.current.waitingInput
    var embeddedView: NSView { content }
    /// Embedded workbench guidance is hosted by the selected device's Inspector,
    /// never inside its captured screen. The controller still owns all actions.
    var connectionGuidanceView: ControlConnectionOverlay { content.connectionOverlay }
    var onClose: (() -> Void)?
    var onDeminiaturize: (() -> Void)?

    init(deviceID: String?, name: String? = nil, embedded: Bool = false) {
        self.deviceID = deviceID
        controlView = PhoneControlView(deviceID: deviceID, frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        sidebar = ControlSidebar(frame: .zero)
        let content = ControlWindowContent(phoneView: controlView, sidebar: sidebar, embedded: embedded)
        self.content = content
        let window: NSWindow? = embedded ? nil : NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window?.title = deviceID.map { "\(name ?? "iPhone") — \($0)" } ?? StringsUI.current.waitingWindowTitle
        window?.tabbingMode = .disallowed
        window?.isReleasedWhenClosed = false
        if !embedded { window?.contentView = content }
        window?.acceptsMouseMovedEvents = true
        window?.contentMinSize = NSSize(width: 240 + ControlSidebar.width, height: 460)
        window?.center()
        super.init(window: window)
        content.connectionOverlay.onRetryBluetoothMatch = { [weak self] completion in
            guard let device = self?.lastKnownDevice else {
                completion(.failure(BluetoothMatchRetryError.unavailable))
                return
            }
            DeviceRegistry.shared.retryBluetoothAssociation(device, completion: completion)
        }
        window?.delegate = self
        window?.initialFirstResponder = controlView
        window?.makeFirstResponder(controlView)
        sidebar.onAction = { [weak controlView] shortcut in
            controlView?.performShortcut(shortcut)
        }
        sidebar.onBackendChange = { [weak self] backend in
            self?.content.showBackendSelectionFailure(nil)
            self?.cancelUSBSetup(); self?.controlView.selectBackend(backend)
            // Keep showing the actual route while the native check is pending.
            if let self { self.sidebar.updateBackend(self.controlView.selectedBackend) }
        }
        controlView.onBackendSelectionFailed = { [weak self] message in
            guard let self else { return }
            self.sidebar.updateBackend(self.controlView.selectedBackend)
            self.content.showBackendSelectionFailure(message)
        }
        content.onEnableUSB = { [weak self] in self?.beginUSBSetup() }
        content.onCancelUSBSetup = { [weak self] in
            guard let self, self.setupDownload != nil else { return }
            self.cancelUSBSetup()
            self.content.updateUSBSetup(.cancelled)
        }
        content.connectionOverlay.onRetryUSB = { [weak self] finished in
            guard let self, self.lastKnownDevice != nil, self.controlView.selectedBackend == .usb else {
                finished(); return
            }
            self.content.showBackendSelectionFailure(nil)
            self.cancelUSBSetup()
            self.controlView.selectBackend(.usb, completion: finished)
        }
        controlView.onShortcutStateChanged = { [weak self] available, status in
            guard let self else { return }
            self.availableShortcuts = available
            self.inputStatus = status
            self.sidebar.update(available: available, status: status)
            self.onPresentationChanged?()
        }
        controlView.onConnectionStateChanged = { [weak content] status in
            content?.updateConnectionState(status)
        }
        controlView.onUSBPresentationChanged = { [weak self] presentation in
            guard let self else { return }
            self.lastUSBPresentation = presentation
            self.content.updateUSBPresentation(presentation)
            if presentation?.hasScreen != true || (self.setupDownload != nil && presentation?.offersUSBSetup != true) {
                self.cancelUSBSetup()
            } else {
                self.finishUSBPreparationIfKnown()
            }
        }
        controlView.onLockStateChanged = { [weak content] state in
            content?.updateLockState(state)
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: AppLanguageStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshLocalization()
        }
        if !embedded { controlView.start() }
    }

    func selectInputBackend(_ backend: InputBackendKind) {
        content.showBackendSelectionFailure(nil)
        cancelUSBSetup()
        controlView.selectBackend(backend)
    }

    func updateDevice(_ device: Device?) {
        if lastKnownDevice?.screen !== device?.screen {
            cancelUSBSetup(); content.showBackendSelectionFailure(nil)
        }
        lastKnownDevice = device.flatMap { $0.id == deviceID ? $0 : nil }
        applyWindowStrings()
        sidebar.updateBackend(controlView.selectedBackend)
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

    func stop() {
        cancelUSBSetup(); controlView.stop()
        availableShortcuts = []
        inputStatus = StringsWorkbench.current.waitingInput
    }

    private func cancelUSBSetup() {
        setupGeneration = UUID()
        setupDownload?.cancel(); setupDownload = nil
        awaitingUSBReadiness = false
        setupConnectionRequest?.cancel(); setupConnectionRequest = nil
        content.updateUSBSetup(nil)
    }

    private func beginUSBSetup() {
        guard setupDownload == nil, !installingDDI, !awaitingUSBReadiness,
              let device = lastKnownDevice, device.id == deviceID, controlView.selectedBackend == .usb,
              lastUSBPresentation?.offersUSBSetup == true,
              ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen),
              let executable = Bundle.main.executableURL else { return }
        let generation = UUID(); setupGeneration = generation
        let download = DDIDownload(); setupDownload = download
        content.updateUSBSetup(.inspecting)
        let update: (USBSetupPresentation) -> Void = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.setupGeneration == generation, self.setupDownload === download else { return }
                self.content.updateUSBSetup(state)
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = Result { () throws -> DDIFirstMount.Target in
                let inspected = try DDIReviewClient(executable: executable).run(.inspect(device.id))
                let target = try JSONDecoder().decode(DDIFirstMount.Target.self, from: Data(inspected.json.utf8))
                try USBBackendCompatibility.validate(version: target.productVersion)
                _ = try download.prepareCached(productType: target.productType, progress: update)
                return target
            }
            DispatchQueue.main.async {
                guard let self, self.setupGeneration == generation else { return }
                self.setupDownload = nil
                guard self.isCurrentUSBSetup(device) else { self.cancelUSBSetup(); return }
                switch outcome {
                case .success(let target): self.installDDI(target, executable: executable, device: device, generation: generation)
                case .failure(let error):
                    log("DDI preparation failed: \(error)")
                    self.content.updateUSBSetup(error is CancellationError ? .cancelled : .failed)
                }
            }
        }
    }

    private func isCurrentUSBSetup(_ device: Device) -> Bool {
        lastKnownDevice?.screen === device.screen && controlView.selectedBackend == .usb
            && ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen)
    }

    private func installDDI(_ target: DDIFirstMount.Target, executable: URL, device: Device, generation: UUID) {
        installingDDI = true
        content.updateUSBSetup(.checkingImage)
        let update: (DDIFirstMount.Stage) -> Void = { [weak self] stage in
            DispatchQueue.main.async {
                guard let self, self.setupGeneration == generation, self.installingDDI else { return }
                switch stage {
                case .uninstalling: self.content.updateUSBSetup(.uninstalling)
                case .installing: self.content.updateUSBSetup(.installing)
                case .verifyingInstallation: self.content.updateUSBSetup(.verifyingInstallation)
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = Result { try DDIFirstMount.install(executable: executable, target: target, progress: update) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installingDDI = false
                guard self.setupGeneration == generation else { return }
                guard self.isCurrentUSBSetup(device) else { self.cancelUSBSetup(); return }
                switch outcome {
                case .success:
                    self.content.updateUSBSetup(.connecting)
                    let request = USBBackendSelectionRequest()
                    self.setupConnectionRequest = request
                    self.controlView.selectBackend(.usb, request: request) { [weak self] in
                        guard let self, self.setupGeneration == generation, !request.isCancelled else { return }
                        self.setupConnectionRequest = nil
                        self.awaitingUSBReadiness = true
                        self.finishUSBPreparationIfKnown()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in
                        guard let self, self.setupGeneration == generation else { return }
                        self.setupGeneration = UUID()
                        self.awaitingUSBReadiness = false
                        self.setupConnectionRequest?.cancel(); self.setupConnectionRequest = nil
                        // A terminal result invalidates this timer immediately.
                        self.content.updateUSBSetup(.connectionFailed)
                    }
                case .failure(let error):
                    log("DDI installation failed: \(error)")
                    self.content.updateUSBSetup(.installFailed)
                }
            }
        }
    }

    private func finishUSBPreparationIfKnown() {
        guard awaitingUSBReadiness, let presentation = lastUSBPresentation,
              [.ready, .failed, .disconnected, .unsupportedHost, .unsupportedDevice,
               .requiresTrust, .requiresDeveloperMode].contains(presentation.state) else { return }
        awaitingUSBReadiness = false
        let finished = UUID(); setupGeneration = finished
        let ready = presentation.state == .ready
        content.updateUSBSetup(ready ? .complete : .connectionFailed)
        if ready {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.setupGeneration == finished else { return }
                self.content.updateUSBSetup(nil)
            }
        }
    }

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

/// Legacy windows overlay connection guidance. Embedded workbench content keeps
/// guidance external; PhoneControlView's readiness/error gates still guard input.
private final class ControlWindowContent: NSView {
    private let phoneView: PhoneControlView
    private var automaticallyFocus = true
    let connectionOverlay: ControlConnectionOverlay
    private let lockNotice = ControlLockNotice(frame: .zero)
    var onEnableUSB: (() -> Void)? {
        get { connectionOverlay.onEnableUSB }
        set { connectionOverlay.onEnableUSB = newValue }
    }
    var onCancelUSBSetup: (() -> Void)? {
        get { connectionOverlay.onCancelUSBSetup }
        set { connectionOverlay.onCancelUSBSetup = newValue }
    }
    func updateUSBSetup(_ state: USBSetupPresentation?) { connectionOverlay.updateSetup(state) }

    func showBackendSelectionFailure(_ message: String?) {
        phoneView.isBackendNoticeVisible = message != nil
        connectionOverlay.showBackendSelectionFailure(message)
        if automaticallyFocus { window?.makeFirstResponder(connectionOverlay.isHidden ? phoneView : connectionOverlay) }
    }

    init(phoneView: PhoneControlView, sidebar: ControlSidebar, embedded: Bool = false) {
        self.phoneView = phoneView
        self.automaticallyFocus = !embedded
        connectionOverlay = ControlConnectionOverlay(frame: .zero, presentation: embedded ? .inspector : .screenOverlay)
        sidebar.isHidden = embedded
        super.init(frame: NSRect(x: 0, y: 0, width: 390 + ControlSidebar.width, height: 700))
        connectionOverlay.onNoticeDismissed = { [weak self] in
            guard let self else { return }
            self.phoneView.isBackendNoticeVisible = false
            if self.automaticallyFocus { self.window?.makeFirstResponder(self.connectionOverlay.isHidden ? self.phoneView : self.connectionOverlay) }
        }
        phoneView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phoneView)
        if !embedded { addSubview(sidebar) }
        lockNotice.translatesAutoresizingMaskIntoConstraints = false
        connectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        // Last sibling receives hit testing first while the overlay is visible.
        if !embedded {
            addSubview(connectionOverlay)
        }
        // The advisory remains visible over pairing guidance, and passes events
        // through to the existing overlay or phone without changing either gate.
        addSubview(lockNotice)
        NSLayoutConstraint.activate([
            phoneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            phoneView.topAnchor.constraint(equalTo: topAnchor),
            phoneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            phoneView.trailingAnchor.constraint(equalTo: embedded ? trailingAnchor : sidebar.leadingAnchor),
            lockNotice.centerXAnchor.constraint(equalTo: phoneView.centerXAnchor),
            lockNotice.bottomAnchor.constraint(equalTo: phoneView.bottomAnchor, constant: -24),
            lockNotice.widthAnchor.constraint(equalTo: phoneView.widthAnchor, constant: -24),
        ])
        if !embedded {
            NSLayoutConstraint.activate([
                connectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                // Keep backend selection reachable even while BLE is disconnected.
                connectionOverlay.trailingAnchor.constraint(equalTo: phoneView.trailingAnchor),
                connectionOverlay.topAnchor.constraint(equalTo: topAnchor),
                connectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                sidebar.widthAnchor.constraint(equalToConstant: ControlSidebar.width),
                sidebar.topAnchor.constraint(equalTo: topAnchor),
                sidebar.trailingAnchor.constraint(equalTo: trailingAnchor),
                sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    func updateConnectionState(_ status: ControlConnectionStatus) {
        if status == .waitingForDevice { phoneView.isBackendNoticeVisible = false }
        connectionOverlay.update(status)
        if automaticallyFocus { window?.makeFirstResponder(connectionOverlay.isHidden ? phoneView : connectionOverlay) }
    }

    func updateUSBPresentation(_ presentation: ControlUSBPresentation?) {
        connectionOverlay.updateUSB(presentation)
        if automaticallyFocus { window?.makeFirstResponder(connectionOverlay.isHidden ? phoneView : connectionOverlay) }
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
