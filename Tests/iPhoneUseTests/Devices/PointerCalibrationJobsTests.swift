import XCTest

@testable import iPhoneUse

final class PointerCalibrationJobsTests: XCTestCase {
    func testForegroundTakeoverStopsAutomaticRetriesUntilExplicitRetryOrNewSession() {
        var jobs = PointerCalibrationJobs()
        let id = PointerCalibrationJobs.Identity(screenID: "phone", host: UUID(), session: UUID())
        XCTAssertTrue(jobs.begin(id, retry: false, now: 0))
        jobs.finish(id, failure: "interrupted", userInterrupted: true, now: 1)
        XCTAssertFalse(jobs.status(screenID: "phone")?["automaticRetryPending"] as? Bool ?? true)
        for now in [4.0, 17.0, 1000.0] {
            XCTAssertFalse(jobs.begin(id, retry: false, now: now), "background work must not fight the user")
        }
        XCTAssertTrue(jobs.begin(id, retry: true, now: 1001))
        jobs.finish(id, failure: "interrupted", userInterrupted: true, now: 1002)
        let reconnect = PointerCalibrationJobs.Identity(screenID: id.screenID, host: id.host, session: UUID())
        XCTAssertTrue(jobs.begin(reconnect, retry: false, now: 1003))
    }

    func testOnlyOneAttemptPerSessionUntilExplicitRetryOrReconnect() {
        var jobs = PointerCalibrationJobs()
        let identity = PointerCalibrationJobs.Identity(screenID: "phone", host: UUID(), session: UUID())
        XCTAssertTrue(jobs.begin(identity, retry: false))
        XCTAssertFalse(jobs.begin(identity, retry: true))
        jobs.progress(identity, count: 7)
        XCTAssertEqual(jobs.status(screenID: "phone")?["measuredCounts"] as? Int, 7)
        jobs.finish(identity, failure: "moving screen")
        XCTAssertFalse(jobs.begin(identity, retry: false))
        XCTAssertEqual(jobs.status(screenID: "phone")?["state"] as? String, "unavailable")
        XCTAssertTrue(jobs.begin(identity, retry: true))
        jobs.finish(identity, failure: nil)
        let newSession = PointerCalibrationJobs.Identity(screenID: "phone", host: identity.host, session: UUID())
        XCTAssertTrue(jobs.begin(newSession, retry: false))
        jobs.finish(identity, failure: "stale worker")
        XCTAssertTrue(jobs.isRunning(screenID: "phone"))
    }

    func testTransientFailuresRetryWithBackoffAndStopAfterThreeAttempts() {
        var jobs = PointerCalibrationJobs()
        let id = PointerCalibrationJobs.Identity(screenID: "phone", host: UUID(), session: UUID())
        XCTAssertFalse(jobs.isVerified(id))
        XCTAssertTrue(jobs.begin(id, retry: false, now: 0))
        jobs.finish(id, failure: "animation", now: 1)
        XCTAssertFalse(jobs.isVerified(id))
        XCTAssertFalse(jobs.begin(id, retry: false, now: 3))
        XCTAssertTrue(jobs.begin(id, retry: false, now: 4))
        jobs.finish(id, failure: "animation", now: 5)
        XCTAssertFalse(jobs.begin(id, retry: false, now: 16))
        XCTAssertTrue(jobs.begin(id, retry: false, now: 17))
        jobs.finish(id, failure: "animation", now: 18)
        XCTAssertFalse(jobs.begin(id, retry: false, now: 100))
        XCTAssertTrue(jobs.begin(id, retry: true, now: 100))
        jobs.finish(id, failure: nil, reused: true, now: 101)
        XCTAssertTrue(jobs.isVerified(id))
        XCTAssertFalse(jobs.begin(id, retry: false, now: 200))
        // A read-only diagnostic must not revoke a curve already verified in this session.
        XCTAssertTrue(jobs.begin(id, retry: true, now: 201))
        jobs.finish(id, failure: nil, now: 202)
        XCTAssertTrue(jobs.isVerified(id))
        let reconnect = PointerCalibrationJobs.Identity(screenID: id.screenID, host: id.host, session: UUID())
        XCTAssertFalse(jobs.isVerified(reconnect))
    }

    func testExplicitReloadCannotInheritVerificationForDifferentProfileContents() {
        var jobs = PointerCalibrationJobs()
        let id = PointerCalibrationJobs.Identity(screenID: "phone", host: UUID(), session: UUID())
        XCTAssertTrue(jobs.begin(id, retry: false))
        jobs.finish(id, failure: nil, reused: true)
        XCTAssertTrue(jobs.isVerified(id))
        jobs.invalidate(screenID: id.screenID)
        XCTAssertFalse(jobs.isVerified(id))
        XCTAssertTrue(jobs.begin(id, retry: false))
    }

    func testMeasuredMismatchSurvivesReconnectUntilSuccessfulReplacement() {
        var jobs = PointerCalibrationJobs()
        let id = PointerCalibrationJobs.Identity(screenID: "phone", host: UUID(), session: UUID())
        XCTAssertTrue(jobs.begin(id, retry: false))
        jobs.rejectExisting(id)
        jobs.finish(id, failure: "replacement interrupted")
        let reconnect = PointerCalibrationJobs.Identity(screenID: id.screenID, host: id.host, session: UUID())
        XCTAssertTrue(jobs.hasRejectedCalibration(reconnect))
        XCTAssertTrue(jobs.begin(reconnect, retry: false))
        jobs.finish(reconnect, failure: nil, saved: true)
        XCTAssertFalse(jobs.hasRejectedCalibration(reconnect))
    }

    func testTwoPhonesCanAdaptIndependently() {
        var jobs = PointerCalibrationJobs()
        let a = PointerCalibrationJobs.Identity(screenID: "a", host: UUID(), session: UUID())
        let b = PointerCalibrationJobs.Identity(screenID: "b", host: UUID(), session: UUID())
        XCTAssertTrue(jobs.begin(a, retry: false))
        XCTAssertTrue(jobs.begin(b, retry: false))
        jobs.finish(a, failure: nil)
        XCTAssertFalse(jobs.isRunning(screenID: "a"))
        XCTAssertTrue(jobs.isRunning(screenID: "b"))
        jobs.rejectExisting(b)
        jobs.finish(b, failure: "interrupted")
        XCTAssertTrue(jobs.hasRejectedCalibration(b))
        XCTAssertFalse(jobs.hasRejectedCalibration(a))
        XCTAssertTrue(jobs.begin(b, retry: true))
        XCTAssertTrue(jobs.hasRejectedCalibration(b))
        jobs.finish(b, failure: nil, saved: true)
        XCTAssertFalse(jobs.hasRejectedCalibration(b))
    }
}
