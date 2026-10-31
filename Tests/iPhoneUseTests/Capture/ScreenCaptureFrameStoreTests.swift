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
}
