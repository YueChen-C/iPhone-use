import XCTest

@testable import iPhoneUse

final class DragPointerCalibrationTests: XCTestCase {
    func testMeasuredCurveFitsAndRejectsDifferentVerticalGain() throws {
        func measure(verticalGain: Double, curve: [Double]? = nil, verticalScale: (Double) -> Void = { _ in }) throws
            -> [Double]
        {
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
                    func distance(_ count: Int) -> Double {
                        let magnitude = abs(count)
                        let value =
                            curve.flatMap { magnitude < $0.count ? $0[magnitude] : nil }
                            ?? Double(magnitude * magnitude) * 0.1
                        return count < 0 ? -value : value
                    }
                    x += distance(dx)
                    y += distance(dy) * verticalGain
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
                }, verticalScale: verticalScale)
        }
        XCTAssertEqual(try measure(verticalGain: 1)[8], 6.4, accuracy: 0.1)
        XCTAssertThrowsError(try measure(verticalGain: 1.5))
        var observedVerticalScale = 0.0
        _ = try measure(verticalGain: 1.03, verticalScale: { observedVerticalScale = $0 })
        XCTAssertEqual(observedVerticalScale, 1.03, accuracy: 0.015)
        let nonlinear = [0.0, 0.2, 0.7, 1.5, 2.7, 4.1, 5.1, 6.0, 7.2]
        let measured = try measure(verticalGain: 1, curve: nonlinear)
        // Two integer-pixel endpoints add at most 1/report quantization
        // error; the shortest sample contains eight reports.
        for count in 1...8 {
            XCTAssertEqual(measured[count], nonlinear[count], accuracy: 0.13)
        }
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
