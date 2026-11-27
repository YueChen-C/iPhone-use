import XCTest

@testable import iPhoneUse

final class PointerCalibrationJobsTests: XCTestCase {
    func testManualRecheckSelectsModeFromProofAndDoesNotFallbackAfterInterruption() throws {
        var measurements = 0
        func measure() -> String { measurements += 1; return "measured profile" }

        let absolute = try PointerRecalibrationResult.choose(verifyAbsolute: { true }, measureRelative: measure)
        XCTAssertEqual(absolute.mode, .absolute)
        XCTAssertNil(absolute.profile)
        XCTAssertEqual(measurements, 0)

        let relative = try PointerRecalibrationResult.choose(verifyAbsolute: { false }, measureRelative: measure)
        XCTAssertEqual(relative.mode, .relative)
        XCTAssertEqual(relative.profile, "measured profile")
        XCTAssertEqual(measurements, 1)

        XCTAssertThrowsError(try PointerRecalibrationResult.choose(
            verifyAbsolute: { throw DeviceInput.InputError.pairingProbeUnavailable }, measureRelative: measure))
        XCTAssertEqual(measurements, 1)
        XCTAssertFalse(PointerCalibrationMode.recalibrate.reusesExisting)
    }

    func testManualFailurePreservesExistingProofAndDoesNotMovePhoneAgainAutomatically() {
        var jobs = PointerCalibrationJobs()
        let id = PointerCalibrationJobs.Identity(screenID: "phone", host: UUID(), session: UUID())
        XCTAssertTrue(jobs.begin(id, retry: false, now: 0))
        jobs.finish(id, failure: nil, reused: true, now: 1)
        XCTAssertTrue(jobs.isVerified(id))
        XCTAssertTrue(jobs.begin(id, retry: true, mode: .recalibrate, now: 2))
        XCTAssertFalse(jobs.begin(id, retry: true, mode: .recalibrate, now: 2))
        jobs.finish(id, failure: "interrupted", now: 3)
        XCTAssertTrue(jobs.isVerified(id))
        XCTAssertFalse(jobs.shouldRetryOnUsableFrame(screenID: id.screenID))
        XCTAssertEqual(jobs.status(screenID: id.screenID)?["automaticRetryPending"] as? Bool, false)
        XCTAssertFalse(jobs.begin(id, retry: false, now: 100))
        XCTAssertTrue(jobs.begin(id, retry: true, mode: .recalibrate, now: 101))
    }

    func testAbsoluteProofIsScopedToTheExactLiveBindingAndClearedOnReload() {
        var jobs = PointerCalibrationJobs()
        let id = PointerCalibrationJobs.Identity(screenID: "phone", host: UUID(), session: UUID())
        let capture = UUID(), route = UUID(), size = CGSize(width: 750, height: 1334)
        let proof = PointerCalibrationJobs.AbsoluteProof(identity: id, capture: capture, routeGeneration: route, size: size)
        jobs.recordAbsolute(proof)
        XCTAssertTrue(jobs.usesAbsolute(proof))
        XCTAssertFalse(jobs.usesAbsolute(.init(identity: id, capture: UUID(), routeGeneration: route, size: size)))
        XCTAssertFalse(jobs.usesAbsolute(.init(identity: id, capture: capture, routeGeneration: UUID(), size: size)))
        XCTAssertFalse(jobs.usesAbsolute(.init(
            identity: id, capture: capture, routeGeneration: route, size: CGSize(width: 1334, height: 750))))
        let reconnected = PointerCalibrationJobs.Identity(screenID: id.screenID, host: id.host, session: UUID())
        XCTAssertFalse(jobs.usesAbsolute(.init(identity: reconnected, capture: capture, routeGeneration: route, size: size)))
        jobs.invalidate(screenID: id.screenID)
        XCTAssertFalse(jobs.usesAbsolute(proof))
    }

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
