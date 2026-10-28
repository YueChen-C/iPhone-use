import XCTest

@testable import iPhoneUse

final class HIDConnectionStateTests: XCTestCase {
    private let host = UUID()
    private let other = UUID()

    func testKeyboardConnectionIsNotReadyForPointerUntilItsReportsSubscribe() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.keyboard), host: host)
        let session = try XCTUnwrap(state.sessions[host])
        XCTAssertTrue(state.isReady(report: .keyboard, host: host, session: session))
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: host, session: session))
        XCTAssertFalse(state.isReady(report: .relativeMouse, host: host, session: session))

        state.subscribe(.report(.absolutePointer), host: host)
        XCTAssertTrue(state.isReady(report: .absolutePointer, host: host, session: session))
        XCTAssertFalse(state.isReady(report: .relativeMouse, host: host, session: session))
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: host, session: nil))
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: host, session: UUID()))
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: other, session: session))

        state.subscribe(.report(.relativeMouse), host: host)
        XCTAssertTrue(state.isReady(report: .relativeMouse, host: host, session: session))
    }

    func testPointerReadinessChangesOnPartialUnsubscribeAndResubscribe() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.keyboard), host: host)
        state.subscribe(.report(.absolutePointer), host: host)
        let session = try XCTUnwrap(state.sessions[host])
        XCTAssertTrue(state.isReady(report: .absolutePointer, host: host, session: session))

        state.unsubscribe(.report(.absolutePointer), host: host)
        XCTAssertEqual(state.sessions[host], session)
        XCTAssertTrue(state.isReady(report: .keyboard, host: host, session: session))
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: host, session: session))

        state.subscribe(.report(.absolutePointer), host: host)
        XCTAssertTrue(state.isReady(report: .absolutePointer, host: host, session: session))
    }

    func testPointerReadinessCannotBeReusedAfterDisconnectOrBluetoothReset() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.absolutePointer), host: host)
        let disconnectedSession = try XCTUnwrap(state.sessions[host])
        state.unsubscribe(.report(.absolutePointer), host: host)
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: host, session: disconnectedSession))

        state.subscribe(.report(.absolutePointer), host: host)
        let resetSession = try XCTUnwrap(state.sessions[host])
        XCTAssertNotEqual(resetSession, disconnectedSession)
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: host, session: disconnectedSession))
        XCTAssertTrue(state.isReady(report: .absolutePointer, host: host, session: resetSession))

        state.reset()
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: host, session: resetSession))
        state.subscribe(.report(.absolutePointer), host: host)
        XCTAssertFalse(state.isReady(report: .absolutePointer, host: host, session: resetSession))
        XCTAssertTrue(state.isReady(report: .absolutePointer, host: host, session: state.sessions[host]))
    }

    func testRejectsUnsubscribedReportsAndMissingSession() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.keyboard), host: host)
        let session = try XCTUnwrap(state.sessions[host])
        state.enqueue(.report(.absolutePointer), data: Data([0, 1, 0, 1, 0]), host: host, session: session)
        state.enqueue(.report(.keyboard), data: Data(repeating: 0, count: 8), host: host)
        XCTAssertTrue(state.pending.isEmpty)
        state.enqueue(.report(.keyboard), data: Data(repeating: 0, count: 8), host: host, session: session)
        XCTAssertEqual(state.pending.count, 1)
    }

    func testUnsubscribePurgesBlockedChannelAndPreservesOtherHost() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.keyboard), host: host)
        state.subscribe(.report(.keyboard), host: other)
        state.enqueue(.report(.keyboard), data: Data([1]), host: host, session: state.sessions[host])
        state.enqueue(.report(.keyboard), data: Data([2]), host: other, session: state.sessions[other])
        state.unsubscribe(.report(.keyboard), host: host)
        XCTAssertNil(state.sessions[host])
        XCTAssertNil(state.subscriptions[host])
        XCTAssertEqual(state.pending.map(\.host), [other])
        XCTAssertEqual(state.pending.map(\.data), [Data([2])])
        state.removeFirst()
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testReconnectRejectsOldInputEvenIfServiceChangedRemainsSubscribed() throws {
        var state = HIDConnectionState()
        state.subscribe(.serviceChanged, host: host)
        state.subscribe(.report(.keyboard), host: host)
        let oldSession = try XCTUnwrap(state.sessions[host])
        state.enqueue(.report(.keyboard), data: Data([1]), host: host, session: oldSession)
        state.unsubscribe(.report(.keyboard), host: host)
        XCTAssertNil(state.sessions[host])
        XCTAssertEqual(state.subscriptions[host], [.serviceChanged])
        XCTAssertTrue(state.pending.isEmpty)

        state.subscribe(.report(.keyboard), host: host)
        let newSession = try XCTUnwrap(state.sessions[host])
        XCTAssertNotEqual(oldSession, newSession)
        state.enqueue(.report(.keyboard), data: Data([2]), host: host, session: oldSession)
        state.enqueue(.report(.keyboard), data: Data([3]), host: host, session: newSession)
        XCTAssertEqual(state.pending.map(\.data), [Data([3])])
    }

    func testPartialUnsubscribePreservesOtherInputChannel() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.keyboard), host: host)
        state.subscribe(.report(.relativeMouse), host: host)
        let session = try XCTUnwrap(state.sessions[host])
        state.enqueue(.report(.keyboard), data: Data([1]), host: host, session: session)
        state.enqueue(.report(.relativeMouse), data: Data([0, 0, 0, 0]), host: host, session: session)
        state.unsubscribe(.report(.keyboard), host: host)
        XCTAssertEqual(state.sessions[host], session)
        XCTAssertEqual(state.pending.map(\.channel), [.report(.relativeMouse)])
        state.enqueue(.report(.keyboard), data: Data([2]), host: host, session: session)
        XCTAssertEqual(state.pending.count, 1)
    }

    func testBluetoothResetClearsAllConnectionStateAndInvalidatesInput() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.keyboard), host: host)
        state.subscribe(.battery, host: other)
        let oldSession = try XCTUnwrap(state.sessions[host])
        state.enqueue(.report(.keyboard), data: Data([1]), host: host, session: oldSession)
        state.enqueue(.battery, data: Data([100]), host: other)
        state.reset()
        XCTAssertTrue(state.subscriptions.isEmpty)
        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertTrue(state.pending.isEmpty)
        state.subscribe(.report(.keyboard), host: host)
        XCTAssertNotEqual(state.sessions[host], oldSession)
        state.enqueue(.report(.keyboard), data: Data([2]), host: host, session: oldSession)
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testCongestedPointerKeepsLatestPositionButPreservesClickAndKeyboardOrder() throws {
        var state = HIDConnectionState()
        for id in [ReportID.absolutePointer, .relativeMouse, .keyboard] {
            state.subscribe(.report(id), host: host)
        }
        let session = try XCTUnwrap(state.sessions[host])
        func enqueue(_ id: ReportID, _ bytes: [UInt8]) {
            state.enqueue(.report(id), data: Data(bytes), host: host, session: session)
        }
        enqueue(.absolutePointer, [0, 1, 0, 1, 0])
        enqueue(.absolutePointer, [0, 2, 0, 2, 0])
        enqueue(.relativeMouse, [1, 0, 0, 0])
        enqueue(.absolutePointer, [1, 3, 0, 3, 0])
        enqueue(.absolutePointer, [1, 4, 0, 4, 0])
        enqueue(.relativeMouse, [0, 0, 0, 0])
        enqueue(.keyboard, [0, 0, 4, 0, 0, 0, 0, 0])
        enqueue(.keyboard, [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(
            state.pending.map(\.data),
            [
                Data([0, 2, 0, 2, 0]), Data([1, 0, 0, 0]), Data([1, 4, 0, 4, 0]),
                Data([0, 0, 0, 0]), Data([0, 0, 4, 0, 0, 0, 0, 0]), Data(repeating: 0, count: 8),
            ])
    }

    func testCoalescingPreservesButtonTransitionsOtherHostsAndRelativeDeltas() throws {
        var state = HIDConnectionState()
        for id in [ReportID.absolutePointer, .relativeMouse] {
            state.subscribe(.report(id), host: host)
            state.subscribe(.report(id), host: other)
        }
        let session = try XCTUnwrap(state.sessions[host])
        state.enqueue(.report(.absolutePointer), data: Data([0, 1, 0, 1, 0]), host: host, session: session)
        state.enqueue(.report(.absolutePointer), data: Data([1, 1, 0, 1, 0]), host: host, session: session)
        state.enqueue(
            .report(.absolutePointer), data: Data([0, 2, 0, 2, 0]), host: other, session: state.sessions[other])
        state.enqueue(.report(.absolutePointer), data: Data([1, 3, 0, 3, 0]), host: host, session: session)
        state.enqueue(.report(.relativeMouse), data: Data([0, 1, 0, 0]), host: host, session: session)
        state.enqueue(.report(.relativeMouse), data: Data([0, 2, 0, 0]), host: host, session: session)
        XCTAssertEqual(state.pending.count, 6)
    }

    func testRejectsMovementWhenIdentityInvalidatesBeforeEnqueue() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.relativeMouse), host: host)
        let session = try XCTUnwrap(state.sessions[host])
        state.enqueue(
            .report(.relativeMouse), data: Data([0, 10, 0, 0]), host: host, session: session,
            isAllowed: { false })
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testBackpressureDropsOldIdentityMovementAndKeepsOtherHost() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.relativeMouse), host: host)
        state.subscribe(.report(.relativeMouse), host: other)
        let session = try XCTUnwrap(state.sessions[host])
        var currentIdentity = UUID()
        let capturedIdentity = currentIdentity
        state.enqueue(
            .report(.relativeMouse), data: Data([0, 10, 0, 0]), host: host, session: session,
            isAllowed: { currentIdentity == capturedIdentity })
        state.enqueue(
            .report(.relativeMouse), data: Data([0, 20, 0, 0]), host: other, session: state.sessions[other])
        XCTAssertEqual(state.pending.first?.session, session)

        // Capture identity finishes after Bluetooth accepted the input queue;
        // Bluetooth itself remains connected throughout this transition.
        currentIdentity = UUID()
        let next = try XCTUnwrap(state.nextPendingReport())
        XCTAssertEqual(next.host, other)
        XCTAssertEqual(next.data, Data([0, 20, 0, 0]))
        XCTAssertEqual(state.pending.count, 1)
    }

    func testInvalidatedIdentityStillReleasesMouseKeyboardAndConsumer() throws {
        var state = HIDConnectionState()
        for id in [ReportID.relativeMouse, .keyboard, .consumer] {
            state.subscribe(.report(id), host: host)
        }
        let session = try XCTUnwrap(state.sessions[host])
        var allowed = true
        for (id, press, release) in [
            (ReportID.relativeMouse, Data([1, 0, 0, 0]), Data(repeating: 0, count: 4)),
            (.keyboard, Data([0, 0, 4, 0, 0, 0, 0, 0]), Data(repeating: 0, count: 8)),
            (.consumer, Data([1, 0]), Data(repeating: 0, count: 2)),
        ] {
            state.enqueue(.report(id), data: press, host: host, session: session, isAllowed: { allowed })
            state.enqueue(.report(id), data: release, host: host, session: session, isAllowed: { allowed })
        }
        allowed = false
        var released: [HIDConnectionState.Channel] = []
        while let report = state.nextPendingReport() {
            XCTAssertTrue(report.data.allSatisfy { $0 == 0 })
            released.append(report.channel)
            state.removeFirst()
        }
        XCTAssertEqual(released, [.report(.relativeMouse), .report(.keyboard), .report(.consumer)])

        // Releases generated after invalidation must also enter the queue.
        state.enqueue(
            .report(.relativeMouse), data: Data(repeating: 0, count: 4), host: host, session: session,
            isAllowed: { false })
        XCTAssertNotNil(state.nextPendingReport())
    }

    func testAbsoluteOriginIsMovementAndCannotBypassIdentityGate() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.absolutePointer), host: host)
        let session = try XCTUnwrap(state.sessions[host])
        var allowed = true
        state.enqueue(
            .report(.absolutePointer), data: Data(repeating: 0, count: 5), host: host, session: session,
            isAllowed: { allowed })
        allowed = false
        XCTAssertNil(state.nextPendingReport())
        XCTAssertTrue(state.pending.isEmpty)
        state.enqueue(
            .report(.absolutePointer), data: Data(repeating: 0, count: 5), host: host, session: session,
            isAllowed: { false })
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testCoalescedPositionRetainsLatestIdentityPermission() throws {
        var state = HIDConnectionState()
        state.subscribe(.report(.absolutePointer), host: host)
        let session = try XCTUnwrap(state.sessions[host])
        var latestIdentityAllowed = true
        state.enqueue(
            .report(.absolutePointer), data: Data([0, 1, 0, 1, 0]), host: host, session: session,
            isAllowed: { true })
        state.enqueue(
            .report(.absolutePointer), data: Data([0, 2, 0, 2, 0]), host: host, session: session,
            isAllowed: { latestIdentityAllowed })
        XCTAssertEqual(state.pending.count, 1)
        latestIdentityAllowed = false
        XCTAssertNil(state.nextPendingReport())
    }
}
