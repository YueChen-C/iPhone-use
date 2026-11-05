import Foundation

/// Registry-lock protected bookkeeping. Repeated status/matching refreshes must
/// not launch concurrent measurements or continuously move a failing phone.
struct PointerCalibrationJobs {
    struct Identity: Hashable {
        let screenID: String
        let host: UUID
        let session: UUID
    }

    private struct Job {
        let identity: Identity
        var running = true
        var measuredCounts = 0
        var failure: String?
        var profile: RelativePointerCalibration?
        var saved = false
        var reused = false
        var rejectedExisting = false
        var attempts = 1
        var nextAttemptAt: TimeInterval = 0
        var userInterrupted = false
    }

    private var jobs: [String: Job] = [:]
    private var attempted: Set<Identity> = []
    private var verified: Set<Identity> = []

    mutating func begin(
        _ identity: Identity, retry: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard jobs[identity.screenID]?.running != true else { return false }
        let previous = jobs[identity.screenID]
        let sameSession = previous?.identity == identity
        if !retry, sameSession {
            guard previous?.failure != nil, previous?.userInterrupted != true, (previous?.attempts ?? 0) < 3,
                now >= (previous?.nextAttemptAt ?? 0)
            else { return false }
        } else if !retry, attempted.contains(identity) {
            return false
        }
        attempted.insert(identity)
        let rejected = hasRejectedCalibration(identity)
        jobs[identity.screenID] = Job(
            identity: identity, rejectedExisting: rejected,
            attempts: !retry && sameSession ? (previous?.attempts ?? 0) + 1 : 1)
        return true
    }

    mutating func progress(_ identity: Identity, count: Int) {
        guard jobs[identity.screenID]?.identity == identity else { return }
        jobs[identity.screenID]?.measuredCounts = count
    }

    mutating func rejectExisting(_ identity: Identity) {
        guard jobs[identity.screenID]?.identity == identity else { return }
        jobs[identity.screenID]?.rejectedExisting = true
    }

    func hasRejectedCalibration(_ identity: Identity) -> Bool {
        jobs[identity.screenID]?.rejectedExisting == true
    }

    mutating func clearRejection(screenID: String) {
        jobs[screenID]?.rejectedExisting = false
    }

    mutating func finish(
        _ identity: Identity, failure: String?, profile: RelativePointerCalibration? = nil,
        saved: Bool = false, reused: Bool = false, userInterrupted: Bool = false,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard jobs[identity.screenID]?.identity == identity else { return }
        jobs[identity.screenID]?.running = false
        jobs[identity.screenID]?.failure = failure
        jobs[identity.screenID]?.userInterrupted = userInterrupted
        let attempts = jobs[identity.screenID]?.attempts ?? 1
        jobs[identity.screenID]?.nextAttemptAt = now + (attempts == 1 ? 3 : 12)
        jobs[identity.screenID]?.profile = profile
        jobs[identity.screenID]?.saved = saved
        jobs[identity.screenID]?.reused = reused
        if failure == nil, saved || reused {
            jobs[identity.screenID]?.rejectedExisting = false
            verified = verified.filter { $0.screenID != identity.screenID }
            verified.insert(identity)
        }
    }

    mutating func invalidate(screenID: String) {
        // Explicit profile reload must not inherit proof for different file contents.
        jobs[screenID] = nil
        attempted = attempted.filter { $0.screenID != screenID }
        verified = verified.filter { $0.screenID != screenID }
    }

    func isVerified(_ identity: Identity) -> Bool {
        verified.contains(identity) && !hasRejectedCalibration(identity)
    }

    func isRunning(screenID: String) -> Bool { jobs[screenID]?.running == true }

    func status(screenID: String) -> [String: Any]? {
        guard let job = jobs[screenID] else { return nil }
        var result: [String: Any] = [
            "state": job.running ? "measuring" : (job.failure == nil ? "complete" : "unavailable"),
            "measuredCounts": job.measuredCounts,
            "totalCounts": 32,
            "attempts": job.attempts,
            "automaticRetryPending": !job.running && job.failure != nil && !job.userInterrupted && job.attempts < 3,
            "rejectedExisting": job.rejectedExisting,
        ]
        if let failure = job.failure { result["reason"] = failure }
        if let profile = job.profile {
            result["verified"] = true
            result["saved"] = job.saved
            result["reused"] = job.reused
            result["distances"] = profile.distances
        }
        return result
    }
}
