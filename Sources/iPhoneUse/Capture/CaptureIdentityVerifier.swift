import Foundation

enum ScreenCaptureIdentityState: String {
    case singleDevice
    case pending
    case verified
    case partiallyVerified
    /// The system device framework or the phones' screenshot services are unavailable.
    case unavailable
    /// Independent screenshots did not prove a reliable mapping.
    case failed

    func unconfirmedMessage(language: AppLanguage) -> String {
        let zh = language == .zh
        switch self {
        case .unavailable:
            return zh ? "画面校验服务不可用，已暂停操控" : "Display verification service unavailable. Control paused."
        case .failed, .partiallyVerified:
            return zh ? "未能确认此设备的画面，已暂停操控" : "This display could not be verified. Control paused."
        default:
            return zh ? "正在确认设备画面…" : "Verifying device display…"
        }
    }

    func permitsAssociation(identityVerified: Bool) -> Bool {
        switch self {
        case .singleDevice, .verified, .unavailable: true
        case .partiallyVerified: identityVerified
        case .pending, .failed: false
        }
    }
}

/// Subscription callbacks arrive separately for each HID report. Retry a
/// blocked capture identity once per new BLE session, never once per callback
/// or status poll. Disconnecting another phone does not restart verification.
struct CaptureIdentityRetrySchedule {
    private var sessions: [UUID: UUID] = [:]

    mutating func update(_ current: [UUID: UUID]) -> Bool {
        let hasNewSession = current.contains { sessions[$0.key] != $0.value }
        sessions = current
        return hasNewSession
    }
}

/// Failed identity checks must not become terminal while USB topology is stable.
/// Back off to one observation every 30 seconds; no pointer probes or per-frame work.
struct CaptureIdentityRecovery {
    static func delay(attempt: Int) -> TimeInterval {
        [3.0, 10.0, 30.0][min(2, max(0, attempt))]
    }

    static func permitsRetry(
        stopped: Bool, expected: UInt64, current: UInt64,
        sourceCount: Int, state: ScreenCaptureIdentityState
    ) -> Bool {
        !stopped && expected == current && sourceCount > 0
            && [.failed, .partiallyVerified, .unavailable].contains(state)
    }
}

/// A new frame can move a backed-off check earlier without leaving two jobs
/// for the same generation. A topology change always gets a fresh ticket.
struct CaptureIdentityCheckSchedule {
    private var nextTicket: UInt64 = 0
    private var pending: (generation: UInt64, deadline: DispatchTime, ticket: UInt64)?

    mutating func request(generation: UInt64, deadline: DispatchTime) -> UInt64? {
        if let pending, pending.generation == generation, pending.deadline <= deadline { return nil }
        nextTicket &+= 1
        pending = (generation, deadline, nextTicket)
        return nextTicket
    }

    mutating func take(ticket: UInt64) -> Bool {
        guard pending?.ticket == ticket else { return false }
        pending = nil
        return true
    }
}

/// Runs after topology changes, explicit retries or failed-check backoff. No
/// subprocess, screenshot, or comparison is performed on the video hot path.
enum CaptureIdentityVerifier {
    enum Result {
        case verified([String: String])
        case partiallyVerified([String: String])
        case unavailable
        case failed
    }

    enum Screenshot {
        case image(CaptureIdentityImage)
        case unavailable
        case failed
    }

    struct Evidence {
        var independent: [String: String] = [:]
        var contradicted: Set<String> = []
    }

    private struct Round {
        var candidates: [String: String] = [:]
        var unavailable: Set<String> = []
    }

    /// Bound the number of USB screenshot workers, not the number of phones.
    /// Sample immediately after each shot so a slow peer cannot age the image.
    private static func collectRound(
        pending: [String], ids: Set<String>, maxConcurrentScreenshots: Int,
        sourceImages: () -> [String: CaptureIdentityImage], isCurrent: () -> Bool,
        screenshot: (String) -> Screenshot
    ) -> Round {
        let workLock = NSLock()
        // CI rendering is much more memory intensive than comparing signatures.
        let frameLock = NSLock()
        var next = 0
        var round = Round()
        let workerCount = min(pending.count, max(1, maxConcurrentScreenshots))
        func work(_: Int) {
            while isCurrent() {
                let id = workLock.withLock { () -> String? in
                    guard next < pending.count else { return nil }
                    defer { next += 1 }
                    return pending[next]
                }
                guard let id, isCurrent() else { return }
                let shot = screenshot(id)
                guard isCurrent() else { return }
                switch shot {
                case .image(let image):
                    guard let frames = frameLock.withLock({ isCurrent() ? sourceImages() : nil }) else { return }
                    let candidate = CaptureIdentityMatcher.matchingSource(for: image, sources: frames, physicalIDs: ids)
                    workLock.withLock { round.candidates[id] = candidate }
                case .unavailable:
                    _ = workLock.withLock { round.unavailable.insert(id) }
                case .failed:
                    break
                }
            }
        }
        if workerCount == 1 { work(0) }
        else { DispatchQueue.concurrentPerform(iterations: workerCount, execute: work) }
        return round
    }

