import AppKit
import CoreVideo
import VideoToolbox

/// A lightweight scrcpy-style window. The screen is drawn directly from the latest
/// CVPixelBuffer and mouse events are sent to the phone's HID input queue.
final class PhoneControlView: NSView {
    private var binding: ControlDeviceBinding
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var device: Device?
    private var input: DeviceInput?
    private var dragging = false
    private var mousePosition = ControlMousePosition()
    private var pointerReady = false
    private let inputQueue = DispatchQueue(label: "iphone-use.window-input-resolution")
    private let shortcutQueue = DispatchQueue(label: "iphone-use.window-shortcuts")
    private var activeShortcut: ControlShortcut?
    private var shortcutFeedback: (text: String, expires: Date)?
    private var lastShortcutState: (available: Set<ControlShortcut>, status: String)?
    var onShortcutStateChanged: ((Set<ControlShortcut>, String) -> Void)?
    private var connectionStatus: ControlConnectionStatus?
    var onConnectionStateChanged: ((ControlConnectionStatus) -> Void)?

    private var canSendWindowInput: Bool {
        binding.acceptsEvents(isKeyWindow: window?.isKeyWindow == true)
            && connectionStatus == .connected && input?.isBluetoothReady == true
    }

    /// Pointer input is not tied to key-window focus: the window under the
    /// mouse steers its own phone. Keyboard input keeps the focus gate above.
    private var canSendPointerInput: Bool {
        binding.isDeviceBound
            && connectionStatus == .connected && input?.isBluetoothReady == true
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
        cancelInteraction()
        super.setFrameSize(newSize)
    }

    func start() {
        guard timer == nil else { return }
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
        timer?.invalidate()
        timer = nil
        binding.stop()
        cancelInteraction()
        device = nil
        input = nil
        pointerReady = false
        activeShortcut = nil
        shortcutFeedback = nil
        connectionStatus = nil
        lastShortcutState = nil
    }

    deinit { timer?.invalidate() }

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
            if canSendPointerInput { preemptBackgroundPointerMotion() }
            mousePosition.reset()
            input?.cancelPointer()
        }
    }

    override func mouseDown(with event: NSEvent) {
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
        guard dragging else { return }
        recordMousePosition(event, clampToImage: true)
    }

    override func mouseUp(with event: NSEvent) {
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
        guard canSendWindowInput, let input else { return }
        switch ControlKeyboardEvent(event).command {
        case .key(let key, let modifiers):
            _ = input.keyFromKeyboard(key, modifiers: modifiers)
        case .text(let text, let modifiers):
            if !input.typeFromKeyboard(text, modifiers: modifiers) { NSSound.beep() }
        case nil:
            break
        }
    }

    // AppKit may handle Command-V as a local key equivalent before keyDown is
    // delivered. Forward it explicitly so the phone receives the native paste
    // shortcut and can use Universal Clipboard when available.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        if ControlKeyboardEvent.isPasteShortcut(event) {
            preemptBackgroundPointerMotion()
            guard canSendWindowInput, let input else { return true }
            _ = input.keyFromKeyboard("v", modifiers: ["cmd"])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Gesture and shortcut coordination

    func cancelInteraction() {
        dragging = false
        mousePosition.reset()
        input?.cancelPointer()
    }

    func performShortcut(_ shortcut: ControlShortcut) {
        refreshDevice()
        preemptBackgroundPointerMotion()
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

    private func updateShortcutState() {
        // Status is recomputed from the live table on every 30 Hz tick, so a
        // language change flips this line within one tick without an observer.
        let table = StringsUI.current
        var available: Set<ControlShortcut> = []
        let status: String
        if connectionStatus == .verifyingScreen {
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
                deviceID: device.id, captureID: ObjectIdentifier(device.screen), host: device.host,
                session: device.host.flatMap { HIDPeripheral.shared.connectionSession(for: $0) })
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
        let status = ControlConnectionStatus.resolve(
            hasScreen: device != nil, hasMatchedHost: device?.host != nil,
            bluetoothState: device?.bluetoothState ?? .disconnected,
            inputIsCurrent: input?.isCurrentSession == true, inputIsReady: input?.isBluetoothReady == true,
            screenPermitsInput: device.map { ScreenCaptureManager.shared.permitsPointerAssociation(for: $0.screen) }
                ?? false)
        guard connectionStatus != status else { return }
        cancelInteraction()
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
        cancelInteraction()
        if !ready { input?.invalidatePointerEstimate() }
        pointerReady = ready
    }

    // MARK: Pointer sampling and coordinate conversion

    /// AppKit can omit an enter/move event while activating the window. Polling
    /// also submits the latest changed position at 30 Hz. A stationary mouse
    /// never overrides a position submitted through the API.
    private func synchronizeMousePosition() {
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
        if let point = normalizedPoint(window.mouseLocationOutsideOfEventStream, device: device, clamp: dragging) {
            mousePosition.update(point)
            flushMousePosition()
        } else {
            flushMousePosition()
            mousePosition.reset()
        }
    }

    private func recordMousePosition(_ event: NSEvent, clampToImage: Bool) {
        // Mouse-entered/moved/dragged events are delivered only to the window
        // under the cursor, so a background control window still steers its
        // own phone while the mouse is over it.
        guard binding.isDeviceBound else {
            mousePosition.reset()
            return
        }
        // Hovering a disabled connection overlay cannot steer this phone.
        // Do not let tracking-area events cancel the discovery that enables it.
        if canSendPointerInput { preemptBackgroundPointerMotion() }
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
        guard let device else { return }
        // A new phone may still be undergoing discovery and have no input
        // cached for its screen. Cancel the registry's whole discovery round.
        DeviceRegistry.shared.cancelBackgroundMotion(for: device)
    }

    private func flushMousePosition() {
        guard canSendPointerInput, activeShortcut == nil, let input, input.isPointerReady,
            let position = mousePosition.takePosition()
        else { return }
        if dragging {
            input.drag(x: position.x, y: position.y)
        } else {
            input.positionPointer(x: position.x, y: position.y)
        }
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
