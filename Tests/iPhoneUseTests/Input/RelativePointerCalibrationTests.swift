import XCTest

@testable import iPhoneUse

final class RelativePointerCalibrationTests: XCTestCase {
    func testVerifiedHostPrefersCurrentScreenTemplateOverAStaleHostProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let stale = RelativePointerCalibration(
            host: host, screenWidth: 750, screenHeight: 1334,
            reportInterval: 0.03, distances: [0, 1, 3, 8, 20], screenID: "old-screen")
        let current = RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334,
            reportInterval: 0.03, distances: [0, 2, 5, 12, 25], screenID: "current-screen")
        try save(stale, in: directory)
        try save(current, in: directory)
        let templateURL = RelativePointerCalibration.screenFileURL(screenID: "current-screen", directory: directory)
        try FileManager.default.createDirectory(
            at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(current).write(to: templateURL)

        let resolved = try XCTUnwrap(
            RelativePointerCalibration.loadVerifiedHost(
                host: host, screenID: "current-screen", directory: directory))
        XCTAssertEqual(resolved.host, host)
        XCTAssertEqual(resolved.screenID, "current-screen")
        XCTAssertEqual(resolved.distances, current.distances)
    }

    func testVerifiedHostKeepsItsCurveWhenReplacementScreenHasNoTemplate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let own = RelativePointerCalibration(
            host: host, screenWidth: 750, screenHeight: 1334,
            reportInterval: 0.03, distances: [0, 1, 3, 8, 20], screenID: "old-screen")
        try save(own, in: directory)

        let resolved = try XCTUnwrap(
            RelativePointerCalibration.loadVerifiedHost(
                host: host, screenID: "replacement-screen", directory: directory))
        XCTAssertEqual(resolved.screenID, "replacement-screen")
        XCTAssertEqual(resolved.distances, own.distances)
    }

    func testNativeVerifiedProfilePersistsByHostAndUSBIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let value = RelativePointerCalibration(
            host: host, screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 0.5, 5, 25], screenID: "usb-phone")
        try value.saveVerified(directory: directory)
        let stable = RelativePointerCalibration.screenFileURL(screenID: "usb-phone", directory: directory)
        XCTAssertEqual(
            try Data(contentsOf: stable),
            try Data(contentsOf: directory.appendingPathComponent(host.uuidString + ".json")))
        let rebound = RelativePointerCalibration.loadMatchingScreen(
            host: UUID(), screenSize: CGSize(width: 750, height: 1334), screenID: "usb-phone", directory: directory)
        XCTAssertEqual(rebound?.distances, value.distances)

        let original = try Data(contentsOf: stable)
        let invalid = RelativePointerCalibration(
            host: host, screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 0, 25], screenID: "usb-phone")
        XCTAssertThrowsError(try invalid.saveVerified(directory: directory))
        XCTAssertEqual(try Data(contentsOf: stable), original)
    }

    private func profile(_ distances: [Double] = [0, 1, 3, 8, 20]) -> RelativePointerCalibration {
        RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: distances)
    }

    func testPlansBothAxesAndPreservesPredictedLandingAcrossMoves() throws {
        let calibration = profile()
        try calibration.validate()
        let first = calibration.plan(from: .zero, to: CGPoint(x: 42.4, y: 69.7))
        XCTAssertEqual(first.position, CGPoint(x: 42, y: 70))
        XCTAssertTrue(first.reports.allSatisfy { ($0.dx == 0) != ($0.dy == 0) })
        let repeated = calibration.plan(from: first.position, to: CGPoint(x: 42.4, y: 69.7))
        XCTAssertTrue(repeated.reports.isEmpty)
        XCTAssertEqual(repeated.position, first.position)
        let back = calibration.plan(from: first.position, to: .zero)
        XCTAssertEqual(back.position, .zero)
        XCTAssertTrue(back.reports.allSatisfy { $0.dx <= 0 && $0.dy <= 0 })
    }

    func testClampsTargetsToPhysicalScreenAndHomesPastBothEdges() {
        let calibration = profile()
        let result = calibration.plan(from: .zero, to: CGPoint(x: 1000, y: -100))
        XCTAssertEqual(result.position, CGPoint(x: 99, y: 0))
        XCTAssertEqual(calibration.homingReports.filter { $0.dx < 0 }.count, 7)
        XCTAssertEqual(calibration.homingReports.filter { $0.dy < 0 }.count, 12)
        XCTAssertFalse(calibration.matches(CGSize(width: 200, height: 100)))
    }

    func testTrackingConvergesWithoutReversingAndInterleavesAxes() {
        let calibration = profile()
        for target in [
            CGPoint(x: 91.7, y: 180.2), CGPoint(x: 1.2, y: 2.6),
            CGPoint(x: 91.7, y: 2.6), CGPoint(x: 1.2, y: 180.2),
        ] {
            let start = CGPoint(x: 50, y: 100)
            var position = start
            var previous: RelativePointerCalibration.Movement?
            var reports: [RelativePointerCalibration.Movement] = []
            for _ in 0..<1000 {
                guard let step = calibration.trackingStep(from: position, to: target, after: previous) else { break }
                XCTAssertGreaterThanOrEqual(Double(step.report.dx) * (target.x - start.x), 0)
                XCTAssertGreaterThanOrEqual(Double(step.report.dy) * (target.y - start.y), 0)
                XCTAssertTrue((step.report.dx == 0) != (step.report.dy == 0))
                position = step.position
                previous = step.report
                reports.append(step.report)
            }
            XCTAssertLessThan(reports.count, 1000, "tracking did not converge")
            XCTAssertEqual(position.x, target.x, accuracy: calibration.distances[1] / 2)
            XCTAssertEqual(position.y, target.y, accuracy: calibration.distances[1] / 2)
            XCTAssertTrue(reports.prefix(2).contains { $0.dx != 0 })
            XCTAssertTrue(reports.prefix(2).contains { $0.dy != 0 })
            XCTAssertNil(calibration.trackingStep(from: position, to: target, after: previous))
        }
    }

    func testTrackingFinishesFineAxisAndClampsScreenEdges() {
        let calibration = profile()
        for target in [CGPoint(x: 0.7, y: 190), CGPoint(x: 1000, y: -100)] {
            var position = CGPoint.zero
            var previous: RelativePointerCalibration.Movement?
            for _ in 0..<1000 {
                guard let step = calibration.trackingStep(from: position, to: target, after: previous) else { break }
                position = step.position
                previous = step.report
                XCTAssertTrue((0...99).contains(position.x))
                XCTAssertTrue((0...199).contains(position.y))
            }
            XCTAssertEqual(position.x, max(0, min(99, target.x)), accuracy: 0.5)
            XCTAssertEqual(position.y, max(0, min(199, target.y)), accuracy: 0.5)
            XCTAssertNil(calibration.trackingStep(from: position, to: target, after: previous))
        }
    }

    func testRejectsUnusableOrUnboundedCalibration() throws {
        for values in [[Double](), [0], [0, 0], [0, 2, 1], [0, .infinity], [0, 0.000001]] {
            XCTAssertThrowsError(try profile(values).validate())
        }
        let valid = profile()
        let decoded = try JSONDecoder().decode(RelativePointerCalibration.self, from: JSONEncoder().encode(valid))
        try decoded.validate()
        XCTAssertEqual(decoded.distances, valid.distances)
    }

    func testAPITapAfterWindowMoveUsesSharedPositionAndOnlyRelativeChannel() throws {
        let calibration = profile()
        var reports: [[UInt8]] = []
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            reportSender: { id, bytes in
                XCTAssertEqual(id, .relativeMouse)
                reports.append(bytes)
            })
        input.positionPointer(x: 0.8, y: 0.8)
        try input.tap(x: 0.5, y: 0.5, hold: 0)
        // Simulate a screen with the exact calibration curve, including clipping.
        var position = CGPoint(x: 80, y: 70)
        var click: CGPoint?
        for bytes in reports {
            let dx = Int(Int8(bitPattern: bytes[1]))
            let dy = Int(Int8(bitPattern: bytes[2]))
            position.x = max(0, min(99, position.x + (dx < 0 ? -1 : 1) * calibration.distances[abs(dx)]))
            position.y = max(0, min(199, position.y + (dy < 0 ? -1 : 1) * calibration.distances[abs(dy)]))
            if bytes[0] == 1 { click = position }
        }
        XCTAssertEqual(click, CGPoint(x: 50, y: 100))
        XCTAssertEqual(reports.last, [0, 0, 0, 0])
    }

    func testMismatchedCalibrationDoesNotClickButAllowsRawCalibrationMovement() throws {
        var reports = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), calibrationRequired: true,
            reportSender: { _, _ in reports += 1 })
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, 0)
        try input.nudge(dx: 1, dy: 0, click: false)
        XCTAssertEqual(reports, 1)
    }

    func testCaptureFirstFrameEnablesCalibrationAndRotationDisablesIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = profile()
        try save(saved, in: directory)
        let calibration = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: saved.host, screenSize: nil, directory: directory))
        var size: CGSize?
        var reports = 0
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            calibrationRequired: true, screenSize: { size },
            reportSender: { id, _ in
                XCTAssertEqual(id, .relativeMouse)
                reports += 1
            })
        XCTAssertThrowsError(try input.move(x: 0.5, y: 0.5))
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, 0)
        size = CGSize(width: 100, height: 200)
        try input.move(x: 0.5, y: 0.5)
        let sent = reports
        XCTAssertGreaterThan(sent, 0)
        size = CGSize(width: 200, height: 100)
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, sent)
        size = CGSize(width: 100, height: 200)
        try input.move(x: 0.5, y: 0.5)
        XCTAssertGreaterThan(reports, sent)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save(_ calibration: RelativePointerCalibration, in directory: URL, named host: UUID? = nil) throws {
        try JSONEncoder().encode(calibration).write(
            to: directory.appendingPathComponent((host ?? calibration.host).uuidString + ".json"))
    }

    func testLegacyProfileBindsOnlyItsConfirmedHostAndPersistsScreenIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calibration = profile()
        try save(calibration, in: directory)
        let size = CGSize(width: 100, height: 200)
        let original = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: calibration.host, screenSize: size, directory: directory))
        XCTAssertNil(original.screenID)
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: UUID(), screenSize: size, screenID: "phone-a", directory: directory))

        let bound = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: calibration.host, screenSize: size, screenID: "phone-a", directory: directory))
        XCTAssertEqual(bound.screenID, "phone-a")
        let persisted = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: calibration.host, screenSize: size, directory: directory))
        XCTAssertEqual(persisted.screenID, "phone-a")
        XCTAssertNil(
            RelativePointerCalibration.load(
                host: calibration.host, screenSize: size, screenID: "phone-b", directory: directory))
        let unknownHost = UUID()
        try save(calibration, in: directory, named: unknownHost)
        XCTAssertNil(
            RelativePointerCalibration.load(
                host: unknownHost, screenSize: size, screenID: "phone-a", directory: directory))
    }

    func testDifferentScreenEvidenceRequiresAValidExplicitScreenIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let bound = RelativePointerCalibration(
            host: host, screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "old-usb-id")
        try save(bound, in: directory)

        XCTAssertTrue(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: host, screenID: "new-usb-id", directory: directory))
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: host, screenID: "old-usb-id", directory: directory))

        let legacy = profile()
        try save(legacy, in: directory)
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: legacy.host, screenID: "new-usb-id", directory: directory))

        let invalid = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 0], screenID: "old-usb-id")
        try save(invalid, in: directory)
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: invalid.host, screenID: "new-usb-id", directory: directory))

        let malformedHost = UUID()
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent(malformedHost.uuidString + ".json"))
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: malformedHost, screenID: "new-usb-id", directory: directory))

        let wrongHost = UUID()
        try save(bound, in: directory, named: wrongHost)
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: wrongHost, screenID: "new-usb-id", directory: directory))
    }

    func testRepairedHostRequiresExactScreenIdentityInsteadOfResolution() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newHost = UUID()
        let legacy = profile()
        try save(legacy, in: directory)
        let otherPhone = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 4, 9, 22], screenID: "phone-b")
        try save(otherPhone, in: directory)
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 100, height: 200), screenID: "phone-a", directory: directory))
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "phone-a")
        try save(calibration, in: directory)
        let rebound = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 100, height: 200), screenID: "phone-a", directory: directory))
        try rebound.validate()
        XCTAssertEqual(rebound.host, newHost)
        XCTAssertEqual(rebound.screenID, "phone-a")
        XCTAssertEqual(rebound.distances, calibration.distances)
        let reboundWithoutFrame = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: nil, screenID: "phone-a", directory: directory))
        XCTAssertEqual(reboundWithoutFrame.host, newHost)
        XCTAssertEqual(reboundWithoutFrame.screenID, "phone-a")
        let reboundAfterRotation = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 200, height: 100), screenID: "phone-a", directory: directory))
        XCTAssertEqual(reboundAfterRotation.host, newHost)
        XCTAssertEqual(reboundAfterRotation.screenID, "phone-a")
        XCTAssertEqual(reboundAfterRotation.distances, calibration.distances)
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 100, height: 200), directory: directory))

        var size: CGSize? = CGSize(width: 200, height: 100)
        var reports = 0
        let input = DeviceInput(
            host: newHost, session: UUID(), calibration: reboundAfterRotation,
            calibrationRequired: true, screenSize: { size },
            reportSender: { id, _ in
                XCTAssertEqual(id, .relativeMouse)
                reports += 1
            })
        XCTAssertThrowsError(try input.move(x: 0.5, y: 0.5))
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, 0)
        size = CGSize(width: 100, height: 200)
        XCTAssertNoThrow(try input.move(x: 0.5, y: 0.5))
        let sent = reports
        size = CGSize(width: 200, height: 100)
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, sent)
        size = CGSize(width: 100, height: 200)
        XCTAssertNoThrow(try input.move(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(reports, sent)
    }

    func testMatchProbeInputCalibrationReusesProfileBoundToTheProbedScreen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rePairedHost = UUID()
        let bound = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "phone-a")
        try save(bound, in: directory)

        // The single free screen hands its uniquely bound profile to a
        // re-paired host, rebound in memory and never written to disk.
        let reused = RelativePointerCalibration.probeInputCalibration(
            host: rePairedHost, screenID: "phone-a", directory: directory)
        XCTAssertTrue(reused.required)
        let rebound = try XCTUnwrap(reused.calibration)
        XCTAssertEqual(rebound.host, rePairedHost)
        XCTAssertEqual(rebound.screenID, "phone-a")
        XCTAssertEqual(rebound.distances, bound.distances)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(rePairedHost.uuidString + ".json").path))

        // Several free screens in play keep the candidate on the absolute
        // report, and so does a screen nothing was ever calibrated on.
        for screenID in [nil, "phone-b"] {
            let resolved = RelativePointerCalibration.probeInputCalibration(
                host: rePairedHost, screenID: screenID, directory: directory)
            XCTAssertNil(resolved.calibration)
            XCTAssertFalse(resolved.required)
        }
    }

    func testMatchProbeInputCalibrationPrefersOwnProfileAndKeepsBrokenOwnFilesCalibrated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let otherPhone = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 4, 9, 22], screenID: "phone-a")
        try save(otherPhone, in: directory)

        // The host's own profile wins over another phone's screen-bound one.
        let own = profile()
        try save(own, in: directory)
        var resolved = RelativePointerCalibration.probeInputCalibration(
            host: own.host, screenID: "phone-a", directory: directory)
        XCTAssertTrue(resolved.required)
        let ownLoaded = try XCTUnwrap(resolved.calibration)
        XCTAssertEqual(ownLoaded.host, own.host)
        XCTAssertNil(ownLoaded.screenID)

        // A broken own profile still opts the host into calibrated control;
        // it must not silently fall back to the absolute report.
        let brokenHost = UUID()
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent(brokenHost.uuidString + ".json"))
        resolved = RelativePointerCalibration.probeInputCalibration(
            host: brokenHost, screenID: "phone-b", directory: directory)
        XCTAssertNil(resolved.calibration)
        XCTAssertTrue(resolved.required)

        // Two profiles bound to the same screen are ambiguous; the probe
        // falls back to the absolute report instead of guessing.
        try save(otherPhone, in: directory, named: UUID())
        resolved = RelativePointerCalibration.probeInputCalibration(
            host: UUID(), screenID: "phone-a", directory: directory)
        XCTAssertNil(resolved.calibration)
        XCTAssertFalse(resolved.required)
    }

    func testMigrationUpdatesHostAndScreenIdentityOnDisk() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calibration = profile()
        try save(calibration, in: directory)
        let newHost = UUID()
        let migrated = try XCTUnwrap(
            RelativePointerCalibration.rebind(
                from: calibration.host, to: newHost, screenID: "phone-a", directory: directory))
        XCTAssertEqual(migrated.host, newHost)
        XCTAssertEqual(migrated.screenID, "phone-a")
        let persisted = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: newHost, screenSize: CGSize(width: 100, height: 200), screenID: "phone-a", directory: directory))
        XCTAssertEqual(persisted.host, newHost)
        XCTAssertEqual(persisted.screenID, "phone-a")
        XCTAssertEqual(persisted.distances, calibration.distances)
        XCTAssertThrowsError(
            try RelativePointerCalibration.rebind(
                from: newHost, to: UUID(), screenID: "phone-b", directory: directory))
    }

    func testScreenTemplateSurvivesMultiplePairingsAndOverridesStaleHostCurves() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "phone-a")
        let latest = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.03, distances: [0, 2, 5, 12, 25], screenID: "phone-a",
            vectorModel: .radialQuantized)
        try save(old, in: directory)
        try save(latest, in: directory)
        let templateURL = RelativePointerCalibration.screenFileURL(screenID: "phone-a", directory: directory)
        try FileManager.default.createDirectory(
            at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(latest).write(to: templateURL)

        let reused = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: old.host, screenSize: nil, screenID: "phone-a", directory: directory))
        XCTAssertEqual(reused.host, old.host)
        XCTAssertEqual(reused.distances, latest.distances)
        XCTAssertEqual(reused.reportInterval, latest.reportInterval)
        XCTAssertEqual(reused.vectorModel, latest.vectorModel)
        let newHost = UUID()
        let rePaired = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: nil, screenID: "phone-a", directory: directory))
        XCTAssertEqual(rePaired.host, newHost)
        XCTAssertEqual(rePaired.distances, latest.distances)
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(
                host: newHost, screenID: "phone-a", directory: directory))
        let migrated = try XCTUnwrap(
            RelativePointerCalibration.rebind(
                from: old.host, to: newHost, screenID: "phone-a", directory: directory))
        XCTAssertEqual(migrated.distances, latest.distances)
        XCTAssertNil(
            RelativePointerCalibration.load(
                host: old.host, screenSize: nil, screenID: "phone-b", directory: directory))
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: UUID(), screenSize: nil, screenID: "phone-b", directory: directory))
    }

    func testBrokenOrMisidentifiedScreenTemplateDoesNotFallBackToAbsoluteInput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let templateURL = RelativePointerCalibration.screenFileURL(screenID: "phone-a", directory: directory)
        try FileManager.default.createDirectory(
            at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrongScreen = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "phone-b")
        for data in [Data("not-json".utf8), try JSONEncoder().encode(wrongScreen)] {
            try data.write(to: templateURL)
            let host = UUID()
            XCTAssertNil(
                RelativePointerCalibration.loadMatchingScreen(
                    host: host, screenSize: nil, screenID: "phone-a", directory: directory))
            XCTAssertTrue(
                RelativePointerCalibration.requiresCalibration(
                    host: host, screenID: "phone-a", directory: directory))
        }
        let opaqueID = "phone/../other"
        XCTAssertEqual(
            RelativePointerCalibration.screenFileURL(screenID: opaqueID, directory: directory).lastPathComponent,
            "70686f6e652f2e2e2f6f74686572.json")
    }

    func testInvalidOrMisnamedMigrationCannotCreateANewProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 0], screenID: "phone-a")
        try save(invalid, in: directory)
        let newHost = UUID()
        XCTAssertThrowsError(
            try RelativePointerCalibration.rebind(
                from: invalid.host, to: newHost, screenID: "phone-a", directory: directory))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(newHost.uuidString + ".json").path))
        let wrongHost = UUID()
        try save(profile(), in: directory, named: wrongHost)
        XCTAssertThrowsError(
            try RelativePointerCalibration.rebind(
                from: wrongHost, to: newHost, screenID: "phone-a", directory: directory))
        XCTAssertNil(
            try RelativePointerCalibration.rebind(
                from: UUID(), to: newHost, screenID: "phone-a", directory: directory))
    }

    func testInvalidBoundProfileStillRequiresCalibration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        XCTAssertFalse(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-a", directory: directory))
        let invalid = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{\"screenID\":\"phone-a\",\"distances\":[0,0]}".utf8).write(to: invalid)
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-a", directory: directory))
        XCTAssertFalse(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-b", directory: directory))
        XCTAssertFalse(RelativePointerCalibration.requiresCalibration(host: host, screenID: nil, directory: directory))
        try Data("broken".utf8).write(to: directory.appendingPathComponent(host.uuidString + ".json"))
        XCTAssertTrue(RelativePointerCalibration.requiresCalibration(host: host, screenID: nil, directory: directory))
    }

    func testRelativeModeRequirementSurvivesMissingProfilesAndBluetoothIdentityChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try RelativePointerCalibration.markRequired(screenID: "phone-a", directory: directory)
        for host in [UUID(), UUID()] {
            XCTAssertTrue(
                RelativePointerCalibration.requiresCalibration(
                    host: host, screenID: "phone-a", directory: directory))
            XCTAssertFalse(
                RelativePointerCalibration.requiresCalibration(
                    host: host, screenID: "phone-b", directory: directory))
        }
        XCTAssertThrowsError(try RelativePointerCalibration.markRequired(screenID: "", directory: directory))
    }

    func testAbsoluteProofClearsOnlyTheTargetRequirementAndPreservesProfiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        for screen in ["phone-a", "phone-b"] {
            try RelativePointerCalibration.markRequired(screenID: screen, directory: directory)
        }
        try RelativePointerCalibration.clearRequirementAfterAbsoluteProof(screenID: "phone-a", directory: directory)
        XCTAssertFalse(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-a", directory: directory))
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-b", directory: directory))
        let brokenProfile = directory.appendingPathComponent(host.uuidString + ".json")
        try Data("broken".utf8).write(to: brokenProfile)
        try RelativePointerCalibration.clearRequirementAfterAbsoluteProof(screenID: "phone-a", directory: directory)
        XCTAssertEqual(try Data(contentsOf: brokenProfile), Data("broken".utf8))
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-a", directory: directory))
    }
}
