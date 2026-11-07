import XCTest

@testable import iPhoneUse

final class DeviceInputPointerTests: XCTestCase {
    func testClickCurrentPointerUsesLastAbsolutePositionWithoutRepositioning() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        try input.move(x: 0.5, y: 0.5)
        try input.nudge(dx: 0, dy: 0, click: true)
        XCTAssertEqual(reports.map { $0.0 }, [.absolutePointer, .absolutePointer, .absolutePointer])
        XCTAssertEqual(reports.last?.1, [0, 0, 64, 0, 64])
        reports.removeAll()
        try input.nudge(dx: 1, dy: 0, click: false)
        try input.nudge(dx: 0, dy: 0, click: true)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .relativeMouse }, "raw nudges invalidate absolute coordinates")
    }

    func testVerifiedRotationCorrectsHomingTrackingAndSurvivesRawRediscovery() throws {
        for orientation in RelativePointerScreenMatcher.Orientation.allCases {
            let profile = RelativePointerCalibration(
                host: UUID(), screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
                distances: [0, 1, 10, 100], screenID: "phone")
            var position = CGPoint(x: 320, y: 640)
            var reports: [[UInt8]] = []
            var rediscovering = false
            let input = DeviceInput(
                host: profile.host, session: UUID(), calibration: profile,
                relativePointerOrientation: orientation, sleep: { _ in },
                reportSender: { id, bytes in
                    XCTAssertEqual(id, .relativeMouse)
                    reports.append(bytes)
                    if rediscovering { return }
                    let report = orientation.screenDelta(
                        dx: Int(Int8(bitPattern: bytes[1])), dy: Int(Int8(bitPattern: bytes[2])))
                    func distance(_ count: Int) -> Double {
                        Double(count.signum()) * profile.distances[abs(count)]
                    }
                    position.x = min(749, max(0, position.x + distance(report.dx)))
                    position.y = min(1333, max(0, position.y + distance(report.dy)))
                }, reportReadiness: { _, _, _ in true })
            try input.move(x: 0.4, y: 0.5)
            XCTAssertEqual(position.x, 300, accuracy: 0.5)
            XCTAssertEqual(position.y, 667, accuracy: 0.5)
            input.positionPointer(x: 0.6, y: 0.6)
            try input.nudge(dx: 0, dy: 0, click: false)
            XCTAssertEqual(position.x, 450, accuracy: 0.5)
            XCTAssertEqual(position.y, 800.4, accuracy: 0.5)
            XCTAssertEqual(input.pointerStatus["relativePointerOrientation"] as? String, orientation.rawValue)
            XCTAssertTrue(reports.allSatisfy { $0[0] == 0 })

            // Discovery must always use raw reports, not apply the last transform
            // twice when a reconnect/rotation requires another proof.
            reports.removeAll()
            rediscovering = true
            _ = try input.relativePairingProbe(preparePosition: false, isReady: { true }, capture: { [[0]] })
            XCTAssertEqual(reports[0], [0, 248, 0, 0])
            XCTAssertEqual(reports[1], [0, 8, 0, 0])
        }
    }

    func testRotatedSessionVerificationReusesCurveWithoutTreatingOrientationAsGainMismatch() throws {
        let phone = AutomaticPointerCalibrationTests.Phone()
        phone.radial = true
        let profile = RelativePointerCalibration(
            host: UUID(), screenWidth: phone.width, screenHeight: phone.height, reportInterval: 0.03,
            distances: (0...32).map { phone.distance($0) }, screenID: "phone", vectorModel: .radialQuantized)
        let orientation = RelativePointerScreenMatcher.Orientation.counterclockwise
        let input = DeviceInput(
            host: profile.host, session: UUID(), calibration: profile,
            relativePointerOrientation: orientation, sleep: { _ in },
            reportSender: { id, bytes in
                XCTAssertEqual(id, .relativeMouse)
                XCTAssertEqual(bytes[0], 0)
                let delta = orientation.screenDelta(
                    dx: Int(Int8(bitPattern: bytes[1])), dy: Int(Int8(bitPattern: bytes[2])))
                phone.send(delta.dx, delta.dy)
            }, reportReadiness: { _, _, _ in true })
        let result = try input.measureRelativePointer(
            screenID: "phone", size: CGSize(width: phone.width, height: phone.height), reuseExisting: true,
            isReady: { true }, capture: { phone.frame().pixels },
            onMismatch: { XCTFail("a session rotation must not invalidate the gain curve") })
        XCTAssertTrue(result.reused)
        XCTAssertEqual(result.profile, profile)
    }

    func testRotationAdoptionInvalidatesOldEstimateWithoutChangingCurve() throws {
        let profile = RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 1, 10, 100], screenID: "phone")
        var rotation = RelativePointerScreenMatcher.Orientation.identity
        var position = CGPoint(x: 100, y: 300)
        let input = DeviceInput(
            host: profile.host, session: UUID(), calibration: profile, sleep: { _ in },
            reportSender: { _, bytes in
                let delta = rotation.screenDelta(
                    dx: Int(Int8(bitPattern: bytes[1])), dy: Int(Int8(bitPattern: bytes[2])))
                func step(_ n: Int) -> Double { Double(n.signum()) * profile.distances[abs(n)] }
                position.x = min(749, max(0, position.x + step(delta.dx)))
                position.y = min(1333, max(0, position.y + step(delta.dy)))
            }, reportReadiness: { _, _, _ in true })
        try input.move(x: 0.4, y: 0.5)
        rotation = .counterclockwise
        input.adoptRelativePointerOrientation(rotation)
        try input.move(x: 0.6, y: 0.6)
        XCTAssertEqual(position.x, 450, accuracy: 0.5)
        XCTAssertEqual(position.y, 800.4, accuracy: 0.5)
        XCTAssertEqual(input.calibration, profile)
        // A new BLE session must not inherit another session's transform.
        let fresh = DeviceInput(host: profile.host, session: UUID(), calibration: profile)
        XCTAssertEqual(fresh.pointerOrientation, .identity)
    }

    func testConfirmedBadCurveMustStayBlockedUntilReplacementIsPublished() throws {
        let phone = AutomaticPointerCalibrationTests.Phone()
        let old = RelativePointerCalibration(
            host: UUID(), screenWidth: phone.width, screenHeight: phone.height,
            reportInterval: 0.03, distances: (0...32).map { phone.distance($0) * 0.7 },
            screenID: "00008030-001A690E2EC3802E")
        var mismatch = false
        var clicked: CGPoint?
        var input: DeviceInput!
        input = DeviceInput(
            host: old.host, session: UUID(), calibration: old, sleep: { _ in },
            reportSender: { id, bytes in
                guard id == .relativeMouse else { return }
                phone.send(Int(Int8(bitPattern: bytes[1])), Int(Int8(bitPattern: bytes[2])))
                if bytes[0] == 1 { clicked = CGPoint(x: phone.x, y: phone.y) }
            }, reportReadiness: { _, _, _ in true })
        let resolution = try input.measureRelativePointer(
            screenID: "00008030-001A690E2EC3802E", size: CGSize(width: phone.width, height: phone.height),
            reuseExisting: true,
            isReady: { true }, capture: { phone.frame().pixels }, onMismatch: { mismatch = true })
        // Foreground input arrives while the registry checks files before retiring/publishing.
        print("REVIEW SAVE WINDOW rejected=\(mismatch) reused=\(resolution.reused) oldReady=\(input.isPointerReady)")
        XCTAssertTrue(mismatch)
        XCTAssertFalse(resolution.reused)
        XCTAssertFalse(
            input.isPointerReady, "A proven-bad old curve must not become available before replacement publication")
        let activity = input.inputActivitySequence
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5, hold: 0))
        print(
            "REVIEW SAVE WINDOW requested=(\(Double(phone.width) * 0.5),\(Double(phone.height) * 0.5)) clicked=\(String(describing: clicked))"
        )
        XCTAssertNil(clicked, "Do not click using the curve which measurement just rejected")
        XCTAssertThrowsError(try input.retireForCalibrationReload(ifActivityUnchanged: activity))
    }

    func testInterruptedSessionVerificationDoesNotDisableSavedCurveOrMouseFollowing() throws {
        let host = UUID()
        var verified = false
        var reports: [ReportID] = []
        let profile = RelativePointerCalibration(
            host: host, screenWidth: 750, screenHeight: 1334,
            reportInterval: 0.03, distances: [0, 1, 10, 100], screenID: "phone")
        let input = DeviceInput(
            host: host, session: UUID(), calibration: profile,
            calibrationIsVerified: { verified }, sleep: { _ in },
            reportSender: { id, _ in reports.append(id) }, reportReadiness: { _, _, _ in true })
        XCTAssertTrue(input.isPointerReady)
        XCTAssertFalse(input.needsCalibration)
        XCTAssertTrue(input.isBluetoothReady)
        input.positionPointer(x: 0.4, y: 0.5)
        try input.nudge(dx: 0, dy: 0, click: false)  // Drain the same queue.
        XCTAssertTrue(reports.contains(.relativeMouse))
        verified = true
        XCTAssertTrue(input.isPointerReady)
        verified = false
        XCTAssertTrue(input.isPointerReady, "an interrupted observation must not disable the saved curve")
        input.rejectCalibration()
        XCTAssertFalse(input.isPointerReady, "a measured mismatch still blocks incorrect coordinates")
        XCTAssertThrowsError(try input.move(x: 0.4, y: 0.5))
        XCTAssertTrue(input.isBluetoothReady)
    }

    func testRejectedCoordinateInvalidationDoesNotCancelSessionVerification() throws {
        let phone = AutomaticPointerCalibrationTests.Phone()
        let profile = RelativePointerCalibration(
            host: UUID(), screenWidth: phone.width, screenHeight: phone.height, reportInterval: 0.03,
            distances: (0...32).map { phone.distance($0) }, screenID: "phone")
        var checked = false
        var input: DeviceInput!
        input = DeviceInput(
            host: profile.host, session: UUID(), calibration: profile,
            calibrationIsVerified: { false }, sleep: { _ in },
            reportSender: { id, bytes in
                if !checked {
                    checked = true
                    let activity = input.inputActivitySequence
                    XCTAssertTrue(input.isPointerReady)
                    input.invalidatePointerEstimate(preservingBackgroundMotion: true)
                    XCTAssertEqual(input.inputActivitySequence, activity)
                }
                phone.send(Int(Int8(bitPattern: bytes[1])), Int(Int8(bitPattern: bytes[2])))
            }, reportReadiness: { _, _, _ in true })
        let result = try input.measureRelativePointer(
            screenID: "phone", size: CGSize(width: phone.width, height: phone.height), reuseExisting: true,
            isReady: { true }, capture: { phone.frame().pixels })
        XCTAssertTrue(checked)
        XCTAssertTrue(result.reused)
    }

    func testReadinessChangeCannotCancelItsOwnStaleCurveRecovery() throws {
        let phone = AutomaticPointerCalibrationTests.Phone()
        phone.radial = true
        let old = RelativePointerCalibration(
            host: UUID(), screenWidth: phone.width, screenHeight: phone.height, reportInterval: 0.03,
            distances: (0...32).map { phone.distance($0) * 0.7 }, screenID: "phone", vectorModel: .radialQuantized)
        var mismatch = false
        var readinessPublished = false
        var input: DeviceInput!
        input = DeviceInput(
            host: old.host, session: UUID(), calibration: old, sleep: { _ in },
            reportSender: { id, bytes in
                XCTAssertEqual(id, .relativeMouse)
                XCTAssertEqual(bytes[0], 0)
                if !readinessPublished {
                    readinessPublished = true
                    let activity = input.inputActivitySequence
                    input.cancelPointer(preservingBackgroundMotion: true)
                    input.invalidatePointerEstimate(preservingBackgroundMotion: true)
                    XCTAssertEqual(input.inputActivitySequence, activity)
                }
                if mismatch {
                    XCTAssertTrue(input.isPointerReady, "readiness must not change mid-recovery")
                    if !input.isPointerReady { input.cancelBackgroundMotion() }
                }
                phone.send(Int(Int8(bitPattern: bytes[1])), Int(Int8(bitPattern: bytes[2])))
            }, reportReadiness: { _, _, _ in true })
        let result = try input.measureRelativePointer(
            screenID: "phone", size: CGSize(width: phone.width, height: phone.height), reuseExisting: true,
            isReady: { true }, capture: { phone.frame().pixels }, onMismatch: { mismatch = true })
        XCTAssertTrue(mismatch)
        XCTAssertFalse(result.reused)
        XCTAssertEqual(result.profile.vectorModel, .radialQuantized)
    }

    func testInterruptedReplacementBlocksRejectedCurveAndKeepsKeyboardAvailable() throws {
        let phone = AutomaticPointerCalibrationTests.Phone()
        let old = RelativePointerCalibration(
            host: UUID(), screenWidth: phone.width, screenHeight: phone.height, reportInterval: 0.03,
            distances: (0...32).map { phone.distance($0) * 0.7 }, screenID: "phone")
        var mismatch = false
        var input: DeviceInput!
        input = DeviceInput(
            host: old.host, session: UUID(), calibration: old, sleep: { _ in },
            reportSender: { id, bytes in
                if id == .relativeMouse {
                    phone.send(Int(Int8(bitPattern: bytes[1])), Int(Int8(bitPattern: bytes[2])))
                    if mismatch { input.cancelBackgroundMotion() }
                }
            }, reportReadiness: { _, _, _ in true })
        XCTAssertThrowsError(
            try input.measureRelativePointer(
                screenID: "phone", size: CGSize(width: phone.width, height: phone.height), reuseExisting: true,
                isReady: { true }, capture: { phone.frame().pixels }, onMismatch: { mismatch = true }))
        XCTAssertTrue(mismatch)
        XCTAssertTrue(input.needsCalibration)
        XCTAssertFalse(input.isPointerReady)
        XCTAssertTrue(input.isBluetoothReady)
        XCTAssertEqual(input.calibration, old)
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        try input.key("enter", modifiers: [])
    }

    func testRejectedResponseBlocksCoordinatesButKeepsBluetoothAndKeyboard() throws {
        var reports: [ReportID] = []
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 1, 5, 25], screenID: "phone")
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration, calibrationRejected: true,
            sleep: { _ in }, reportSender: { id, _ in reports.append(id) }, reportReadiness: { _, _, _ in true })
        XCTAssertTrue(input.isBluetoothReady)
        XCTAssertTrue(input.needsCalibration)
        XCTAssertFalse(input.isPointerReady)
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        try input.key("enter", modifiers: [])
        XCTAssertEqual(reports, [.keyboard, .keyboard])
    }

    func testForegroundActivityPreventsRetirementOfMeasuredInput() throws {
        let input = DeviceInput(host: UUID(), session: UUID(), sleep: { _ in }, reportSender: { _, _ in })
        let activity = input.inputActivitySequence
        input.cancelBackgroundMotion()
        XCTAssertThrowsError(try input.retireForCalibrationReload(ifActivityUnchanged: activity))
        XCTAssertFalse(input.isRetired)
        try input.move(x: 0.5, y: 0.5)
    }

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
                if id == .absolutePointer && bytes[0] == 1 { allowed = false }
            })

        input.press(x: 0.5, y: 0.5)
        input.cancelPointer()
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(reports.map { $0.0 }, [.absolutePointer, .absolutePointer, .absolutePointer])
        XCTAssertEqual(reports[1].1, [1, 0, 64, 0, 64])
        XCTAssertEqual(reports[2].1, [0, 0, 64, 0, 64])
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

    func testAbsoluteProbeVerifiesThirdLandingBeforeReturningWithoutClicks() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), calibrationRequired: true, sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        let frames = try input.pairingProbe(
            calibration: nil, firstPoint: CGPoint(x: 0.3, y: 0.35), secondPoint: CGPoint(x: 0.7, y: 0.65),
            returnToStart: true, thirdPoint: CGPoint(x: 0.5, y: 0.5), wait: 0, isReady: { true },
            capture: { [UInt8(reports.count)] })
        XCTAssertEqual(frames.before, [2])
        XCTAssertEqual(frames.after, [3])
        XCTAssertEqual(frames.intermediate, [4])
        XCTAssertEqual(frames.returned, [5])
        XCTAssertEqual(reports.count, 5)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .absolutePointer && $0.1[0] == 0 })
        XCTAssertEqual(reports[0].1, reports[3].1, "wake-up visits a different coordinate before the first capture")
        XCTAssertEqual(reports[1].1, reports[4].1)
        XCTAssertFalse(input.isPointerReady, "a probe alone must not enable normal coordinate input")
    }

    func testLocalRelativeProbeUsesEighteenReportsWithoutSweepingEdges() throws {
        var position = CGPoint(x: 200, y: 400)
        var positions: [CGPoint] = []
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { id, bytes in
                reports.append((id, bytes))
                position.x += Double(Int8(bitPattern: bytes[1])) * 3
                position.y += Double(Int8(bitPattern: bytes[2])) * 3
            })
        _ = try input.relativePairingProbe(
            preparePosition: false, isReady: { true },
            capture: {
                positions.append(position)
                return [[0]]
            })
        XCTAssertEqual(reports.count, 18)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .relativeMouse && $0.1[0] == 0 })
        XCTAssertEqual(
            positions,
            [
                CGPoint(x: 200, y: 400), CGPoint(x: 296, y: 400), CGPoint(x: 296, y: 496),
                CGPoint(x: 200, y: 496), CGPoint(x: 200, y: 400),
            ])

        reports.removeAll()
        XCTAssertThrowsError(
            try input.relativePairingProbe(
                preparePosition: false, isReady: { reports.count < 1 }, capture: { [[0]] }))
        XCTAssertEqual(reports.count, 1, "local probing must stop as soon as readiness is lost")
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

    func testTwoPointSwipeUsesAbsolutePositionsAndOneHeldButton() throws {
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 1170, height: 2532) },
            sleep: { pauses.append($0) }, reportSender: { reports.append(($0, $1)) })
        input.step = 0.125
        try input.swipe(points: [(0, 0), (1, 1)], duration: 0.5)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .absolutePointer })
        XCTAssertEqual(reports.first?.1, [0, 0, 0, 0, 0])
        XCTAssertEqual(reports.last?.1, [0, 255, 127, 255, 127])
        XCTAssertTrue(reports.dropFirst().dropLast().allSatisfy { $0.1[0] == 1 })
        XCTAssertEqual(reports[reports.count - 2].1, [1, 255, 127, 255, 127])
        XCTAssertEqual(pauses, [0.25, 0.125, 0.125, 0.125, 0.125, 0.125, 0.25, 0.125])
    }

    func testSlowAbsoluteSwipePreservesMovementDuration() throws {
        var pauses: [TimeInterval] = []
        var reports: [ReportID] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { pauses.append($0) },
            reportSender: { id, _ in reports.append(id) })
        input.step = 0.125
        try input.swipe(points: [(0.5, 0.5), (0.501, 0.501)], duration: 0.6)
        XCTAssertTrue(reports.allSatisfy { $0 == .absolutePointer })
        XCTAssertEqual(pauses.dropFirst(2).dropLast(2).reduce(0, +), 0.6, accuracy: 1e-12)
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

    func testAbsolutePointerReadinessRequiresOnlyAbsoluteSubscription() {
        let input = DeviceInput(
            host: UUID(), session: UUID(),
            reportReadiness: { report, _, _ in
                [.keyboard, .absolutePointer, .consumer].contains(report)
            })

        XCTAssertTrue(input.isPointerReady)
        XCTAssertTrue(input.isBluetoothReady)

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
        XCTAssertTrue(reports.allSatisfy { $0.0 == .absolutePointer })
        let movement = Array(reports.dropFirst(2).dropLast())
        XCTAssertEqual(movement.count, 6)
        XCTAssertEqual(movement[1].1, [1, 255, 127, 0, 0])
        XCTAssertEqual(movement.last?.1, [1, 255, 127, 255, 127])
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        XCTAssertEqual(pauses.dropFirst(2).dropLast(2).reduce(0, +), 0.75, accuracy: 1e-12)
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

            // One press and one release on the absolute report — repeated or
            // stationary points never add a second button transition.
            XCTAssertTrue(reports.allSatisfy { $0.0 == .absolutePointer })
            XCTAssertEqual(reports.first?.1[0], 0)
            XCTAssertEqual(reports.last?.1[0], 0)
            XCTAssertTrue(reports.dropFirst().dropLast().allSatisfy { $0.1[0] == 1 })
            XCTAssertTrue(pauses.allSatisfy { $0.isFinite && $0 >= 0 })
            XCTAssertEqual(pauses.dropFirst(2).dropLast(2).reduce(0, +), 0.5, accuracy: 1e-12)
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
        try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: .leastNonzeroMagnitude)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .absolutePointer })
        XCTAssertTrue(reports.contains { $0.1 == [1, 255, 127, 0, 0] })
        XCTAssertEqual(reports.last?.1, [0, 255, 127, 255, 127])
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
                .absolutePointer, .absolutePointer, .absolutePointer, .absolutePointer,
                .absolutePointer, .absolutePointer, .absolutePointer, .absolutePointer,
            ])
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [0, 255, 127, 255, 127], [0, 85, 85, 249, 47], [1, 85, 85, 249, 47], [0, 85, 85, 249, 47],
                [0, 0, 0, 0, 0], [0, 0, 64, 0, 64], [1, 0, 64, 0, 64], [0, 0, 64, 0, 64],
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
                .absolutePointer, .absolutePointer, .absolutePointer, .absolutePointer,
            ])
        XCTAssertEqual(
            reports.dropFirst(3).map { $0.1 },
            [
                [0, 0, 0, 255, 127], [1, 0, 0, 255, 127], [1, 0, 0, 255, 127], [0, 0, 0, 255, 127],
            ])
    }

    func testWindowDragUsesAbsoluteFinalLocationWithoutScreenSizeOrGain() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        input.press(x: 0, y: 0)
        input.drag(x: 0.5, y: 0.5)
        input.drag(x: 1, y: 1)
        input.release(x: 1, y: 1)
        try input.nudge(dx: 0, dy: 0, click: false)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .absolutePointer })
        XCTAssertEqual(reports.first?.1, [0, 0, 0, 0, 0])
        XCTAssertEqual(reports.last?.1, [0, 255, 127, 255, 127])
        XCTAssertEqual(reports[reports.count - 2].1, [1, 255, 127, 255, 127])
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

        XCTAssertTrue(reports.contains { $0.0 == .absolutePointer && $0.1[0] & 1 == 1 })
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
                [0, 255, 127, 255, 127], [1, 255, 127, 255, 127], [0, 255, 127, 255, 127],
            ])
    }

    func testFocusCancellationReleasesWindowButtonAndAllowsAPITap() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.press(x: 0, y: 0)
        input.cancelPointer()
        input.release(x: 1, y: 1)  // A stale mouse-up must not reposition the phone.
        try input.tap(x: 0.5, y: 0.5)
        XCTAssertTrue(reports.allSatisfy { $0.0 == .absolutePointer })
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [0, 0, 0, 0, 0], [1, 0, 0, 0, 0], [0, 0, 0, 0, 0],
                [0, 0, 64, 0, 64], [1, 0, 64, 0, 64], [0, 0, 64, 0, 64],
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
