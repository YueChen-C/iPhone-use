import AppKit
import CoreVideo
import VideoToolbox

/// A lightweight scrcpy-style window. The screen is drawn directly from the latest
/// CVPixelBuffer and mouse events are sent to the phone's HID input queue.
final class PhoneControlView: NSView {
    var onInteraction: (() -> Void)?
    var isKeyboardTarget = true
    var isPointerTarget = true
    private(set) var isRendering = false
    var acceptsLocalKeyEquivalents: Bool { isKeyboardTarget && window?.firstResponder === self }
    private var binding: ControlDeviceBinding
    private let bluetoothDemandToken = UUID()
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var device: Device?
    private var input: DeviceInput?
    private var usbInput: USBDeviceInput?
    private var usbSelected: Bool { binding.deviceID.map { USBInputController.shared.selected($0) == .usb } ?? false }
    var selectedBackend: InputBackendKind {
        binding.deviceID.map { USBInputController.shared.selected($0) } ?? .ble
    }
    private var backendRequest: USBBackendSelectionRequest?
    var onBackendSelectionFailed: ((String) -> Void)?
    var isBackendNoticeVisible = false {
        didSet { if isBackendNoticeVisible { cancelInteraction() } }
    }
    func selectBackend(_ backend: InputBackendKind, completion: (() -> Void)? = nil) {
        cancelInteraction()
        activeShortcut = nil
        shortcutFeedback = nil
        guard let device else { return }
        backendRequest?.cancel()
        let request = USBBackendSelectionRequest(); backendRequest = request
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try USBInputController.shared.select(backend, device: device, request: request) }
            DispatchQueue.main.async { [weak self] in
                defer { completion?() }
                guard let self, self.backendRequest === request, !request.isCancelled, self.binding.isRunning,
                      self.device?.screen === device.screen else { return }
                switch outcome {
                case .success: self.input = nil; self.usbInput = nil
                case .failure(let error): self.onBackendSelectionFailed?(String(describing: error))
                }
                self.refreshDevice()
            }
        }
    }
    private var dragging = false
    private var mousePosition = ControlMousePosition()
    private var pointerReady = false
    private let inputQueue = DispatchQueue(label: "iphone-use.window-input-resolution")
    private let shortcutQueue = DispatchQueue(label: "iphone-use.window-shortcuts")
    private var activeShortcut: ControlShortcut?
    private var textDispatch: ControlTextDispatch?
    private var shortcutFeedback: (text: String, expires: Date)?
    private var lastShortcutState: (available: Set<ControlShortcut>, status: String)?
    private var lastUSBPresentation: ControlUSBPresentation?
    var onUSBPresentationChanged: ((ControlUSBPresentation?) -> Void)?
    var onShortcutStateChanged: ((Set<ControlShortcut>, String) -> Void)?
    private var connectionStatus: ControlConnectionStatus?
    var onConnectionStateChanged: ((ControlConnectionStatus) -> Void)?
    private var lockState: DeviceLockState = .unknown
    var onLockStateChanged: ((DeviceLockState) -> Void)?

    private var canSendWindowInput: Bool {
        isKeyboardTarget && !isBackendNoticeVisible && binding.acceptsEvents(isKeyWindow: window?.isKeyWindow == true)
            && connectionStatus == .connected
            && (usbSelected ? usbInput?.isKeyboardReady == true : input?.isBluetoothReady == true)
    }

    /// Pointer input is not tied to key-window focus: the window under the
    /// mouse steers its own phone. Keyboard input keeps the focus gate above.
    private var canSendPointerInput: Bool {
        isPointerTarget && !isBackendNoticeVisible && binding.isDeviceBound
            && connectionStatus == .connected
            && (usbSelected ? usbInput?.isReady == true : input?.isBluetoothReady == true)
    }

    // MARK: View lifecycle and rendering

    init(deviceID: String?, frame: NSRect) {
        binding = ControlDeviceBinding(deviceID: deviceID)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        // The image rectangle changes on resize. End a drag and let the next
        // sample position the pointer using the new geometry.
        if frame.size != newSize { cancelInteraction() }
        super.setFrameSize(newSize)
    }

    func start() {
        guard timer == nil else { return }
        isRendering = true
        HIDPeripheral.shared.beginWindowDemand(bluetoothDemandToken)
        binding.start()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.refreshDevice()
            self?.synchronizeMousePosition()
            self?.needsDisplay = true
        }
        self.timer = timer
        // Keep refreshing during AppKit's mouse tracking modes as well.
        RunLoop.main.add(timer, forMode: .common)
        refreshDevice()
    }

    func stop() {
        isRendering = false
        backendRequest?.cancel(); backendRequest = nil
        HIDPeripheral.shared.endWindowDemand(bluetoothDemandToken)
        timer?.invalidate()
        timer = nil
        binding.stop()
        cancelInteraction()
        device = nil
        input = nil
        usbInput?.cancel(); usbInput = nil
        pointerReady = false
        activeShortcut = nil
        shortcutFeedback = nil
        connectionStatus = nil
        lockState = .unknown
        lastShortcutState = nil
        lastUSBPresentation = nil
    }

    deinit {
        backendRequest?.cancel()
        HIDPeripheral.shared.endWindowDemand(bluetoothDemandToken)
        timer?.invalidate()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        // Hover steering follows the window under the mouse, so tracking must
        // stay active even while another control window holds keyboard focus.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let device, !device.screen.displayIdentityConfirmed {
            WorkbenchTheme.canvas.setFill()
            dirtyRect.intersection(bounds).fill()
            let text = AppLanguageStore.shared.language == .zh
                ? "正在确认设备画面…" : "Verifying device display…"
            WorkbenchTheme.text(text,
                in: NSRect(x: 8, y: bounds.midY - 20, width: max(1, bounds.width - 16), height: 40),
                size: 11, color: WorkbenchTheme.muted, alignment: .center)
            return
        }
        NSColor.black.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let buffer = device?.screen.frame() else {
            ControlScreenRenderer.drawWaitingMessage(in: bounds)
            return
        }
        ControlScreenRenderer.draw(buffer, in: bounds)
    }

    // MARK: AppKit input events

    override func mouseMoved(with event: NSEvent) {
        recordMousePosition(event, clampToImage: false)
    }

    override func mouseEntered(with event: NSEvent) {
        if !dragging { mousePosition.reset() }
        recordMousePosition(event, clampToImage: dragging)
        flushMousePosition()
    }

    override func mouseExited(with event: NSEvent) {
        if !dragging {
            let ready = canSendPointerInput && input?.isPointerReady == true
            if ready { preemptBackgroundPointerMotion() }
            mousePosition.reset()
            input?.cancelPointer(preservingBackgroundMotion: !ready)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        if usbSelected {
            guard canSendPointerInput, let device, let usbInput,
                  let point = normalizedPoint(event.locationInWindow, device: device) else { return }
            window?.makeFirstResponder(self)
            dragging = usbInput.down(.init(x: point.x, y: point.y))
            if !dragging { NSSound.beep() }
            return
        }
        preemptBackgroundPointerMotion()
        // A subscription can become ready between timer ticks. Complete that
        // transition before starting a gesture so the next tick cannot cancel it.
        updatePointerReadiness()
        guard canSendPointerInput, activeShortcut == nil, pointerReady, let device, let input,
            let position = normalizedPoint(event.locationInWindow, device: device)
        else { return }
        window?.makeFirstResponder(self)
        if ProcessInfo.processInfo.environment["IPHONE_USE_TRACE_POINTER"] == "1" {
            log(
                "mouse down window=\(event.locationInWindow) normalized=\(position) sessionCurrent=\(input.isCurrentSession)"
            )
        }
        dragging = true
        mousePosition.markSubmitted(position)
        // Always position from this click's coordinates, even if an enter or
        // hover event arrived before Bluetooth became ready.
        input.press(x: position.x, y: position.y)
    }

    override func mouseDragged(with event: NSEvent) {
        if usbSelected {
            guard dragging, canSendPointerInput, let device,
                  let point = normalizedPoint(event.locationInWindow, device: device, clamp: true) else { return }
            usbInput?.move(.init(x: point.x, y: point.y)); return
        }
        guard dragging else { return }
        recordMousePosition(event, clampToImage: true)
    }

    override func mouseUp(with event: NSEvent) {
        if usbSelected {
            guard dragging else { return }
            defer { dragging = false }
            guard canSendPointerInput, let device,
                  let point = normalizedPoint(event.locationInWindow, device: device, clamp: true) else {
                usbInput?.cancel(); return
            }
            usbInput?.up(.init(x: point.x, y: point.y)); return
        }
        guard dragging else { return }
        guard canSendPointerInput, let device, let input,
            let position = normalizedPoint(event.locationInWindow, device: device, clamp: true)
        else {
            cancelInteraction()
            return
        }
        mousePosition.markSubmitted(position)
        input.release(x: position.x, y: position.y)
        dragging = false
    }

    override func keyDown(with event: NSEvent) {
        preemptBackgroundPointerMotion()
        guard canSendWindowInput else { return }
        switch ControlKeyboardEvent(event).command {
        case .key(let key, let modifiers):
            let accepted = usbSelected ? usbInput?.keyFromKeyboard(key, modifiers: modifiers) : input?.keyFromKeyboard(key, modifiers: modifiers)
            if accepted != true { NSSound.beep() }
        case .text(let text, let modifiers):
            let accepted = usbSelected ? usbInput?.typeFromKeyboard(text, modifiers: modifiers) : input?.typeFromKeyboard(text, modifiers: modifiers)
            if accepted != true { NSSound.beep() }
        case nil:
            break
        }
    }

    // AppKit may handle Command-V as a local key equivalent before keyDown is
    // delivered. Forward it explicitly so the phone receives the native paste
    // shortcut and can use Universal Clipboard when available.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard acceptsLocalKeyEquivalents, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        // Local edit menus must not consume focused-phone editing shortcuts.
        // Keep app/window commands (Quit, Close, Hide...) local on both backends.
        if event.modifierFlags.contains(.command),
           let name = event.charactersIgnoringModifiers?.lowercased(), ["a", "c", "x", "v", "z"].contains(name) {
            preemptBackgroundPointerMotion()
            guard canSendWindowInput else { return true }
            switch ControlKeyboardEvent(event).command {
            case .key(let key, let modifiers):
                if usbSelected { _ = usbInput?.keyFromKeyboard(key, modifiers: modifiers) }
                else { _ = input?.keyFromKeyboard(key, modifiers: modifiers) }
            case .text(let text, let modifiers):
                if usbSelected { _ = usbInput?.typeFromKeyboard(text, modifiers: modifiers) }
                else { _ = input?.typeFromKeyboard(text, modifiers: modifiers) }
            case nil: break
            }
            return true
        }
        if ControlKeyboardEvent.isPasteShortcut(event) {
            preemptBackgroundPointerMotion()
            guard canSendWindowInput else { return true }
            if usbSelected { _ = usbInput?.keyFromKeyboard("v", modifiers: ["cmd"]) }
            else { _ = input?.keyFromKeyboard("v", modifiers: ["cmd"]) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Gesture and shortcut coordination

    func cancelInteraction(preservingBackgroundMotion: Bool = false) {
        if let textDispatch {
            textDispatch.cancel()
            self.textDispatch = nil
            activeShortcut = nil
        }
        dragging = false
        mousePosition.reset()
        input?.cancelPointer(preservingBackgroundMotion: preservingBackgroundMotion)
        usbInput?.cancel()
    }

    func performShortcut(_ shortcut: ControlShortcut) {
        refreshDevice()
        preemptBackgroundPointerMotion()
        if usbSelected { performUSBShortcut(shortcut); return }
        guard canSendWindowInput, activeShortcut == nil, let input, shortcut.isAvailable(on: input) else { return }
        window?.makeFirstResponder(self)
        // Release any window drag before entering the same input queue used by
        // pointer tracking and HTTP gestures. Keep synchronous HID work off AppKit.
        cancelInteraction()
        activeShortcut = shortcut
        shortcutFeedback = nil
        updateShortcutState()
        let generation = binding.generation
        shortcutQueue.async { [weak self] in
            let feedback: String
            do {
                if input.isBluetoothReady, shortcut.isAvailable(on: input) {
                    try shortcut.perform(on: input)
                    // The store is lock-protected; this closure runs off the main thread.
                    let table = StringsUI.current
                    feedback =
                        shortcut.isAvailable(on: input)
                        ? table.sentShortcut(shortcut.title) : table.shortcutDisconnected
                } else {
                    feedback = StringsUI.current.shortcutNotReady
                }
            } catch {
                log("window shortcut \(shortcut.title) failed: \(error)")
                feedback = StringsUI.current.shortcutFailed
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.binding.isCurrent(generation), self.input === input else { return }
                self.activeShortcut = nil
                self.shortcutFeedback = (feedback, Date().addingTimeInterval(3))
                self.refreshDevice()
            }
        }
    }

    func sendText(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        refreshDevice()
        guard canSendWindowInput, activeShortcut == nil, let device,
              lastShortcutState?.available.contains(.enter) == true else {
            completion(.failure(DeviceError(StringsWorkbench.current.waitingInput))); return
        }
        let request: TypeTextRequest
        do { request = try TypeTextRequest(["text": text], language: AppLanguageStore.shared.language) }
        catch { completion(.failure(error)); return }
        let usb = usbSelected
        let backend = selectedBackend
        let input = self.input
        let usbInput = self.usbInput
        let generation = binding.generation
        cancelInteraction()
        let ticket = ControlTextDispatch()
        textDispatch = ticket
        activeShortcut = .enter
        updateShortcutState()
        shortcutQueue.async { [weak self] in
            let result = Result<Void, Error> {
                guard !ticket.isCancelled, ScreenCaptureManager.shared.isCurrent(device.screen),
                      USBInputController.shared.selected(device.id) == backend else {
                    throw DeviceError(StringsWorkbench.current.disconnected)
                }
                if usb {
                    guard let usbInput, usbInput.isKeyboardReady else { throw DeviceError(StringsWorkbench.current.waitingInput) }
                    try usbInput.type(request, ocr: {
                        guard let frame = device.screen.snapshotObservation(png: false, maxEdge: 1600) else { return nil }
                        return USBKeyboardModeOCR.observe(frame.data, device: device.id, receivedAt: frame.receivedAt,
                                                          includeCandidate: request.ensureChineseIME)
                    })
                } else {
                    guard let input, input.isCurrentSession, input.isBluetoothReady else { throw DeviceError(StringsWorkbench.current.waitingInput) }
                    try request.perform(on: input, ocr: {
                        device.screen.snapshot(png: false).map { ScreenOCR.recognize($0, device: device.id) }
                    })
                }
            }
            DispatchQueue.main.async { [weak self] in
                if let self, self.binding.isCurrent(generation), self.textDispatch === ticket {
                    self.textDispatch = nil
                    self.activeShortcut = nil
                    self.refreshDevice()
                }
                completion(ticket.finalResult(result))
            }
        }
    }

    private func performUSBShortcut(_ shortcut: ControlShortcut) {
        guard canSendWindowInput, activeShortcut == nil, let usbInput,
              shortcut.isAvailableUSB(keyboardReady: usbInput.isKeyboardReady, buttonsReady: usbInput.isButtonsReady) else { return }
        window?.makeFirstResponder(self)
        // Share the native keyboard/button admission and expiry gate. Do not queue behind a held
        // pointer, cancel another action, or dispatch on the BLE shortcut queue.
        activeShortcut = shortcut
        shortcutFeedback = nil
        let generation = binding.generation
        let completion: (Result<Void, Error>) -> Void = { [weak self, weak usbInput] result in
            DispatchQueue.main.async {
                guard let self, let usbInput, self.usbSelected,
                      self.binding.isCurrent(generation), self.usbInput === usbInput else { return }
                self.activeShortcut = nil
                let table = StringsUSBControl.current
                let message: String
                switch result {
                case .success: message = table.shortcutAcknowledged(shortcut.title)
                case .failure: message = table.shortcutFailed
                }
                self.shortcutFeedback = (message, Date().addingTimeInterval(3))
                self.refreshDevice()
            }
        }
        let accepted: Bool
        if let button = shortcut.usbButton { accepted = usbInput.buttonFromWindow(button, completion: completion) }
        else if let key = shortcut.usbKey { accepted = usbInput.keyFromKeyboard(key.name, modifiers: key.modifiers, completion: completion) }
        else { accepted = false }
        if !accepted {
            activeShortcut = nil
            shortcutFeedback = (StringsUI.current.shortcutNotReady, Date().addingTimeInterval(3))
            NSSound.beep()
        }
        updateShortcutState()
    }

    private func updateShortcutState() {
        // Status is recomputed from the live table on every 30 Hz tick, so a
        // language change flips this line within one tick without an observer.
        let table = StringsUI.current
        var available: Set<ControlShortcut> = []
        let status: String
        let usbPresentation = usbSelected ? ControlUSBPresentation(
            snapshot: device.map { USBInputController.shared.status($0) } ?? [:],
            inputReady: usbInput?.isReady == true, hasScreen: device != nil) : nil
        if lastUSBPresentation != usbPresentation {
            lastUSBPresentation = usbPresentation
            onUSBPresentationChanged?(usbPresentation)
        }
        if let usbPresentation {
            if activeShortcut == nil {
                available = Set(ControlShortcut.allCases.filter {
                    $0.isAvailableUSB(keyboardReady: usbPresentation.keyboardReady, buttonsReady: usbPresentation.buttonsReady)
                })
            }
            if let activeShortcut { status = table.sendingShortcut(activeShortcut.title) }
            else if usbPresentation.state == .ready, let shortcutFeedback, shortcutFeedback.expires > Date() {
                status = shortcutFeedback.text
            } else { status = StringsUSBControl.current.status(usbPresentation) }
        } else if connectionStatus == .verifyingScreen {
            status = table.statusVerifyingScreen
        } else if connectionStatus != .connected {
            status =
                connectionStatus == .unmatched
                ? table.overlayUnmatchedTitle
                : (device == nil ? table.statusWaitingDevice : table.statusWaitingBluetooth)
        } else if let activeShortcut {
            status = table.sendingShortcut(activeShortcut.title)
        } else if let input, input.isCurrentSession {
            available = Set(ControlShortcut.allCases.filter { $0.isAvailable(on: input) })
            if let device, DeviceRegistry.shared.isAutomaticallyCalibrating(screenID: device.id) {
                available = []
                status = table.statusAutomaticallyCalibrating
            } else if available.isEmpty {
                status = table.statusWaitingBluetooth
            } else if lockState.showsNotice {
                status = lockState.title
            } else if let shortcutFeedback, shortcutFeedback.expires > Date() {
                status = shortcutFeedback.text
            } else {
                status =
                    input.needsCalibration
                    ? table.statusCalibrationRequired
                    : (input.isPointerReady ? table.statusConnected : table.statusPointerNotReady)
            }
        } else {
            status = device == nil ? table.statusWaitingDevice : table.statusWaitingBluetooth
        }
        if isBackendNoticeVisible { available = [] }
        guard lastShortcutState?.available != available || lastShortcutState?.status != status else { return }
        lastShortcutState = (available, status)
        onShortcutStateChanged?(available, status)
    }

    // MARK: Device and connection transitions

    private func refreshDevice() {
        guard binding.isRunning else { return }
        // Publish connection changes first: they can cancel a gesture and clear
        // shortcut feedback before the sidebar computes its next visible state.
        defer {
            updateLockState()
            updateConnectionState()
            updateShortcutState()
        }
        // A window never follows a similarly named phone or an ID prefix. A USB
        // reconnect is a new capture object even when the stable ID is unchanged.
        let current = binding.deviceID.flatMap { id in
            DeviceRegistry.shared.all().first { $0.id == id }
        }
        let connection = current.map { device in
            ControlDeviceBinding.Connection(
                deviceID: device.id, captureID: ObjectIdentifier(device.screen), host: usbSelected ? nil : device.host,
                session: usbSelected ? nil : device.host.flatMap { HIDPeripheral.shared.connectionSession(for: $0) })
        }
        // BLE rematching must not discard a version notice for the same phone.
        if device?.screen !== current?.screen {
            backendRequest?.cancel(); backendRequest = nil
        }
        if binding.observe(connection) {
            cancelInteraction()
            input?.invalidatePointerEstimate()
            input = nil
            activeShortcut = nil
            shortcutFeedback = nil
        }
        if input?.isRetired == true {
            cancelInteraction()
            input = nil
        }
        device = current
        if usbSelected {
            if let current {
                USBInputController.shared.refresh(current)
                let resolved = USBInputController.shared.input(current)
                if usbInput !== resolved {
                    usbInput?.cancel(); usbInput = resolved
                    activeShortcut = nil; shortcutFeedback = nil
                }
            } else { usbInput?.retire(); usbInput = nil }
            input = nil
            return
        }
        if let usbInput {
            usbInput.cancel(); self.usbInput = nil
            activeShortcut = nil; shortcutFeedback = nil
        }
        // Matching an unknown Bluetooth host can probe several screens. Resolve
        // it outside AppKit and keep only one outstanding attempt per window.
        if input == nil, let current, let request = binding.beginInputRequest(at: Date()) {
            inputQueue.async { [weak self] in
                let resolved = Self.resolveInput(for: current)
                DispatchQueue.main.async { [weak self] in
                    self?.completeInputRequest(request, input: resolved)
                }
            }
        }
        updatePointerReadiness()
    }

    private static func resolveInput(for device: Device) -> DeviceInput? {
        let registry = DeviceRegistry.shared
        // Background retries must not probe: probing moves real phone pointers.
        // Topology changes and explicit /match own the probing passes.
        if device.host == nil { registry.match(allowProbing: false) }
        // The public registry lookup accepts names and prefixes. A window must
        // reselect the exact capture after matching, including during USB removal.
        guard let current = registry.all().first(where: { $0.id == device.id && $0.screen === device.screen }),
            current.host != nil
        else { return nil }
        return try? registry.input(for: current)
    }

    private func completeInputRequest(_ request: ControlDeviceBinding.Request, input resolved: DeviceInput?) {
        // Read fresh USB/BLE state before accepting the result. Closing, restarting,
        // rematching or reconnecting the window invalidates its old request token.
        refreshDevice()
        if usbSelected {
            _ = binding.finishInputRequest(request, host: nil, session: nil, isCurrentSession: false)
            return
        }
        guard
            binding.finishInputRequest(
                request, host: resolved?.host, session: resolved?.session,
                isCurrentSession: resolved?.isCurrentSession == true)
        else { return }
        input = resolved
        updatePointerReadiness()
        updateConnectionState()
        updateShortcutState()
    }

    private func updateConnectionState() {
        let status: ControlConnectionStatus = usbSelected
            ? (device == nil ? .waitingForDevice : (usbInput?.isReady == true ? .connected : .verifyingScreen))
            : ControlConnectionStatus.resolve(
            hasScreen: device != nil, hasMatchedHost: device?.host != nil,
            bluetoothState: device?.bluetoothState ?? .disconnected,
            inputIsCurrent: input?.isCurrentSession == true, inputIsReady: input?.isBluetoothReady == true,
            screenPermitsInput: device.map { ScreenCaptureManager.shared.permitsPointerAssociation(for: $0.screen) }
                ?? false)
        guard connectionStatus != status else { return }
        cancelInteraction(preservingBackgroundMotion: status == .connected)
        if status != .connected { input?.invalidatePointerEstimate() }
        shortcutFeedback = nil
        connectionStatus = status
        onConnectionStateChanged?(status)
    }

    private func updatePointerReadiness() {
        let ready = input?.isPointerReady == true
        guard ready != pointerReady else { return }
        // Keyboard subscriptions can arrive before the pointer reports. Reset
        // the observed position so readiness triggers fresh positioning.
        // A readiness notification is not user activity. In particular, the
        // first ready tick must not cancel connection-time curve verification.
        // Background jobs already check capture/session ownership themselves.
        cancelInteraction(preservingBackgroundMotion: true)
        if !ready { input?.invalidatePointerEstimate(preservingBackgroundMotion: true) }
        pointerReady = ready
    }

    private func updateLockState() {
        let current = device?.lockState ?? .unknown
        guard current != lockState else { return }
        lockState = current
        onLockStateChanged?(current)
    }

    // MARK: Pointer sampling and coordinate conversion

    /// AppKit can omit an enter/move event while activating the window. Polling
    /// also submits the latest changed position at 30 Hz. A stationary mouse
    /// never overrides a position submitted through the API.
    private func synchronizeMousePosition() {
        if usbSelected { return } // Touchscreens have no hover contact.
        guard canSendPointerInput, activeShortcut == nil, let window, let device, let input,
            input.isPointerReady
        else {
            mousePosition.reset()
            return
        }
        // The window under the mouse owns hover steering, key window or not;
        // a key window covered by another window must not steer its phone.
        // During an existing drag, keep tracking beyond the window and clamp
        // to its image.
        let isTopmostWindow =
            dragging
            || NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        guard
            binding.acceptsPointerSample(isTopmostWindow: isTopmostWindow, isDragging: dragging)
        else {
            mousePosition.reset()
            return
        }
        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard dragging || visibleRect.contains(localPoint) else {
            mousePosition.reset()
            return
        }
        if let point = normalizedPoint(window.mouseLocationOutsideOfEventStream, device: device, clamp: dragging) {
            mousePosition.update(point)
            flushMousePosition()
        } else {
            flushMousePosition()
            mousePosition.reset()
        }
    }

    private func recordMousePosition(_ event: NSEvent, clampToImage: Bool) {
        if usbSelected { return }
        // Mouse-entered/moved/dragged events are delivered only to the window
        // under the cursor, so a background control window still steers its
        // own phone while the mouse is over it.
        guard binding.isDeviceBound else {
            mousePosition.reset()
            return
        }
        // Hovering a disabled connection overlay cannot steer this phone.
        // Do not let tracking-area events cancel the discovery that enables it.
        if canSendPointerInput && input?.isPointerReady == true { preemptBackgroundPointerMotion() }
        updatePointerReadiness()
        guard canSendPointerInput, activeShortcut == nil, pointerReady, let device,
            let point = normalizedPoint(event.locationInWindow, device: device, clamp: clampToImage)
        else {
            flushMousePosition()
            mousePosition.reset()
            return
        }
        mousePosition.update(point)
        // Calibrated DeviceInput already coalesces and paces its Bluetooth reports.
        // Forward events immediately; native absolute reports retain the timer
        // throttle so high-frequency mice cannot flood that unpaced path.
        if input?.calibration != nil { flushMousePosition() }
    }

    private func preemptBackgroundPointerMotion() {
        // Mouse clicks, keys and shortcuts can arrive while the overlay blocks
        // input. Such ignored events must not cancel discovery or its retry.
        guard connectionStatus?.permitsBackgroundMotionPreemption == true, let device else { return }
        DeviceRegistry.shared.cancelBackgroundMotion(for: device)
    }

    private func flushMousePosition() {
        if usbSelected { return }
        guard canSendPointerInput, activeShortcut == nil, let input, input.isPointerReady,
            let position = mousePosition.takePosition()
        else { return }
        if dragging {
            input.drag(x: position.x, y: position.y)
        } else {
            input.positionPointer(x: position.x, y: position.y)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard usbSelected, canSendPointerInput, !dragging, let usbInput, let device,
              let point = normalizedPoint(event.locationInWindow, device: device),
              abs(event.scrollingDeltaY) > 0.01 else { return }
        let delta = max(-0.3, min(0.3, -event.scrollingDeltaY / 200))
        usbInput.scroll(at: .init(x: point.x, y: point.y), delta: delta)
    }

    /// Fractions of the phone image, independent of capture and Retina scale.
    private func normalizedPoint(
        _ windowPoint: NSPoint, device: Device, clamp: Bool = false
    ) -> CGPoint? {
        let point = convert(windowPoint, from: nil)
        guard let size = device.screen.size,
            let layout = ControlImageLayout(screenSize: size, bounds: bounds)
        else { return nil }
        return layout.normalizedPoint(point, clamp: clamp)
    }
}

/// Main-thread state for a window's immutable USB identity and asynchronous input
/// lookup. Keeping this independent of AppKit and hardware makes reconnect races
/// testable without starting capture sessions or requesting Bluetooth permission.
struct ControlDeviceBinding {
    struct Connection: Equatable {
        let deviceID: String
        let captureID: ObjectIdentifier
        let host: UUID?
        let session: UUID?
    }

    struct Request: Equatable {
        let generation: UInt64
        let connection: Connection
    }

    let deviceID: String?
    private(set) var isRunning = false
    private(set) var generation: UInt64 = 0
    private var connection: Connection?
    private var pendingRequest: Request?
    private var lastInputAttempt = Date.distantPast

    init(deviceID: String?) {
        self.deviceID = deviceID
    }

    mutating func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
    }

    mutating func stop() {
        isRunning = false
        connection = nil
        generation &+= 1
        lastInputAttempt = .distantPast
        // An already-running lookup still occupies the background queue. Retain
        // its token until completion so stop/start cannot queue duplicate probes.
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        isRunning && self.generation == generation
    }

    /// The window currently shows its bound device, independent of focus.
    var isDeviceBound: Bool {
        isRunning && connection != nil
    }

    /// Keyboard input follows the key window only.
    func acceptsEvents(isKeyWindow: Bool) -> Bool {
        isDeviceBound && isKeyWindow
    }

    /// Pointer input follows the window under the mouse: the topmost window
    /// at the cursor steers its own phone without taking focus. An active
    /// drag keeps sampling beyond its window; every other case requires the
    /// topmost position so a covered window never steers the wrong phone.
    func acceptsPointerSample(isTopmostWindow: Bool, isDragging: Bool) -> Bool {
        isDeviceBound && (isDragging || isTopmostWindow)
    }

    /// Foreign IDs, including a longer prefix match, are treated as disconnected.
    @discardableResult
    mutating func observe(_ candidate: Connection?) -> Bool {
        let current = candidate.flatMap { $0.deviceID == deviceID ? $0 : nil }
        guard connection != current else { return false }
        connection = current
        generation &+= 1
        lastInputAttempt = .distantPast
        return true
    }

    mutating func beginInputRequest(at now: Date) -> Request? {
        guard isRunning, let connection, pendingRequest == nil,
            now.timeIntervalSince(lastInputAttempt) >= 1
        else { return nil }
        lastInputAttempt = now
        let request = Request(generation: generation, connection: connection)
        pendingRequest = request
        return request
    }

    mutating func finishInputRequest(
        _ request: Request, host: UUID?, session: UUID?, isCurrentSession: Bool
    ) -> Bool {
        guard pendingRequest == request else { return false }
        pendingRequest = nil
        guard isCurrent(request.generation), connection == request.connection,
            let host, let session, isCurrentSession
        else { return false }
        return connection?.host == host && connection?.session == session
    }
}

/// Draw the capture's existing BGRA pixels without a Core Image GPU round trip.
private enum ControlScreenRenderer {
    static func draw(_ buffer: CVPixelBuffer, in bounds: CGRect) {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard let layout = ControlImageLayout(screenSize: size, bounds: bounds) else { return }
        // AVCapture already supplies BGRA. Core Image rendered and read those
        // pixels back from the GPU on AppKit's event thread for every frame.
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr,
            let image,
            let cgContext = NSGraphicsContext.current?.cgContext
        else { return }
        cgContext.interpolationQuality = .high
        cgContext.draw(image, in: layout.imageRect)
    }

    static func drawWaitingMessage(in bounds: CGRect) {
        // Read per draw so the 30 Hz repaint picks up a language change at once.
        let text = StringsUI.current.canvasWaitingText
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .font: NSFont.systemFont(ofSize: 16), .paragraphStyle: style,
        ]
        (text as NSString).draw(in: bounds.insetBy(dx: 20, dy: bounds.height / 2 - 30), withAttributes: attributes)
    }
}

/// Cancels pending UI text dispatch without reading AppKit state on a worker queue.
/// Already-dispatched input is never replayed or rebound to a new selection.
final class ControlTextDispatch {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    func finalResult(_ result: Result<Void, Error>) -> Result<Void, Error> {
        // Cancellation cannot retract text already accepted by a backend.
        // Preserve the draft and report uncertainty rather than a late success.
        isCancelled ? .failure(DeviceError(StringsWorkbench.current.textCancelled)) : result
    }
}