    /// Compare each screenshot with the latest frames immediately after its
    /// own capture, not after all the other devices have finished taking theirs.
    static func verify(
        physicalIDs: [String], sourceImages: () -> [String: CaptureIdentityImage],
        isCurrent: () -> Bool, waitForRetry: () -> Void = {}, retained: [String: String] = [:],
        reportEvidence: (Evidence) -> Void = { _ in }, maxConcurrentScreenshots: Int = 1,
        screenshot: (String) -> Screenshot
    ) -> Result {
        guard !physicalIDs.isEmpty, isCurrent() else { return .failed }
        let pending = physicalIDs.filter { retained[$0] == nil }
        guard !pending.isEmpty else { return .verified(retained) }
        let ids = Set(physicalIDs)
        var previous: [String: String]?
        var previousIndependent: [String: String] = [:]
        var previousConflicts: Set<String> = []
        for attempt in 0..<3 {
            if attempt > 0 { waitForRetry() }
            guard isCurrent() else { return .failed }
            let round = collectRound(
                pending: pending, ids: ids, maxConcurrentScreenshots: maxConcurrentScreenshots,
                sourceImages: sourceImages, isCurrent: isCurrent, screenshot: screenshot)
            guard isCurrent() else { return .failed }
            let candidates = round.candidates
            let unavailable = round.unavailable
            if unavailable.count == pending.count {
                return retained.isEmpty ? .unavailable : .partiallyVerified(retained)
            }
            let claimedSources = Set(candidates.values)
            let conflicts = Set(retained.filter { claimedSources.contains($0.value) }.keys)
            if !conflicts.isEmpty {
                // A repeated independent contradiction suspends only the affected
                // retained route. Never use it to infer another phone by exclusion.
                let repeated = conflicts.intersection(previousConflicts)
                if !repeated.isEmpty {
                    reportEvidence(.init(contradicted: repeated))
                    return .failed
                }
                previousConflicts = conflicts
                previous = nil
                previousIndependent = [:]
                continue
            }
            previousConflicts = []
            let independent = CaptureIdentityMatcher.uniqueMappings(candidates)
            var mapping = retained.merging(independent) { old, _ in old }
            if !independent.isEmpty, unavailable.count == 1, mapping.count + 1 == ids.count {
                mapping = CaptureIdentityMatcher.completingUnavailable(
                    mapping: mapping, physicalIDs: ids, sources: sourceImages(), unavailable: unavailable)
            }
            guard isCurrent() else { return .failed }
            if !mapping.isEmpty, previous == mapping {
                reportEvidence(.init(independent: independent.filter { previousIndependent[$0.key] == $0.value }))
                return mapping.count == ids.count ? .verified(mapping) : .partiallyVerified(mapping)
            }
            previous = mapping
            previousIndependent = independent
        }
        return retained.isEmpty ? .failed : .partiallyVerified(retained)
    }

    static func verify(
        physicalIDs: [String], sourceImages: () -> [String: CaptureIdentityImage],
        isCurrent: () -> Bool, retained: [String: String], reportEvidence: (Evidence) -> Void,
        screenshotTimeout: TimeInterval = 3
    ) -> Result {
        verify(
            physicalIDs: physicalIDs, sourceImages: sourceImages, isCurrent: isCurrent,
            waitForRetry: { Thread.sleep(forTimeInterval: 0.5) }, retained: retained,
            reportEvidence: reportEvidence, maxConcurrentScreenshots: 4,
            screenshot: { USBIdentityScreenshot.capture(physicalID: $0, timeout: screenshotTimeout) })
    }
}
