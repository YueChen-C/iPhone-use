import XCTest

@testable import iPhoneUse

final class PointerCalibrationJobsTests: XCTestCase {
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

    func testTwoPhonesCanAdaptIndependently() {
        var jobs = PointerCalibrationJobs()
        let a = PointerCalibrationJobs.Identity(screenID: "a", host: UUID(), session: UUID())
        let b = PointerCalibrationJobs.Identity(screenID: "b", host: UUID(), session: UUID())
        XCTAssertTrue(jobs.begin(a, retry: false))
        XCTAssertTrue(jobs.begin(b, retry: false))
        jobs.finish(a, failure: nil)
        XCTAssertFalse(jobs.isRunning(screenID: "a"))
        XCTAssertTrue(jobs.isRunning(screenID: "b"))
    }
}
