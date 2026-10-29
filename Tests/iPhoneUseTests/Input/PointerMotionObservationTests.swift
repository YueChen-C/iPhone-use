import CoreGraphics
import XCTest

@testable import iPhoneUse

final class PointerMotionObservationTests: XCTestCase {
    private let width = 400
    private let height = 400

    private func disk(_ pixels: inout [UInt8], x: Int, y: Int) {
        for dy in -14...14 {
            for dx in -14...14 where dx * dx + dy * dy <= 14 * 14 {
                pixels[(y + dy) * width + x + dx] = 0
            }
        }
    }

    private func pair(
        lineHeight: Int = 0, isolatedPixels: Int = 0,
        thirdDisk: Bool = false, nonCircularBlock: Bool = false
    ) -> (PointerMotionObservation.Frame, PointerMotionObservation.Frame) {
        var before = [UInt8](repeating: 255, count: width * height)
        var after = before
        disk(&before, x: 80, y: 80)
        disk(&after, x: 200, y: 80)
        for y in 200..<(200 + lineHeight) { after[y * width + 80] = 0 }
        for index in 0..<isolatedPixels {
            let x = 200 + (index % 20) * 2
            let y = 200 + (index / 20) * 2
            after[y * width + x] = 0
        }
        if thirdDisk { disk(&after, x: 300, y: 300) }
        if nonCircularBlock {
            for y in 300..<320 {
                for x in 280..<320 { after[y * width + x] = 0 }
            }
        }
        return (
            .init(width: width, height: height, pixels: before),
            .init(width: width, height: height, pixels: after)
        )
    }

    private func motion(
        _ frames: (PointerMotionObservation.Frame, PointerMotionObservation.Frame)
    ) -> PointerMotionObservation.Motion? {
        PointerMotionObservation.motion(from: frames.0, to: frames.1, direction: CGPoint(x: 1, y: 0))
    }

    func testTwentyFourPixelTextEdgeAndSparseNoisePreservePointerObservation() throws {
        // Reproduce the observed component geometry without storing phone frames:
        // one 1 x 24 text edge plus 111 isolated changed pixels, away from disks.
        let observed = try XCTUnwrap(motion(pair(lineHeight: 24, isolatedPixels: 111)))
        XCTAssertEqual(observed.from, CGPoint(x: 80.5, y: 80.5))
        XCTAssertEqual(observed.to, CGPoint(x: 200.5, y: 80.5))
    }

    func testThinAndSparseFragmentsShareExactlyTheExistingNoiseBudget() {
        XCTAssertNotNil(motion(pair(lineHeight: 145, isolatedPixels: 111)))
        XCTAssertNil(motion(pair(lineHeight: 146, isolatedPixels: 111)))
    }

    func testAdditionalCircularCandidateStillFails() {
        XCTAssertNil(motion(pair(lineHeight: 24, isolatedPixels: 111, thirdDisk: true)))
    }

    func testLargeNonCircularChangeStillFails() {
        XCTAssertNil(motion(pair(nonCircularBlock: true)))
    }
}
