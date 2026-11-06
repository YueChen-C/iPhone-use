import XCTest
@testable import iPhoneUse

final class DragPointerGainRegressionTests: XCTestCase {
    func testCancellationStopsAPISwipeAndWindowRelease() throws {
        for windowRelease in [false, true] {
            let width = 375, height = 667
            var x = 0.0, y = 0.0
            var held = false
            var movements = 0
            var allowed = true
            var input: DeviceInput!
            input = DeviceInput(
                host: UUID(), session: UUID(),
                screenSize: { CGSize(width: width, height: height) },
                inputIsAllowed: { allowed },
                pointerFrame: {
                    var pixels = [UInt8](repeating: 240, count: width * height)
                    for dy in -9...9 {
                        for dx in -9...9 where dx * dx + dy * dy <= 81 {
                            let px = Int(x.rounded()) + dx, py = Int(y.rounded()) + dy
                            if (0..<width).contains(px), (0..<height).contains(py) {
                                pixels[py * width + px] = 110
                            }
                        }
                    }
                    return .init(width: width, height: height, pixels: pixels)
                }, sleep: { _ in },
                reportSender: { id, bytes in
                    if id == .absolutePointer {
                        x = Double(Int(bytes[1]) | Int(bytes[2]) << 8) / 32767 * Double(width)
                        y = Double(Int(bytes[3]) | Int(bytes[4]) << 8) / 32767 * Double(height)
                    } else if id == .relativeMouse {
                        held = bytes[0] == 1
                        let dx = Int(Int8(bitPattern: bytes[1])), dy = Int(Int8(bitPattern: bytes[2]))
                        x += Double(dx * abs(dx)) * 0.1
                        y += Double(dy * abs(dy)) * 0.1 * 1.03
                        if held && (dx != 0 || dy != 0) {
                            movements += 1
                            if movements == 3 { input.cancelPointer() }
                            // Keep a broken cancellation implementation from hanging this test.
                            if movements > 100 { allowed = false }
                        }
                    }
                }, reportReadiness: { _, _, _ in true })
            input.press(x: 0.3, y: 0.3)
            input.release(x: 0.3, y: 0.3)
            try input.type("")
            if windowRelease {
                input.press(x: 0.3, y: 0.3)
                input.release(x: 0.3, y: 0.7)
            } else {
                try input.swipe(points: [(0.3, 0.3), (0.3, 0.7)], duration: 0.3)
            }
            try input.type("")
            XCTAssertEqual(movements, 3, "Cancellation must stop further held movement reports")
            XCTAssertTrue(allowed, "The test's emergency cutoff must not be needed")
            XCTAssertFalse(held)
        }
    }

