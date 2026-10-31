import CoreVideo
import Foundation
import XCTest

@testable import iPhoneUse

final class ScreenCaptureFrameStoreTests: XCTestCase {
    private func buffer(width: Int = 8, height: Int = 6) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &value)
        XCTAssertEqual(result, kCVReturnSuccess)
        return try XCTUnwrap(value)
    }

    func testSnapshotKeepsBufferSequenceAndTimestampTogether() throws {
        let store = ScreenCaptureFrameStore()
        XCTAssertNil(store.snapshot())

        store.publish(try buffer(width: 8), receivedAt: 10)
        let first = try XCTUnwrap(store.snapshot())
        XCTAssertEqual(CVPixelBufferGetWidth(first.buffer), 8)
        XCTAssertEqual(first.receivedAt, 10)

        store.publish(try buffer(width: 16), receivedAt: 12)
        let second = try XCTUnwrap(store.snapshot())
        XCTAssertGreaterThan(second.sequence, first.sequence)
        XCTAssertEqual(CVPixelBufferGetWidth(second.buffer), 16)
        XCTAssertEqual(second.receivedAt, 12)
        XCTAssertEqual(CVPixelBufferGetWidth(first.buffer), 8, "an acquired snapshot must retain its own frame")
        XCTAssertEqual(first.receivedAt, 10)
    }

    func testConcurrentPublicationCannotMixFrameAndMetadata() throws {
        let store = ScreenCaptureFrameStore()
        let buffers = try (2...17).map { try buffer(width: $0) }

        DispatchQueue.concurrentPerform(iterations: 256) { index in
            let value = buffers[index % buffers.count]
            let timestamp = TimeInterval(CVPixelBufferGetWidth(value))
            store.publish(value, receivedAt: timestamp)
            guard let snapshot = store.snapshot() else { return XCTFail("a published frame must be available") }
            XCTAssertEqual(TimeInterval(CVPixelBufferGetWidth(snapshot.buffer)), snapshot.receivedAt)
        }

        XCTAssertNotNil(store.snapshot())
    }

    func testZeroTimeoutAcceptsAnAlreadyFreshFrame() throws {
        let store = ScreenCaptureFrameStore()
        store.publish(try buffer(), receivedAt: 20)
        let current = try XCTUnwrap(store.snapshot())

        let result = try store.wait(after: nil, notBefore: 20, timeout: 0)
        XCTAssertEqual(result.sequence, current.sequence)
        XCTAssertEqual(result.receivedAt, 20, "notBefore is inclusive")
    }

    func testAfterRequiresAStrictlyNewerSequence() throws {
        let store = ScreenCaptureFrameStore()
        store.publish(try buffer(width: 8), receivedAt: 10)
        let first = try XCTUnwrap(store.snapshot())

        XCTAssertThrowsError(try store.wait(after: first.sequence, notBefore: 10, timeout: 0)) {
            XCTAssertTrue($0 is DeviceError)
        }

        store.publish(try buffer(width: 16), receivedAt: 10)
        let result = try store.wait(after: first.sequence, notBefore: 10, timeout: 0)
        XCTAssertGreaterThan(result.sequence, first.sequence)
        XCTAssertEqual(CVPixelBufferGetWidth(result.buffer), 16)
    }

    func testNewSequenceDoesNotMakeAnOldTimestampFresh() throws {
        let store = ScreenCaptureFrameStore()
        store.publish(try buffer(width: 8), receivedAt: 10)
        let first = try XCTUnwrap(store.snapshot())
        store.publish(try buffer(width: 16), receivedAt: 19)

        XCTAssertThrowsError(try store.wait(after: first.sequence, notBefore: 20, timeout: 0)) {
            XCTAssertTrue($0 is DeviceError)
        }
    }

    func testWaitContinuesUntilBothSequenceAndTimestampAreFresh() throws {
        let store = ScreenCaptureFrameStore()
        store.publish(try buffer(width: 8), receivedAt: 10)
        let first = try XCTUnwrap(store.snapshot())
        let oldTimestamp = try buffer(width: 16)
        let fresh = try buffer(width: 24)
        let started = expectation(description: "wait started")
        let finished = expectation(description: "fresh frame received")
        let publisher = DispatchQueue(label: "frame-store-tests.publisher")
        defer { store.stop() }

        DispatchQueue.global().async {
            started.fulfill()
            do {
                let result = try store.wait(after: first.sequence, notBefore: 20, timeout: 1)
                XCTAssertGreaterThan(result.sequence, first.sequence)
                XCTAssertEqual(result.receivedAt, 20)
                XCTAssertEqual(CVPixelBufferGetWidth(result.buffer), 24)
            } catch {
                XCTFail("waiting for a fresh frame failed: \(error)")
            }
            finished.fulfill()
        }
        wait(for: [started], timeout: 1)
        publisher.asyncAfter(deadline: .now() + 0.01) { store.publish(oldTimestamp, receivedAt: 19) }
        publisher.asyncAfter(deadline: .now() + 0.03) { store.publish(fresh, receivedAt: 20) }
        wait(for: [finished], timeout: 1.5)
    }

    func testMissingFrameTimesOutWithinTheRequestedBound() {
        let store = ScreenCaptureFrameStore()
        let started = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(try store.wait(after: nil, notBefore: 0, timeout: 0.03)) {
            XCTAssertTrue($0 is DeviceError)
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThanOrEqual(elapsed, 0.02, "a positive timeout should wait for a frame")
        XCTAssertLessThan(elapsed, 0.5, "a missing stream must not block indefinitely")
    }

    func testStopWakesAPendingWaitWithoutWaitingForItsTimeout() {
        let store = ScreenCaptureFrameStore()
        let started = expectation(description: "wait started")
        let stopped = expectation(description: "stopped wait returned")
        defer { store.stop() }

        DispatchQueue.global().async {
            started.fulfill()
            do {
                _ = try store.wait(after: nil, notBefore: 0, timeout: 2)
                XCTFail("a stopped stream must not return a frame")
            } catch {
                XCTAssertTrue(error is DeviceError)
            }
            stopped.fulfill()
        }
        wait(for: [started], timeout: 1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { store.stop() }
        wait(for: [stopped], timeout: 0.5)
    }

    func testStoppedStoreRejectsEvenAPreviouslyFreshFrame() throws {
        let store = ScreenCaptureFrameStore()
        store.publish(try buffer(), receivedAt: 20)
        store.stop()

        XCTAssertThrowsError(try store.wait(after: nil, notBefore: 20, timeout: 0)) {
            XCTAssertTrue($0 is DeviceError)
        }
    }

    func testResumeAcceptsAPublishedFrameAfterStop() throws {
        let store = ScreenCaptureFrameStore()
        store.publish(try buffer(width: 8), receivedAt: 10)
        let first = try XCTUnwrap(store.snapshot())
        store.stop()
        store.resume()
        store.publish(try buffer(width: 16), receivedAt: 20)

        let result = try store.wait(after: first.sequence, notBefore: 20, timeout: 0)
        XCTAssertGreaterThan(result.sequence, first.sequence, "resume must not reuse an earlier sequence")
        XCTAssertEqual(result.receivedAt, 20)
        XCTAssertEqual(CVPixelBufferGetWidth(result.buffer), 16)
    }

    func testInvalidWaitParametersAreRejectedEvenWhenAFrameIsAvailable() throws {
        let store = ScreenCaptureFrameStore()
        store.publish(try buffer(), receivedAt: 20)

        for timestamp in [TimeInterval.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try store.wait(after: nil, notBefore: timestamp, timeout: 0)) {
                XCTAssertTrue($0 is DeviceError)
            }
        }
        for timeout in [-1, TimeInterval.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try store.wait(after: nil, notBefore: 0, timeout: timeout)) {
                XCTAssertTrue($0 is DeviceError)
            }
        }
    }

    func testPublishReportsFirstFrameOnlyOnceAndFalseWhenStoppedOrInvalid() throws {
        let store = ScreenCaptureFrameStore()
        XCTAssertFalse(store.publish(try buffer(), receivedAt: -1))
        XCTAssertFalse(store.publish(try buffer(), receivedAt: .nan))
        XCTAssertNil(store.snapshot())

        XCTAssertTrue(store.publish(try buffer(width: 8), receivedAt: 10))
        XCTAssertFalse(store.publish(try buffer(width: 16), receivedAt: 11))

        store.stop()
        XCTAssertFalse(store.publish(try buffer(width: 24), receivedAt: 12))
        store.resume()
        XCTAssertFalse(store.publish(try buffer(width: 24), receivedAt: 13))
    }

    func testLifecycleStopAndWaitDrainsInFlightRestartAndPreventsFramePublication() throws {
        let store = ScreenCaptureFrameStore()
        let queue = DispatchQueue(label: "capture-lifecycle-tests.interleave")
        let enteredStart = expectation(description: "restart entered startRunning")
        let releaseStart = DispatchSemaphore(value: 0)
        let session = MockCaptureRunningSession(onStart: {
            enteredStart.fulfill()
            releaseStart.wait()
        })
        let lifecycle = CaptureSourceLifecycle(session: session, frames: store, queue: queue)

        XCTAssertTrue(lifecycle.restart())
        wait(for: [enteredStart], timeout: 1.0)

        let stopCompleted = expectation(description: "stopAndWait completed")
        DispatchQueue.global().async {
            XCTAssertTrue(lifecycle.stopAndWait(timeout: 1.0))
            stopCompleted.fulfill()
        }

        // Wait briefly until stop() acquires stateLock (not blocked by startRunning!)
        // and flips lifecycle.isStopped while startRunning() is still blocked.
        let deadline = Date().addingTimeInterval(0.5)
        while !lifecycle.isStopped, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(lifecycle.isStopped, "stop() must not block on stateLock while startRunning() runs")
        XCTAssertFalse(store.publish(try buffer(width: 8), receivedAt: 30))

        releaseStart.signal()
        wait(for: [stopCompleted], timeout: 1.0)

        XCTAssertFalse(session.isRunning)
        XCTAssertGreaterThanOrEqual(session.stopCount, 2)
        XCTAssertFalse(lifecycle.restart())
        XCTAssertFalse(store.publish(try buffer(width: 16), receivedAt: 31))
        XCTAssertNil(store.snapshot())
    }

    func testLifecycleStopAndWaitRespectsTimeoutWhenSessionBlocks() throws {
        let store = ScreenCaptureFrameStore()
        let queue = DispatchQueue(label: "capture-lifecycle-tests.timeout")
        let enteredStart = expectation(description: "start entered startRunning")
        let releaseStart = DispatchSemaphore(value: 0)
        let session = MockCaptureRunningSession(onStart: {
            enteredStart.fulfill()
            releaseStart.wait()
        })
        let lifecycle = CaptureSourceLifecycle(session: session, frames: store, queue: queue)

        lifecycle.start()
        wait(for: [enteredStart], timeout: 1.0)

        let started = ProcessInfo.processInfo.systemUptime
        let drained = lifecycle.stopAndWait(timeout: 0.03)
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertFalse(drained)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertTrue(lifecycle.isStopped)
        XCTAssertFalse(store.publish(try buffer(width: 8), receivedAt: 40))

        let cleanupDone = expectation(description: "queue drained after release")
        releaseStart.signal()
        queue.async { cleanupDone.fulfill() }
        wait(for: [cleanupDone], timeout: 1.0)
        XCTAssertFalse(session.isRunning)
    }

    func testShutdownCoordinatorSharesDeadlineAndNeverRestoresUSBBeforeCaptureDrains() {
        let notifyQueue = DispatchQueue(label: "capture-shutdown-tests.notify")

        // Case 1: Capture source blocks past deadline -> stop returns within deadline,
        // captureDrained == false, usbRestored == false, and USB restore has NOT run early.
        let releaseCaptureStop = DispatchSemaphore(value: 0)
        let blockedSource = MockStoppableCaptureSource { completion in
            DispatchQueue.global().async {
                releaseCaptureStop.wait()
                completion?()
            }
        }
        let restoreLock = NSLock()
        var usbRestoreCalls = 0
        let postDrainUSBFinished = expectation(description: "USB restore ran after capture eventually drained")

        let t0 = ProcessInfo.processInfo.systemUptime
        let blockedCaptureResult = CaptureShutdownCoordinator.stop(
            waitTimeout: 0.04,
            activeSources: [blockedSource],
            notifyQueue: notifyQueue,
            restoreAllUSB: { _ in
                restoreLock.withLock { usbRestoreCalls += 1 }
                postDrainUSBFinished.fulfill()
                return true
            })
        let elapsed1 = ProcessInfo.processInfo.systemUptime - t0
        XCTAssertEqual(
            blockedCaptureResult,
            ScreenCaptureStopResult(initiated: true, captureDrained: false, usbRestored: false))
        XCTAssertLessThan(elapsed1, 0.5)
        XCTAssertEqual(
            restoreLock.withLock { usbRestoreCalls },
            0,
            "USB configuration restore must not run while capture session is still draining")
        releaseCaptureStop.signal()
        wait(for: [postDrainUSBFinished], timeout: 1.0)

        // Case 2: Capture drains promptly, USB restore blocks past remaining shared deadline ->
        // stop returns within deadline with captureDrained == true, usbRestored == false.
        let fastSource = MockStoppableCaptureSource { completion in completion?() }
        let releaseUSBRestore = DispatchSemaphore(value: 0)
        let usbEntered = expectation(description: "USB restore started")
        let t1 = ProcessInfo.processInfo.systemUptime
        let blockedUSBResult = CaptureShutdownCoordinator.stop(
            waitTimeout: 0.04,
            activeSources: [fastSource],
            notifyQueue: notifyQueue,
            restoreAllUSB: { _ in
                usbEntered.fulfill()
                releaseUSBRestore.wait()
                return true
            })
        let elapsed2 = ProcessInfo.processInfo.systemUptime - t1
        XCTAssertEqual(
            blockedUSBResult,
            ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: false))
        XCTAssertLessThan(elapsed2, 0.5)
        wait(for: [usbEntered], timeout: 1.0)
        releaseUSBRestore.signal()
        notifyQueue.sync {}

        // Case 3: Both capture drain and USB restore succeed within shared deadline.
        var eventOrder: [String] = []
        let cleanSource = MockStoppableCaptureSource { completion in
            eventOrder.append("captureStopped")
            completion?()
        }
        let cleanResult = CaptureShutdownCoordinator.stop(
            waitTimeout: 1.0,
            activeSources: [cleanSource],
            notifyQueue: notifyQueue,
            restoreAllUSB: { _ in
                eventOrder.append("usbRestored")
                return true
            })
        XCTAssertEqual(
            cleanResult,
            ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: true))
        XCTAssertTrue(cleanResult.isClean)
        XCTAssertEqual(eventOrder, ["captureStopped", "usbRestored"])

        // Case 4: Capture drain consumes part of the shared deadline budget; USB restore
        // receives ONLY the remaining monotonic deadline (never a second full budget).
        let partialSource = MockStoppableCaptureSource { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                completion?()
            }
        }
        let releasePartialUSB = DispatchSemaphore(value: 0)
        var observedRemainingAtUSBStart: TimeInterval = .infinity
        let partialUSBEntered = expectation(description: "USB restore started with reduced remaining budget")
        let partialResult = CaptureShutdownCoordinator.stop(
            waitTimeout: 0.09,
            activeSources: [partialSource],
            notifyQueue: notifyQueue,
            restoreAllUSB: { deadlineUptime in
                observedRemainingAtUSBStart = deadlineUptime - ProcessInfo.processInfo.systemUptime
                partialUSBEntered.fulfill()
                releasePartialUSB.wait()
                return true
            })
        wait(for: [partialUSBEntered], timeout: 1.0)
        XCTAssertLessThan(observedRemainingAtUSBStart, 0.06)
        XCTAssertEqual(
            partialResult,
            ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: false))
        releasePartialUSB.signal()
        notifyQueue.sync {}
    }

    func testErrorTrackerPreservesRuntimeErrorAcrossRestartUntilAcceptedFrameArrives() throws {
        let store = ScreenCaptureFrameStore()
        let queue = DispatchQueue(label: "capture-error-tracker-tests.queue")
        let session = MockCaptureRunningSession()
        let lifecycle = CaptureSourceLifecycle(session: session, frames: store, queue: queue)
        let tracker = CaptureSourceErrorTracker()

        let underlying = NSError(
            domain: NSOSStatusErrorDomain,
            code: 560_227_702,
            userInfo: ["AVErrorFourCharCode": "'!dev'"])
        let avError = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation could not be completed",
                NSLocalizedFailureReasonErrorKey: "An unknown error occurred (560227702)",
                NSUnderlyingErrorKey: underlying,
            ])

        let formatted = tracker.recordRuntimeError(avError, isStopped: lifecycle.isStopped)
        XCTAssertTrue(formatted.contains("560227702"))
        XCTAssertTrue(formatted.contains("'!dev'"))
        XCTAssertEqual(tracker.lastError, formatted)

        // Appending recovery diagnostics preserves the runtime error without duplicating.
        tracker.recordRecoveryError(
            CaptureValeriaRecoveryCoordinator.usbResourceShortageMessage,
            isStopped: lifecycle.isStopped)
        tracker.recordRecoveryError(
            CaptureValeriaRecoveryCoordinator.usbResourceShortageMessage,
            isStopped: lifecycle.isStopped)
        let combined = try XCTUnwrap(tracker.lastError)
        XCTAssertTrue(combined.contains("560227702"))
        XCTAssertTrue(
            combined.contains(CaptureValeriaRecoveryCoordinator.usbResourceShortageMessage))

        // Restarting the session MUST NOT erase `lastError` before an actual frame is accepted!
        XCTAssertTrue(lifecycle.restart())
        queue.sync {}
        XCTAssertEqual(tracker.lastError, combined)

        // A rejected frame on a stopped store MUST NOT clear `lastError`.
        store.stop()
        let rejected = tracker.publishFrameClearingPriorErrors(
            try buffer(width: 8), into: store, receivedAt: 10)
        XCTAssertEqual(rejected, .rejected)
        XCTAssertEqual(tracker.lastError, combined)

        // Resuming and accepting a real frame clears `lastError` immediately.
        store.resume()
        let first = tracker.publishFrameClearingPriorErrors(
            try buffer(width: 8), into: store, receivedAt: 11)
        XCTAssertEqual(first, .firstFrame)
        XCTAssertNil(tracker.lastError)

        // Subsequent runtime error is also cleared by `.subsequentFrame`.
        _ = tracker.recordRuntimeError(avError, isStopped: false)
        XCTAssertNotNil(tracker.lastError)
        let second = tracker.publishFrameClearingPriorErrors(
            try buffer(width: 16), into: store, receivedAt: 12)
        XCTAssertEqual(second, .subsequentFrame)
        XCTAssertNil(tracker.lastError)
    }

    func testErrorRecordedBetweenFramePublishAndClearIsPreservedAndPostStopErrorsAreIgnored() throws {
        let store = ScreenCaptureFrameStore()
        let tracker = CaptureSourceErrorTracker()

        let oldError = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [NSLocalizedDescriptionKey: "Initial capture error"])
        let concurrentError = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11819,
            userInfo: [NSLocalizedDescriptionKey: "Media services were reset"])

        _ = tracker.recordRuntimeError(oldError, isStopped: false)
        XCTAssertEqual(tracker.lastError, "Initial capture error")

        // 1. R6-P2-03 counterexample: Frame 1 is accepted by `store.publishOutcome`, and BEFORE
        // `clearOnAcceptedFrame` runs, a newer runtime error is recorded. The stale frame outcome
        // MUST NOT erase the newer runtime error!
        let first = tracker.publishFrameClearingPriorErrors(
            try buffer(width: 8),
            into: store,
            receivedAt: 1,
            beforeClearHook: {
                _ = tracker.recordRuntimeError(concurrentError, isStopped: false)
            })
        XCTAssertEqual(first, .firstFrame)
        XCTAssertEqual(
            tracker.lastError,
            "Media services were reset",
            "an error recorded after frame acceptance began must not be wiped by that older frame")

        // 2. Same barrier with a newly appended recovery diagnostic: Frame 2's pre-error revision
        // must not erase the newly recorded recovery error either.
        let second = tracker.publishFrameClearingPriorErrors(
            try buffer(width: 8),
            into: store,
            receivedAt: 2,
            beforeClearHook: {
                tracker.recordRecoveryError(
                    CaptureValeriaRecoveryCoordinator.usbResourceShortageMessage,
                    isStopped: false)
            })
        XCTAssertEqual(second, .subsequentFrame)
        let preservedCombined = try XCTUnwrap(tracker.lastError)
        XCTAssertTrue(preservedCombined.contains("Media services were reset"))
        XCTAssertTrue(
            preservedCombined.contains(CaptureValeriaRecoveryCoordinator.usbResourceShortageMessage))

        // 3. Once a subsequent frame (Frame 3) begins and is accepted AFTER the error with no
        // newer error intervening, `lastError` is cleared.
        let third = tracker.publishFrameClearingPriorErrors(
            try buffer(width: 16),
            into: store,
            receivedAt: 3)
        XCTAssertEqual(third, .subsequentFrame)
        XCTAssertNil(tracker.lastError)

        // 4. Stop vs error-recording interleaving: if an observer checked `!lifecycle.isStopped`
        // (`false`) just before `stop()` ran `errorTracker.markStopped()`, late post-stop writes
        // must not mutate `lastError`.
        tracker.markStopped()
        _ = tracker.recordRuntimeError(concurrentError, isStopped: false)
        tracker.recordRecoveryError("late recovery error", isStopped: false)
        XCTAssertNil(tracker.lastError)
    }
}

private final class MockStoppableCaptureSource: StoppableCaptureSource {
    private let handler: (((() -> Void)?) -> Void)

    init(handler: @escaping (((() -> Void)?) -> Void)) {
        self.handler = handler
    }

    func stop(completion: (() -> Void)?) {
        handler(completion)
    }
}

private final class MockCaptureRunningSession: CaptureRunningSession {
    private let lock = NSLock()
    private var running = false
    private var starts = 0
    private var stops = 0
    private let onStart: (() -> Void)?

    init(onStart: (() -> Void)? = nil) {
        self.onStart = onStart
    }

    var isRunning: Bool { lock.withLock { running } }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func startRunning() {
        onStart?()
        lock.withLock {
            starts += 1
            running = true
        }
    }

    func stopRunning() {
        lock.withLock {
            stops += 1
            running = false
        }
    }
}
