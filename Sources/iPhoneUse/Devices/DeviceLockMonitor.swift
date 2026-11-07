import CoreVideo
import Foundation

/// Results are scoped to one physical phone and capture source. Old observations
/// cannot survive a remap/reconnect, and stale frames never keep a hint alive.
struct DeviceLockObservations {
    struct Request: Equatable {
        let physicalID: String
        let generation: UInt64
    }
    private struct Entry {
        var generation: UInt64
        let captureID: UUID
        var pending = false
        var state: DeviceLockState = .unknown
        var consecutiveMatches = 0
        var observedAt: TimeInterval?
        var awaitingUsableFrame = false
    }
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0

    mutating func requests(for captures: [String: UUID]) -> [Request] {
        entries = entries.filter { captures[$0.key] == $0.value.captureID }
        return captures.keys.sorted().compactMap { id in
            if entries[id] == nil, let captureID = captures[id] {
                entries[id] = Entry(generation: generation, captureID: captureID)
            }
            guard var entry = entries[id], !entry.pending else { return nil }
            generation &+= 1
            entry.generation = generation
            entry.pending = true
            entries[id] = entry
            return Request(physicalID: id, generation: entry.generation)
        }
    }

    /// A confirmed lock or paused capture gets one discovery retry when a
    /// usable unlocked frame returns, rather than polling with pointer motion.
    @discardableResult
    mutating func complete(_ request: Request, state: DeviceLockState, now: TimeInterval) -> Bool {
        guard var entry = entries[request.physicalID], entry.generation == request.generation, entry.pending
        else { return false }
        entry.pending = false
        let fresh = entry.observedAt.map { now - $0 < 8 } ?? false
        entry.consecutiveMatches = state == .suspected ? (fresh ? min(2, entry.consecutiveMatches + 1) : 1) : 0
        entry.state = state == .suspected && entry.consecutiveMatches < 2 ? .unknown : state
        entry.observedAt = now
        if entry.state == .suspected || entry.state == .paused { entry.awaitingUsableFrame = true }
        let retryMatching = entry.awaitingUsableFrame && state == .notDetected
        if retryMatching { entry.awaitingUsableFrame = false }
        entries[request.physicalID] = entry
        return retryMatching
    }

    func state(for physicalID: String, captureID: UUID? = nil, now: TimeInterval) -> DeviceLockState {
        guard let entry = entries[physicalID], let observedAt = entry.observedAt,
            captureID == nil || captureID == entry.captureID,
            now - observedAt < 8
        else { return .unknown }
        return entry.state
    }
}

final class DeviceLockMonitor {
    static let shared = DeviceLockMonitor()
    private let lock = NSLock()
    private var observations = DeviceLockObservations()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "iphone-use.device-lock-monitor", qos: .utility)
    var onUsableFrameRestored: ((String) -> Void)?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let screens = ScreenCaptureManager.shared.all
            let captures = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.sourceInstanceID) })
            let requests = self.lock.withLock { self.observations.requests(for: captures) }
            for request in requests {
                // Use the verified screen mapping, never a nominal AVFoundation
                // UID. No OCR or image conversion runs on a video callback.
                let screen = screens.first { $0.id == request.physicalID }
                let state: DeviceLockState
                let manager = ScreenCaptureManager.shared
                if let screen, manager.identityState == .singleDevice || manager.identityVerified(for: screen),
                    let snapshot = screen.observationFrame()
                {
                    if ProcessInfo.processInfo.systemUptime - snapshot.receivedAt > 5 {
                        state = .paused
                    } else {
                        state = autoreleasepool { LockScreenRecognition.read(snapshot.buffer) }
                    }
                } else {
                    state = .unknown
                }
                let retryMatching = self.lock.withLock {
                    self.observations.complete(request, state: state, now: ProcessInfo.processInfo.systemUptime)
                }
                if retryMatching { self.onUsableFrameRestored?(request.physicalID) }
            }
        }
        self.timer = timer
        timer.resume()
    }

    func state(for screen: ScreenCaptureSession) -> DeviceLockState {
        let manager = ScreenCaptureManager.shared
        guard manager.isCurrent(screen), manager.identityState == .singleDevice || manager.identityVerified(for: screen)
        else { return .unknown }
        return lock.withLock {
            observations.state(
                for: screen.id, captureID: screen.sourceInstanceID, now: ProcessInfo.processInfo.systemUptime)
        }
    }
}