    func testAcceptedVerticalGainMustNotOscillateForOrdinarySwipe() throws {
        let width = 375, height = 667
        var x = 0.0, y = 0.0
        var held = false
        var allowed = true
        var heldMovements = 0
        var capTripped = false
        var finalReports: [String] = []
        var lastAbsoluteY = 0.0
        var input: DeviceInput!
        input = DeviceInput(
            host: UUID(), session: UUID(),
            screenSize: { CGSize(width: width, height: height) },
            inputIsAllowed: { allowed },
            pointerFrame: {
                var pixels = [UInt8](repeating: 240, count: width * height)
                for dy in -9...9 {
                    for dx in -9...9 where dx * dx + dy * dy <= 81 {
                        let px = Int(x.rounded()) + dx, py = Int(y.rounded()) + dy
                        if (0..<width).contains(px), (0..<height).contains(py) { pixels[py * width + px] = 110 }
                    }
                }
                return .init(width: width, height: height, pixels: pixels)
            }, sleep: { _ in },
            reportSender: { id, bytes in
                if id == .absolutePointer {
                    x = Double(Int(bytes[1]) | Int(bytes[2]) << 8) / 32767 * Double(width)
                    y = Double(Int(bytes[3]) | Int(bytes[4]) << 8) / 32767 * Double(height)
                    lastAbsoluteY = y
                } else if id == .relativeMouse {
                    held = bytes[0] == 1
                    let dx = Int(Int8(bitPattern: bytes[1])), dy = Int(Int8(bitPattern: bytes[2]))
                    x += Double(dx * abs(dx)) * 0.1
                    y += Double(dy * abs(dy)) * 0.1 * 1.03
                    if held && (dx != 0 || dy != 0) {
                        heldMovements += 1
                        if heldMovements >= 195 { finalReports.append("#\(heldMovements) dx=\(dx) dy=\(dy) y=\(y)") }
                        if heldMovements == 100 {
                            print("REVIEW cancel requested at report 100; held=\(held)")
                            input.cancelPointer()
                        }
                        if heldMovements > 200 { capTripped = true; allowed = false }
                    }
                }
            }, reportReadiness: { _, _, _ in true })
        input.press(x: 0.3, y: 0.3)
        input.release(x: 0.3, y: 0.3)
        try input.type("")
        let info = try XCTUnwrap(input.pointerStatus["preparation"] as? [String: Any])
        let curve = try XCTUnwrap(info["dragDistances"] as? [Double])
        let scale = try XCTUnwrap(info["dragVerticalScale"] as? Double)
        print("REVIEW vertical scale=\(scale), curve=\(curve)")
        XCTAssertGreaterThan(scale, 1)
        let endY = 0.401
        print("REVIEW ordinary swipe start=(0.3,0.3) end=(0.3,\(endY)), distance=\((endY - 0.3) * Double(height))px")
        try input.swipe(points: [(0.3, 0.3), (0.3, endY)], duration: 0.3)
        print("REVIEW held movement reports=\(heldMovements), capTripped=\(capTripped), finalReports=\(finalReports)")
        print("REVIEW last absolute y=\(lastAbsoluteY), tolerance=\(curve[1] / 2), minimum y step=\(curve[1] * scale)")
        XCTAssertFalse(capTripped, "Accepted calibration must converge; the cap avoids an infinite test")
        XCTAssertFalse(held)
    }
    func testEndpointObservationAddsHoldBeforeRelease() throws {
        let width = 375, height = 667
        var x = 0.0, y = 0.0, clock = 0.0
        var held = false
        var lastMovementTime = 0.0
        var releaseTime = 0.0
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: width, height: height) },
            pointerFrame: {
                var pixels = [UInt8](repeating: 240, count: width * height)
                for dy in -9...9 {
                    for dx in -9...9 where dx * dx + dy * dy <= 81 {
                        let px = Int(x.rounded()) + dx, py = Int(y.rounded()) + dy
                        if (0..<width).contains(px), (0..<height).contains(py) { pixels[py * width + px] = 110 }
                    }
                }
                return .init(width: width, height: height, pixels: pixels)
            }, sleep: { clock += $0 }, monotonicTime: { clock },
            reportSender: { id, bytes in
                if id == .absolutePointer {
                    x = Double(Int(bytes[1]) | Int(bytes[2]) << 8) / 32767 * Double(width)
                    y = Double(Int(bytes[3]) | Int(bytes[4]) << 8) / 32767 * Double(height)
                } else if id == .relativeMouse {
                    let nextHeld = bytes[0] == 1
                    if held && !nextHeld { releaseTime = clock }
                    held = nextHeld
                    let dx = Int(Int8(bitPattern: bytes[1])), dy = Int(Int8(bitPattern: bytes[2]))
                    x += Double(dx * abs(dx)) * 0.1
                    y += Double(dy * abs(dy)) * 0.1
                    if held && (dx != 0 || dy != 0) { lastMovementTime = clock }
                }
            }, reportReadiness: { _, _, _ in true })
        try input.swipe(points: [(0.3, 0.6), (0.6, 0.6)], duration: 0.3)
        print("REVIEW delay from last movement to release = \(releaseTime - lastMovementTime)s")
        // The PR explicitly chooses endpoint observation before release.
        // Verify that impact without inventing a fast-release requirement.
        XCTAssertEqual(releaseTime - lastMovementTime, 0.43, accuracy: 0.000001)
        XCTAssertFalse(held)
    }

}
