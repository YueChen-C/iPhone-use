import XCTest

@testable import iPhoneUse

final class RelativePointerScreenMatcherTests: XCTestCase {
    private func frame(_ x: Int, _ y: Int, inverted: Bool = false) -> [UInt8] {
        var pixels = [UInt8](repeating: inverted ? 20 : 240, count: 180 * 320)
        for dy in -4...4 {
            for dx in -4...4
            where dx * dx + dy * dy <= 16 && (0..<180).contains(x + dx) && (0..<320).contains(y + dy) {
                pixels[(y + dy) * 180 + x + dx] = inverted ? 230 : 100
            }
        }
        return pixels
    }

    func testRectangleIdentifiesLightAndDarkPointersWithoutARequiredGain() {
        for inverted in [false, true] {
            for distance in [8, 20, 35] {
                let frames = [
                    (30, 80), (30 + distance, 80), (30 + distance, 80 + distance),
                    (30, 80 + distance), (30, 80),
                ].map { frame($0.0, $0.1, inverted: inverted) }
                XCTAssertTrue(RelativePointerScreenMatcher.matches(frames))
            }
        }
    }

    func testNoMovementAndScreenAnimationsCannotIdentifyAHost() {
        let unchanged = frame(40, 80)
        XCTAssertFalse(RelativePointerScreenMatcher.matches(Array(repeating: unchanged, count: 5)))
        XCTAssertFalse(
            RelativePointerScreenMatcher.matches(
                (0..<5).map { n in
                    Array(repeating: UInt8(n * 40), count: unchanged.count)
                }))
        XCTAssertFalse(RelativePointerScreenMatcher.matches([]))
        XCTAssertFalse(RelativePointerScreenMatcher.matches(Array(repeating: [0], count: 5)))
    }

    func testClippedMovementWrongDirectionAndFailedReturnDoNotMatch() {
        for points in [
            [(30, 80), (30, 100), (50, 100), (50, 80), (30, 80)],
            [(30, 80), (50, 80), (50, 80), (30, 80), (30, 80)],
            [(30, 80), (50, 80), (50, 100), (30, 100), (35, 80)],
        ] {
            XCTAssertFalse(RelativePointerScreenMatcher.matches(points.map { frame($0.0, $0.1) }))
        }
    }

    func testDistantBackgroundChangesDoNotInvalidateLocalPointerEvidence() {
        var frames = [(30, 80), (50, 80), (50, 100), (30, 100), (30, 80)].map { frame($0.0, $0.1) }
        for i in 0..<40 { frames[1][i] = 0 }
        for i in 60..<100 { frames[4][i] = 0 }
        XCTAssertTrue(RelativePointerScreenMatcher.matches(frames))
    }

    func testClockAnimationLocationPulseAndScatteredCaptureNoiseDoNotHideThePointer() {
        // The captured Home screen has an animated clock well away from the
        // cursor; Maps also pulses its location marker during identification.
        var frames = [(85, 120), (94, 120), (94, 130), (85, 130), (85, 120)].map { frame($0.0, $0.1) }
        for i in frames.indices {
            for y in 75..<82 {
                frames[i][y * 180 + 20 + i] = 20
            }
            for y in 190..<195 {
                for x in 100..<105 { frames[i][y * 180 + x] = i.isMultiple(of: 2) ? 70 : 180 }
            }
            for pixel in stride(from: i * 17, to: 180 * 320, by: 701) {
                if !(70..<150).contains(pixel / 180) { frames[i][pixel] = 100 }
            }
        }
        XCTAssertTrue(RelativePointerScreenMatcher.matches(frames))
    }

    func testPointerCanReturnAtAClippedScreenEdge() {
        let frames = [(0, 3), (12, 3), (12, 15), (0, 15), (0, 3)].map { frame($0.0, $0.1) }
        XCTAssertTrue(RelativePointerScreenMatcher.matches(frames))
    }

    func testPointerMayHaveDifferentContrastAtDifferentCorners() {
        let points = [(30, 80), (50, 80), (50, 100), (30, 100), (30, 80)]
        let frames = points.map { point -> [UInt8] in
            var pixels = [UInt8](repeating: 240, count: 180 * 320)
            for y in 90..<120 {
                for x in 40..<65 { pixels[y * 180 + x] = 20 }
            }
            for dy in -4...4 {
                for dx in -4...4 where dx * dx + dy * dy <= 16 {
                    pixels[(point.1 + dy) * 180 + point.0 + dx] = point == (50, 100) ? 230 : 100
                }
            }
            return pixels
        }
        XCTAssertTrue(RelativePointerScreenMatcher.matches(frames))
    }

    func testFourIndependentMovingObjectsCannotRelayPointerEvidence() {
        let starts = [(30, 80), (90, 80), (90, 180), (30, 180)]
        let ends = [(50, 80), (90, 100), (70, 180), (30, 160)]
        let frames = (0..<5).map { frameIndex -> [UInt8] in
            var pixels = [UInt8](repeating: 240, count: 180 * 320)
            for i in starts.indices {
                let point = i < frameIndex ? ends[i] : starts[i]
                for dy in -4...4 {
                    for dx in -4...4 where dx * dx + dy * dy <= 16 {
                        pixels[(point.1 + dy) * 180 + point.0 + dx] = 100
                    }
                }
            }
            return pixels
        }
        XCTAssertFalse(RelativePointerScreenMatcher.matches(frames))
    }

    func testAnUnrestoredLocalBackgroundCannotProveAClosedPointerPath() {
        var frames = [(30, 80), (50, 80), (50, 100), (30, 100), (30, 80)].map { frame($0.0, $0.1) }
        for y in 76...84 {
            for x in 26...34 where (x - 30) * (x - 30) + (y - 80) * (y - 80) <= 16 {
                frames[4][y * 180 + x] = 180
            }
        }
        XCTAssertFalse(RelativePointerScreenMatcher.matches(frames))
    }

    func testUnmatchedConnectionIsNeverPresentedAsBluetoothDisconnected() {
        XCTAssertEqual(
            ControlConnectionStatus.resolve(
                hasScreen: true, hasMatchedHost: false, bluetoothState: .unmatched,
                inputIsCurrent: false, inputIsReady: false, screenPermitsInput: true), .unmatched)
        XCTAssertEqual(
            ControlConnectionStatus.resolve(
                hasScreen: true, hasMatchedHost: true, bluetoothState: .connected,
                inputIsCurrent: false, inputIsReady: false, screenPermitsInput: true), .connecting)
        XCTAssertEqual(
            ControlConnectionStatus.resolve(
                hasScreen: true, hasMatchedHost: false, bluetoothState: .disconnected,
                inputIsCurrent: false, inputIsReady: false, screenPermitsInput: true), .disconnected)
    }
}
