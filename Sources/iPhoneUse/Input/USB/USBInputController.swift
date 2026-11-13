import Foundation

/// One USB queue/session per complete physical identity. The registry remains
/// responsible for BLE matching; USB selection never asks it to fabricate a host.
final class USBInputController {
    static let shared = USBInputController()
    private let lock = NSLock()
    private var entries: [String: USBDeviceInput] = [:]
    private var selections: [String: InputBackendKind] = [:]
    private var generations: [String: UUID] = [:]

    func selectAtLaunch(physicalID: String) {
        lock.withLock { selections[physicalID] = .usb }
    }

    func selected(_ id: String) -> InputBackendKind { lock.withLock { selections[id] ?? .ble } }
    func input(_ device: Device) -> USBDeviceInput? {
        lock.withLock {
            guard selections[device.id] == .usb, let input = entries[device.id],
                  input.captureID == device.screen.associationIdentity else { return nil }
            return input
        }
    }
    func select(_ backend: InputBackendKind, device: Device) {
        // Publish generation change before allowing any new action. A retired
        // worker may finish its release only; no queued contact is reused.
        let generation = UUID()
        let previous = lock.withLock { () -> USBDeviceInput? in
            selections[device.id] = backend
            generations[device.id] = generation
            return entries.removeValue(forKey: device.id)
        }
        previous?.retire()
        DeviceRegistry.shared.cancelBackgroundMotion(for: device)
        if device.host != nil, let ble = try? DeviceRegistry.shared.input(for: device) { ble.cancelPointer() }
        guard backend == .usb else { return }
        let input = USBDeviceInput(device: device)
        let accepted = lock.withLock { () -> Bool in
            guard selections[device.id] == .usb, generations[device.id] == generation else { return false }
            entries[device.id] = input; return true
        }
        if accepted { input.prepare() } else { input.retire() }
    }
    func refresh(_ device: Device) {
        guard selected(device.id) == .usb else { return }
        if let entry = input(device) { entry.validateCapture(); return }
        select(.usb, device: device)
    }
    func status(_ device: Device) -> [String: Any] {
        guard selected(device.id) == .usb else { return ["backend": "ble"] }
        return input(device)?.status ?? ["backend": "usb", "state": "disconnected", "capabilities": []]
    }
    func stop() {
        let old = lock.withLock { () -> [USBDeviceInput] in
            let old = Array(entries.values); entries.removeAll(); return old
        }
        for entry in old { entry.retire() }
    }
}

final class USBDeviceInput {
    let physicalID: String
    let captureID: UUID
    private weak var screen: ScreenCaptureSession?
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var client: USBTouchClient?
    private var readiness: InputBackendReadiness = .preparing
    private var detail = ""
    private var retired = false
    private var pendingMotion: USBTouchPoint?
    private var motionScheduled = false
    private var gestureHeld = false
    private var motionGeneration: UInt64 = 0
    private var screenValid: Bool {
        guard let screen else { return false }
        let manager = ScreenCaptureManager.shared
        return manager.isCurrent(screen) && manager.permitsPointerAssociation(for: screen)
    }
    var isReady: Bool {
        lock.withLock { !retired && readiness == .ready && client?.sessionID != nil } && screenValid
    }
    var status: [String: Any] {
        let captureValid = screenValid
        return lock.withLock {
            let alive = captureValid && !retired && readiness == .ready && client?.sessionID != nil
            return ["backend": "usb", "state": !captureValid ? "identityUnverified" : (alive ? "ready" : (client?.error == nil ? readiness.rawValue : "failed")),
                    "capabilities": alive ? ["tap", "swipe", "drag"] : [],
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
                guard screenValid else { throw AXDTX.Failure("USB capture identity is not verified") }
                let fresh = try USBTouchClient(physicalID: physicalID)
                guard screenValid, let screen, let size = screen.size, let dimensions = fresh.dimensions,
                      Int(size.width) == dimensions.0, Int(size.height) == dimensions.1 else {
                    fresh.close(); throw AXDTX.Failure("USB display/capture identity or dimensions changed")
                }
                lock.withLock {
                    if retired { fresh.close() } else { client = fresh; readiness = .ready; detail = "" }
                }
            } catch { fail(error) }
        }
    }
    func validateCapture() { if !screenValid { retire() } }
    private func fail(_ error: Error) {
        let old = lock.withLock { () -> USBTouchClient? in
            readiness = .failed; detail = "\(error)"; let old = client; client = nil; gestureHeld = false; return old
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
        for point in points { try point.validate() }
        try queue.sync {
            guard !lock.withLock({ gestureHeld }) else { throw AXDTX.Failure("USB pointer is busy") }
            do { try current().send(operation, points: points, duration: duration) } catch { fail(error); throw error }
        }
    }
    func down(_ point: USBTouchPoint) {
        let generation = lock.withLock { () -> UInt64 in
            gestureHeld = true; motionGeneration &+= 1; return motionGeneration
        }
        enqueue("down", point: point, generation: generation)
    }
    func move(_ point: USBTouchPoint) {
        let schedule = lock.withLock { () -> Bool in
            guard gestureHeld && !retired else { return false }
            pendingMotion = point
            if motionScheduled { return false }; motionScheduled = true; return true
        }
        if schedule {
            let generation = lock.withLock { motionGeneration }
            queue.async { [self] in
                let target = lock.withLock { () -> USBTouchPoint? in
                    defer { pendingMotion = nil; motionScheduled = false }; return pendingMotion
                }
                if let target { perform("move", point: target, generation: generation) }
            }
        }
    }
    func up(_ point: USBTouchPoint) {
        let generation = lock.withLock { () -> UInt64 in
            gestureHeld = false; pendingMotion = nil; return motionGeneration
        }
        enqueue("up", point: point, generation: generation)
    }
    func cancel() {
        lock.withLock { gestureHeld = false; pendingMotion = nil; motionGeneration &+= 1 }
        queue.async { [self] in
            if let client = lock.withLock({ self.client }), client.sessionID != nil { try? client.send("cancel") }
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
        let old = lock.withLock { () -> USBTouchClient? in
            retired = true; readiness = .disconnected; gestureHeld = false; pendingMotion = nil
            let old = client; client = nil; return old
        }
        old?.close()
    }
}
