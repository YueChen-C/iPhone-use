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

    func testHostsToReconnectSelectsSavedHostForUnmatchedScreenWhileIgnoringUnrelatedWatch() {
        let phoneA = UUID()
        let phoneB = UUID()
        let watch = UUID()
        let pairings = ["screen-a": phoneA, "screen-b": phoneB]

        // Unrelated CloudPaired Watch connected, phoneA still dormant over BLE.
        XCTAssertEqual(
            HIDPeripheral.hostsToReconnect(
                pairings: pairings, presentScreenIDs: ["screen-a"],
                matchedScreenIDs: [], connectedHosts: [watch]),
            [phoneA])

        // Once phoneA connects or matches, or when no USB screen is present, no wake is needed.
        XCTAssertTrue(
            HIDPeripheral.hostsToReconnect(
                pairings: pairings, presentScreenIDs: ["screen-a"],
                matchedScreenIDs: [], connectedHosts: [watch, phoneA]
            ).isEmpty)
        XCTAssertTrue(
            HIDPeripheral.hostsToReconnect(
                pairings: pairings, presentScreenIDs: ["screen-a"],
                matchedScreenIDs: ["screen-a"], connectedHosts: []
            ).isEmpty)
        XCTAssertTrue(
            HIDPeripheral.hostsToReconnect(
                pairings: pairings, presentScreenIDs: [],
                matchedScreenIDs: [], connectedHosts: []
            ).isEmpty)

        // Replaced USB screen ID wakes saved hosts not already matched to another live screen.
        XCTAssertEqual(
            HIDPeripheral.hostsToReconnect(
                pairings: pairings, presentScreenIDs: ["screen-b", "screen-replaced"],
                matchedScreenIDs: ["screen-b"], connectedHosts: [phoneB]),
            [phoneA])
    }

    func testReconnectTrackerQueuesRetryAcrossAsyncCancelWithoutDroppingNewAttempt() {
        let saved = UUID()
        var tracker = HIDReconnectTracker()

        XCTAssertTrue(
            tracker.updateTargets([saved], activeSessions: [], resetExhausted: true).isEmpty)
        XCTAssertEqual(tracker.connectableHosts(activeSessions: []), [saved])
        let attempt1 = tracker.beginConnecting(saved)
        XCTAssertEqual(tracker.reconnectingHosts(activeSessions: []), [saved])

        // Attempt 1 times out and enters cancelling while waiting for CoreBluetooth's callback.
        XCTAssertTrue(tracker.markTimedOut(host: saved, attempt: attempt1, hasActiveSession: false))
        XCTAssertEqual(tracker.phases[saved], .cancelling(attempt: attempt1, retryDesired: false))

        // A fresh request arrives before didDisconnectPeripheral fires; it must defer connect
        // until cancellation finishes so the late callback cannot delete Attempt 2.
        XCTAssertTrue(
            tracker.updateTargets([saved], activeSessions: [], resetExhausted: true).isEmpty)
        XCTAssertTrue(tracker.connectableHosts(activeSessions: []).isEmpty)
        XCTAssertEqual(tracker.phases[saved], .cancelling(attempt: attempt1, retryDesired: true))
        XCTAssertEqual(tracker.reconnectingHosts(activeSessions: []), [saved])

        // Now Attempt 1's late disconnect callback arrives and cleanly triggers Attempt 2.
        XCTAssertEqual(
            tracker.handleTermination(host: saved, hasActiveSession: false),
            .retryNow)
        XCTAssertEqual(tracker.connectableHosts(activeSessions: []), [saved])
        let attempt2 = tracker.beginConnecting(saved)
        XCTAssertNotEqual(attempt2, attempt1)
        XCTAssertEqual(tracker.reconnectingHosts(activeSessions: []), [saved])
    }

    func testReconnectTrackerBoundsRetriesAndRecoversMidSessionDisconnect() {
        let saved = UUID()
        var tracker = HIDReconnectTracker()
        _ = tracker.updateTargets([saved], activeSessions: [], resetExhausted: true)

        // Attempt 1 fails -> backoff 2s.
        _ = tracker.beginConnecting(saved)
        guard
            case .scheduleBackoff(let token1, let delay1) = tracker.handleTermination(
                host: saved, hasActiveSession: false)
        else {
            return XCTFail("expected first backoff")
        }
        XCTAssertEqual(delay1, 2.0)
        XCTAssertEqual(tracker.reconnectingHosts(activeSessions: []), [saved])
        XCTAssertTrue(tracker.completeBackoff(host: saved, token: token1, hasActiveSession: false))

        // Attempt 2 fails -> backoff 6s.
        _ = tracker.beginConnecting(saved)
        guard
            case .scheduleBackoff(let token2, let delay2) = tracker.handleTermination(
                host: saved, hasActiveSession: false)
        else {
            return XCTFail("expected second backoff")
        }
        XCTAssertEqual(delay2, 6.0)
        XCTAssertTrue(tracker.completeBackoff(host: saved, token: token2, hasActiveSession: false))

        // Attempt 3 fails -> budget exhausted; no endless 12-second loop.
        _ = tracker.beginConnecting(saved)
        XCTAssertEqual(
            tracker.handleTermination(host: saved, hasActiveSession: false),
            .notifyChanged)
        XCTAssertTrue(tracker.reconnectingHosts(activeSessions: []).isEmpty)
        XCTAssertTrue(tracker.connectableHosts(activeSessions: []).isEmpty)

        // Passive host-change re-evaluation keeps the exhausted budget quiet.
        _ = tracker.updateTargets([saved], activeSessions: [], resetExhausted: false)
        XCTAssertTrue(tracker.connectableHosts(activeSessions: []).isEmpty)

        // Explicit /match or USB event resets budget; active session also resets budget for
        // later mid-session BLE drops while USB stays online.
        _ = tracker.updateTargets([saved], activeSessions: [], resetExhausted: true)
        _ = tracker.beginConnecting(saved)
        tracker.noteSessionEstablished(saved)
        XCTAssertEqual(tracker.attemptsUsed[saved], 0)
        XCTAssertTrue(tracker.reconnectingHosts(activeSessions: [saved]).isEmpty)

        // Mid-session BLE unsubscribe before central disconnect cancels stale link and retries.
        let toCancel = tracker.updateTargets([saved], activeSessions: [], resetExhausted: false)
        XCTAssertEqual(toCancel, [saved])
        XCTAssertEqual(
            tracker.handleTermination(host: saved, hasActiveSession: false),
            .retryNow)
        XCTAssertEqual(tracker.connectableHosts(activeSessions: []), [saved])
    }

    func testExcludedBackpressuredHostDoesNotHeadOfLineBlockOtherSubscribedPhone() throws {
        var state = HIDConnectionState()
        let watchHost = host
        let phoneHost = other
        for channel in [HIDConnectionState.Channel.report(.absolutePointer), .report(.relativeMouse)] {
            state.subscribe(channel, host: watchHost)
            state.subscribe(channel, host: phoneHost)
        }
        let watchSession = try XCTUnwrap(state.sessions[watchHost])
        let phoneSession = try XCTUnwrap(state.sessions[phoneHost])

        // Watch queues two relative reports before stalling CoreBluetooth's transmit slot.
        state.enqueue(.report(.relativeMouse), data: Data([0, 1, 0, 0]), host: watchHost, session: watchSession)
        state.enqueue(.report(.relativeMouse), data: Data([0, 2, 0, 0]), host: watchHost, session: watchSession)

        // Phone queues one report whose identity permission later expires, followed by two valid reports.
        var stalePhoneAllowed = true
        state.enqueue(
            .report(.relativeMouse), data: Data([0, 9, 0, 0]), host: phoneHost, session: phoneSession,
            isAllowed: { stalePhoneAllowed })
        state.enqueue(.report(.absolutePointer), data: Data([0, 10, 0, 20, 0]), host: phoneHost, session: phoneSession)
        state.enqueue(.report(.relativeMouse), data: Data([0, 3, 0, 0]), host: phoneHost, session: phoneSession)
        stalePhoneAllowed = false

        var dropped: [Data] = []
        var drainedPhone: [Data] = []
        let blocked: Set<UUID> = [watchHost]
        while let next = state.nextPendingReportIndex(
            excludingHosts: blocked,
            onDrop: { dropped.append($0.data) })
        {
            XCTAssertEqual(next.report.host, phoneHost)
            drainedPhone.append(next.report.data)
            state.removePending(at: next.index)
        }

        XCTAssertEqual(dropped, [Data([0, 9, 0, 0])])
        XCTAssertEqual(drainedPhone, [Data([0, 10, 0, 20, 0]), Data([0, 3, 0, 0])])
        // Watch's queued reports remain untouched in strict FIFO order for peripheralManagerIsReady.
        XCTAssertEqual(state.pending.map(\.host), [watchHost, watchHost])
        XCTAssertEqual(state.pending.map(\.data), [Data([0, 1, 0, 0]), Data([0, 2, 0, 0])])
    }

    func testRecordSubscriptionEstablishesSessionWithoutEnqueuingUnsolicitedPointerOrInputReports() throws {
        var connections = HIDConnectionState()
        var tracker = HIDReconnectTracker()
        _ = tracker.updateTargets([host], activeSessions: [], resetExhausted: true)
        let attempt = tracker.beginConnecting(host)

        // Non-input GATT channels do not establish an input session or queue reports.
        XCTAssertFalse(
            HIDPeripheral.recordSubscription(
                .serviceChanged, host: host, connections: &connections, reconnectTracker: &tracker))
        XCTAssertFalse(
            HIDPeripheral.recordSubscription(
                .battery, host: host, connections: &connections, reconnectTracker: &tracker))
        XCTAssertNil(connections.sessions[host])
        XCTAssertTrue(connections.pending.isEmpty)
        XCTAssertEqual(tracker.phases[host], .connecting(attempt: attempt))

        // Every HID input report subscription establishes/reuses the session and resets
        // reconnect tracking while keeping pending empty (no unsolicited (0, 0) pointer wake).
        for report in [ReportID.keyboard, .absolutePointer, .relativeMouse, .consumer] {
            XCTAssertTrue(
                HIDPeripheral.recordSubscription(
                    .report(report), host: host, connections: &connections, reconnectTracker: &tracker))
            let session = try XCTUnwrap(connections.sessions[host])
            XCTAssertTrue(connections.isReady(report: report, host: host, session: session))
        }
        XCTAssertTrue(connections.pending.isEmpty)
        XCTAssertNil(connections.nextPendingReport())
        XCTAssertEqual(tracker.phases[host], .established(attempt: attempt))
        XCTAssertEqual(tracker.attemptsUsed[host], 0)
    }

    func testLifecyclePolicyStaysIdleUntilUSBOrAwakeControlWindowDemandsBluetooth() {
        var policy = HIDLifecyclePolicy()
        let waitingWindow = UUID()
        let deviceWindow = UUID()

        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .notStarted)
        XCTAssertEqual(policy.inactiveReason?.stateDescription, "starting")

        // Quiet background startup with 0 USB screens and 0 windows keeps CoreBluetooth unregistered.
        policy.start(initialDisplayState: .atLeastOneAwake)
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .idleNoDemand)
        XCTAssertEqual(policy.inactiveReason?.stateDescription, "idle (waiting for iPhone)")

        // Opening Waiting for iPhone window advertises Bluetooth for pre-USB pairing.
        policy.beginWindowDemand(waitingWindow)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)
        XCTAssertNil(policy.inactiveReason)

        // Placeholder replacement registers the device window before closing the waiting window.
        policy.beginWindowDemand(deviceWindow)
        policy.endWindowDemand(waitingWindow)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Idempotent close of the last window with 0 USB screens suspends back to idle.
        policy.endWindowDemand(deviceWindow)
        policy.endWindowDemand(deviceWindow)
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .idleNoDemand)

        // Plugging in an iPhone over USB with 0 open windows activates BLE for headless MCP.
        XCTAssertTrue(policy.setUSBScreenDemand(true, revision: 1))
        XCTAssertTrue(policy.shouldRunCoreBluetooth)
        XCTAssertTrue(policy.setUSBScreenDemand(false, revision: 2))
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .idleNoDemand)
    }

    func testLifecyclePolicyRejectsOutOfOrderUSBScreenDemandAcrossWindowlessAndDisplaySleep() {
        var policy = HIDLifecyclePolicy()
        let waitingWindow = UUID()
        policy.start(initialDisplayState: .atLeastOneAwake)

        // Out-of-order false->true race (revision 2 `true` applied before stale revision 1 `false`)
        // under windowless MCP must keep CoreBluetooth running.
        XCTAssertTrue(policy.setUSBScreenDemand(true, revision: 2))
        XCTAssertEqual(policy.lastUSBDemandRevision, 2)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)
        XCTAssertFalse(policy.setUSBScreenDemand(false, revision: 1))
        XCTAssertFalse(policy.setUSBScreenDemand(false, revision: 2))
        XCTAssertTrue(policy.hasPresentUSBScreens)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Same out-of-order stale `false` rejection while displays are asleep with an open window.
        policy.beginWindowDemand(waitingWindow)
        policy.screensDidSleep()
        XCTAssertFalse(policy.setUSBScreenDemand(false, revision: 1))
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Reverse out-of-order true->false race (revision 4 `false` applied before stale revision 3 `true`)
        // must keep CoreBluetooth torn down while displays remain asleep.
        XCTAssertTrue(policy.setUSBScreenDemand(false, revision: 4))
        XCTAssertEqual(policy.lastUSBDemandRevision, 4)
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .idleNoDemand)
        XCTAssertFalse(policy.setUSBScreenDemand(true, revision: 3))
        XCTAssertFalse(policy.hasPresentUSBScreens)
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
    }

    func testOnlineDisplayClassifierSeparatesQueryErrorsFromHeadlessAndSleepStates() {
        // First CGGetOnlineDisplayList count query fails -> `.unknown` (never `.noOnlineDisplays`).
        XCTAssertEqual(
            HIDOnlineDisplayState.classify(countQueryError: .failure, reportedCount: 0),
            .unknown)

        // Confirmed zero online displays -> `.noOnlineDisplays` (headless Mac mini).
        XCTAssertEqual(
            HIDOnlineDisplayState.classify(countQueryError: .success, reportedCount: 0),
            .noOnlineDisplays)

        // Second CGGetOnlineDisplayList list query fails -> `.unknown`.
        XCTAssertEqual(
            HIDOnlineDisplayState.classify(
                countQueryError: .success,
                reportedCount: 1,
                listQueryError: .illegalArgument,
                resolvedCount: 1,
                asleepFlags: [false]),
            .unknown)

        // Sole external display detached between first and second query with `.success` -> `.noOnlineDisplays`.
        XCTAssertEqual(
            HIDOnlineDisplayState.classify(
                countQueryError: .success,
                reportedCount: 1,
                listQueryError: .success,
                resolvedCount: 0,
                asleepFlags: []),
            .noOnlineDisplays)

        // Online displays all asleep vs at least one awake.
        XCTAssertEqual(
            HIDOnlineDisplayState.classify(
                countQueryError: .success,
                reportedCount: 2,
                listQueryError: .success,
                resolvedCount: 2,
                asleepFlags: [true, true]),
            .allAsleep)
        XCTAssertEqual(
            HIDOnlineDisplayState.classify(
                countQueryError: .success,
                reportedCount: 2,
                listQueryError: .success,
                resolvedCount: 2,
                asleepFlags: [true, false]),
            .atLeastOneAwake)
    }

    func testLifecyclePolicyBlocksDarkWakeAndUnknownWakeQueriesUntilPositiveEvidence() {
        var policy = HIDLifecyclePolicy()
        let windowToken = UUID()
        policy.start(initialDisplayState: .atLeastOneAwake)
        XCTAssertTrue(policy.setUSBScreenDemand(true, revision: 1))
        policy.beginWindowDemand(windowToken)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Entering system sleep tears down CoreBluetooth even while USB and windows are present.
        policy.systemWillSleep()
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .systemSleeping)
        XCTAssertEqual(policy.inactiveReason?.stateDescription, "suspended for system sleep")

        // Backpack maintenance DarkWake (all online displays asleep) must NOT re-register BLE.
        policy.systemDidWake(displayState: .allAsleep)
        XCTAssertTrue(policy.isSystemSleeping)
        XCTAssertTrue(policy.isDisplaySleeping)
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .systemSleeping)

        // Transient CoreGraphics failure (`.unknown`) during DarkWake must also preserve the sleep gate.
        policy.systemDidWake(displayState: .unknown)
        XCTAssertTrue(policy.isSystemSleeping)
        XCTAssertTrue(policy.isDisplaySleeping)
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .systemSleeping)

        // Opening the lid / waking displays clears DarkWake hold and resumes BLE.
        policy.screensDidWake()
        XCTAssertFalse(policy.isSystemSleeping)
        XCTAssertFalse(policy.isDisplaySleeping)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Headless desktop Mac with confirmed zero online displays (`.noOnlineDisplays`)
        // resumes immediately on systemDidWake without requiring screensDidWake.
        policy.systemWillSleep()
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        policy.systemDidWake(displayState: .noOnlineDisplays)
        XCTAssertFalse(policy.isSystemSleeping)
        XCTAssertFalse(policy.isDisplaySleeping)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Full user wake with an awake display (`.atLeastOneAwake`) also resumes immediately.
        policy.systemWillSleep()
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        policy.systemDidWake(displayState: .atLeastOneAwake)
        XCTAssertFalse(policy.isSystemSleeping)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)
    }

    func testLifecyclePolicyKeepsHeadlessUSBActiveAcrossDisplaySleepButSuspendsWindowOnlyIdle() {
        var policy = HIDLifecyclePolicy()
        let waitingWindow = UUID()
        policy.start(initialDisplayState: .unknown)
        policy.beginWindowDemand(waitingWindow)
        // Unknown display state at startup gates window-only BLE advertising until a bounded
        // re-query or demand-triggered refresh observes an awake display (without needing a
        // new `screensDidWakeNotification` when the screen was already awake).
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertTrue(policy.hasUnresolvedDisplayQuery)
        guard let startupRetry = policy.nextUnknownDisplayRetry() else {
            return XCTFail("expected bounded retry slot after start(.unknown)")
        }
        XCTAssertTrue(
            policy.resolveUnknownDisplayQuery(.atLeastOneAwake, generation: startupRetry.generation))
        XCTAssertFalse(policy.hasUnresolvedDisplayQuery)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Display sleep with 0 USB phones suspends window-only BLE advertising immediately.
        policy.screensDidSleep()
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .idleNoDemand)

        // Headless MCP with a connected USB iPhone stays active while displays are asleep.
        XCTAssertTrue(policy.setUSBScreenDemand(true, revision: 1))
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Permanent stop overrides all demands and ignores subsequent events.
        policy.stop()
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .stopped)
        XCTAssertEqual(policy.inactiveReason?.stateDescription, "stopped")
        policy.start(initialDisplayState: .atLeastOneAwake)
        XCTAssertFalse(policy.setUSBScreenDemand(true, revision: 2))
        policy.beginWindowDemand(UUID())
        policy.screensDidWake()
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .stopped)
    }

    func testLifecyclePolicyRecoversFromTransientUnknownWakeWithoutNewWakeNotificationAndRejectsStaleGenerations() {
        var policy = HIDLifecyclePolicy()
        policy.start(initialDisplayState: .noOnlineDisplays)
        XCTAssertTrue(policy.setUSBScreenDemand(true, revision: 1))
        XCTAssertTrue(policy.shouldRunCoreBluetooth)

        // Headless Mac enters sleep, then wakes while CoreGraphics transiently fails (`.unknown`).
        policy.systemWillSleep()
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        policy.systemDidWake(displayState: .unknown)
        XCTAssertTrue(policy.isSystemSleeping)
        XCTAssertTrue(policy.isDisplaySleeping)
        XCTAssertTrue(policy.hasUnresolvedDisplayQuery)
        XCTAssertFalse(policy.shouldRunCoreBluetooth)

        // First retry still returns `.unknown`; retry budget remains bounded to 3 slots.
        guard let retry1 = policy.nextUnknownDisplayRetry() else {
            return XCTFail("expected retry 1")
        }
        XCTAssertFalse(policy.resolveUnknownDisplayQuery(.unknown, generation: retry1.generation))
        XCTAssertTrue(policy.isSystemSleeping)
        XCTAssertTrue(policy.hasUnresolvedDisplayQuery)

        // Second retry succeeds with confirmed 0 displays (`.noOnlineDisplays`) and unlocks BLE
        // without requiring any `screensDidWakeNotification` or second `systemDidWake`.
        guard let retry2 = policy.nextUnknownDisplayRetry() else {
            return XCTFail("expected retry 2")
        }
        XCTAssertTrue(
            policy.resolveUnknownDisplayQuery(.noOnlineDisplays, generation: retry2.generation))
        XCTAssertFalse(policy.hasUnresolvedDisplayQuery)
        XCTAssertFalse(policy.isSystemSleeping)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)
        XCTAssertNil(policy.nextUnknownDisplayRetry())

        // Stale retry from a prior wake generation must NEVER cross a newer `systemWillSleep`.
        policy.systemWillSleep()
        policy.systemDidWake(displayState: .unknown)
        guard let staleWakeRetry = policy.nextUnknownDisplayRetry() else {
            return XCTFail("expected retry before re-sleep")
        }
        policy.systemWillSleep()
        XCTAssertFalse(policy.hasUnresolvedDisplayQuery)
        XCTAssertFalse(
            policy.resolveUnknownDisplayQuery(.atLeastOneAwake, generation: staleWakeRetry.generation))
        XCTAssertTrue(policy.isSystemSleeping)
        XCTAssertFalse(policy.shouldRunCoreBluetooth)

        // If all bounded scheduled retries return `.unknown`, `hasUnresolvedDisplayQuery` stays
        // armed so a later demand inflow (window open, USB plug-in, or `/match`) can still resolve it.
        policy.systemDidWake(displayState: .unknown)
        var lastGeneration: UInt64 = 0
        for expectedDelay in HIDLifecyclePolicy.unknownDisplayRetryDelays {
            guard let slot = policy.nextUnknownDisplayRetry() else {
                return XCTFail("expected bounded retry slot")
            }
            XCTAssertEqual(slot.delay, expectedDelay)
            lastGeneration = slot.generation
            XCTAssertFalse(policy.resolveUnknownDisplayQuery(.unknown, generation: slot.generation))
        }
        XCTAssertNil(policy.nextUnknownDisplayRetry())
        XCTAssertTrue(policy.hasUnresolvedDisplayQuery)
        XCTAssertTrue(
            policy.resolveUnknownDisplayQuery(.noOnlineDisplays, generation: lastGeneration))
        XCTAssertFalse(policy.hasUnresolvedDisplayQuery)
        XCTAssertFalse(policy.isSystemSleeping)
        XCTAssertTrue(policy.shouldRunCoreBluetooth)
    }

    func testReconnectTrackerSuspendForLifecycleTeardownPreservesTargetsAndResetsRetryBudget() {
        var tracker = HIDReconnectTracker()
        _ = tracker.updateTargets([host, other], activeSessions: [], resetExhausted: true)

        // `host` fails twice into backoff; `other` is actively connecting when sleep occurs.
        _ = tracker.beginConnecting(host)
        guard
            case .scheduleBackoff(let staleBackoffToken, _) = tracker.handleTermination(
                host: host, hasActiveSession: false)
        else {
            return XCTFail("expected backoff for host")
        }
        let staleConnectAttempt = tracker.beginConnecting(other)

        let cancelledForSleep = tracker.suspendForLifecycleTeardown()
        XCTAssertEqual(cancelledForSleep, [other])
        XCTAssertEqual(tracker.targets, [host, other])
        XCTAssertTrue(tracker.phases.isEmpty)
        XCTAssertTrue(tracker.attemptsUsed.isEmpty)

        // Stale pre-sleep timer callbacks cannot mutate post-wake reconnection state.
        XCTAssertFalse(tracker.completeBackoff(host: host, token: staleBackoffToken, hasActiveSession: false))
        XCTAssertFalse(tracker.markTimedOut(host: other, attempt: staleConnectAttempt, hasActiveSession: false))

        // On wake, both targets are immediately connectable with fresh retry budgets.
        XCTAssertEqual(tracker.connectableHosts(activeSessions: []), [host, other])

        // Permanent stop clears targets as well as active phases.
        _ = tracker.beginConnecting(host)
        XCTAssertEqual(tracker.cancelAllForStop(), [host])
        XCTAssertTrue(tracker.targets.isEmpty)
        XCTAssertTrue(tracker.connectableHosts(activeSessions: []).isEmpty)
    }
}
