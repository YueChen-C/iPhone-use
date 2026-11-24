import Foundation

/// Full physical identity owns selection and retirement. Switching is off the
/// AppKit thread; neither backend may send while the previous one is retiring.
final class USBInputController {
    static let shared = USBInputController(preferences: .shared) { id, retry in
        DeviceRegistry.shared.bluetoothRouteDidChange(id, retry: retry)
    }
    private let lock = NSLock()
    private var transitions: [String: DispatchQueue] = [:]
    private var entries: [String: USBDeviceInput] = [:]
    private var retiring: [String: [USBDeviceInput]] = [:]
    private var selections: [String: InputBackendSelection] = [:]
    private var selectionRequests: [String: UUID] = [:]
    private var refreshing: Set<String> = []
    private var defaultInspections: [String: UUID] = [:]
    private var inspectingDefault: [String: UUID] = [:]
    private let transitionWork = DispatchGroup()
    private var stopped = false
    private var shutdownWork: DispatchGroup?
    private var shutdownReleased = false
    private let requireUSB: (String) throws -> Void
    private let preferences: InputBackendPreferences?
    private let bluetoothRouteChanged: (String, Bool) -> Void

    init(requireUSB: @escaping (String) throws -> Void = USBBackendCompatibility.require,
         preferences: InputBackendPreferences? = nil,
         bluetoothRouteChanged: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.requireUSB = requireUSB
        self.preferences = preferences
        self.bluetoothRouteChanged = bluetoothRouteChanged
        for (id, backend) in preferences?.load() ?? [:] {
            var state = InputBackendSelection()
            let generation = state.begin(backend)
            state.finish(generation, released: true)
            selections[id] = state
            // Saved choices beat discovery metadata, just like current choices.
            selectionRequests[id] = UUID()
        }
    }

