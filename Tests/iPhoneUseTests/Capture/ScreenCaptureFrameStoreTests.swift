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
}
