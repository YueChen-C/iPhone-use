import Foundation
import XCTest

@testable import iPhoneUse

final class DeviceInputVisualTests: XCTestCase {
    /// A phone with a visible circular pointer and a simple two-pixels-per-count
    /// response. Tests observe the DeviceInput boundary, not the controller's steps.
    private final class Phone {
        let width = 375
        let height = 667
        var point = CGPoint(x: 100, y: 120)
        var time: TimeInterval = 100
        var sequence: UInt64 = 0
        var captures = 0
        var drains = 0
        var allowed = true
        var ready = true
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        var captureFailureAt: Int?
        var staleSequenceAt: Int?
        var staleTimestampAt: Int?
        var drainFailureAt: Int?
        var failDrainAfterPress = false
        var onReport: ((ReportID, [UInt8]) -> Void)?

        var size: CGSize { CGSize(width: width, height: height) }
        // Two successful diagonal probes reach this point from the initial pose.
        var nearbyTarget: CGPoint { CGPoint(x: 164, y: 184) }
        var buttonDowns: [[UInt8]] {
            reports.filter { $0.0 == .relativeMouse && $0.1[0] != 0 }.map { $0.1 }
        }
        var buttonReports: [[UInt8]] {
            reports.filter {
                $0.0 == .relativeMouse && $0.1[1] == 0 && $0.1[2] == 0
            }.map { $0.1 }
        }
        var buttonTransitions: [UInt8] {
            var previous: UInt8 = 0
            return reports.compactMap { id, bytes in
                guard id == .relativeMouse, bytes[0] != previous else { return nil }
                previous = bytes[0]
                return previous
            }
        }

        func input(
            session: UUID? = UUID(), calibration: RelativePointerCalibration? = nil,
            reportDrainer: ((TimeInterval) -> Bool)? = nil,
            visualReportSender: ((ReportID, [UInt8], @escaping () -> Bool) -> Void)? = nil
        ) -> DeviceInput {
            DeviceInput(
                host: calibration?.host ?? UUID(), session: session,
                calibration: calibration, calibrationRequired: true,
                screenSize: { self.size }, inputIsAllowed: { self.allowed },
                sleep: { seconds in
                    self.pauses.append(seconds)
                    self.time += seconds
                },
                reportSender: send,
                reportReadiness: { _, _, _ in self.ready },
                reportDrainer: { timeout in
                    self.drains += 1
                    if let reportDrainer { return reportDrainer(timeout) }
                    return self.drains != self.drainFailureAt
                        && !(self.failDrainAfterPress && !self.buttonDowns.isEmpty)
                }, visualReportSender: visualReportSender)
        }

        func send(_ id: ReportID, _ bytes: [UInt8]) {
            reports.append((id, bytes))
            if id == .relativeMouse {
                point.x = max(0, min(Double(width - 1), point.x + Double(Int8(bitPattern: bytes[1])) * 2))
                point.y = max(0, min(Double(height - 1), point.y + Double(Int8(bitPattern: bytes[2])) * 2))
            }
            onReport?(id, bytes)
        }

        func capture(_ after: UInt64?, _ notBefore: TimeInterval) throws -> VisualPointerFrame {
            captures += 1
            if captures == captureFailureAt { throw DeviceError("simulated USB capture failure") }
            time = max(time, notBefore) + 0.01
            sequence += 1
            var pixels = [UInt8](repeating: 240, count: width * height)
            let cx = Int(point.x.rounded())
            let cy = Int(point.y.rounded())
            for dy in -9...9 {
                for dx in -9...9 where dx * dx + dy * dy <= 81 {
                    let x = cx + dx
                    let y = cy + dy
                    if (0..<width).contains(x), (0..<height).contains(y) {
                        pixels[y * width + x] = 110
                    }
                }
            }
            return VisualPointerFrame(
                frame: .init(width: width, height: height, pixels: pixels),
                sequence: captures == staleSequenceAt ? (after ?? 0) : sequence,
                receivedAt: captures == staleTimestampAt ? notBefore - 1 : time)
        }

        func tap(_ input: DeviceInput, hold: TimeInterval = 0.08) throws {
            try input.visualTap(
                x: nearbyTarget.x / Double(width), y: nearbyTarget.y / Double(height),
                hold: hold, size: size, capture: capture, now: { self.time })
        }
    }