    func selectAtLaunch(physicalID: String) throws {
        let ticket = try checkSelection(.usb, id: physicalID)
        // Capture refresh will prepare USB after identity becomes verified.
        let accepted = lock.withLock { () -> Bool in
            guard !stopped, selectionRequests[physicalID] == ticket else { return false }
            var state = InputBackendSelection()
            let id = state.begin(.usb); state.finish(id, released: true)
            selections[physicalID] = state
            return true
        }
        guard accepted else { throw USBInputFailure(.staleSession, "USB selection cancelled or superseded; no replay") }
    }
    func selected(_ id: String) -> InputBackendKind { lock.withLock { selections[id]?.backend ?? .ble } }
    /// Metadata chooses a route, not readiness. No USB worker/input is usable
    /// until refresh performs the normal release, identity and service gates.
    /// Even an in-flight explicit choice wins over a late version inspection.
    @discardableResult
    func applyDefault(physicalID: String, version: String) -> Bool {
        guard InputBackendKind.defaultForIOSVersion(version) == .usb else { return false }
        let changed = lock.withLock {
            guard !stopped, selectionRequests[physicalID] == nil,
                  entries[physicalID] == nil, selections[physicalID]?.backend != .usb else { return false }
            var state = selections[physicalID] ?? InputBackendSelection()
            let generation = state.begin(.usb)
            state.finish(generation, released: true)
            selections[physicalID] = state
            return true
        }
        if changed { bluetoothRouteChanged(physicalID, false) }
        return changed
    }
    func generation(_ id: String) -> UUID { lock.withLock {
        if selections[id] == nil { selections[id] = InputBackendSelection() }
        return selections[id]!.generation
    } }
    func permitsBLE(_ id: String, generation: UUID?) -> Bool {
        lock.withLock { !stopped && (selections[id]?.permits(.ble, generation: generation) ?? (generation == nil)) }
    }
    /// Do not wake BLE during version detection, just before discovering that
    /// a new phone defaults to USB. A saved or explicit choice wins.
    func permitsBluetoothReconnect(_ id: String, requiresKnownBackend: Bool = false) -> Bool {
        lock.withLock {
            let explicit = selectionRequests[id] != nil
            guard !stopped, inspectingDefault[id] == nil || explicit else { return false }
            if requiresKnownBackend, !explicit, defaultInspections[id] == nil { return false }
            return selections[id]?.permits(.ble) ?? true
        }
    }
    func input(_ device: Device) -> USBDeviceInput? {
        lock.withLock {
            guard !stopped, selections[device.id]?.permits(.usb) == true, let input = entries[device.id],
                  !input.isRetired, input.captureID == device.screen.associationIdentity else { return nil }
            return input
        }
    }
    private func checkSelection(_ backend: InputBackendKind, id: String,
                                request: USBBackendSelectionRequest? = nil, expectedGeneration: UUID? = nil) throws -> UUID {
        let ticket = UUID()
        let checking = lock.withLock { () -> Bool in
            guard !stopped, request?.isCancelled != true,
                  expectedGeneration == nil || selections[id]?.generation == expectedGeneration else { return false }
            selectionRequests[id] = ticket
            return true
        }
        guard checking else { throw USBInputFailure(.staleSession, "USB selection cancelled or superseded; no replay") }
        if backend == .usb {
            do { try requireUSB(id) }
            catch let error as USBBackendCompatibility.Failure {
                let code: USBInputFailure.Code
                if case .unsupported = error { code = .unsupported } else { code = .notReady }
                throw USBInputFailure(code, error.description)
            }
        }
        return ticket
    }
    func select(_ backend: InputBackendKind, device: Device,
                request: USBBackendSelectionRequest? = nil, expectedGeneration: UUID? = nil) throws {
        // Do not inspect a provisional/obsolete capture. Recheck after the
        // child returns: identity may have changed while reading the device.
        func requireCurrentCapture() throws {
            guard ScreenCaptureManager.shared.isCurrent(device.screen),
                  backend != .usb || ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen) else {
                throw USBInputFailure(.staleSession, StringsUSBControl.current.guidance(.identity))
            }
        }
        try requireCurrentCapture()
        let ticket = try checkSelection(backend, id: device.id, request: request, expectedGeneration: expectedGeneration)
        try requireCurrentCapture()
        let admitted = lock.withLock { () -> (UUID, USBDeviceInput?, DispatchQueue)? in
            guard !stopped, request?.isCancelled != true, selectionRequests[device.id] == ticket,
                  expectedGeneration == nil || selections[device.id]?.generation == expectedGeneration else { return nil }
            var state = selections[device.id] ?? InputBackendSelection()
            let generation = state.begin(backend); selections[device.id] = state
            if expectedGeneration == nil {
                preferences?.save(backend, physicalID: device.id)
            }
            let previous = entries.removeValue(forKey: device.id)
            if let previous { retiring[device.id, default: []].append(previous) }
            let queue = transitions[device.id] ?? DispatchQueue(label: "iphone-use.input-transition.\(device.id)")
            transitions[device.id] = queue
            // Register before dropping the admission lock: shutdown must also
            // drain transitions that have not reached their queue yet.
            transitionWork.enter()
            return (generation, previous, queue)
        }
        guard let (generation, previous, transitionQueue) = admitted else {
            throw USBInputFailure(.staleSession, "USB selection cancelled or superseded; no replay")
        }
        if expectedGeneration == nil { bluetoothRouteChanged(device.id, false) }
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
            if accepted {
                input?.prepare()
                if backend == .ble { bluetoothRouteChanged(device.id, true) }
            } else { input?.retire() }
        }
    }
    func refresh(_ device: Device) {
        let allowed = lock.withLock { !stopped && selections[device.id]?.permits(.usb) == true }
        guard allowed else { return }
        if let entry = input(device) { entry.validateCapture(); return }
        // Startup capture objects exist before physical/display identity is
        // confirmed. Wait without inspecting or latching a preparation failure.
        guard ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen) else { return }
        // Launch selection also needs preflight, without blocking a 30Hz UI tick
        // or launching duplicate inspections before the first one completes.
        let generation = lock.withLock { () -> UUID? in
            guard !stopped, selections[device.id]?.permits(.usb) == true,
                  refreshing.insert(device.id).inserted else { return nil }
            return selections[device.id]?.generation
        }
        guard let generation else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { _ = lock.withLock { refreshing.remove(device.id) } }
            do { try select(.usb, device: device, expectedGeneration: generation) }
            catch {
                // An obsolete discovery result is not a failure of the saved
                // USB choice. The next current verified capture may prepare;
                // no click, key or text request is queued or replayed here.
                guard (error as? USBInputFailure)?.code != .staleSession,
                      ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen) else {
                    log("USB preparation deferred for \(device.id): \(error)")
                    return
                }
                lock.withLock {
                    // Keep the selected route and surface its failure. A USB
                    // default must never silently fall back to Bluetooth.
                    if !stopped, selections[device.id]?.generation == generation, entries[device.id] == nil {
                        selections[device.id]?.fail(generation, message: String(describing: error))
                    }
                }
                log("USB selection refused for \(device.id): \(error)")
            }
        }
    }
    /// Capture removal or identity replacement retires only its own input.
    /// Temporary gates release held input without retiring an idle transport.
    /// Validate even when no control window is polling. Keep each entry owned until explicit
    /// selection/shutdown can confirm release and exit. New capture metadata may
    /// choose a default and prepare its route, but never replay any user input.
    /// Do not hold our lock across capture reads.
    func captureDidChange() {
        let current = lock.withLock { stopped ? [] : Array(entries.values) }
        for input in current { input.validateCapture() }
        // Restored USB preferences must prepare in quiet mode too; no visible
        // PhoneControlView is required to poll them into readiness.
        for device in DeviceRegistry.shared.all() where selected(device.id) == .usb {
            refresh(device)
        }
        // One read-only inspection per capture lifetime, off AppKit/video paths.
        // This also applies in quiet mode, before any workbench is opened.
        for screen in ScreenCaptureManager.shared.all {
            let inspect = lock.withLock { () -> Bool in
                guard !stopped, selectionRequests[screen.id] == nil,
                      defaultInspections[screen.id] != screen.associationIdentity else { return false }
                defaultInspections[screen.id] = screen.associationIdentity
                inspectingDefault[screen.id] = screen.associationIdentity
                return true
            }
            guard inspect else { continue }
            DispatchQueue.global(qos: .utility).async { [self] in
                defer {
                    let current = lock.withLock {
                        guard inspectingDefault[screen.id] == screen.associationIdentity else { return false }
                        inspectingDefault[screen.id] = nil
                        return !stopped
                    }
                    if current { bluetoothRouteChanged(screen.id, false) }
                }
                guard let version = try? USBBackendCompatibility.version(physicalID: screen.id),
                      ScreenCaptureManager.shared.isCurrent(screen),
                      applyDefault(physicalID: screen.id, version: version),
                      let device = DeviceRegistry.shared.all().first(where: { $0.screen === screen }) else { return }
                log("Default input USB for iOS \(version): \(screen.id)")
                refresh(device)
            }
        }
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
    private weak var boundScreen: ScreenCaptureSession?
    private var screen: ScreenCaptureSession? { lock.withLock { boundScreen } }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var client: USBTouchClient?
    private var preparationStarted = false
    private var readiness: InputBackendReadiness = .preparing
    private var preparationFailure: USBPreparationFailure?
    private var retired = false
    private var capturePaused = false
    var isRetired: Bool { lock.withLock { retired } }
    private var pendingMotion: USBTouchPoint?
    private var motionScheduled: UUID?
    private var admission = USBWindowInputAdmission()
    private var synchronousGesture = false
    private let wheelGate = USBWheelGate()
    private let keyboardGate = USBKeyboardGate()
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
    var isButtonsReady: Bool { isReady && lock.withLock { client?.supportsButtons == true } }
    var status: [String: Any] {
        let captureValid = screenValid
        return lock.withLock {
            let alive = captureValid && !retired && readiness == .ready && client?.sessionID != nil
            let failure = retired ? nil : (preparationFailure ?? client?.error)
            var result: [String: Any] = ["backend": "usb", "state": !captureValid ? "identityUnverified" : (alive ? "ready" : (failure?.readiness.rawValue ?? readiness.rawValue)),
                    "capabilities": alive ? ["tap", "swipe", "drag"] + (client?.supportsKeyboard == true ? ["text", "key"] : []) + (client?.supportsButtons == true ? USBHardwareButton.allCases.map(\.rawValue) : []) : [],
                    "requiresCalibration": false, "sessionCurrent": alive, "detail": failure?.description ?? ""]
            if !captureValid { result["reason"] = USBPreparationFailure.Reason.identityMismatch.rawValue }
            else if !alive, let failure { result["reason"] = failure.reason.rawValue }
            return result
        }
    }
    init(device: Device) {
        physicalID = device.id; captureID = device.screen.associationIdentity; boundScreen = device.screen
        queue = DispatchQueue(label: "iphone-use.usb-input.\(device.id)")
    }
    func prepare() {
        guard lock.withLock({
            if retired || preparationStarted { return false }
            preparationStarted = true; return true
        }) else { return }
        queue.async { [self] in
            do {
                guard !lock.withLock({ retired }) else { return }
                guard screenValid else { throw USBPreparationFailure(.identityMismatch, "USB capture identity is not verified") }
                let fresh = try USBTouchClient(physicalID: physicalID)
                // A failed capture/dimension check still owns a live worker;
                // retain it for shutdown/transition release confirmation.
                lock.withLock {
                    client = fresh
                    if retired { fresh.close() }
                }
                try fresh.waitUntilReady()
                guard screenValid, let screen, let size = screen.size, let dimensions = fresh.dimensions,
                      Int(size.width) == dimensions.0, Int(size.height) == dimensions.1 else {
                    fresh.close(); throw USBPreparationFailure(.identityMismatch, "USB display/capture identity or dimensions changed")
                }
                lock.withLock {
                    if retired { fresh.close() } else { readiness = .ready; preparationFailure = nil }
                }
            } catch { fail(error) }
        }
    }
    func validateCapture() {
        let manager = ScreenCaptureManager.shared
        guard let current = manager.all.first(where: {
            $0.id == physicalID && $0.associationIdentity == captureID
        }) else { retire(); return }
        let rebound = lock.withLock { () -> Bool in
            guard boundScreen !== current else { return false }
            boundScreen = current
            return true
        }
        let valid = screenValid
        let action = lock.withLock { () -> (cancel: Bool, retire: Bool) in
            let wasPaused = capturePaused
            capturePaused = !valid
            let cancel = (rebound || (!valid && !wasPaused)) && !retired
            return (cancel, cancel && synchronousGesture)
        }
        // Temporary identity checks release held input without discarding an
        // idle exact-device transport. Interrupting a synchronous gesture does
        // close its worker: retire it so refresh can prepare after confirmed release.
        if action.retire { retire() }
        else if action.cancel { cancel() }
    }
    private func fail(_ error: Error) {
        keyboardGate.cancel()
        lock.withLock {
            let failure = USBPreparationFailure(error)
            readiness = failure.readiness; preparationFailure = failure; admission.clearWindow()
            client?.close()
        }
    }
    private func current() throws -> USBTouchClient {
        guard screenValid else { throw USBInputFailure(.notReady, "USB capture identity unavailable") }
        return try lock.withLock {
            guard !retired, readiness == .ready, let client, client.sessionID != nil else {
                throw USBInputFailure(.notReady, "USB input not ready; prepare explicitly, no Bluetooth fallback")
            }
            return client
        }
    }
    private func reserveOperation() throws -> (UInt64, UUID) {
        try lock.withLock {
            guard !retired else { throw USBInputFailure(.staleSession, "USB input session retired") }
            guard let ticket = admission.beginOperation() else {
                throw USBInputFailure(.busy, "USB pointer busy or release pending")
            }
            return (motionGeneration, ticket)
        }
    }
    private func withOperation(_ perform: (UInt64) throws -> Void) throws {
        let (generation, ticket) = try reserveOperation()
        defer { finishOperation(ticket) }
        try queue.sync { try perform(generation) }
    }
    private func finishOperation(_ ticket: UUID) { lock.withLock { admission.finishOperation(ticket) } }
    func gesture(_ operation: String, points: [USBTouchPoint], duration: Double) throws {
        try USBTouchRequest.validate(operation, points: points, duration: duration)
        try withOperation { generation in
            guard beginSynchronousInput(generation: generation) else {
                throw USBInputFailure(.staleSession, "USB gesture session changed before dispatch")
            }
            defer { lock.withLock { synchronousGesture = false } }
            do { try current().send(operation, points: points, duration: duration) } catch { fail(error); throw error }
        }
    }
    func keyboard(_ strokes: [USBKeyboardStroke]) throws {
        if strokes.isEmpty { return }
        try USBKeyboardRequest.validate(strokes)
        try withOperation { try performKeyboard(strokes, generation: $0) }
    }
    func button(_ button: USBHardwareButton) throws {
        try withOperation { try performButton(button, generation: $0) }
    }
    private func performButton(_ button: USBHardwareButton, generation: UInt64) throws {
        guard beginSynchronousInput(generation: generation) else {
            throw USBInputFailure(.staleSession, "USB button session changed before dispatch")
        }
        defer { lock.withLock { synchronousGesture = false } }
        let active = try current()
        guard active.supportsButtons else { throw USBInputFailure(.unsupported, "USB Indigo button service unavailable") }
        do { try active.send(button.rawValue) } catch { fail(error); throw error }
    }
    func buttonFromWindow(_ button: USBHardwareButton,
                          completion: ((Result<Void, Error>) -> Void)? = nil) -> Bool {
        guard isButtonsReady else { return false }
        return enqueueWindowInput(cost: 1, completion: completion) { try self.performButton(button, generation: $0) }
    }
    func type(_ request: TypeTextRequest, ocr: () -> USBKeyboardObservation?) throws {
        try withOperation { generation in
            var dispatched = false
            do {
                try withKeyboardSession(generation: generation) { active in
                    try request.performUSB(ocr: ocr,
                        checkCurrent: { try self.checkKeyboardSession(active, generation: generation) },
                        send: { strokes in
                            try self.sendKeyboard(strokes, on: active, generation: generation)
                            dispatched = true
                        })
                }
            } catch let error as USBInputFailure {
                // An acknowledged earlier batch (e.g. IME toggle or pinyin)
                // remains input even if the next lease check sends nothing.
                throw error.includingPriorInput(dispatched)
            }
        }
    }
    func key(_ name: String, modifiers: [String]) throws {
        try keyboard([USBKeyboardRequest.key(name, modifiers: modifiers)])
    }
    func typeFromKeyboard(_ text: String, modifiers: [String]) -> Bool {
        guard let strokes = try? USBKeyboardRequest.text(text, modifiers: modifiers) else { return false }
        return enqueueKeyboard(strokes)
    }
    func keyFromKeyboard(_ name: String, modifiers: [String],
                         completion: ((Result<Void, Error>) -> Void)? = nil) -> Bool {
        guard let stroke = try? USBKeyboardRequest.key(name, modifiers: modifiers) else { return false }
        return enqueueKeyboard([stroke], completion: completion)
    }
    private func enqueueKeyboard(_ strokes: [USBKeyboardStroke],
                                 completion: ((Result<Void, Error>) -> Void)? = nil) -> Bool {
        guard isKeyboardReady else { return false }
        if strokes.isEmpty { return true }
        return enqueueWindowInput(cost: strokes.count, completion: completion) { try self.performKeyboard(strokes, generation: $0) }
    }
    /// Keyboard and Indigo buttons share admission, bounded expiry and invalidation.
    private func enqueueWindowInput(cost: Int, completion: ((Result<Void, Error>) -> Void)?,
                                    perform: @escaping (UInt64) throws -> Void) -> Bool {
        guard let ticket = keyboardGate.begin(strokes: cost) else { return false }
        guard let (generation, operation) = try? reserveOperation() else { keyboardGate.finish(ticket); return false }
        queue.async { [self] in
            defer { keyboardGate.finish(ticket); finishOperation(operation) }
            guard keyboardGate.isCurrent(ticket) else {
                completion?(.failure(USBInputFailure(.staleSession, "USB window input expired or cancelled; no replay")))
                return
            }
            do { try perform(generation); completion?(.success(())) }
            catch { completion?(.failure(error)) }
        }
        return true
    }
    private func performKeyboard(_ strokes: [USBKeyboardStroke], generation: UInt64) throws {
        try withKeyboardSession(generation: generation) { active in
            try sendKeyboard(strokes, on: active, generation: generation)
        }
    }
    /// Shared dispatch boundary for API gestures, keyboard batches and wheel work.
    /// Cancellation closes the active worker while this flag is set.
    private func beginSynchronousInput(generation: UInt64) -> Bool {
        lock.withLock {
            guard !retired, !admission.held, !admission.releasing, motionGeneration == generation else { return false }
            synchronousGesture = true; return true
        }
    }
    private func withKeyboardSession(generation: UInt64, perform: (USBTouchClient) throws -> Void) throws {
        guard beginSynchronousInput(generation: generation) else {
            throw USBInputFailure(.staleSession, "USB keyboard session changed before dispatch")
        }
        defer { lock.withLock { synchronousGesture = false } }
        let active = try current()
        guard active.supportsKeyboard else { throw USBInputFailure(.unsupported, "USB keyboard surface unavailable") }
        try perform(active)
    }
    private func checkKeyboardSession(_ active: USBTouchClient, generation: UInt64) throws {
        guard lock.withLock({ !retired && !admission.held && !admission.releasing && motionGeneration == generation }),
            try current() === active else {
            throw USBInputFailure(.staleSession, "USB keyboard session changed before dispatch")
        }
    }
    private func sendKeyboard(_ strokes: [USBKeyboardStroke], on active: USBTouchClient, generation: UInt64) throws {
        try checkKeyboardSession(active, generation: generation)
        do { try active.send("keyboard", strokes: strokes) } catch { fail(error); throw error }
    }
    func scroll(at point: USBTouchPoint, delta: Double) {
        guard delta.isFinite, abs(delta) > 0.0001, let token = wheelGate.begin() else { return }
        guard let (generation, operation) = try? reserveOperation() else { wheelGate.finish(token); return }
        queue.async { [self] in
            defer { wheelGate.finish(token); finishOperation(operation) }
            guard wheelGate.isCurrent(token) else { return }
            guard beginSynchronousInput(generation: generation) else { return }
            defer { lock.withLock { synchronousGesture = false } }
            let end = USBTouchPoint(x: point.x, y: max(0.05, min(0.95, point.y + delta)))
            do { try current().send("swipe", points: [point, end], duration: 0.18) } catch { fail(error) }
        }
    }
    @discardableResult
    func down(_ point: USBTouchPoint) -> Bool {
        guard (try? point.validate()) != nil, isReady else { return false }
        let generation = lock.withLock { () -> UInt64? in
            // Reserve before enqueue, not when the old API operation finishes.
            // A rejected mouse-down owns no move/up and is never replayed.
            guard !retired, admission.beginWindow() else { return nil }
            pendingMotion = nil; motionScheduled = nil
            return motionGeneration
        }
        guard let generation else { return false }
        wheelGate.cancel()
        keyboardGate.cancel()
        enqueue("down", point: point, generation: generation)
        return true
    }
    func move(_ point: USBTouchPoint) {
        let schedule = lock.withLock { () -> (UUID, UInt64)? in
            guard admission.held && !retired else { return nil }
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
        let work = lock.withLock { () -> (UInt64, UUID)? in
            guard !retired, let ticket = admission.endWindow() else { return nil }
            pendingMotion = nil; motionScheduled = nil; return (motionGeneration, ticket)
        }
        guard let (generation, ticket) = work else { return }
        queue.async { [self] in
            defer { lock.withLock { admission.finishRelease(ticket) } }
            perform("up", point: point, generation: generation)
        }
    }
    func cancel() {
        wheelGate.cancel()
        keyboardGate.cancel()
        let (generation, ticket, active) = lock.withLock { () -> (UInt64, UUID, USBTouchClient?) in
            pendingMotion = nil; motionScheduled = nil; motionGeneration &+= 1
            return (motionGeneration, admission.cancelWindow(), synchronousGesture ? client : nil)
        }
        if let active {
            // Closing stdin interrupts an in-flight tap/swipe immediately, not
            // after it finishes on the same serial command queue.
            active.close(); fail(AXDTX.Failure("USB gesture cancelled; explicitly reselect to prepare"))
            return
        }
        queue.async { [self] in
            defer { lock.withLock { admission.finishRelease(ticket) } }
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
        keyboardGate.cancel()
        lock.withLock {
            retired = true; readiness = .disconnected; admission.clearWindow(); pendingMotion = nil; motionScheduled = nil
            client?.close()
        }
    }
    func retireAndWait() -> Bool {
        retire()
        return queue.sync { lock.withLock { client }?.closeAndWait() ?? true }
    }
}

/// Lock-confined admission, independent of the serial worker queue. Window
/// presses never wait behind admitted API/keyboard/wheel work, or a prior up's
/// release/PING. Old completions cannot reopen a newer release barrier.
struct USBWindowInputAdmission {
    private(set) var held = false
    private var release: UUID?
    private var operations: Set<UUID> = []
    var releasing: Bool { release != nil }
    mutating func beginOperation() -> UUID? {
        guard !held, !releasing else { return nil }
        let ticket = UUID(); operations.insert(ticket); return ticket
    }
    mutating func finishOperation(_ ticket: UUID) { operations.remove(ticket) }
    mutating func beginWindow() -> Bool {
        guard !held, !releasing, operations.isEmpty else { return false }
        held = true; return true
    }
    mutating func endWindow() -> UUID? {
        guard held else { return nil }
        return cancelWindow()
    }
    mutating func cancelWindow() -> UUID {
        held = false
        let ticket = UUID(); release = ticket; return ticket
    }
    mutating func finishRelease(_ ticket: UUID) { if release == ticket { release = nil } }
    mutating func clearWindow() { held = false; release = nil }
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
