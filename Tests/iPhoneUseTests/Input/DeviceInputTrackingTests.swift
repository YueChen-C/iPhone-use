import XCTest

@testable import iPhoneUse

final class DeviceInputTrackingTests: XCTestCase {
    private struct Report {
        let buttons: UInt8
        let dx: Int
        let dy: Int
        let position: CGPoint

        var moves: Bool { dx != 0 || dy != 0 }
    }

    /// Integrate the measured curve as a host would, including screen clipping.
    /// The callback runs on DeviceInput's queue, so it can submit a new AppKit event
    /// precisely while an earlier movement is still being transmitted.
    private final class SimulatedPointer {
        let calibration: RelativePointerCalibration
        var position = CGPoint(x: 93, y: 170)
        var reports: [Report] = []
        var onReport: ((Report) -> Void)?

        init(calibration: RelativePointerCalibration) {
            self.calibration = calibration
        }

        func receive(_ id: ReportID, _ bytes: [UInt8]) {
            XCTAssertEqual(id, .relativeMouse)
            guard id == .relativeMouse, bytes.count == 4 else { return }
            let dx = Int(Int8(bitPattern: bytes[1]))
            let dy = Int(Int8(bitPattern: bytes[2]))
            guard abs(dx) < calibration.distances.count,
                abs(dy) < calibration.distances.count
            else {
                return XCTFail("movement exceeded the measured calibration curve")
            }
            let delta: CGPoint
            if calibration.vectorModel == .radialQuantized, dx != 0 || dy != 0 {
                let magnitude = Int(hypot(Double(dx), Double(dy)))
                let gain = calibration.distances[magnitude] / Double(magnitude)
                delta = CGPoint(x: Double(dx) * gain, y: Double(dy) * gain)
            } else {
                delta = CGPoint(
                    x: Double(dx < 0 ? -1 : 1) * calibration.distances[abs(dx)],
                    y: Double(dy < 0 ? -1 : 1) * calibration.distances[abs(dy)])
            }
            position.x = max(0, min(Double(calibration.screenWidth - 1), position.x + delta.x))
            position.y = max(0, min(Double(calibration.screenHeight - 1), position.y + delta.y))
            let report = Report(buttons: bytes[0], dx: dx, dy: dy, position: position)
            reports.append(report)
            onReport?(report)
        }
    }

