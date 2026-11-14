import Foundation

/// Full physical identity owns selection and retirement. Switching is off the
/// AppKit thread; neither backend may send while the previous one is retiring.
final class USBInputController {
    static let shared = USBInputController()
    private let lock = NSLock()
    private var transitions: [String: DispatchQueue] = [:]
    private var entries: [String: USBDeviceInput] = [:]
    private var retiring: [String: [USBDeviceInput]] = [:]
    private var selections: [String: InputBackendSelection] = [:]
    private let transitionWork = DispatchGroup()
    private var stopped = false
    private var shutdownWork: DispatchGroup?
    private var shutdownReleased = false

    func selectAtLaunch(physicalID: String) {
        // Capture refresh will prepare USB after identity becomes verified.
        lock.withLock {
            guard !stopped else { return }
            var state = InputBackendSelection()
            let id = state.begin(.usb); state.finish(id, released: true)
            selections[physicalID] = state
        }
    }
    func selected(_ id: String) -> InputBackendKind { lock.withLock { selections[id]?.backend ?? .ble } }
    func generation(_ id: String) -> UUID { lock.withLock {
        if selections[id] == nil { selections[id] = InputBackendSelection() }
        return selections[id]!.generation
    } }
    func permitsBLE(_ id: String, generation: UUID?) -> Bool {
        lock.withLock { !stopped && (selections[id]?.permits(.ble, generation: generation) ?? (generation == nil)) }
    }
    func input(_ device: Device) -> USBDeviceInput? {
        lock.withLock {
            guard !stopped, selections[device.id]?.permits(.usb) == true, let input = entries[device.id],
                  input.captureID == device.screen.associationIdentity else { return nil }
            return input
        }
    }
    func select(_ backend: InputBackendKind, device: Device) {
        let admitted = lock.withLock { () -> (UUID, USBDeviceInput?, DispatchQueue)? in
            guard !stopped else { return nil }
            var state = selections[device.id] ?? InputBackendSelection()
            let generation = state.begin(backend); selections[device.id] = state
            let previous = entries.removeValue(forKey: device.id)
            if let previous { retiring[device.id, default: []].append(previous) }
            let queue = transitions[device.id] ?? DispatchQueue(label: "iphone-use.input-transition.\(device.id)")
            transitions[device.id] = queue
            // Register before dropping the admission lock: shutdown must also
            // drain transitions that have not reached their queue yet.
            transitionWork.enter()
            return (generation, previous, queue)
        }
        guard let (generation, previous, transitionQueue) = admitted else { return }
        previous?.retire() // EOF interrupts a synchronous worker gesture too.
        DeviceRegistry.shared.cancelBackgroundMotion(for: device)
        transitionQueue.async { [self] in
            defer { transitionWork.leave() }
            guard !lock.withLock({ stopped }) else { return }
            let old = lock.withLock { retiring[device.id] ?? [] }
            let unreleased = old.filter { !$0.retireAndWait() }
            let usbReleased = unreleased.isEmpty
            lock.withLock {
                retiring[device.id]?.removeAll { candidate in
                    old.contains(where: { $0 === candidate }) && !unreleased.contains(where: { $0 === candidate })
                }
            }
            let bleReleased = DeviceRegistry.shared.releaseForBackendSwitch(device)
            let input = backend == .usb ? USBDeviceInput(device: device) : nil
            let accepted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                selections[device.id]?.finish(generation, released: usbReleased && bleReleased)
                guard selections[device.id]?.permits(backend, generation: generation) == true else { return false }
                if let input { entries[device.id] = input }
                return true
            }
            if accepted { input?.prepare() } else { input?.retire() }
        }
    }
    func refresh(_ device: Device) {
        let allowed = lock.withLock { !stopped && selections[device.id]?.permits(.usb) == true }
        guard allowed else { return }
        if let entry = input(device) { entry.validateCapture(); return }
        select(.usb, device: device)
    }
    /// Capture removal/remapping/revoked identity must retire input even when
    /// no control window is polling. Keep each entry owned until explicit
    /// selection/shutdown can confirm release and exit; never prepare or replay
    /// from a capture notification. Do not hold our lock across capture reads.
    func captureDidChange() {
        let current = lock.withLock { stopped ? [] : Array(entries.values) }
        for input in current { input.validateCapture() }
    }
    func status(_ device: Device) -> [String: Any] {
        let (state, isStopped) = lock.withLock { (selections[device.id], stopped) }
        if isStopped {
            return ["backend": (state?.backend ?? .ble).rawValue, "state": "disconnected",
                    "detail": "Application input is shutting down; no replay or restart", "capabilities": [],
                    "sessionCurrent": false]
        }
        if let state, state.transitioning || state.failure != nil {
            return ["backend": state.backend.rawValue, "state": state.failure == nil ? "preparing" : "failed",
                    "detail": state.failure ?? "Releasing previous input session", "capabilities": [],
                    "sessionCurrent": false]
        }
        guard state?.backend == .usb else { return ["backend": "ble"] }
        return input(device)?.status ?? ["backend": "usb", "state": "preparing", "capabilities": []]
    }
    /// Close admission first, then wait for transitions, preparation and every
    /// current/retiring worker's release/PING AND exit. A bounded timeout is a
    /// failed shutdown, not permission to claim that contacts were released.
    @discardableResult
    func stop(waitTimeout: TimeInterval = 4) -> Bool {
        let (work, old, initiate) = lock.withLock { () -> (DispatchGroup, [USBDeviceInput], Bool) in
            if let shutdownWork { return (shutdownWork, [], false) }
            stopped = true
            for id in Array(selections.keys) {
                var state = selections[id]!; _ = state.begin(state.backend); selections[id] = state
            }
            var seen = Set<ObjectIdentifier>()
            let old = (Array(entries.values) + retiring.values.flatMap { $0 }).filter {
                seen.insert(ObjectIdentifier($0)).inserted
            }
            entries.removeAll()
            let work = DispatchGroup(); work.enter(); shutdownWork = work
            return (work, old, true)
        }
        if initiate {
            for entry in old { entry.retire() }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                transitionWork.wait()
                // Do not short-circuit: all owners must get a release attempt.
                let released = old.map { $0.retireAndWait() }.allSatisfy { $0 }
                lock.withLock { shutdownReleased = released; retiring.removeAll() }
                work.leave()
            }
        }
        let timeout = waitTimeout.isFinite ? max(0, min(waitTimeout, 60)) : 0
        guard work.wait(timeout: .now() + timeout) == .success else { return false }
        return lock.withLock { shutdownReleased }
    }
}
final class USBDeviceInput {
    let physicalID: String
    let captureID: UUID
    private weak var screen: ScreenCaptureSession?
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var client: USBTouchClient?
    private var closingClients: [USBTouchClient] = []
    private var readiness: InputBackendReadiness = .preparing
    private var detail = ""
    private var retired = false
    private var pendingMotion: USBTouchPoint?
    private var motionScheduled: UUID?
    private var gestureHeld = false
    private var synchronousGesture = false
    private let wheelGate = USBWheelGate()
    private var motionGeneration: UInt64 = 0
    private var screenValid: Bool {
        guard let screen else { return false }
        let manager = ScreenCaptureManager.shared
        return manager.isCurrent(screen) && manager.permitsPointerAssociation(for: screen)
    }
    var isReady: Bool {
        lock.withLock { !retired && readiness == .ready && client?.sessionID != nil } && screenValid
    }
    var isKeyboardReady: Bool {
        isReady && lock.withLock { client?.supportsKeyboard == true }
    }
    var status: [String: Any] {
        let captureValid = screenValid
        return lock.withLock {
            let alive = captureValid && !retired && readiness == .ready && client?.sessionID != nil
            return ["backend": "usb", "state": !captureValid ? "identityUnverified" : (alive ? "ready" : (client?.error == nil ? readiness.rawValue : "failed")),
                    "capabilities": alive ? ["tap", "swipe", "drag"] + (client?.supportsKeyboard == true ? ["text", "key"] : []) : [],
                    "requiresCalibration": false, "sessionCurrent": alive, "detail": client?.error ?? detail]
        }
    }
    init(device: Device) {
        physicalID = device.id; captureID = device.screen.associationIdentity; screen = device.screen
        queue = DispatchQueue(label: "iphone-use.usb-input.\(device.id)")
    }
    func prepare() {
        queue.async { [self] in
            do {
                guard !lock.withLock({ retired }) else { return }
                guard screenValid else { throw AXDTX.Failure("USB capture identity is not verified") }
                let fresh = try USBTouchClient(physicalID: physicalID)
                // A failed capture/dimension check still owns a live worker;
                // retain it for shutdown/transition release confirmation.
                lock.withLock {
                    closingClients.append(fresh)
                    if retired { fresh.close() }
                }
                try fresh.waitUntilReady()
                guard screenValid, let screen, let size = screen.size, let dimensions = fresh.dimensions,
                      Int(size.width) == dimensions.0, Int(size.height) == dimensions.1 else {
                    fresh.close(); throw AXDTX.Failure("USB display/capture identity or dimensions changed")
                }
                lock.withLock {
                    client = fresh
                    closingClients.removeAll { $0 === fresh }
                    if retired { fresh.close() } else { readiness = .ready; detail = "" }
                }
            } catch { fail(error) }
        }
    }
    func validateCapture() { if !screenValid { retire() } }
    private func fail(_ error: Error) {
        let old = lock.withLock { () -> USBTouchClient? in
            readiness = .failed; detail = "\(error)"; let old = client; client = nil; gestureHeld = false
            if let old { closingClients.append(old) }
            return old
        }
        old?.close()
    }
    private func current() throws -> USBTouchClient {
        guard screenValid else { throw AXDTX.Failure("USB capture identity unavailable") }
        return try lock.withLock {
            guard !retired, readiness == .ready, let client, client.sessionID != nil else {
                throw AXDTX.Failure("USB input not ready; prepare explicitly, no Bluetooth fallback")
            }
            return client
        }
    }
    func gesture(_ operation: String, points: [USBTouchPoint], duration: Double) throws {
        try USBTouchRequest.validate(operation, points: points, duration: duration)
        let generation = lock.withLock { motionGeneration }
        try queue.sync {
            let accepted = lock.withLock { () -> Bool in
                guard !retired && !gestureHeld && motionGeneration == generation else { return false }
                synchronousGesture = true; return true
            }
            guard accepted else {
                throw AXDTX.Failure("USB pointer busy or stale gesture; replayAllowed=false")
            }
            defer { lock.withLock { synchronousGesture = false } }
            do { try current().send(operation, points: points, duration: duration) } catch { fail(error); throw error }
        }
    }
    func keyboard(_ strokes: [USBKeyboardStroke]) throws {
        if strokes.isEmpty { return }
        try USBKeyboardRequest.validate(strokes)
        let generation = lock.withLock { motionGeneration }
        try queue.sync { try performKeyboard(strokes, generation: generation) }
    }
    func type(_ request: TypeTextRequest, ocr: () -> ScreenOCR.Result?) throws {
        let strokes = try request.usbStrokes(ocr: ocr())
        // Validate the complete batch before clear_before or clipboard writes.
        if !strokes.isEmpty { try USBKeyboardRequest.validate(strokes) }
        guard isKeyboardReady else { throw AXDTX.Failure("USB keyboard not ready; no Bluetooth fallback") }
        for action in request.actions {
            if case .clipboard(let text) = action { try TextEntry.writeClipboard(text) }
        }
        try keyboard(strokes)
    }
    func key(_ name: String, modifiers: [String]) throws {
        try keyboard([USBKeyboardRequest.key(name, modifiers: modifiers)])
    }
    func typeFromKeyboard(_ text: String, modifiers: [String]) -> Bool {
        guard let strokes = try? USBKeyboardRequest.text(text, modifiers: modifiers) else { return false }
        return enqueueKeyboard(strokes)
    }
    func keyFromKeyboard(_ name: String, modifiers: [String]) -> Bool {
        guard let stroke = try? USBKeyboardRequest.key(name, modifiers: modifiers) else { return false }
        return enqueueKeyboard([stroke])
    }
    private func enqueueKeyboard(_ strokes: [USBKeyboardStroke]) -> Bool {
        guard isKeyboardReady else { return false }
        if strokes.isEmpty { return true }
        let generation = lock.withLock { motionGeneration }
        queue.async { [self] in try? performKeyboard(strokes, generation: generation) }
        return true
    }
    private func performKeyboard(_ strokes: [USBKeyboardStroke], generation: UInt64) throws {
        let accepted = lock.withLock { () -> Bool in
            guard !retired, !gestureHeld, motionGeneration == generation else { return false }
            synchronousGesture = true; return true
        }
        guard accepted else { throw AXDTX.Failure("USB keyboard busy or stale; replayAllowed=false") }
        defer { lock.withLock { synchronousGesture = false } }
        let active = try current()
        guard active.supportsKeyboard else { throw AXDTX.Failure("USB keyboard surface unavailable") }
        do { try active.send("keyboard", strokes: strokes) } catch { fail(error); throw error }
    }
    func scroll(at point: USBTouchPoint, delta: Double) {
        guard delta.isFinite, abs(delta) > 0.0001, let token = wheelGate.begin() else { return }
        let generation = lock.withLock { motionGeneration }
        queue.async { [self] in
            defer { wheelGate.finish(token) }
            guard wheelGate.isCurrent(token) else { return }
            let accepted = lock.withLock { () -> Bool in
                guard !gestureHeld && !retired && motionGeneration == generation else { return false }
                synchronousGesture = true; return true
            }
            guard accepted else { return }
            let end = USBTouchPoint(x: point.x, y: max(0.05, min(0.95, point.y + delta)))
            do {
                defer { lock.withLock { synchronousGesture = false } }
                try current().send("swipe", points: [point, end], duration: 0.18)
            } catch { fail(error) }
        }
    }
    func down(_ point: USBTouchPoint) {
        wheelGate.cancel()
        let generation = lock.withLock { () -> UInt64 in
            gestureHeld = true; pendingMotion = nil; motionScheduled = nil
            return motionGeneration
        }
        enqueue("down", point: point, generation: generation)
    }
    func move(_ point: USBTouchPoint) {
        let schedule = lock.withLock { () -> (UUID, UInt64)? in
            guard gestureHeld && !retired else { return nil }
            pendingMotion = point
            guard motionScheduled == nil else { return nil }
            let ticket = UUID(); motionScheduled = ticket
            return (ticket, motionGeneration)
        }
        if let (ticket, generation) = schedule {
            queue.async { [self] in
                let target = lock.withLock { () -> USBTouchPoint? in
                    guard motionScheduled == ticket else { return nil }
                    defer { pendingMotion = nil; motionScheduled = nil }; return pendingMotion
                }
                if let target { perform("move", point: target, generation: generation) }
            }
        }
    }
    func up(_ point: USBTouchPoint) {
        let generation = lock.withLock { () -> UInt64 in
            gestureHeld = false; pendingMotion = nil; motionScheduled = nil; return motionGeneration
        }
        enqueue("up", point: point, generation: generation)
    }
    func cancel() {
        wheelGate.cancel()
        let (generation, active) = lock.withLock { () -> (UInt64, USBTouchClient?) in
            gestureHeld = false; pendingMotion = nil; motionScheduled = nil; motionGeneration &+= 1
            return (motionGeneration, synchronousGesture ? client : nil)
        }
        if let active {
            // Closing stdin interrupts an in-flight tap/swipe immediately, not
            // after it finishes on the same serial command queue.
            active.close(); fail(AXDTX.Failure("USB gesture cancelled; explicitly reselect to prepare"))
            return
        }
        queue.async { [self] in
            guard lock.withLock({ motionGeneration == generation && !retired }) else { return }
            if let client = lock.withLock({ self.client }), client.sessionID != nil {
                do { try client.send("cancel") } catch { fail(error) }
            }
        }
    }
    private func enqueue(_ operation: String, point: USBTouchPoint, generation: UInt64) {
        queue.async { [self] in perform(operation, point: point, generation: generation) }
    }
    private func perform(_ operation: String, point: USBTouchPoint, generation: UInt64) {
        guard lock.withLock({ motionGeneration == generation && !retired }) else { return }
        do { try current().send(operation, points: [point]) } catch { fail(error) }
    }
    func retire() {
        wheelGate.cancel()
        let old = lock.withLock { () -> [USBTouchClient] in
            retired = true; readiness = .disconnected; gestureHeld = false; pendingMotion = nil; motionScheduled = nil
            return closingClients + (client.map { [$0] } ?? [])
        }
        for client in old { client.close() }
    }
    func retireAndWait() -> Bool {
        retire()
        return queue.sync {
            let clients = lock.withLock { closingClients + (client.map { [$0] } ?? []) }
            return clients.map { $0.closeAndWait() }.allSatisfy { $0 }
        }
    }
}

/// At most one queued/in-flight wheel swipe. Drop excess events rather than
/// replaying a backlog after the user has stopped scrolling or changed backend.
final class USBWheelGate {
    private let lock = NSLock()
    private var active: UUID?
    func begin() -> UUID? { lock.withLock {
        guard active == nil else { return nil }
        let token = UUID(); active = token; return token
    } }
    func isCurrent(_ token: UUID) -> Bool { lock.withLock { active == token } }
    func finish(_ token: UUID) { lock.withLock { if active == token { active = nil } } }
    func cancel() { lock.withLock { active = nil } }
}
