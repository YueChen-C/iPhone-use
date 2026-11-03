import XCTest

@testable import iPhoneUse

final class PointerTurnTests: XCTestCase {
    func testEveryTurnRoundTripsAbsoluteAndRelativeCoordinates() {
        for turn in PointerTurn.allCases {
            let point = CGPoint(x: 0.23, y: 0.71)
            let raw = turn.rawPoint(for: point)
            let actual = turn.screenPoint(for: raw)
            XCTAssertEqual(actual.x, point.x, accuracy: 0.00001)
            XCTAssertEqual(actual.y, point.y, accuracy: 0.00001)
            let delta = turn.rawDelta(dx: 7, dy: -3)
            let origin = turn.screenPoint(for: .zero)
            let end = turn.screenPoint(for: CGPoint(x: delta.0, y: delta.1))
            XCTAssertEqual(end.x - origin.x, 7)
            XCTAssertEqual(end.y - origin.y, -3)
        }
    }

    func testRotatedAbsoluteTrajectoryIsDetectedWithoutAcceptingBlankFrames() {
        let targets = PointerScreenMatcher.gutterProbeTargets
        for turn in PointerTurn.allCases {
            let frames = [targets[0], targets[1], targets[2], targets[0]].map { target in
                let point = turn.screenPoint(for: CGPoint(x: target.x, y: target.y))
                var pixels = [UInt8](repeating: 230, count: 90 * 195)
                let x = Int((point.x * 90).rounded())
                let y = Int((point.y * 195).rounded())
                for dy in -2...2 {
                    for dx in -2...2 where dx * dx + dy * dy <= 4 {
                        pixels[(y + dy) * 90 + x + dx] = 80
                    }
                }
                return pixels
            }
            XCTAssertEqual(PointerScreenMatcher.pointerTurn(frames, targets: targets), turn)
        }
        XCTAssertNil(
            PointerScreenMatcher.pointerTurn(
                Array(repeating: [UInt8](repeating: 230, count: 90 * 195), count: 4), targets: targets))
    }
}

extension PointerTurnTests {
    func testLiveOrientationProofCorrectsTapAndRejectsBlankFrames() throws {
        for turn in PointerTurn.allCases {
            var raw = CGPoint.zero
            var pressed = false
            let input = DeviceInput(
                host: UUID(), session: UUID(),
                screenSize: { CGSize(width: 90, height: 195) },
                orientationFrame: {
                    let point = turn.screenPoint(for: raw)
                    var pixels = [UInt8](repeating: 230, count: 90 * 195)
                    let x = Int((point.x * 90).rounded())
                    let y = Int((point.y * 195).rounded())
                    for dy in -2...2 {
                        for dx in -2...2 where dx * dx + dy * dy <= 4 {
                            pixels[(y + dy) * 90 + x + dx] = 80
                        }
                    }
                    return pixels
                }, sleep: { _ in },
                reportSender: { id, bytes in
                    if id == .absolutePointer {
                        raw = CGPoint(
                            x: Double(Int(bytes[1]) | Int(bytes[2]) << 8) / 32767,
                            y: Double(Int(bytes[3]) | Int(bytes[4]) << 8) / 32767)
                    } else if id == .relativeMouse && bytes[0] == 1 {
                        pressed = true
                    }
                }, reportReadiness: { _, _, _ in true })
            try input.tap(x: 0.23, y: 0.71)
            let actual = turn.screenPoint(for: raw)
            XCTAssertEqual(actual.x, 0.23, accuracy: 0.0001)
            XCTAssertEqual(actual.y, 0.71, accuracy: 0.0001)
            XCTAssertTrue(pressed)
        }
        var pressed = false
        let input = DeviceInput(
            host: UUID(), session: UUID(),
            orientationFrame: { [UInt8](repeating: 230, count: 90 * 195) }, sleep: { _ in },
            reportSender: { id, bytes in if id == .relativeMouse && bytes[0] == 1 { pressed = true } },
            reportReadiness: { _, _, _ in true })
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertFalse(pressed)
    }
}