    private func freshInput(vectorModel: RelativePointerCalibration.VectorModel? = nil) -> (
        DeviceInput, SimulatedPointer
    ) {
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01,
            distances: vectorModel == nil ? [0, 1, 3, 8, 20] : [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 22],
            vectorModel: vectorModel)
        let pointer = SimulatedPointer(calibration: calibration)
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            reportSender: pointer.receive)
        input.step = 0
        return (input, pointer)
    }

    private func preparedInput(
        x: Double = 0.2, y: Double = 0.2,
        vectorModel: RelativePointerCalibration.VectorModel? = nil
    ) throws -> (DeviceInput, SimulatedPointer) {
        let (input, pointer) = freshInput(vectorModel: vectorModel)
        try input.move(x: x, y: y)
        pointer.reports.removeAll()
        return (input, pointer)
    }

    func testNewHoverInterruptsRunningPathAndResumesFromReportsActuallySent() throws {
        let (input, pointer) = try preparedInput()
        let retargeted = expectation(description: "new target submitted during first report")
        pointer.onReport = { _ in
            pointer.onReport = nil
            input.positionPointer(x: 0.1, y: 0.05)
            retargeted.fulfill()
        }

        input.positionPointer(x: 0.9, y: 0.9)
        wait(for: [retargeted], timeout: 2)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertTrue(try XCTUnwrap(pointer.reports.first).moves)
        XCTAssertTrue(
            pointer.reports.dropFirst().allSatisfy { $0.dx <= 0 && $0.dy <= 0 },
            "the superseded path must stop before its next movement report")
        XCTAssertEqual(
            pointer.position, CGPoint(x: 10, y: 10),
            "retargeting must resume from the partial movement, not its abandoned destination")
    }

    func testContinuousHoverTargetsShareOneInterruptibleHomingPath() throws {
        let (input, pointer) = freshInput()
        let retargeted = expectation(description: "new targets submitted throughout homing")
        let homing = pointer.calibration.homingReports
        pointer.onReport = { _ in
            input.positionPointer(x: 0.5, y: 0.5)
            if pointer.reports.count == homing.count {
                pointer.onReport = nil
                retargeted.fulfill()
            }
        }

        input.positionPointer(x: 0.5, y: 0.5)
        wait(for: [retargeted], timeout: 3)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(pointer.reports.prefix(homing.count).map(\.dx), homing.map(\.dx))
        XCTAssertEqual(pointer.reports.prefix(homing.count).map(\.dy), homing.map(\.dy))
        XCTAssertEqual(pointer.position, CGPoint(x: 50, y: 100))
        XCTAssertTrue(pointer.reports.dropFirst(homing.count).allSatisfy { $0.dx >= 0 && $0.dy >= 0 })
    }

    func testHoverCancellationStopsHomingAndNextInteractionRecoversUnknownOrigin() throws {
        let (input, pointer) = freshInput()
        let cancelled = expectation(description: "hover exit submitted during homing")
        pointer.onReport = { _ in
            pointer.onReport = nil
            input.cancelPointer()
            cancelled.fulfill()
        }

        input.positionPointer(x: 0.5, y: 0.5)
        wait(for: [cancelled], timeout: 2)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(pointer.reports.count, 1, "leaving the view must stop before the next homing report")
        pointer.reports.removeAll()
        pointer.position = CGPoint(x: 93, y: 170)
        input.positionPointer(x: 0.5, y: 0.5)
        try input.nudge(dx: 0, dy: 0, click: false)

        let homing = pointer.calibration.homingReports
        XCTAssertEqual(pointer.reports.prefix(homing.count).map(\.dx), homing.map(\.dx))
        XCTAssertEqual(pointer.reports.prefix(homing.count).map(\.dy), homing.map(\.dy))
        XCTAssertEqual(pointer.position, CGPoint(x: 50, y: 100))
    }

    func testBackgroundCancellationPreservesKnownPointerPosition() throws {
        let (input, pointer) = try preparedInput()
        let before = input.inputActivitySequence
        input.cancelBackgroundMotion()
        XCTAssertNotEqual(input.inputActivitySequence, before)
        try input.move(x: 0.3, y: 0.3)

        XCTAssertEqual(pointer.position, CGPoint(x: 30, y: 60))
        XCTAssertTrue(pointer.reports.allSatisfy { $0.dx >= 0 && $0.dy >= 0 })
    }

    func testDuplicateMouseEventDoesNotCancelTargetAlreadySubmittedByTimer() throws {
        let (input, pointer) = try preparedInput(vectorModel: .radialQuantized)
        let target = CGPoint(x: 0.8, y: 0.7)
        var mouse = ControlMousePosition()
        mouse.update(target)
        let submitted = try XCTUnwrap(mouse.takePosition())
        let eventHandled = expectation(description: "mouse event follows timer submission")
        pointer.onReport = { _ in
            pointer.onReport = nil
            // The 30 Hz timer can observe the cursor before AppKit delivers
            // mouseMoved for that same coordinate. That event cancels only
            // background work and has no new target to submit.
            input.cancelBackgroundMotion()
            mouse.update(target)
            XCTAssertNil(mouse.takePosition())
            eventHandled.fulfill()
        }
        input.positionPointer(x: submitted.x, y: submitted.y)
        wait(for: [eventHandled], timeout: 2)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(pointer.position.x, 80, accuracy: 0.5)
        XCTAssertEqual(pointer.position.y, 140, accuracy: 0.5)
    }

    func testBackgroundCancellationStillStopsEveryProbeBeforeItsNextReport() throws {
        for kind in ["relative", "absolute", "calibrated", "measurement"] {
            let calibration = RelativePointerCalibration(
                host: UUID(), screenWidth: 750, screenHeight: 1334,
                reportInterval: 0.03, distances: [0, 1, 3, 8, 20])
            var reports = 0
            var input: DeviceInput!
            input = DeviceInput(
                host: calibration.host, session: UUID(), calibration: calibration,
                sleep: { _ in },
                reportSender: { _, _ in
                    reports += 1
                    input.cancelBackgroundMotion()
                })
            XCTAssertThrowsError(
                try {
                    switch kind {
                    case "relative":
                        _ = try input.relativePairingProbe(
                            isReady: { true },
                            capture: {
                                XCTFail()
                                return [[0]]
                            })
                    case "measurement":
                        _ = try input.measureRelativePointer(
                            screenID: "test", size: CGSize(width: 750, height: 1334),
                            isReady: { true },
                            capture: {
                                XCTFail()
                                return nil
                            })
                    default:
                        _ = try input.pairingProbe(
                            calibration: kind == "calibrated" ? calibration : nil,
                            firstPoint: CGPoint(x: 0.8, y: 0.8), secondPoint: CGPoint(x: 0.2, y: 0.2),
                            wait: 0, isReady: { true },
                            capture: {
                                XCTFail()
                                return [0]
                            })
                    }
                }(), kind)
            XCTAssertEqual(reports, 1, kind)
        }
    }

    func testRegistryCancellationStopsCalibratedProbeDuringHomingOrTracking() throws {
        let homingCount = freshInput().1.calibration.homingReports.count
        for stopAfter in [1, homingCount + 1] {
            let (input, pointer) = freshInput()
            let sequence = input.inputActivitySequence

            XCTAssertThrowsError(
                try input.pairingProbe(
                    calibration: pointer.calibration,
                    firstPoint: CGPoint(x: 0.8, y: 0.8), secondPoint: CGPoint(x: 0.2, y: 0.2),
                    wait: 0, isReady: { pointer.reports.count < stopAfter },
                    capture: {
                        XCTFail("cancelled discovery must stop before capture")
                        return [0]
                    }))

            XCTAssertEqual(input.inputActivitySequence, sequence, "temporary probe inputs need no direct cancellation")
            XCTAssertEqual(pointer.reports.count, stopAfter, "registry cancellation must stop before the next report")
            XCTAssertTrue(pointer.reports.allSatisfy { $0.buttons == 0 })
        }
    }

    func testContinuousDiagonalTargetsAdvanceBothAxesWithoutStarvation() throws {
        let (input, pointer) = try preparedInput(x: 0.1, y: 0.1)
        let retargeted = expectation(description: "all moving targets submitted")
        var targetCount = 0
        pointer.onReport = { report in
            guard report.moves else { return }
            targetCount += 1
            input.positionPointer(
                x: Double(40 + targetCount * 3) / 100,
                y: Double(80 + targetCount * 4) / 200)
            if targetCount == 8 {
                pointer.onReport = nil
                retargeted.fulfill()
            }
        }

        input.positionPointer(x: 0.4, y: 0.4)
        wait(for: [retargeted], timeout: 3)
        try input.nudge(dx: 0, dy: 0, click: false)

        let tracking = Array(pointer.reports.prefix(8))
        XCTAssertEqual(tracking.count, 8)
        XCTAssertTrue(tracking.allSatisfy { $0.dx >= 0 && $0.dy >= 0 })
        for (previous, next) in zip(tracking, tracking.dropFirst()) {
            XCTAssertNotEqual(
                previous.dx != 0, next.dx != 0,
                "a new target on every report must not restart on the same axis")
        }
        XCTAssertEqual(pointer.position, CGPoint(x: 64, y: 112))
    }

    func testMouseDownDiscardsRunningHoverBeforePositioningTheClick() throws {
        let (input, pointer) = try preparedInput()
        let pressed = expectation(description: "click submitted during hover")
        pointer.onReport = { _ in
            pointer.onReport = nil
            input.press(x: 0.1, y: 0.05)
            input.release(x: 0.1, y: 0.05)
            pressed.fulfill()
        }

        input.positionPointer(x: 0.9, y: 0.9)
        wait(for: [pressed], timeout: 2)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertTrue(pointer.reports.dropFirst().allSatisfy { $0.dx <= 0 && $0.dy <= 0 })
        XCTAssertEqual(
            try XCTUnwrap(pointer.reports.first { $0.buttons == 1 }).position,
            CGPoint(x: 10, y: 10))
        XCTAssertEqual(pointer.reports.last?.buttons, 0)
        XCTAssertEqual(pointer.position, CGPoint(x: 10, y: 10))
    }

    func testMouseUpDiscardsRunningDragAndReleasesAtItsFinalCoordinate() throws {
        let (input, pointer) = try preparedInput()
        input.press(x: 0.2, y: 0.2)
        // Empty text is a queue barrier that leaves the held mouse button alone.
        try input.type("")
        pointer.reports.removeAll()
        let released = expectation(description: "mouse-up submitted during drag")
        pointer.onReport = { _ in
            pointer.onReport = nil
            input.release(x: 0.1, y: 0.05)
            released.fulfill()
        }

        input.drag(x: 0.9, y: 0.9)
        wait(for: [released], timeout: 2)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertTrue(pointer.reports.dropFirst().allSatisfy { $0.dx <= 0 && $0.dy <= 0 })
        XCTAssertTrue(pointer.reports.filter(\.moves).allSatisfy { $0.buttons == 1 })
        XCTAssertEqual(pointer.reports.last?.buttons, 0)
        XCTAssertEqual(pointer.position, CGPoint(x: 10, y: 10))
    }

    func testFocusCancellationStopsRunningDragBeforeReleasingButton() throws {
        let (input, pointer) = try preparedInput()
        input.press(x: 0.2, y: 0.2)
        try input.type("")
        pointer.reports.removeAll()
        let cancelled = expectation(description: "focus cancellation submitted during drag")
        pointer.onReport = { _ in
            pointer.onReport = nil
            input.cancelPointer()
            cancelled.fulfill()
        }

        input.drag(x: 0.9, y: 0.9)
        wait(for: [cancelled], timeout: 2)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(pointer.reports.count, 2, "only the in-flight movement and button release may remain")
        XCTAssertEqual(pointer.reports.first?.buttons, 1)
        XCTAssertEqual(pointer.reports.last?.buttons, 0)
        XCTAssertEqual(pointer.position, pointer.reports.first?.position)
        XCTAssertFalse(try XCTUnwrap(pointer.reports.last).moves)
    }

    func testCoordinateTapAndSubsequentWindowTrackingShareAnAccuratePosition() throws {
        let (input, pointer) = try preparedInput()
        input.positionPointer(x: 0.8, y: 0.7)
        try input.nudge(dx: 0, dy: 0, click: false)
        pointer.reports.removeAll()
        try input.tap(x: 0.3, y: 0.2, hold: 0)

        XCTAssertTrue(
            pointer.reports.allSatisfy { $0.dx <= 0 && $0.dy <= 0 },
            "the API must move directly back from the window position without going past the target to home")
        XCTAssertEqual(
            try XCTUnwrap(pointer.reports.first { $0.buttons == 1 }).position,
            CGPoint(x: 30, y: 40))

        pointer.reports.removeAll()
        input.positionPointer(x: 0.6, y: 0.3)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(pointer.position, CGPoint(x: 60, y: 60))
        XCTAssertTrue(
            pointer.reports.allSatisfy { $0.buttons == 0 && $0.dx >= 0 && $0.dy >= 0 },
            "window tracking after the API tap must use its landing without another homing pass")
    }

    func testCombinedTrackingRetargetsWithoutLosingPositionOrAPIClickAccuracy() throws {
        let (input, pointer) = try preparedInput(vectorModel: .radialQuantized)
        let retargeted = expectation(description: "new target during combined report")
        pointer.onReport = { _ in
            pointer.onReport = nil
            input.positionPointer(x: 0.1, y: 0.05)
            retargeted.fulfill()
        }
        input.positionPointer(x: 0.9, y: 0.9)
        wait(for: [retargeted], timeout: 2)
        try input.nudge(dx: 0, dy: 0, click: false)
        XCTAssertTrue(pointer.reports.contains { $0.dx != 0 && $0.dy != 0 })
        XCTAssertTrue(pointer.reports.dropFirst().allSatisfy { $0.dx <= 0 && $0.dy <= 0 })
        XCTAssertEqual(pointer.position.x, 10, accuracy: 0.5)
        XCTAssertEqual(pointer.position.y, 10, accuracy: 0.5)

        try input.tap(x: 0.3, y: 0.2, hold: 0)
        let click = try XCTUnwrap(pointer.reports.first { $0.buttons == 1 })
        XCTAssertEqual(click.position.x, 30, accuracy: 0.5)
        XCTAssertEqual(click.position.y, 40, accuracy: 0.5)
        pointer.reports.removeAll()
        input.positionPointer(x: 0.7, y: 0.65)
        try input.nudge(dx: 0, dy: 0, click: false)
        XCTAssertTrue(pointer.reports.contains { $0.dx != 0 && $0.dy != 0 })
        XCTAssertTrue(pointer.reports.allSatisfy { $0.buttons == 0 && $0.dx >= 0 && $0.dy >= 0 })
        XCTAssertEqual(pointer.position.x, 70, accuracy: 0.5)
        XCTAssertEqual(pointer.position.y, 130, accuracy: 0.5)
    }

    func testCoordinateAPIsMoveDirectlyFromKnownPositionWithCombinedReports() throws {
        let (input, pointer) = try preparedInput(vectorModel: .radialQuantized)

        try input.tap(x: 0.4, y: 0.4, hold: 0)
        XCTAssertTrue(
            pointer.reports.contains { $0.dx > 0 && $0.dy > 0 },
            "a verified diagonal click target should use combined movement")
        XCTAssertTrue(
            pointer.reports.allSatisfy { $0.dx >= 0 && $0.dy >= 0 },
            "a known position must not return to the origin before tapping")
        let click = try XCTUnwrap(pointer.reports.first { $0.buttons == 1 })
        XCTAssertEqual(click.position.x, 40, accuracy: 0.5)
        XCTAssertEqual(click.position.y, 80, accuracy: 0.5)
        XCTAssertEqual(pointer.reports.last?.buttons, 0)

        pointer.reports.removeAll()
        try input.move(x: 0.6, y: 0.5)
        XCTAssertTrue(pointer.reports.allSatisfy { $0.buttons == 0 && $0.dx >= 0 && $0.dy >= 0 })
        XCTAssertEqual(pointer.position.x, 60, accuracy: 0.5)
        XCTAssertEqual(pointer.position.y, 100, accuracy: 0.5)

        pointer.reports.removeAll()
        input.step = 0.01
        try input.swipe(points: [(0.7, 0.6), (0.9, 0.9)], duration: 0.02)
        XCTAssertTrue(
            pointer.reports.allSatisfy { $0.dx >= 0 && $0.dy >= 0 },
            "positioning the swipe start must also reuse the current position")
        let press = try XCTUnwrap(pointer.reports.first { $0.buttons == 1 })
        XCTAssertEqual(press.position.x, 70, accuracy: 0.5)
        XCTAssertEqual(press.position.y, 120, accuracy: 0.5)
        XCTAssertTrue(pointer.reports.contains { $0.buttons == 1 && $0.moves })
        XCTAssertEqual(pointer.reports.last?.buttons, 0)
        XCTAssertEqual(pointer.position.x, 90, accuracy: 0.5)
        XCTAssertEqual(pointer.position.y, 180, accuracy: 0.5)
    }

    func testUnknownInvalidatedAndNudgedPositionsStillHomeBeforeCoordinateClick() throws {
        for state in ["new session", "invalidated", "raw nudge"] {
            let (input, pointer) = freshInput(vectorModel: .radialQuantized)
            if state != "new session" {
                try input.move(x: 0.2, y: 0.2)
                if state == "invalidated" {
                    input.invalidatePointerEstimate()
                    // The real phone may have moved while disconnected.
                    try input.type("")
                    pointer.position = CGPoint(x: 80, y: 170)
                } else {
                    try input.nudge(dx: 3, dy: -2, click: false)
                }
                pointer.reports.removeAll()
            }

            try input.tap(x: 0.6, y: 0.5, hold: 0)

            let homing = pointer.calibration.homingReports
            XCTAssertGreaterThan(pointer.reports.count, homing.count, state)
            for (actual, expected) in zip(pointer.reports.prefix(homing.count), homing) {
                XCTAssertEqual(actual.dx, expected.dx, state)
                XCTAssertEqual(actual.dy, expected.dy, state)
                XCTAssertEqual(actual.buttons, 0, state)
            }
            let click = try XCTUnwrap(pointer.reports.first { $0.buttons == 1 })
            XCTAssertEqual(click.position.x, 60, accuracy: 0.5, state)
            XCTAssertEqual(click.position.y, 100, accuracy: 0.5, state)
        }
    }

    func testCoordinateAPIsRemainRejectedDuringWindowDrag() throws {
        let (input, pointer) = try preparedInput(vectorModel: .radialQuantized)
        input.press(x: 0.2, y: 0.2)
        try input.type("")
        pointer.reports.removeAll()

        for operation in [
            { try input.tap(x: 0.6, y: 0.5, hold: 0) },
            { try input.move(x: 0.6, y: 0.5) },
            { try input.swipe(points: [(0.3, 0.3), (0.6, 0.5)], duration: 0.02) },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard case DeviceInput.InputError.pointerBusy = error else {
                    return XCTFail("expected pointerBusy, received \(error)")
                }
            }
        }
        XCTAssertTrue(pointer.reports.isEmpty, "rejected API calls must not move or release the held pointer")
        input.release(x: 0.2, y: 0.2)
        try input.type("")
        XCTAssertEqual(pointer.reports.last?.buttons, 0)
    }
}
