import XCTest

@testable import iPhoneUse

final class AutomaticPointerCalibrationTests: XCTestCase {
    private final class Phone {
        let width = 375, height = 667
        var x = 350.0, y = 340.0
        var verticalScale = 1.0
        var animate = false
        var reports = 0
        var captures = 0

        func distance(_ count: Int) -> Double {
            let n = Double(abs(count))
            return (0.3 * n + 0.07 * n * n) * Double(count.signum())
        }

        func send(_ dx: Int, _ dy: Int) {
            reports += 1
            x = max(0, min(Double(width - 1), x + distance(dx)))
            y = max(0, min(Double(height - 1), y + distance(dy) * verticalScale))
        }

        func frame() -> PointerMotionObservation.Frame {
            captures += 1
            var pixels = [UInt8](repeating: 240, count: width * height)
            let cx = Int(x.rounded())
            let cy = Int(y.rounded())
            for dy in -9...9 {
                for dx in -9...9 where dx * dx + dy * dy <= 81 {
                    let px = cx + dx
                    let py = cy + dy
                    if (0..<width).contains(px), (0..<height).contains(py) {
                        pixels[py * width + px] = 110
                    }
                }
            }
            if animate {
                for py in 80..<95 {
                    for px in 10..<40 { pixels[py * width + px] = captures % 2 == 0 ? 10 : 240 }
                }
            }
            return .init(width: width, height: height, pixels: pixels)
        }
    }

    private func measure(_ phone: Phone) throws -> RelativePointerCalibration {
        try AutomaticPointerCalibration(
            host: UUID(), screenID: "phone", width: phone.width, height: phone.height,
            send: phone.send, capture: phone.frame
        ).measure()
    }

    func testNonlinearPhoneAtRightEdgeMeasuresWithoutWebOrExistingProfile() throws {
        let phone = Phone()
        let result = try measure(phone)
        try result.validate()
        XCTAssertEqual(result.screenID, "phone")
        XCTAssertNil(result.vectorModel)
        for count in 1...32 {
            XCTAssertEqual(result.distances[count], phone.distance(count), accuracy: 0.8)
        }
        XCTAssertEqual(phone.x, Double(phone.width) * 0.4, accuracy: 3)
        XCTAssertEqual(phone.y, Double(phone.height) * 0.5, accuracy: 3)
    }

    func testAnimatedBackgroundAndDifferentVerticalGainCannotProduceAProfile() {
        let animated = Phone()
        animated.animate = true
        XCTAssertThrowsError(try measure(animated))
        let anisotropic = Phone()
        anisotropic.verticalScale = 1.5
        XCTAssertThrowsError(try measure(anisotropic))
    }

    func testLostSessionStopsBeforeFurtherReportsOrSaving() {
        let phone = Phone()
        let runner = AutomaticPointerCalibration(
            host: UUID(), screenID: "phone", width: phone.width, height: phone.height,
            send: { dx, dy in
                guard phone.reports < 5 else { throw DeviceError("disconnected") }
                phone.send(dx, dy)
            }, capture: phone.frame)
        XCTAssertThrowsError(try runner.measure())
        XCTAssertEqual(phone.reports, 5)
        XCTAssertEqual(phone.captures, 0)
    }

    func testOverlappingPointersAndClippedShapesAreNotDisplacementMeasurements() {
        let phone = Phone()
        phone.x = 150
        let before = phone.frame()
        phone.x += 3
        XCTAssertNil(PointerMotionObservation.motion(from: before, to: phone.frame(), direction: CGPoint(x: 1, y: 0)))
        phone.x = 160
        XCTAssertNil(PointerMotionObservation.motion(from: before, to: phone.frame(), direction: CGPoint(x: 1, y: 0)))
        phone.x = 374
        XCTAssertNil(PointerMotionObservation.motion(from: before, to: phone.frame(), direction: CGPoint(x: 1, y: 0)))
        phone.x = 220
        let motion = PointerMotionObservation.motion(from: before, to: phone.frame(), direction: CGPoint(x: 1, y: 0))
        XCTAssertEqual(motion?.delta.x, 70)
        XCTAssertEqual(motion?.delta.y, 0)
    }
}