    func testVisualMovementDoesNotPromoteMissingCalibrationToReady() throws {
        let phone = Phone()
        let input = phone.input()
        XCTAssertTrue(input.visualPointerTransportAvailable)
        XCTAssertTrue(input.needsCalibration)
        XCTAssertFalse(input.isPointerReady)

        try input.visualMove(
            x: phone.nearbyTarget.x / Double(phone.width),
            y: phone.nearbyTarget.y / Double(phone.height), size: phone.size,
            capture: phone.capture, now: { phone.time })

        XCTAssertLessThanOrEqual(hypot(phone.point.x - phone.nearbyTarget.x, phone.point.y - phone.nearbyTarget.y), 5)
        XCTAssertTrue(phone.buttonDowns.isEmpty)
        XCTAssertNil(input.calibration)
        XCTAssertTrue(input.needsCalibration)
        XCTAssertFalse(input.isPointerReady)
    }

    func testInvalidCoordinatesAndHoldFailBeforeCaptureOrReports() {
        let invalid: [(Double, Double, TimeInterval)] = [
            (.nan, 0.5, 1), (.infinity, 0.5, 1), (-0.01, 0.5, 1),
            (1.01, 0.5, 1), (0.5, .nan, 1), (0.5, -0.01, 1),
            (0.5, 0.5, -.infinity), (0.5, 0.5, .nan),
            (0.5, 0.5, -0.01), (0.5, 0.5, 10.01),
        ]
        for (x, y, hold) in invalid {
            let phone = Phone()
            XCTAssertThrowsError(
                try phone.input().visualTap(
                    x: x, y: y, hold: hold, size: phone.size,
                    capture: phone.capture, now: { phone.time }))
            XCTAssertTrue(phone.reports.isEmpty)
            XCTAssertEqual(phone.captures, 0)
        }
    }

    func testMissingSessionTransportOrCapturePermissionSendsNoReports() {
        for unavailable in 0..<3 {
            let phone = Phone()
            if unavailable == 1 { phone.ready = false }
            if unavailable == 2 { phone.allowed = false }
            let input = phone.input(session: unavailable == 0 ? nil : UUID())
            XCTAssertFalse(input.visualPointerTransportAvailable)
            XCTAssertThrowsError(try phone.tap(input))
            XCTAssertTrue(phone.reports.isEmpty)
            XCTAssertEqual(phone.captures, 0)
        }
    }

    func testDeadlineIncludesTimeSpentWaitingForInputQueue() {
        let phone = Phone()
        var clockReads = 0
        XCTAssertThrowsError(
            try phone.input().visualTap(
                x: 0.5, y: 0.5, size: phone.size, capture: phone.capture,
                now: {
                    clockReads += 1
                    // First read occurs before queue admission; subsequent reads
                    // represent a request whose forty-second budget has expired.
                    return clockReads == 1 ? 0 : 41
                }))
        XCTAssertGreaterThanOrEqual(clockReads, 2)
        XCTAssertTrue(phone.reports.isEmpty)
        XCTAssertEqual(phone.captures, 0)
    }

    func testCaptureFailureAfterMovementNeverPresses() {
        let phone = Phone()
        phone.captureFailureAt = 2
        XCTAssertThrowsError(try phone.tap(phone.input()))
        XCTAssertFalse(phone.reports.isEmpty)
        XCTAssertTrue(phone.buttonDowns.isEmpty)
        XCTAssertEqual(phone.captures, 2)
    }

    func testOldFrameSequenceOrTimestampNeverPresses() {
        for staleSequence in [true, false] {
            let phone = Phone()
            if staleSequence {
                phone.staleSequenceAt = 2
            } else {
                phone.staleTimestampAt = 1
            }
            XCTAssertThrowsError(try phone.tap(phone.input()))
            XCTAssertTrue(phone.buttonDowns.isEmpty)
        }
    }

    func testLostTransportDuringMovementStopsBeforeAnotherReportOrPress() {
        let phone = Phone()
        phone.onReport = { id, _ in
            if id == .relativeMouse { phone.ready = false }
        }
        XCTAssertThrowsError(try phone.tap(phone.input()))
        XCTAssertEqual(phone.reports.count, 1)
        XCTAssertTrue(phone.buttonDowns.isEmpty)
        XCTAssertEqual(phone.captures, 1)
    }

