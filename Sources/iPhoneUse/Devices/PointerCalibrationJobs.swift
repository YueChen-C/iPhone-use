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
    }

    private var jobs: [String: Job] = [:]
    private var attempted: Set<Identity> = []

    mutating func begin(_ identity: Identity, retry: Bool) -> Bool {
        guard jobs[identity.screenID]?.running != true,
            retry || !attempted.contains(identity)
        else { return false }
        attempted.insert(identity)
        jobs[identity.screenID] = Job(identity: identity)
        return true
    }

    mutating func progress(_ identity: Identity, count: Int) {
        guard jobs[identity.screenID]?.identity == identity else { return }
        jobs[identity.screenID]?.measuredCounts = count
    }

    mutating func finish(
        _ identity: Identity, failure: String?, profile: RelativePointerCalibration? = nil, saved: Bool = false
    ) {
        guard jobs[identity.screenID]?.identity == identity else { return }
        jobs[identity.screenID]?.running = false
        jobs[identity.screenID]?.failure = failure
        jobs[identity.screenID]?.profile = profile
        jobs[identity.screenID]?.saved = saved
    }

    func isRunning(screenID: String) -> Bool { jobs[screenID]?.running == true }

    func status(screenID: String) -> [String: Any]? {
        guard let job = jobs[screenID] else { return nil }
        var result: [String: Any] = [
            "state": job.running ? "measuring" : (job.failure == nil ? "complete" : "unavailable"),
            "measuredCounts": job.measuredCounts,
            "totalCounts": 32,
        ]
        if let failure = job.failure { result["reason"] = failure }
        if let profile = job.profile {
            result["verified"] = true
            result["saved"] = job.saved
            result["distances"] = profile.distances
        }
        return result
    }
}
