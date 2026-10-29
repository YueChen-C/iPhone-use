import XCTest

@testable import iPhoneUse

/// Replays one relative-report byte through the built-in drag curve.
private func curveStep(_ byte: UInt8) -> Double {
    let count = Int(Int8(bitPattern: byte))
    return Double(count.signum()) * DeviceInput.estimatedDragCurve[abs(count)]
}

final class DeviceInputPointerTests: XCTestCase {
    func testCaptureRecheckRetainsBluetoothReadinessButBlocksInputUntilConfirmed() throws {
        var allowed = true
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), inputIsAllowed: { allowed }, sleep: { _ in },
            reportSender: { reports.append(($0, $1)) }, reportReadiness: { _, _, _ in true })
        XCTAssertTrue(input.isPointerReady)
        allowed = false
        XCTAssertTrue(input.isBluetoothReady)
        XCTAssertFalse(input.isPointerReady)
        XCTAssertThrowsError(try input.move(x: 0.5, y: 0.5))
        try input.key("enter", modifiers: [])
        XCTAssertTrue(reports.allSatisfy { $0.1.allSatisfy { $0 == 0 } })
        allowed = true
        try input.move(x: 0.5, y: 0.5)
        XCTAssertTrue(input.isPointerReady)
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.count, 1)
    }

    func testUnverifiedCaptureRejectsCoordinatesAndRawMovement() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), inputIsAllowed: { false }, sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })

        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        try input.nudge(dx: 32, dy: 0, click: true)
        input.positionPointer(x: 0.8, y: 0.3)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertFalse(input.isPointerReady)
        // A harmless neutral release may pass; no movement or press may pass.
        XCTAssertTrue(reports.allSatisfy { $0.0 == .relativeMouse && $0.1 == [0, 0, 0, 0] })
    }

    func testCaptureInvalidatedDuringPressStillReleasesWithoutReplayingAbsolutePosition() throws {
        var allowed = true
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), inputIsAllowed: { allowed }, sleep: { _ in },
            reportSender: { id, bytes in
                reports.append((id, bytes))
                if id == .relativeMouse && bytes[0] == 1 { allowed = false }
            })

        input.press(x: 0.5, y: 0.5)
        input.cancelPointer()
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(reports.map { $0.0 }, [.absolutePointer, .relativeMouse, .relativeMouse])
        XCTAssertEqual(reports[1].1, [1, 0, 0, 0])
        XCTAssertEqual(reports[2].1, [0, 0, 0, 0])
    }

    func testCaptureInvalidationDiscardsPartialHomingProgressBeforeControlResumes() throws {
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20])
        var allowed = true
        var invalidateAfterFirstReport = true
        var reports: [[UInt8]] = []
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            inputIsAllowed: { allowed },
            sleep: { _ in
                if invalidateAfterFirstReport { allowed = false }
            }, reportSender: { _, bytes in reports.append(bytes) })

        try input.move(x: 0, y: 0)
        XCTAssertEqual(reports.count, 1)
        allowed = true
        invalidateAfterFirstReport = false
        try input.move(x: 0, y: 0)

        let expected = calibration.homingReports.map {
            HIDReportPayload.relativeMouse(buttons: 0, dx: $0.dx, dy: $0.dy)
        }
        XCTAssertEqual(Array(reports.dropFirst()), expected)
    }

    func testAutomaticMeasurementStopsOnLostReadinessAndNeverClicks() {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), calibrationRequired: true, sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        XCTAssertThrowsError(
            try input.measureRelativePointer(
                screenID: "phone", size: CGSize(width: 750, height: 1334),
                isReady: { reports.count < 4 },
                capture: {
                    XCTFail("must stop before capture")
                    return nil
                }))
        XCTAssertEqual(reports.count, 4)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .relativeMouse && $0.1[0] == 0 })
    }

    func testKeyboardInputPreemptsAutomaticMeasurementBeforeItsNextReport() throws {
        var reports: [(ReportID, [UInt8])] = []
        var input: DeviceInput!
        input = DeviceInput(
            host: UUID(), session: UUID(), calibrationRequired: true, sleep: { _ in },
            reportSender: { id, bytes in
                reports.append((id, bytes))
                if id == .relativeMouse { XCTAssertTrue(input.keyFromKeyboard("a")) }
            })
        XCTAssertThrowsError(
            try input.measureRelativePointer(
                screenID: "phone", size: CGSize(width: 750, height: 1334), isReady: { true },
                capture: {
                    XCTFail("user activity must stop measurement before capture")
                    return nil
                }))
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(reports.filter { $0.0 == .relativeMouse }.count, 1)
        XCTAssertEqual(reports.filter { $0.0 == .keyboard }.count, 2)
    }

    func testRelativeProbeSendsNoButtonsOrAbsoluteReportsAndStopsOnLostReadiness() throws {
        var reports: [(ReportID, [UInt8])] = []
        var count = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        let frames = try input.relativePairingProbe(
            isReady: { true },
            capture: {
                count += 1
                return [[UInt8(count)]]
            })
        XCTAssertEqual(frames, [[[1]], [[2]], [[3]], [[4]], [[5]]])
        XCTAssertEqual(reports.count, 48)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .relativeMouse && $0.1[0] == 0 })
        XCTAssertEqual(Array(reports.suffix(4)).map { $0.1 }, Array(repeating: [0, 0, 248, 0], count: 4))
        reports = []
        XCTAssertThrowsError(try input.relativePairingProbe(isReady: { reports.count < 3 }, capture: { [[0]] }))
        XCTAssertEqual(reports.count, 3)
    }

    func testRelativeProbeKeepsTheRectangleInsideScreenEdges() throws {
        for start in [CGPoint.zero, CGPoint(x: 749, y: 1333)] {
            var position = start
            var positions: [CGPoint] = []
            let input = DeviceInput(
                host: UUID(), session: UUID(), sleep: { _ in },
                reportSender: { _, bytes in
                    position.x = min(749, max(0, position.x + Double(Int8(bitPattern: bytes[1])) * 3))
                    position.y = min(1333, max(0, position.y + Double(Int8(bitPattern: bytes[2])) * 3))
                })
            _ = try input.relativePairingProbe(
                isReady: { true },
                capture: {
                    positions.append(position)
                    return [[0]]
                })
            XCTAssertEqual(positions.count, 5)
            XCTAssertTrue(positions.allSatisfy { (20...729).contains($0.x) && (20...1313).contains($0.y) })
            XCTAssertEqual(positions.first, positions.last)
            XCTAssertEqual(positions[1].x - positions[0].x, 96)
            XCTAssertEqual(positions[2].y - positions[1].y, 96)
        }
    }

    func testRetiredInputRejectsCoordinatesAndCannotSendQueuedReports() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        try input.retireForCalibrationReload()
        XCTAssertTrue(input.isRetired)
        XCTAssertFalse(input.isCurrentSession)
        XCTAssertFalse(input.isPointerReady)
        XCTAssertThrowsError(try input.move(x: 0.5, y: 0.5))
        try input.nudge(dx: 8, dy: 0, click: false)
        XCTAssertTrue(reports.isEmpty)
    }

    func testRequiredButMissingCalibrationKeepsBluetoothTransportReady() {
        let input = DeviceInput(
            host: UUID(), session: UUID(), calibrationRequired: true,
            reportReadiness: { report, _, _ in report != .absolutePointer })
        XCTAssertTrue(input.isBluetoothReady)
        XCTAssertTrue(input.needsCalibration)
        XCTAssertFalse(input.isPointerReady)
    }

    private enum GestureEvent: Equatable {
        case report(ReportID, [UInt8])
        case pause(TimeInterval)
    }

    func testTwoPointSwipeDragsOnTheRelativeCollectionWithEstimatedCounts() throws {
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 750, height: 1334) },
            sleep: { pauses.append($0) }, reportSender: { reports.append(($0, $1)) })
        input.step = 0.125

        try input.swipe(points: [(0, 0), (1, 1)], duration: 0.5)

        // One absolute hover positions the pointer; the press, movement and
        // release all carry the touch on the relative collection.
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.map { $0.1 }, [[0, 0, 0, 0, 0]])
        XCTAssertEqual(reports.first { $0.0 == .relativeMouse }?.1, [1, 0, 0, 0])
        XCTAssertEqual(reports.last?.0, .relativeMouse)
        XCTAssertEqual(reports.last?.1, [0, 0, 0, 0])
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        // Replaying the reports through the built-in curve reaches the target.
        var position = CGPoint(x: 0, y: 0)
        for (_, bytes) in movement {
            position.x += curveStep(bytes[1])
            position.y += curveStep(bytes[2])
        }
        XCTAssertEqual(position.x, 749, accuracy: 0.5)
        XCTAssertEqual(position.y, 1333, accuracy: 0.5)
        // Positioning and release retain their original pacing, and every
        // movement report is paced by the report interval, not its distance.
        XCTAssertEqual(pauses.first, 0.25)
        XCTAssertEqual(pauses.last, 0.125)
        XCTAssertEqual(
            Array(pauses.dropFirst(2).dropLast()), Array(repeating: 0.125, count: pauses.count - 3))
        XCTAssertTrue(pauses.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    func testPairingProbeMovesAndCapturesOnTheInputQueue() throws {
        var reports: [(ReportID, [UInt8])] = []
        var captureCount = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })

        let captures = try input.pairingProbe(
            calibration: nil, firstPoint: CGPoint(x: 0.3, y: 0.35), secondPoint: CGPoint(x: 0.7, y: 0.65),
            wait: 0, isReady: { true },
            capture: {
                captureCount += 1
                return [UInt8(captureCount)]
            })

        XCTAssertEqual(captures.before, [1])
        XCTAssertEqual(captures.after, [2])
        XCTAssertEqual(captureCount, 2)
        XCTAssertEqual(reports.map(\.0), [.absolutePointer, .absolutePointer])
    }

    func testPairingProbeStopsBeforeSendingWhenBluetoothIsNotReady() {
        var reports: [(ReportID, [UInt8])] = []
        var captureCount = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })

        XCTAssertThrowsError(
            try input.pairingProbe(
                calibration: nil, firstPoint: CGPoint(x: 0.3, y: 0.35), secondPoint: CGPoint(x: 0.7, y: 0.65),
                wait: 0, isReady: { false },
                capture: {
                    captureCount += 1
                    return [UInt8(captureCount)]
                }))

        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(captureCount, 0)
    }

    func testAbsoluteCapabilityProbeReturnsWithExactlyThreeReportsAndCaptures() throws {
        var reports: [(ReportID, [UInt8])] = []
        var captureCount = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        let captures = try input.pairingProbe(
            calibration: nil, firstPoint: CGPoint(x: 0.3, y: 0.35), secondPoint: CGPoint(x: 0.7, y: 0.65),
            returnToStart: true, wait: 0, isReady: { true },
            capture: {
                captureCount += 1
                return [UInt8(captureCount)]
            })
        XCTAssertEqual(captures.returned, [3])
        XCTAssertEqual(captureCount, 3)
        XCTAssertEqual(reports.map(\.0), [.absolutePointer, .absolutePointer, .absolutePointer])
        XCTAssertEqual(reports.first?.1, reports.last?.1)
    }

    func testCancellationAfterOutboundCaptureSuppressesTheReturnReport() {
        var reportCount = 0
        var captureCount = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { _, _ in reportCount += 1 })
        XCTAssertThrowsError(
            try input.pairingProbe(
                calibration: nil, firstPoint: CGPoint(x: 0.3, y: 0.35), secondPoint: CGPoint(x: 0.7, y: 0.65),
                returnToStart: true, wait: 0, isReady: { true },
                capture: {
                    captureCount += 1
                    if captureCount == 2 { input.cancelBackgroundMotion() }
                    return [UInt8(captureCount)]
                }))
        XCTAssertEqual(reportCount, 2)
        XCTAssertEqual(captureCount, 2)
    }

    func testAbsolutePointerReadinessRequiresMovementAndClickSubscriptions() {
        let input = DeviceInput(
            host: UUID(), session: UUID(),
            reportReadiness: { report, _, _ in
                [.keyboard, .absolutePointer, .consumer].contains(report)
            })

        XCTAssertFalse(input.isPointerReady)
        XCTAssertFalse(input.isBluetoothReady)

        let readyInput = DeviceInput(
            host: UUID(), session: UUID(),
            reportReadiness: { report, _, _ in
                [.keyboard, .absolutePointer, .relativeMouse, .consumer].contains(report)
            })
        XCTAssertTrue(readyInput.isPointerReady)
        XCTAssertTrue(readyInput.isBluetoothReady)
    }

    func testCalibratedPointerReadinessRequiresRelativeSubscription() {
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20])
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            reportReadiness: { report, _, _ in
                [.keyboard, .relativeMouse, .consumer].contains(report)
            })

        XCTAssertTrue(input.isPointerReady)
        XCTAssertTrue(input.isBluetoothReady)
    }

    func testMultiPointSwipePassesCornersWithoutReleasingAndUsesPixelDistances() throws {
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 750, height: 1500) },
            sleep: { pauses.append($0) }, reportSender: { reports.append(($0, $1)) })
        input.step = 0.125

        try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: 0.75)

        // One absolute hover; the whole drag runs on the relative collection.
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.map { $0.1 }, [[0, 0, 0, 0, 0]])
        XCTAssertEqual(reports.first { $0.0 == .relativeMouse }?.1, [1, 0, 0, 0])
        XCTAssertEqual(reports.last?.1, [0, 0, 0, 0])
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        // Replaying through the built-in curve: the horizontal corner arrives
        // before the turn, and the path ends in the opposite corner.
        var position = CGPoint(x: 0, y: 0)
        var reachedHorizontalCorner = false
        for (_, bytes) in movement {
            let dx = Int8(bitPattern: bytes[1])
            let dy = Int8(bitPattern: bytes[2])
            if abs(position.y) <= 1, dy == 0 {
                position.x += curveStep(bytes[1])
            } else {
                XCTAssertEqual(dx, 0, "the vertical segment must not move horizontally")
                position.y += curveStep(bytes[2])
            }
            if abs(position.x - 749) <= 1, abs(position.y) <= 1 { reachedHorizontalCorner = true }
        }
        XCTAssertTrue(reachedHorizontalCorner)
        XCTAssertEqual(position.y, 1499, accuracy: 0.5)
        // The vertical segment is twice as long in pixels, so it receives four
        // intervals while the horizontal segment receives two.
        XCTAssertTrue(pauses.dropFirst(2).dropLast().allSatisfy { $0 == 0.125 })
        XCTAssertGreaterThanOrEqual(pauses.dropFirst(2).dropLast().reduce(0, +), 0.75)
    }

    func testRepeatedSwipePointsKeepOnePressAndPreserveMovementDuration() throws {
        let paths: [[(Double, Double)]] = [
            [(0, 0), (0, 0), (1, 1), (1, 1)],
            [(0.5, 0.5), (0.5, 0.5), (0.5, 0.5)],
        ]
        for points in paths {
            var reports: [(ReportID, [UInt8])] = []
            var pauses: [TimeInterval] = []
            let input = DeviceInput(
                host: UUID(), session: UUID(), sleep: { pauses.append($0) },
                reportSender: { reports.append(($0, $1)) })
            input.step = 0.125

            try input.swipe(points: points, duration: 0.5)

            // One absolute hover, one press, one release — repeated or
            // stationary points never add a second button transition.
            XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.count, 1)
            XCTAssertEqual(reports.first?.1[0], 0)
            XCTAssertEqual(reports.last?.1[0], 0)
            XCTAssertTrue(reports.dropFirst().dropLast().allSatisfy { $0.1[0] == 1 })
            XCTAssertTrue(pauses.allSatisfy { $0.isFinite && $0 >= 0 })
            XCTAssertEqual(pauses.dropFirst(2).dropLast().reduce(0, +), 0.5, accuracy: 1e-12)
        }
    }

    func testCalibratedMultiPointSwipeVisitsCornersAndUsesCalibrationDimensions() throws {
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20])
        var position = CGPoint(x: 90, y: 190)
        var reports: [(buttons: UInt8, position: CGPoint)] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            sleep: { pauses.append($0) },
            reportSender: { id, bytes in
                XCTAssertEqual(id, .relativeMouse)
                let dx = Int(Int8(bitPattern: bytes[1]))
                let dy = Int(Int8(bitPattern: bytes[2]))
                position.x = max(0, min(99, position.x + (dx < 0 ? -1 : 1) * calibration.distances[abs(dx)]))
                position.y = max(0, min(199, position.y + (dy < 0 ? -1 : 1) * calibration.distances[abs(dy)]))
                reports.append((bytes[0], position))
            })
        input.step = 0.125

        try input.swipe(points: [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8)], duration: 0.75)

        let firstPress = try XCTUnwrap(reports.firstIndex { $0.buttons == 1 })
        let heldReports = reports[firstPress..<reports.count - 1]
        XCTAssertEqual(heldReports.first?.position, CGPoint(x: 20, y: 40))
        XCTAssertTrue(heldReports.contains { $0.position == CGPoint(x: 80, y: 40) })
        XCTAssertTrue(heldReports.allSatisfy { $0.buttons == 1 })
        XCTAssertEqual(reports.last?.buttons, 0)
        XCTAssertEqual(position, CGPoint(x: 80, y: 160))
        // Without a capture size, the 100x200 calibration supplies the same 1:2
        // segment ratio. Remove the calibrated report intervals to inspect the
        // six movement waits plus the existing press/release preparation.
        XCTAssertEqual(pauses.filter { $0 != calibration.reportInterval }, [0.25] + Array(repeating: 0.125, count: 8))
    }

    func testVeryShortSwipeSegmentsStillReachEveryCorner() throws {
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 750, height: 1500) },
            sleep: { pauses.append($0) }, reportSender: { reports.append(($0, $1)) })
        input.step = 0.03

        try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: .leastNonzeroMagnitude)

        // The estimated drag converges on every interpolated target, so even
        // a near-zero duration still reaches both corners before releasing.
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        var position = CGPoint(x: 0, y: 0)
        var reachedHorizontalCorner = false
        for (_, bytes) in movement {
            let dx = Int8(bitPattern: bytes[1])
            let dy = Int8(bitPattern: bytes[2])
            if abs(position.y) <= 1, dy == 0 {
                position.x += curveStep(bytes[1])
            } else {
                XCTAssertEqual(dx, 0)
                position.y += curveStep(bytes[2])
            }
            if abs(position.x - 749) <= 1, abs(position.y) <= 1 { reachedHorizontalCorner = true }
        }
        XCTAssertTrue(reachedHorizontalCorner)
        XCTAssertEqual(position.x, 749, accuracy: 0.5)
        XCTAssertEqual(position.y, 1499, accuracy: 0.5)
        XCTAssertTrue(pauses.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    func testInvalidSwipeInputsSendNoReportsOrPauses() {
        var reports: [[UInt8]] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { pauses.append($0) },
            reportSender: { _, bytes in reports.append(bytes) })
        let invalidPoints: [[(Double, Double)]] = [
            [], [(0, 0)], [(0, 0), (.nan, 1)], [(0, 0), (1, .infinity)],
            [(-0.01, 0), (1, 1)], [(0, 0), (1, 1.01)],
        ]
        for points in invalidPoints {
            XCTAssertThrowsError(try input.swipe(points: points, duration: 0.3))
        }
        for duration in [TimeInterval(0), -1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try input.swipe(points: [(0, 0), (1, 1)], duration: duration))
        }
        for interval in [TimeInterval(0), -1, .nan, .infinity, .leastNonzeroMagnitude, .greatestFiniteMagnitude] {
            input.step = interval
            XCTAssertThrowsError(try input.swipe(points: [(0, 0), (1, 1)], duration: 0.3))
        }
        XCTAssertTrue(reports.isEmpty)
        XCTAssertTrue(pauses.isEmpty)
    }

    func testSwipeRequiresMatchingCalibrationBeforeSendingReports() {
        var reports: [[UInt8]] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), calibrationRequired: true,
            sleep: { _ in }, reportSender: { _, bytes in reports.append(bytes) })

        XCTAssertThrowsError(try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: 0.3)) { error in
            guard case DeviceInput.InputError.calibrationMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(reports.isEmpty)
    }

    func testCoordinateTapAfterWindowMovementUsesRequestedPixels() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })

        input.positionPointer(x: 1, y: 1)
        try input.nudge(dx: 0, dy: 0, click: false)
        try input.tap(x: 500.0 / 750, y: 500.0 / 1334)
        input.positionPointer(x: 0, y: 0)
        try input.nudge(dx: 0, dy: 0, click: false)
        try input.tap(x: 0.5, y: 0.5)

        XCTAssertEqual(
            reports.map { $0.0 },
            [
                .absolutePointer, .absolutePointer, .relativeMouse, .relativeMouse,
                .absolutePointer, .absolutePointer, .relativeMouse, .relativeMouse,
            ])
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [0, 255, 127, 255, 127], [0, 85, 85, 249, 47], [1, 0, 0, 0], [0, 0, 0, 0],
                [0, 0, 0, 0, 0], [0, 0, 64, 0, 64], [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testWindowClickPositionsAtMouseDownEvenWithoutHover() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })

        try input.tap(x: 1, y: 0)
        input.press(x: 0, y: 1)
        input.release(x: 0, y: 1)
        // Wait for all asynchronous window reports without adding a movement.
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(
            reports.dropFirst(3).map { $0.0 },
            [
                .absolutePointer, .relativeMouse, .relativeMouse,
            ])
        XCTAssertEqual(
            reports.dropFirst(3).map { $0.1 },
            [
                [0, 0, 0, 255, 127], [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testWindowDragMovesRelativelyAndRetainsFinalLocation() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 750, height: 1334) },
            reportSender: { reports.append(($0, $1)) })

        input.press(x: 0, y: 0)
        input.drag(x: 0.5, y: 0.5)
        input.drag(x: 1, y: 1)
        input.release(x: 1, y: 1)
        try input.nudge(dx: 0, dy: 0, click: false)

        // The queued drags are superseded; the release positions the pointer.
        // One absolute hover, then a wholly relative drag to the release point.
        XCTAssertEqual(reports.first?.1, [0, 0, 0, 0, 0])
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.count, 1)
        XCTAssertEqual(reports.first { $0.0 == .relativeMouse }?.1, [1, 0, 0, 0])
        XCTAssertEqual(reports.last?.1, [0, 0, 0, 0])
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        var position = CGPoint(x: 0, y: 0)
        for (_, bytes) in movement {
            position.x += curveStep(bytes[1])
            position.y += curveStep(bytes[2])
        }
        XCTAssertEqual(position.x, 749, accuracy: 0.5)
        XCTAssertEqual(position.y, 1333, accuracy: 0.5)
    }

    func testWindowDragReleasesButtonStateForEveryPointerReport() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in }, reportSender: { reports.append(($0, $1)) })

        input.press(x: 0.2, y: 0.4)
        input.drag(x: 0.6, y: 0.4)
        // Finish the held movement before the release supersedes pending targets.
        try input.type("")
        input.release(x: 0.8, y: 0.4)
        try input.nudge(dx: 0, dy: 0, click: false)

        // The report map has two independent mouse collections. Releasing one
        // must not be treated as a release of the other's stored button state.
        var buttonStateByReport: [ReportID: UInt8] = [
            .absolutePointer: 0,
            .relativeMouse: 0,
        ]
        for (reportID, payload) in reports {
            guard let buttons = payload.first else { continue }
            buttonStateByReport[reportID] = buttons & 1
        }

        XCTAssertTrue(reports.contains { $0.0 == .relativeMouse && $0.1[0] & 1 == 1 })
        XCTAssertEqual(buttonStateByReport[.absolutePointer], 0, "absolute pointer must not retain a pressed button")
        XCTAssertEqual(buttonStateByReport[.relativeMouse], 0, "relative mouse must not retain a pressed button")
    }

    func testCoordinateGestureCannotInterruptHeldWindowButton() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })

        input.press(x: 0.5, y: 0.5)
        for gesture in [
            { try input.tap(x: 1, y: 1) },
            { try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: 0.06) },
            { try input.move(x: 1, y: 1) },
            { try input.nudge(dx: 1, dy: 1, click: true) },
        ] {
            XCTAssertThrowsError(try gesture()) { error in
                guard case DeviceInput.InputError.pointerBusy = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
        XCTAssertEqual(reports.count, 2)
        input.release(x: 0.5, y: 0.5)
        try input.tap(x: 1, y: 1)
        XCTAssertEqual(
            reports.suffix(3).map { $0.1 },
            [
                [0, 255, 127, 255, 127], [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testFocusCancellationReleasesWindowButtonAndAllowsAPITap() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.press(x: 0, y: 0)
        input.cancelPointer()
        // A stale AppKit mouse-up after cancellation must not reposition the phone.
        input.release(x: 1, y: 1)
        try input.tap(x: 0.5, y: 0.5)

        XCTAssertEqual(
            reports.map { $0.0 },
            [
                .absolutePointer, .relativeMouse, .relativeMouse, .absolutePointer,
                .absolutePointer, .relativeMouse, .relativeMouse,
            ])
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [0, 0, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0, 0],
                [0, 0, 64, 0, 64], [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testRapidMovementDeliversFinalPosition() throws {
        var positions: [[UInt8]] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(),
            reportSender: { id, bytes in
                XCTAssertEqual(id, .absolutePointer)
                positions.append(bytes)
            })
        input.positionPointer(x: 0, y: 0)
        input.positionPointer(x: 0.5, y: 0.5)
        input.positionPointer(x: 1, y: 1)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(positions.last, [0, 255, 127, 255, 127])
        XCTAssertLessThanOrEqual(positions.count, 3)
    }

    func testInvalidatedCalibratedEstimateHomesBeforeNextWindowMove() throws {
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20])
        var reports: [[UInt8]] = []
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            reportSender: { _, bytes in reports.append(bytes) })

        input.positionPointer(x: 0.5, y: 0.5)
        try input.nudge(dx: 0, dy: 0, click: false)
        reports.removeAll()
        input.invalidatePointerEstimate()
        input.positionPointer(x: 0.5, y: 0.5)
        try input.nudge(dx: 0, dy: 0, click: false)

        // The host may have moved anywhere during the interruption. Replaying
        // the emitted reports must recover the requested position from there.
        var position = CGPoint(x: 90, y: 190)
        for bytes in reports {
            let dx = Int(Int8(bitPattern: bytes[1]))
            let dy = Int(Int8(bitPattern: bytes[2]))
            position.x = max(0, min(99, position.x + (dx < 0 ? -1 : 1) * calibration.distances[abs(dx)]))
            position.y = max(0, min(199, position.y + (dy < 0 ? -1 : 1) * calibration.distances[abs(dy)]))
        }
        XCTAssertEqual(position, CGPoint(x: 50, y: 100))
    }

}
