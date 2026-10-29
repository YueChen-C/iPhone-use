import XCTest

@testable import iPhoneUse

final class HIDDrainBarrierTests: XCTestCase {
    private let host = UUID()
    private let session = UUID()

    func testBackpressureWaitsForAllEarlierNotificationsToBeAccepted() {
        let barrier = HIDDrainBarrier()
        let waiter = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 1)
        barrier.register(waiter, pendingCount: 2)
        // A rejected updateValue leaves the FIFO unchanged and emits no acceptance.
        XCTAssertNil(waiter.completedResult)
        barrier.didAccept(host: host, session: session)
        XCTAssertNil(waiter.completedResult)
        XCTAssertEqual(barrier.count, 1)
        // peripheralManagerIsReady resumes drain, accepting the remaining report.
        barrier.didAccept(host: host, session: session)
        XCTAssertTrue(waiter.wait())
        XCTAssertEqual(barrier.count, 0)
    }

    func testDisconnectFailsWaiterInsteadOfTreatingRemovedReportsAsDrained() {
        let barrier = HIDDrainBarrier()
        let waiter = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 1)
        barrier.register(waiter, pendingCount: 1)
        barrier.invalidate(host: host, session: session)
        XCTAssertFalse(waiter.wait())
        XCTAssertEqual(barrier.count, 0)
        barrier.didAccept(host: host, session: session)
        XCTAssertEqual(waiter.completedResult, false)
    }

    func testTimeoutCancellationRemovesWaiterAndLateAcceptanceCannotSucceed() {
        let barrier = HIDDrainBarrier()
        let waiter = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 0.001)
        barrier.register(waiter, pendingCount: 1)
        XCTAssertFalse(waiter.wait())
        barrier.cancel(waiter)
        XCTAssertEqual(barrier.count, 0)
        barrier.didAccept(host: host, session: session)
        XCTAssertEqual(waiter.completedResult, false)
    }

    func testTimeoutBeforeRegistrationDoesNotLeakAWaiter() {
        let barrier = HIDDrainBarrier()
        let waiter = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 0)
        XCTAssertFalse(waiter.wait())
        barrier.register(waiter, pendingCount: 1)
        XCTAssertEqual(barrier.count, 0)
    }

    func testDifferentHostsAndSessionsAreIsolated() {
        let barrier = HIDDrainBarrier()
        let otherHost = UUID()
        let otherSession = UUID()
        let waiter = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 1)
        let other = HIDDrainBarrier.Waiter(host: otherHost, session: otherSession, timeout: 1)
        barrier.register(waiter, pendingCount: 1)
        barrier.register(other, pendingCount: 1)
        barrier.didAccept(host: host, session: UUID())
        XCTAssertNil(waiter.completedResult)
        barrier.didAccept(host: otherHost, session: otherSession)
        XCTAssertTrue(other.wait())
        XCTAssertNil(waiter.completedResult)
        XCTAssertEqual(barrier.count, 1)
        barrier.invalidate(host: otherHost, session: otherSession)
        XCTAssertNil(waiter.completedResult)
        barrier.didAccept(host: host, session: session)
        XCTAssertTrue(waiter.wait())
    }

    func testResetFailsAllWaiters() {
        let barrier = HIDDrainBarrier()
        let waiter = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 1)
        let other = HIDDrainBarrier.Waiter(host: UUID(), session: UUID(), timeout: 1)
        barrier.register(waiter, pendingCount: 2)
        barrier.register(other, pendingCount: 1)
        barrier.invalidateAll()
        XCTAssertFalse(waiter.wait())
        XCTAssertFalse(other.wait())
        XCTAssertEqual(barrier.count, 0)
    }

    func testAnEmptyBoundaryCompletesWithoutWaitingForFutureReports() {
        let barrier = HIDDrainBarrier()
        let waiter = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 1)
        barrier.register(waiter, pendingCount: 0)
        XCTAssertTrue(waiter.wait())
        XCTAssertEqual(barrier.count, 0)
    }

    func testEachBoundaryOnlyWaitsForItsCapturedPendingCount() {
        let barrier = HIDDrainBarrier()
        let first = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 1)
        let second = HIDDrainBarrier.Waiter(host: host, session: session, timeout: 1)
        barrier.register(first, pendingCount: 1)
        barrier.register(second, pendingCount: 2)
        barrier.didAccept(host: host, session: session)
        XCTAssertTrue(first.wait())
        XCTAssertNil(second.completedResult)
        barrier.didAccept(host: host, session: session)
        XCTAssertTrue(second.wait())
    }
}
