import Foundation
import XCTest

@testable import iPhoneUse

final class ControlAPIPointerFallbackTests: XCTestCase {
    private let actions: [ControlAPI.Action] = [.tap, .move, .swipe]

    private final class Phone {
        let size = CGSize(width: 375, height: 667)
        var position = CGPoint(x: 100, y: 120)
        var time: TimeInterval = 100
        var sequence: UInt64 = 0
        var captures = 0
        var ready = true
        var absoluteReady = true
        var calibrationRequired = true
        var failCapture = false
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []

        func input(mapped: Bool) -> DeviceInput {
            let host = UUID()
            let calibration =
                mapped
                ? RelativePointerCalibration(
                    host: host, screenWidth: Int(size.width), screenHeight: Int(size.height),
                    reportInterval: 0.01, distances: (0...127).map { Double($0) * 2 }) : nil
            return DeviceInput(
                host: host, session: UUID(), calibration: calibration, calibrationRequired: calibrationRequired,
                screenSize: { self.size },
                sleep: {
                    self.pauses.append($0)
                    self.time += $0
                },
                reportSender: { id, bytes in
                    self.reports.append((id, bytes))
                    if id == .relativeMouse {
                        self.position.x = max(
                            0,
                            min(
                                self.size.width - 1,
                                self.position.x + Double(Int8(bitPattern: bytes[1])) * 2))
                        self.position.y = max(
                            0,
                            min(
                                self.size.height - 1,
                                self.position.y + Double(Int8(bitPattern: bytes[2])) * 2))
                    }
                },
                reportReadiness: { report, _, _ in self.ready && (report != .absolutePointer || self.absoluteReady) },
                reportDrainer: { _ in true })
        }

        func capture(_ after: UInt64?, _ notBefore: TimeInterval) throws -> VisualPointerFrame {
            captures += 1
            if failCapture { throw DeviceError("simulated USB failure") }
            time = max(time, notBefore) + 0.01
            sequence += 1
            let width = Int(size.width)
            let height = Int(size.height)
            var pixels = [UInt8](repeating: 240, count: width * height)
            let cx = Int(position.x.rounded())
            let cy = Int(position.y.rounded())
            for dy in -9...9 {
                for dx in -9...9 where dx * dx + dy * dy <= 81 {
                    let x = cx + dx
                    let y = cy + dy
                    if (0..<width).contains(x), (0..<height).contains(y) { pixels[y * width + x] = 110 }
                }
            }
            return VisualPointerFrame(
                frame: .init(width: width, height: height, pixels: pixels),
                sequence: sequence, receivedAt: time)
        }

        func perform(
            _ action: ControlAPI.Action, body: [String: Any], input: DeviceInput
        ) throws -> HTTPResponse? {
            try ControlAPI.performPointerAction(
                action, body: body, input: input, screenSize: size, screenName: "test phone",
                capture: capture, now: { self.time })
        }

        var pressed: Bool {
            reports.contains { $0.0 == .relativeMouse && $0.1[0] != 0 }
        }
    }

    private func body(for action: ControlAPI.Action, mapped: Bool) -> [String: Any] {
        if mapped {
            if action == .swipe {
                return ["fraction": true, "points": [["x": 0.0, "y": 0.0], ["x": 0.1, "y": 0.1]], "duration": 0.1]
            }
            return ["fraction": true, "x": 0.0, "y": 0.0, "hold": 11.0]
        }
        if action == .swipe {
            return ["points": [["x": 164.0, "y": 184.0], ["x": 228.0, "y": 248.0]], "duration": 0.3]
        }
        return ["x": 164.0, "y": 184.0]
    }

    func testReadyCoordinateActionsExecuteLegacyInputWithoutCapture() throws {
        for action in actions {
            let phone = Phone()
            phone.failCapture = true
            let input = phone.input(mapped: true)
            XCTAssertTrue(input.isPointerReady)

            XCTAssertNil(try phone.perform(action, body: body(for: action, mapped: true), input: input))

            XCTAssertEqual(phone.captures, 0)
            XCTAssertFalse(phone.reports.isEmpty, "The legacy action must actually execute")
            XCTAssertEqual(phone.pressed, action != .move)
            if action == .tap {
                XCTAssertTrue(
                    phone.pauses.contains(11), "The visual-only ten-second hold limit must not change ready taps")
            }
        }
    }

    func testUnmappedCoordinateActionsExecuteObservedFallbackWithoutPromotingReadiness() throws {
        for action in actions {
            let phone = Phone()
            let input = phone.input(mapped: false)
            XCTAssertFalse(input.isPointerReady)
            XCTAssertTrue(input.visualPointerTransportAvailable)

            XCTAssertNil(try phone.perform(action, body: body(for: action, mapped: false), input: input))

            XCTAssertGreaterThan(phone.captures, 0)
            XCTAssertFalse(phone.reports.isEmpty)
            XCTAssertEqual(phone.pressed, action != .move)
            XCTAssertFalse(input.isPointerReady)
            XCTAssertTrue(input.needsCalibration)
            XCTAssertFalse(phone.reports.contains { $0.0 == .absolutePointer })
        }
    }

    func testUnavailableTransportReturns503BeforeParsingOrSendingInput() throws {
        for action in actions {
            let phone = Phone()
            phone.ready = false
            phone.failCapture = true
            let input = phone.input(mapped: false)
            let malformed: [String: Any] = ["x": "bad", "y": true, "hold": "bad", "points": []]
            let failure = try ControlAPI.performPointerAction(
                action, body: malformed, input: input, screenSize: nil, screenName: "test phone",
                capture: phone.capture, now: { phone.time })

            XCTAssertEqual(failure?.status, 503)
            XCTAssertEqual(phone.captures, 0)
            // Finish queued estimate invalidation; this neutral call sends no HID report.
            try input.nudge(dx: 0, dy: 0, click: false)
            XCTAssertTrue(phone.reports.isEmpty)
        }
    }

    func testFailedVisualObservationNeverFallsBackToLegacyInput() {
        for action in actions {
            let phone = Phone()
            phone.failCapture = true
            // Legacy coordinate mapping would permit an action, but its absolute
            // report is unavailable. An accidental retry could therefore click.
            phone.calibrationRequired = false
            phone.absoluteReady = false
            let input = phone.input(mapped: false)
            XCTAssertFalse(input.isPointerReady)
            XCTAssertTrue(input.visualPointerTransportAvailable)
            XCTAssertFalse(input.needsCalibration)

            XCTAssertThrowsError(try phone.perform(action, body: body(for: action, mapped: false), input: input))

            XCTAssertEqual(phone.captures, 1)
            XCTAssertTrue(phone.reports.isEmpty)
            XCTAssertFalse(phone.pressed)
        }
    }

    func testVisualTapRetainsItsOwnBoundedHoldValidation() {
        let invalidHolds: [Any] = [11.0, true, Double.nan, "bad"]
        for hold in invalidHolds {
            let phone = Phone()
            var arguments = body(for: .tap, mapped: false)
            arguments["hold"] = hold

            XCTAssertThrowsError(try phone.perform(.tap, body: arguments, input: phone.input(mapped: false)))

            XCTAssertEqual(phone.captures, 0)
            XCTAssertTrue(phone.reports.isEmpty)
        }
    }
}
