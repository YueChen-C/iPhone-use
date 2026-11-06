import AppKit
import XCTest

@testable import iPhoneUse

final class DeviceLockStateTests: XCTestCase {
    func testConfirmedLockRetriesMatchingOnlyOnceAfterUnlock() throws {
        var states = DeviceLockObservations()
        let captures = captures("phone")
        for (state, time) in [(DeviceLockState.suspected, 10.0), (.suspected, 12), (.unknown, 14)] {
            XCTAssertFalse(
                states.complete(
                    try XCTUnwrap(states.requests(for: captures).first), state: state, now: time))
        }
        XCTAssertTrue(
            states.complete(
                try XCTUnwrap(states.requests(for: captures).first), state: .notDetected, now: 16))
        XCTAssertFalse(
            states.complete(
                try XCTUnwrap(states.requests(for: captures).first), state: .notDetected, now: 18))
    }

    func testSingleLockFalsePositiveDoesNotRestartMatching() throws {
        var states = DeviceLockObservations()
        let captures = captures("phone")
        XCTAssertFalse(
            states.complete(
                try XCTUnwrap(states.requests(for: captures).first), state: .suspected, now: 10))
        XCTAssertFalse(
            states.complete(
                try XCTUnwrap(states.requests(for: captures).first), state: .notDetected, now: 12))
    }

    func testRestoredFrameRetryIsScopedToTheCaptureAndPhone() throws {
        var states = DeviceLockObservations()
        var captures = captures("a", "b")
        for request in states.requests(for: captures) {
            XCTAssertFalse(states.complete(request, state: .paused, now: 10))
        }
        captures["a"] = UUID()
        for request in states.requests(for: captures) {
            XCTAssertEqual(states.complete(request, state: .notDetected, now: 12), request.physicalID == "b")
        }
    }

    private func captures(_ ids: String...) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) })
    }

    func testEachPhysicalPhoneRequiresTwoMatchesAndKeepsIndependentState() throws {
        var states = DeviceLockObservations()
        let captures = captures("phone-a", "phone-b")
        let requests = states.requests(for: captures)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(states.requests(for: captures).isEmpty)
        let a = try XCTUnwrap(requests.first { $0.physicalID == "phone-a" })
        let b = try XCTUnwrap(requests.first { $0.physicalID == "phone-b" })
        states.complete(a, state: .suspected, now: 10)
        states.complete(b, state: .notDetected, now: 10)
        XCTAssertEqual(states.state(for: "phone-a", now: 11), .unknown)
        let next = states.requests(for: captures)
        states.complete(try XCTUnwrap(next.first { $0.physicalID == "phone-a" }), state: .suspected, now: 12)
        XCTAssertEqual(states.state(for: "phone-a", now: 12), .suspected)
        XCTAssertEqual(states.state(for: "phone-b", now: 12), .notDetected)
    }

    func testDelayedResultCannotApplyAfterCaptureReplacement() throws {
        var states = DeviceLockObservations()
        let old = try XCTUnwrap(states.requests(for: captures("phone")).first)
        let new = try XCTUnwrap(states.requests(for: captures("phone")).first)
        XCTAssertNotEqual(old, new)
        states.complete(old, state: .suspected, now: 10)
        XCTAssertEqual(states.state(for: "phone", now: 10), .unknown)
        states.complete(new, state: .notDetected, now: 11)
        XCTAssertEqual(states.state(for: "phone", now: 11), .notDetected)
    }

    func testDisconnectRemovesObservationsAndRejectsDelayedResults() throws {
        var states = DeviceLockObservations()
        let request = try XCTUnwrap(states.requests(for: captures("phone")).first)
        XCTAssertTrue(states.requests(for: [:]).isEmpty)
        states.complete(request, state: .suspected, now: 10)
        XCTAssertEqual(states.state(for: "phone", now: 10), .unknown)
    }

    func testUnknownAndStaleResultsClearHintsAndResetConfirmation() throws {
        var states = DeviceLockObservations()
        let captures = captures("phone")
        for time: Double in [10, 12] {
            states.complete(try XCTUnwrap(states.requests(for: captures).first), state: .suspected, now: time)
        }
        XCTAssertEqual(states.state(for: "phone", now: 19), .suspected)
        XCTAssertEqual(states.state(for: "phone", now: 20), .unknown)
        states.complete(try XCTUnwrap(states.requests(for: captures).first), state: .suspected, now: 21)
        XCTAssertEqual(states.state(for: "phone", now: 21), .unknown)
        states.complete(try XCTUnwrap(states.requests(for: captures).first), state: .unknown, now: 22)
        XCTAssertEqual(states.state(for: "phone", now: 22), .unknown)
        states.complete(try XCTUnwrap(states.requests(for: captures).first), state: .suspected, now: 23)
        XCTAssertEqual(states.state(for: "phone", now: 23), .unknown)
    }

    func testUnlockedFrameImmediatelyDismissesHint() throws {
        var states = DeviceLockObservations()
        let captures = captures("phone")
        for time: Double in [10, 12] {
            states.complete(try XCTUnwrap(states.requests(for: captures).first), state: .suspected, now: time)
        }
        states.complete(try XCTUnwrap(states.requests(for: captures).first), state: .notDetected, now: 14)
        XCTAssertEqual(states.state(for: "phone", now: 14), .notDetected)
    }

    func testNoticeNeverInterceptsWakeUpInput() {
        let notice = ControlLockNotice(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        notice.isHidden = false
        XCTAssertNil(notice.hitTest(CGPoint(x: 100, y: 50)))
    }

    func testPausedCaptureShowsGuidanceWithoutClaimingALock() throws {
        var states = DeviceLockObservations()
        let captures = captures("phone")
        let request = try XCTUnwrap(states.requests(for: captures).first)
        states.complete(request, state: .paused, now: 10)
        XCTAssertEqual(states.state(for: "phone", now: 10), .paused)
        XCTAssertTrue(DeviceLockState.paused.showsNotice)
        XCTAssertTrue(DeviceLockState.suspected.showsNotice)
        XCTAssertFalse(DeviceLockState.unknown.showsNotice)
        XCTAssertFalse(DeviceLockState.notDetected.showsNotice)
        XCTAssertEqual(states.state(for: "phone", captureID: UUID(), now: 10), .unknown)
    }

    func testDuplicateCompletionCannotReplaceNextObservation() throws {
        var states = DeviceLockObservations()
        let captures = captures("phone")
        let first = try XCTUnwrap(states.requests(for: captures).first)
        states.complete(first, state: .notDetected, now: 10)
        let next = try XCTUnwrap(states.requests(for: captures).first)
        XCTAssertNotEqual(first, next)
        states.complete(first, state: .paused, now: 11)
        XCTAssertEqual(states.state(for: "phone", now: 11), .notDetected)
        states.complete(next, state: .notDetected, now: 12)
        XCTAssertEqual(states.state(for: "phone", now: 12), .notDetected)
    }
}
