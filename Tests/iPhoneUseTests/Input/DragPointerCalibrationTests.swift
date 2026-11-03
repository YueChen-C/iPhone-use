import XCTest

@testable import iPhoneUse

final class DragPointerCalibrationTests: XCTestCase {
    func testMeasuredCurveFitsAndRejectsDifferentVerticalGain() throws {
        func measure(verticalGain: Double) throws -> [Double] {
            let width = 375
            let height = 667
            var x = 0.0
            var y = 0.0
            return try DragPointerCalibration.measure(
                size: CGSize(width: width, height: height),
                position: {
                    x = $0 * Double(width)
                    y = $1 * Double(height)
                },
                send: { dx, dy in
                    x += Double(dx * abs(dx)) * 0.1
                    y += Double(dy * abs(dy)) * 0.1 * verticalGain
                },
                capture: {
                    var pixels = [UInt8](repeating: 240, count: width * height)
                    for dy in -9...9 {
                        for dx in -9...9 where dx * dx + dy * dy <= 81 {
                            let px = Int(x.rounded()) + dx
                            let py = Int(y.rounded()) + dy
                            if (0..<width).contains(px), (0..<height).contains(py) {
                                pixels[py * width + px] = 110
                            }
                        }
                    }
                    return .init(width: width, height: height, pixels: pixels)
                })
        }
        XCTAssertEqual(try measure(verticalGain: 1)[8], 6.4, accuracy: 0.1)
        XCTAssertThrowsError(try measure(verticalGain: 1.5))
    }

    func testFitUsesMeasuredPixelsWithoutScreenWidthScaling() throws {
        let curve = try DragPointerCalibration.fit(six: 3.6, fourteen: 19.6)
        XCTAssertEqual(curve[6], 3.6, accuracy: 0.001)
        XCTAssertEqual(curve[8], 6.4, accuracy: 0.001)
        XCTAssertEqual(curve.count, 9)
        XCTAssertThrowsError(try DragPointerCalibration.fit(six: .nan, fourteen: 1))
        XCTAssertThrowsError(try DragPointerCalibration.fit(six: 20, fourteen: 1))
    }
}
