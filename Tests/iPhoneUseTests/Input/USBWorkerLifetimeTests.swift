import XCTest
@testable import iPhoneUse

final class USBWorkerLifetimeTests: XCTestCase {
    func testPreSessionFailureRequiresExplicitProofAndExit() {
        var state = USBTouchWorkerLifetime()
        state.exited = true
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = false
        state.unprepared = true
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = true
        XCTAssertTrue(state.retirementConfirmed)
    }

    func testReadyOrAnyDispatchedCommandInvalidatesNoContactProof() {
        var state = USBTouchWorkerLifetime(unprepared: true, exited: true)
        state.becameReady = true
        XCTAssertFalse(state.retirementConfirmed)
        state.becameReady = false
        state.commandDispatched = true
        XCTAssertFalse(state.retirementConfirmed)
    }

    func testPreparedSessionStillNeedsReleaseAndExit() {
        var state = USBTouchWorkerLifetime(becameReady: true, commandDispatched: true)
        state.exited = true
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = false
        state.released = true
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = true
        XCTAssertTrue(state.retirementConfirmed)
    }
}
