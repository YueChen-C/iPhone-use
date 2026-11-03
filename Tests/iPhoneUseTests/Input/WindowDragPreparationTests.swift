import XCTest

@testable import iPhoneUse

final class WindowDragPreparationTests: XCTestCase {
    func testFirstWindowDragMeasuresBeforePressAndCancellationNeverPresses() throws {
        for cancelled in [false, true] {
            var x = 0.0
            var y = 0.0
            var captures = 0
            var presses = 0
            var held = false
            var input: DeviceInput!
            input = DeviceInput(
                host: UUID(), session: UUID(),
                screenSize: { CGSize(width: 375, height: 667) },
                pointerFrame: {
                    captures += 1
                    if cancelled && captures == 1 { input.cancelPointer() }
                    var pixels = [UInt8](repeating: 240, count: 375 * 667)
                    for dy in -9...9 {
                        for dx in -9...9 where dx * dx + dy * dy <= 81 {
                            let px = Int(x.rounded()) + dx
                            let py = Int(y.rounded()) + dy
                            if (0..<375).contains(px), (0..<667).contains(py) { pixels[py * 375 + px] = 110 }
                        }
                    }
                    return .init(width: 375, height: 667, pixels: pixels)
                }, sleep: { _ in },
                reportSender: { id, bytes in
                    if id == .absolutePointer {
                        x = Double(Int(bytes[1]) | Int(bytes[2]) << 8) / 32767 * 375
                        y = Double(Int(bytes[3]) | Int(bytes[4]) << 8) / 32767 * 667
                    } else if id == .relativeMouse {
                        if bytes[0] == 1 && !held {
                            presses += 1
                            XCTAssertGreaterThanOrEqual(captures, 8)
                        }
                        held = bytes[0] == 1
                        let dx = Int(Int8(bitPattern: bytes[1]))
                        let dy = Int(Int8(bitPattern: bytes[2]))
                        x += Double(dx * abs(dx)) * 0.1
                        y += Double(dy * abs(dy)) * 0.1
                    }
                }, reportReadiness: { _, _, _ in true })
            input.press(x: 0.3, y: 0.3)
            input.drag(x: 0.5, y: 0.5)
            input.release(x: 0.6, y: 0.6)
            try input.type("")  // Drain queued work without cancelling the gesture.
            XCTAssertEqual(presses, cancelled ? 0 : 1)
            XCTAssertFalse(held)
            if !cancelled {
                XCTAssertEqual(x, 375 * 0.6, accuracy: 3)
                XCTAssertEqual(y, 667 * 0.6, accuracy: 3)
            }
        }
    }
}