    func testUndrainedMovementCannotBeObservedAsSuccessfulOrPressed() {
        let phone = Phone()
        phone.drainFailureAt = 2
        XCTAssertThrowsError(try phone.tap(phone.input()))
        XCTAssertFalse(phone.reports.isEmpty)
        XCTAssertEqual(phone.drains, 2)
        XCTAssertEqual(phone.captures, 1)
        XCTAssertTrue(phone.buttonDowns.isEmpty)
    }

    func testLongPressPreservesHoldAndSendsExactlyOnePressAndRelease() throws {
        let phone = Phone()
        var pressTime: TimeInterval?
        var releaseTime: TimeInterval?
        phone.onReport = { id, bytes in
            guard id == .relativeMouse else { return }
            if bytes[0] == 1 { pressTime = phone.time }
            if bytes == [0, 0, 0, 0], pressTime != nil { releaseTime = phone.time }
        }
        try phone.tap(phone.input(), hold: 1.25)

        XCTAssertEqual(phone.buttonReports, [[1, 0, 0, 0], [0, 0, 0, 0]])
        XCTAssertEqual(try XCTUnwrap(releaseTime) - XCTUnwrap(pressTime), 1.25, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(hypot(phone.point.x - phone.nearbyTarget.x, phone.point.y - phone.nearbyTarget.y), 5)
        XCTAssertFalse(phone.reports.contains { $0.0 == .absolutePointer })
    }

    func testCaptureInvalidatedAfterPressStillReleases() {
        let phone = Phone()
        phone.onReport = { id, bytes in
            if id == .relativeMouse, bytes[0] == 1 { phone.allowed = false }
        }
        do {
            try phone.tap(phone.input(), hold: 0.5)
        } catch {
            // Reporting a changed device is acceptable; leaving its button held is not.
        }
        XCTAssertFalse(phone.allowed)
        XCTAssertEqual(phone.buttonReports, [[1, 0, 0, 0], [0, 0, 0, 0]])
    }

    func testUnconfirmedClickDeliveryThrowsAfterRequestingRelease() {
        let phone = Phone()
        phone.failDrainAfterPress = true
        XCTAssertThrowsError(try phone.tap(phone.input()))
        XCTAssertEqual(phone.buttonReports, [[1, 0, 0, 0], [0, 0, 0, 0]])
    }

    func testVisualSuccessAndFailureInvalidatePreviouslyCalibratedPosition() throws {
        for captureFails in [false, true] {
            let phone = Phone()
            let calibration = RelativePointerCalibration(
                host: UUID(), screenWidth: phone.width, screenHeight: phone.height,
                reportInterval: 0.01, distances: (0...127).map { Double($0) * 2 })
            let input = phone.input(calibration: calibration)
            try input.move(x: 0, y: 0)
            phone.reports.removeAll()
            try input.move(x: 0, y: 0)
            XCTAssertTrue(phone.reports.isEmpty, "Establish that the old calibrated origin was cached")

            if captureFails { phone.captureFailureAt = 1 }
            let move = {
                try input.visualMove(
                    x: 96 / Double(phone.width), y: 96 / Double(phone.height), size: phone.size,
                    capture: phone.capture, now: { phone.time })
            }
            if captureFails {
                XCTAssertThrowsError(try move())
            } else {
                try move()
            }
            phone.reports.removeAll()
            try input.move(x: 0, y: 0)
            let expected = calibration.homingReports.map {
                HIDReportPayload.relativeMouse(buttons: 0, dx: $0.dx, dy: $0.dy)
            }
            XCTAssertEqual(phone.reports.map { $0.1 }, expected)
            XCTAssertTrue(phone.reports.allSatisfy { $0.0 == .relativeMouse })
        }
    }

    func testVisualSwipeNeverPressesWithoutAnObservedStart() {
        for failure in 0..<3 {
            let phone = Phone()
            if failure < 2 { phone.captureFailureAt = failure + 1 }
            if failure == 2 { phone.staleSequenceAt = 2 }
            let start = phone.nearbyTarget
            XCTAssertThrowsError(
                try phone.input().visualSwipe(
                    points: [(start.x / Double(phone.width), start.y / Double(phone.height)), (0.7, 0.6)],
                    duration: 0.3, size: phone.size, capture: phone.capture, now: { phone.time }))
            XCTAssertTrue(phone.buttonDowns.isEmpty)
            XCTAssertTrue(phone.buttonTransitions.isEmpty)
        }
    }

    func testVisualSwipeHasOnePressReleaseAndDiscardsItsPositionEstimate() throws {
        for withCalibration in [false, true] {
            let phone = Phone()
            let calibration =
                withCalibration
                ? RelativePointerCalibration(
                    host: UUID(), screenWidth: phone.width, screenHeight: phone.height,
                    reportInterval: 0.01, distances: (0...127).map { Double($0) * 2 }) : nil
            let input = phone.input(calibration: calibration)
            if withCalibration {
                try input.move(x: 0, y: 0)
                phone.reports.removeAll()
                try input.move(x: 0, y: 0)
                XCTAssertTrue(phone.reports.isEmpty)
            }
            let start = withCalibration ? CGPoint(x: 96, y: 96) : phone.nearbyTarget
            let end = CGPoint(x: start.x + 64, y: start.y + 64)
            try input.visualSwipe(
                points: [start, end].map { ($0.x / Double(phone.width), $0.y / Double(phone.height)) },
                duration: 0.3, size: phone.size, capture: phone.capture, now: { phone.time })

            XCTAssertEqual(phone.buttonTransitions, [1, 0])
            XCTAssertTrue(
                phone.reports.contains {
                    $0.0 == .relativeMouse && $0.1[0] == 1 && ($0.1[1] != 0 || $0.1[2] != 0)
                })
            XCTAssertEqual(phone.reports.last?.1, [0, 0, 0, 0])
            // This fixture has a constant gain; this is not an accuracy promise
            // for real drags after the strictly observed initial position.
            XCTAssertEqual(phone.point.x, end.x, accuracy: 2)
            XCTAssertEqual(phone.point.y, end.y, accuracy: 2)

            phone.reports.removeAll()
            if let calibration {
                try input.move(x: 0, y: 0)
                XCTAssertEqual(
                    phone.reports.map { $0.1 },
                    calibration.homingReports.map {
                        HIDReportPayload.relativeMouse(buttons: 0, dx: $0.dx, dy: $0.dy)
                    })
            } else {
                XCTAssertFalse(input.isPointerReady)
                XCTAssertTrue(input.needsCalibration)
                XCTAssertThrowsError(try input.move(x: 0, y: 0))
                XCTAssertTrue(phone.reports.isEmpty)
            }
        }
    }

    func testVisualSwipeCancellationOrDisconnectAfterPressStillReleases() throws {
        for cancel in [true, false] {
            let phone = Phone()
            let input = phone.input()
            phone.onReport = { id, bytes in
                guard id == .relativeMouse, bytes[0] == 1 else { return }
                if cancel {
                    input.cancelPointer()
                } else {
                    phone.ready = false
                }
            }
            let start = phone.nearbyTarget
            XCTAssertThrowsError(
                try input.visualSwipe(
                    points: [(start.x / Double(phone.width), start.y / Double(phone.height)), (0.7, 0.6)],
                    duration: 0.3, size: phone.size, capture: phone.capture, now: { phone.time }))
            // Flush the queued cancel operation without sending another report.
            try input.nudge(dx: 0, dy: 0, click: false)
            XCTAssertEqual(phone.buttonTransitions, [1, 0])
            XCTAssertEqual(phone.buttonReports, [[1, 0, 0, 0], [0, 0, 0, 0]])
            XCTAssertFalse(
                phone.reports.contains {
                    $0.0 == .relativeMouse && $0.1[0] == 1 && ($0.1[1] != 0 || $0.1[2] != 0)
                })
        }
    }

    func testVisualSwipeRejectsInvalidDurationAndReportBudgetBeforePress() {
        let invalidDurations: [TimeInterval] = [0, -0.1, .nan, .infinity, 5.01]
        for duration in invalidDurations {
            let phone = Phone()
            XCTAssertThrowsError(
                try phone.input().visualSwipe(
                    points: [(0.4, 0.4), (0.7, 0.6)], duration: duration,
                    size: phone.size, capture: phone.capture, now: { phone.time }))
            XCTAssertTrue(phone.reports.isEmpty)
            XCTAssertEqual(phone.captures, 0)
        }
        for interval in [0.001, Double.leastNonzeroMagnitude] {
            let phone = Phone()
            let input = phone.input()
            input.step = interval
            let start = phone.nearbyTarget
            XCTAssertThrowsError(
                try input.visualSwipe(
                    points: [(start.x / Double(phone.width), start.y / Double(phone.height)), (0.7, 0.6)],
                    duration: 5, size: phone.size, capture: phone.capture, now: { phone.time }))
            XCTAssertGreaterThan(phone.captures, 0)
            XCTAssertTrue(phone.buttonDowns.isEmpty)
        }
    }

    func testPressDelayedPastDeadlineIsNotDeliveredAndOperationFails() {
        let phone = Phone()
        let startedAt = phone.time
        var attemptedPresses = 0
        var rejectedPresses = 0
        let input = phone.input(visualReportSender: { id, bytes, allowed in
            if id == .relativeMouse, bytes[0] == 1 {
                attemptedPresses += 1
                // Simulate BLE backpressure between enqueue and final delivery.
                phone.time = startedAt + 41
            }
            let mayDeliver = allowed()
            if id == .relativeMouse, bytes[0] == 1, !mayDeliver { rejectedPresses += 1 }
            if mayDeliver { phone.send(id, bytes) }
        })

        XCTAssertThrowsError(try phone.tap(input))
        XCTAssertEqual(attemptedPresses, 1, "The pointer must first reach its observed target")
        XCTAssertEqual(rejectedPresses, 1)
        XCTAssertTrue(phone.buttonDowns.isEmpty)
        // A neutral release remains permitted even after the movement deadline.
        XCTAssertEqual(phone.buttonReports, [[0, 0, 0, 0]])
    }

    func testCompletedVisualOperationRevokesRetainedMovementDeliveryPermissions() throws {
        let phone = Phone()
        let startedAt = phone.time
        var delayedDeliveries: [() -> Void] = []
        defer { delayedDeliveries.removeAll() }
        let input = phone.input(visualReportSender: { id, bytes, allowed in
            if id == .relativeMouse, bytes[1] != 0 || bytes[2] != 0 {
                // Retain the exact gate a transport retry would consult later.
                delayedDeliveries.append {
                    if allowed() { phone.send(id, bytes) }
                }
            }
            if allowed() { phone.send(id, bytes) }
        })
        try input.visualMove(
            x: phone.nearbyTarget.x / Double(phone.width),
            y: phone.nearbyTarget.y / Double(phone.height), size: phone.size,
            capture: phone.capture, now: { phone.time })

        XCTAssertFalse(delayedDeliveries.isEmpty)
        XCTAssertLessThan(phone.time, startedAt + 40, "Completion must revoke permission before its deadline")
        let reportCount = phone.reports.count
        let completedPosition = phone.point
        for deliver in delayedDeliveries { deliver() }
        XCTAssertEqual(phone.reports.count, reportCount)
        XCTAssertEqual(phone.point, completedPosition)
        XCTAssertTrue(phone.buttonDowns.isEmpty)
    }

    func testLongPressHoldStartsAfterBackpressuredPressIsAccepted() throws {
        let phone = Phone()
        let hold: TimeInterval = 1.25
        let acceptanceDelay: TimeInterval = 0.75
        var pending: [(ReportID, [UInt8], () -> Bool)] = []
        defer { pending.removeAll() }
        var acceptedPressAt: TimeInterval?
        var acceptedReleaseAt: TimeInterval?
        phone.onReport = { id, bytes in
            guard id == .relativeMouse else { return }
            if bytes == [1, 0, 0, 0] { acceptedPressAt = phone.time }
            if bytes == [0, 0, 0, 0], acceptedPressAt != nil { acceptedReleaseAt = phone.time }
        }
        let input = phone.input(
            reportDrainer: { timeout in
                // Simulate FIFO transport acceptance, not just API enqueue.
                let batch = pending
                pending.removeAll()
                if batch.contains(where: { $0.0 == .relativeMouse && $0.1 == [1, 0, 0, 0] }) {
                    XCTAssertGreaterThanOrEqual(timeout, acceptanceDelay)
                    phone.time += acceptanceDelay
                }
                for (id, bytes, allowed) in batch where allowed() { phone.send(id, bytes) }
                return true
            },
            visualReportSender: { id, bytes, allowed in
                pending.append((id, bytes, allowed))
            })

        try phone.tap(input, hold: hold)

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(phone.buttonTransitions, [1, 0])
        let pressedFor = try XCTUnwrap(acceptedReleaseAt) - XCTUnwrap(acceptedPressAt)
        XCTAssertGreaterThanOrEqual(pressedFor + 0.0001, hold)
    }
}
