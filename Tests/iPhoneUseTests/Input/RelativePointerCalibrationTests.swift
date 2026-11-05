import XCTest

@testable import iPhoneUse

final class RelativePointerCalibrationTests: XCTestCase {
    func testSuccessfulReuseStillDetectsHistoricalSourceChangedDuringObservation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = AutomaticPointerCalibrationTests.Phone()
        let screenID = "00008020-0000000000000003"
        let source = RelativePointerCalibration(
            host: UUID(), screenWidth: phone.width, screenHeight: phone.height, reportInterval: 0.03,
            distances: (0...32).map { phone.distance($0) }, screenID: screenID)
        try save(source, in: directory)
        let host = UUID()
        let loaded = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: host, screenSize: nil, screenID: screenID, directory: directory))
        let snapshot = try RelativePointerCalibration.storageSnapshot(
            host: host, screenID: screenID, directory: directory)
        var changed = false
        let newer = RelativePointerCalibration(
            host: source.host, screenWidth: phone.width, screenHeight: phone.height, reportInterval: 0.03,
            distances: source.distances.map { $0 * 1.2 }, screenID: screenID)
        let runner = AutomaticPointerCalibration(
            host: host, screenID: screenID, width: phone.width, height: phone.height,
            send: phone.send,
            capture: {
                if !changed {
                    changed = true
                    try self.save(newer, in: directory)
                }
                return phone.frame()
            })
        let result = try runner.resolve(existing: loaded)
        XCTAssertTrue(result.reused)
        XCTAssertNotEqual(
            snapshot,
            try RelativePointerCalibration.storageSnapshot(host: host, screenID: screenID, directory: directory))
        XCTAssertThrowsError(try result.profile.saveVerified(directory: directory, ifUnchanged: snapshot))
        XCTAssertEqual(
            RelativePointerCalibration.loadMatchingScreen(
                host: host, screenSize: nil, screenID: screenID, directory: directory)?.distances,
            newer.distances)
    }

    func testHistoricalSnapshotDetectsCandidateChangesAndIgnoresOtherPhones() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenID = "00008020-0000000000000003"
        let source = RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: (0...32).map { Double($0 * $0) }, screenID: screenID)
        try save(source, in: directory)
        let host = UUID()
        let snapshot = try RelativePointerCalibration.storageSnapshot(
            host: host, screenID: screenID, directory: directory)
        XCTAssertEqual(
            snapshot,
            try RelativePointerCalibration.storageSnapshot(host: host, screenID: screenID, directory: directory))
        let other = RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: source.distances, screenID: "00008020-0000000000000004")
        try save(other, in: directory)
        XCTAssertEqual(
            snapshot,
            try RelativePointerCalibration.storageSnapshot(host: host, screenID: screenID, directory: directory))

        for conflict in [false, true] {
            let added = RelativePointerCalibration(
                host: UUID(), screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
                distances: source.distances.map { $0 * (conflict ? 1.5 : 1) }, screenID: screenID)
            try save(added, in: directory)
            XCTAssertNotEqual(
                snapshot,
                try RelativePointerCalibration.storageSnapshot(host: host, screenID: screenID, directory: directory))
            XCTAssertThrowsError(try source.saveVerified(directory: directory, ifUnchanged: snapshot))
            try FileManager.default.removeItem(at: directory.appendingPathComponent(added.host.uuidString + ".json"))
        }
        let sourceURL = directory.appendingPathComponent(source.host.uuidString + ".json")
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertNotEqual(
            snapshot,
            try RelativePointerCalibration.storageSnapshot(host: host, screenID: screenID, directory: directory))
        XCTAssertThrowsError(try source.saveVerified(directory: directory, ifUnchanged: snapshot))
    }

    func testChangedHistoricalSourceMustPreventAutomaticReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldHost = UUID()
        let newHost = UUID()
        let historical = RelativePointerCalibration(
            host: oldHost, screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 1, 5, 25], screenID: "00008030-001A690E2EC3802E")
        let historyURL = root.appendingPathComponent(oldHost.uuidString + ".json")
        try JSONEncoder().encode(historical).write(to: historyURL)
        let loaded = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: root))
        let snapshot = try RelativePointerCalibration.storageSnapshot(
            host: newHost, screenID: "00008030-001A690E2EC3802E", directory: root)
        // Another calibration tool updates the historical file supplying this route's curve.
        let newer = RelativePointerCalibration(
            host: oldHost, screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 2, 8, 30], screenID: "00008030-001A690E2EC3802E")
        try JSONEncoder().encode(newer).write(to: historyURL, options: .atomic)
        let after = try RelativePointerCalibration.storageSnapshot(
            host: newHost, screenID: "00008030-001A690E2EC3802E", directory: root)
        print(
            "REVIEW HISTORY changedSource=\(loaded.distances != newer.distances) snapshotChanged=\(snapshot != after)")
        XCTAssertNotEqual(snapshot, after, "A changed source curve must invalidate the measurement snapshot")
        let replacement = RelativePointerCalibration(
            host: newHost, screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 3, 9, 35], screenID: "00008030-001A690E2EC3802E")
        XCTAssertThrowsError(try replacement.saveVerified(directory: root, ifUnchanged: snapshot))
        let selected = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: root))
        print("REVIEW HISTORY newer=\(newer.distances) selected=\(selected.distances)")
        XCTAssertEqual(selected.distances, newer.distances, "Do not shadow the concurrent update with this measurement")
    }

    func testAutomaticReplacementPreservesAProfileInstalledDuringMeasurement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 1, 5, 25], screenID: "00008020-0000000000000003")
        try old.saveVerified(directory: directory)
        let snapshot = try RelativePointerCalibration.storageSnapshot(
            host: old.host, screenID: "00008020-0000000000000003", directory: directory)
        let newer = RelativePointerCalibration(
            host: old.host, screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 2, 8, 30], screenID: "00008020-0000000000000003")
        try newer.saveVerified(directory: directory)
        XCTAssertThrowsError(try old.saveVerified(directory: directory, ifUnchanged: snapshot))
        XCTAssertEqual(
            RelativePointerCalibration.load(
                host: old.host, screenSize: nil, screenID: "00008020-0000000000000003", directory: directory), newer)
        let current = try RelativePointerCalibration.storageSnapshot(
            host: old.host, screenID: "00008020-0000000000000003", directory: directory)
        try old.saveVerified(directory: directory, ifUnchanged: current)
        XCTAssertEqual(
            RelativePointerCalibration.load(
                host: old.host, screenSize: nil, screenID: "00008020-0000000000000003", directory: directory), old)
    }

    func testVerifiedHostPrefersCurrentScreenTemplateOverAStaleHostProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let stale = RelativePointerCalibration(
            host: host, screenWidth: 750, screenHeight: 1334,
            reportInterval: 0.03, distances: [0, 1, 3, 8, 20], screenID: "00008020-0000000000000001")
        let current = RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334,
            reportInterval: 0.03, distances: [0, 2, 5, 12, 25], screenID: "00008020-0000000000000002")
        try save(stale, in: directory)
        try save(current, in: directory)
        let templateURL = RelativePointerCalibration.screenFileURL(
            screenID: "00008020-0000000000000002", directory: directory)
        try FileManager.default.createDirectory(
            at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(current).write(to: templateURL)

        let resolved = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: host, screenSize: nil, screenID: "00008020-0000000000000002", directory: directory))
        XCTAssertEqual(resolved.host, host)
        XCTAssertEqual(resolved.screenID, "00008020-0000000000000002")
        XCTAssertEqual(resolved.distances, current.distances)
    }

    func testForeignHostCurveIsNeverAdoptedByAReplacementScreen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let own = RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334,
            reportInterval: 0.03, distances: [0, 1, 3, 8, 20], screenID: "00008030-001A690E2EC3802E")
        try save(own, in: directory)
        let url = directory.appendingPathComponent(own.host.uuidString + ".json")
        let before = try Data(contentsOf: url)
        XCTAssertNil(
            RelativePointerCalibration.load(
                host: own.host, screenSize: nil, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c",
                directory: directory))
        if case .unavailable = RelativePointerCalibration.pairingProbeCalibration(
            host: own.host, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c", directory: directory)
        {
        } else {
            XCTFail("a foreign curve must not be donated to the pairing probe")
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    RelativePointerCalibration.screenFileURL(
                        screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c", directory: directory
                    ).path))
    }

    func testNativeVerifiedProfilePersistsByHostAndUSBIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let value = RelativePointerCalibration(
            host: host, screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 0.5, 5, 25], screenID: "00008020-0000000000000004")
        try value.saveVerified(directory: directory)
        let stable = RelativePointerCalibration.screenFileURL(
            screenID: "00008020-0000000000000004", directory: directory)
        XCTAssertEqual(
            try Data(contentsOf: stable),
            try Data(contentsOf: directory.appendingPathComponent(host.uuidString + ".json")))
        let rebound = RelativePointerCalibration.loadMatchingScreen(
            host: UUID(), screenSize: CGSize(width: 750, height: 1334), screenID: "00008020-0000000000000004",
            directory: directory)
        XCTAssertEqual(rebound?.distances, value.distances)

        let original = try Data(contentsOf: stable)
        let invalid = RelativePointerCalibration(
            host: host, screenWidth: 750, screenHeight: 1334, reportInterval: 0.03,
            distances: [0, 0, 25], screenID: "00008020-0000000000000004")
        XCTAssertThrowsError(try invalid.saveVerified(directory: directory))
        XCTAssertEqual(try Data(contentsOf: stable), original)
    }

    private func profile(_ distances: [Double] = [0, 1, 3, 8, 20], screenID: String? = nil)
        -> RelativePointerCalibration
    {
        RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: distances, screenID: screenID)
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
        let saved = profile(screenID: "00008030-001A690E2EC3802E")
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

    func testLegacyProfileWithoutUDIDIsNeverAdoptedOrRewritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for missingID in [nil, ""] {
            let legacy = profile(screenID: missingID)
            try save(legacy, in: directory)
            let url = directory.appendingPathComponent(legacy.host.uuidString + ".json")
            let before = try Data(contentsOf: url)
            for screenID in [nil, "00008030-001A690E2EC3802E", "8bdbe135bcd781e8215eb391f48b2848608b292c"] {
                XCTAssertNil(
                    RelativePointerCalibration.load(
                        host: legacy.host, screenSize: CGSize(width: 100, height: 200),
                        screenID: screenID, directory: directory))
            }
            XCTAssertNil(
                RelativePointerCalibration.loadMatchingScreen(
                    host: UUID(), screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
            XCTAssertThrowsError(try legacy.saveVerified(directory: directory))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("by-screen").path))
    }

    func testDifferentScreenEvidenceRequiresAValidExplicitScreenIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let bound = RelativePointerCalibration(
            host: host, screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "00008020-0000000000000005")
        try save(bound, in: directory)

        XCTAssertTrue(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: host, screenID: "00008020-0000000000000006", directory: directory))
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: host, screenID: "00008020-0000000000000005", directory: directory))

        let legacy = profile()
        try save(legacy, in: directory)
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: legacy.host, screenID: "00008020-0000000000000006", directory: directory))

        let invalid = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 0], screenID: "00008020-0000000000000005")
        try save(invalid, in: directory)
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: invalid.host, screenID: "00008020-0000000000000006", directory: directory))

        let malformedHost = UUID()
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent(malformedHost.uuidString + ".json"))
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: malformedHost, screenID: "00008020-0000000000000006", directory: directory))

        let wrongHost = UUID()
        try save(bound, in: directory, named: wrongHost)
        XCTAssertFalse(
            RelativePointerCalibration.isBoundToDifferentScreen(
                host: wrongHost, screenID: "00008020-0000000000000006", directory: directory))
    }

    func testRepairedHostRequiresExactScreenIdentityInsteadOfResolution() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newHost = UUID()
        let legacy = profile()
        try save(legacy, in: directory)
        let otherPhone = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 4, 9, 22], screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c")
        try save(otherPhone, in: directory)
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 100, height: 200), screenID: "00008030-001A690E2EC3802E",
                directory: directory))
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "00008030-001A690E2EC3802E")
        try save(calibration, in: directory)
        let rebound = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 100, height: 200), screenID: "00008030-001A690E2EC3802E",
                directory: directory))
        try rebound.validate()
        XCTAssertEqual(rebound.host, newHost)
        XCTAssertEqual(rebound.screenID, "00008030-001A690E2EC3802E")
        XCTAssertEqual(rebound.distances, calibration.distances)
        let reboundWithoutFrame = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
        XCTAssertEqual(reboundWithoutFrame.host, newHost)
        XCTAssertEqual(reboundWithoutFrame.screenID, "00008030-001A690E2EC3802E")
        let reboundAfterRotation = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 200, height: 100), screenID: "00008030-001A690E2EC3802E",
                directory: directory))
        XCTAssertEqual(reboundAfterRotation.host, newHost)
        XCTAssertEqual(reboundAfterRotation.screenID, "00008030-001A690E2EC3802E")
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
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "00008030-001A690E2EC3802E")
        try save(bound, in: directory)

        // The single free screen hands its uniquely bound profile to a
        // re-paired host, rebound in memory and never written to disk.
        let reused = RelativePointerCalibration.probeInputCalibration(
            host: rePairedHost, screenID: "00008030-001A690E2EC3802E", directory: directory)
        XCTAssertTrue(reused.required)
        let rebound = try XCTUnwrap(reused.calibration)
        XCTAssertEqual(rebound.host, rePairedHost)
        XCTAssertEqual(rebound.screenID, "00008030-001A690E2EC3802E")
        XCTAssertEqual(rebound.distances, bound.distances)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(rePairedHost.uuidString + ".json").path))

        // Several free screens in play keep the candidate on the absolute
        // report, and so does a screen nothing was ever calibrated on.
        for screenID in [nil, "8bdbe135bcd781e8215eb391f48b2848608b292c"] {
            let resolved = RelativePointerCalibration.probeInputCalibration(
                host: rePairedHost, screenID: screenID, directory: directory)
            XCTAssertNil(resolved.calibration)
            XCTAssertFalse(resolved.required)
        }
    }

    func testMatchProbeUsesRequestedUDIDAndKeepsBrokenOwnFilesCalibrated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = profile([0, 1, 4, 9, 22], screenID: "00008030-001A690E2EC3802E")
        let own = profile(screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c")
        try save(requested, in: directory)
        try save(own, in: directory)
        let resolved = RelativePointerCalibration.probeInputCalibration(
            host: own.host, screenID: "00008030-001A690E2EC3802E", directory: directory)
        XCTAssertTrue(resolved.required)
        XCTAssertEqual(resolved.calibration?.screenID, "00008030-001A690E2EC3802E")
        XCTAssertEqual(resolved.calibration?.distances, requested.distances)
        XCTAssertEqual(resolved.calibration?.host, own.host)
        XCTAssertNil(
            RelativePointerCalibration.probeInputCalibration(
                host: own.host, screenID: nil, directory: directory
            ).calibration)
        let brokenHost = UUID()
        try Data("not-json".utf8).write(to: directory.appendingPathComponent(brokenHost.uuidString + ".json"))
        let broken = RelativePointerCalibration.probeInputCalibration(
            host: brokenHost, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c", directory: directory)
        XCTAssertEqual(broken.calibration?.screenID, "8bdbe135bcd781e8215eb391f48b2848608b292c")
        XCTAssertTrue(broken.required)
        let unknown = RelativePointerCalibration.probeInputCalibration(
            host: brokenHost, screenID: "unknown", directory: directory)
        XCTAssertNil(unknown.calibration)
        XCTAssertTrue(unknown.required)
    }

    func testRePairingChangesOnlyTheInMemoryRouteAndNeverWritesFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calibration = profile(screenID: "00008030-001A690E2EC3802E")
        try save(calibration, in: directory)
        let url = directory.appendingPathComponent(calibration.host.uuidString + ".json")
        let before = try Data(contentsOf: url)
        for newHost in [UUID(), UUID()] {
            let routed = try XCTUnwrap(
                RelativePointerCalibration.load(
                    host: newHost, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
            XCTAssertEqual(routed.host, newHost)
            XCTAssertEqual(routed.screenID, calibration.screenID)
            XCTAssertEqual(routed.distances, calibration.distances)
            XCTAssertNil(
                RelativePointerCalibration.load(
                    host: newHost, screenSize: nil, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c",
                    directory: directory))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath:
                        directory.appendingPathComponent(newHost.uuidString + ".json").path))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testConflictingHistoricalCurvesNeverSelectAnArbitraryWinner() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = profile(screenID: "00008030-001A690E2EC3802E")
        let conflict = profile([0, 2, 5, 12, 25], screenID: "00008030-001A690E2EC3802E")
        try save(first, in: directory)
        try save(conflict, in: directory)
        for host in [first.host, conflict.host, UUID()] {
            XCTAssertNil(
                RelativePointerCalibration.load(
                    host: host, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
            let probed = RelativePointerCalibration.probeInputCalibration(
                host: host, screenID: "00008030-001A690E2EC3802E", directory: directory)
            XCTAssertNil(probed.calibration)
            XCTAssertTrue(probed.required)
        }
    }

    func testIdenticalHistoricalCopiesReuseTheSameUDIDWithoutWriting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<2 { try save(profile(screenID: "00008030-001A690E2EC3802E"), in: directory) }
        let loaded = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: UUID(), screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
        XCTAssertEqual(loaded.screenID, "00008030-001A690E2EC3802E")
        XCTAssertEqual(loaded.distances, profile().distances)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testOnlyPhoneUDIDsCanOwnPersistedCurves() throws {
        for id in [
            "00008030-001A690E2EC3802E", "00008030001A690E2EC3802E",
            "8bdbe135bcd781e8215eb391f48b2848608b292c",
        ] {
            XCTAssertTrue(RelativePointerCalibration.isDeviceUDID(id))
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in [
            nil, "", "capture-source", "A312CBE4-758D-50EE-CD7A-67F6FD40ACE4",
            "00008030/001A690E2EC3802E", "00008030-001A690E2EC3802Z",
        ] {
            XCTAssertFalse(RelativePointerCalibration.isDeviceUDID(id))
            let invalid = profile(screenID: id)
            try save(invalid, in: directory)
            XCTAssertThrowsError(try invalid.saveVerified(directory: directory))
            XCTAssertNil(
                RelativePointerCalibration.load(
                    host: invalid.host, screenSize: nil, screenID: id, directory: directory))
        }
    }

    func testScreenTemplateSurvivesMultiplePairingsAndOverridesStaleHostCurves() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "00008030-001A690E2EC3802E")
        let latest = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.03, distances: [0, 2, 5, 12, 25], screenID: "00008030-001A690E2EC3802E",
            vectorModel: .radialQuantized)
        try save(old, in: directory)
        try save(latest, in: directory)
        let templateURL = RelativePointerCalibration.screenFileURL(
            screenID: "00008030-001A690E2EC3802E", directory: directory)
        try FileManager.default.createDirectory(
            at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(latest).write(to: templateURL)
        let templateBytes = try Data(contentsOf: templateURL)

        let reused = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: old.host, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
        XCTAssertEqual(reused.host, old.host)
        XCTAssertEqual(reused.distances, latest.distances)
        XCTAssertEqual(reused.reportInterval, latest.reportInterval)
        XCTAssertEqual(reused.vectorModel, latest.vectorModel)
        let newHost = UUID()
        let rePaired = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
        XCTAssertEqual(rePaired.host, newHost)
        XCTAssertEqual(rePaired.distances, latest.distances)
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(
                host: newHost, screenID: "00008030-001A690E2EC3802E", directory: directory))
        XCTAssertEqual(try Data(contentsOf: templateURL), templateBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    directory.appendingPathComponent(newHost.uuidString + ".json").path))
        XCTAssertNil(
            RelativePointerCalibration.load(
                host: old.host, screenSize: nil, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c",
                directory: directory))
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: UUID(), screenSize: nil, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c",
                directory: directory))
    }

    func testBrokenOrMisidentifiedScreenTemplateDoesNotFallBackToAbsoluteInput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let templateURL = RelativePointerCalibration.screenFileURL(
            screenID: "00008030-001A690E2EC3802E", directory: directory)
        try FileManager.default.createDirectory(
            at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try save(profile(screenID: "00008030-001A690E2EC3802E"), in: directory)
        let wrongScreen = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c")
        for data in [Data("not-json".utf8), try JSONEncoder().encode(wrongScreen)] {
            try data.write(to: templateURL)
            let host = UUID()
            XCTAssertNil(
                RelativePointerCalibration.loadMatchingScreen(
                    host: host, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
            XCTAssertTrue(
                RelativePointerCalibration.requiresCalibration(
                    host: host, screenID: "00008030-001A690E2EC3802E", directory: directory))
        }
        let opaqueID = "phone/../other"
        XCTAssertEqual(
            RelativePointerCalibration.screenFileURL(screenID: opaqueID, directory: directory).lastPathComponent,
            "70686f6e652f2e2e2f6f74686572.json")
    }

    func testInvalidOrMisnamedHistoryCannotSupplyACurveOrCreateAProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try save(profile([0, 0], screenID: "00008030-001A690E2EC3802E"), in: directory)
        let wrongHost = UUID()
        try save(profile(screenID: "00008030-001A690E2EC3802E"), in: directory, named: wrongHost)
        let newHost = UUID()
        for host in [wrongHost, newHost] {
            XCTAssertNil(
                RelativePointerCalibration.load(
                    host: host, screenSize: nil, screenID: "00008030-001A690E2EC3802E", directory: directory))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    directory.appendingPathComponent(newHost.uuidString + ".json").path))
    }

    func testInvalidBoundProfileStillRequiresCalibration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        XCTAssertFalse(
            RelativePointerCalibration.requiresCalibration(
                host: host, screenID: "00008030-001A690E2EC3802E", directory: directory))
        let invalid = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{\"screenID\":\"00008030-001A690E2EC3802E\",\"distances\":[0,0]}".utf8).write(to: invalid)
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(
                host: host, screenID: "00008030-001A690E2EC3802E", directory: directory))
        XCTAssertFalse(
            RelativePointerCalibration.requiresCalibration(
                host: host, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c", directory: directory))
        XCTAssertFalse(RelativePointerCalibration.requiresCalibration(host: host, screenID: nil, directory: directory))
        try Data("broken".utf8).write(to: directory.appendingPathComponent(host.uuidString + ".json"))
        XCTAssertTrue(RelativePointerCalibration.requiresCalibration(host: host, screenID: nil, directory: directory))
    }

    func testRelativeModeRequirementSurvivesMissingProfilesAndBluetoothIdentityChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try RelativePointerCalibration.markRequired(screenID: "00008030-001A690E2EC3802E", directory: directory)
        for host in [UUID(), UUID()] {
            XCTAssertTrue(
                RelativePointerCalibration.requiresCalibration(
                    host: host, screenID: "00008030-001A690E2EC3802E", directory: directory))
            XCTAssertFalse(
                RelativePointerCalibration.requiresCalibration(
                    host: host, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c", directory: directory))
        }
        XCTAssertThrowsError(try RelativePointerCalibration.markRequired(screenID: "", directory: directory))
    }

    func testAbsoluteProofClearsOnlyTheTargetRequirementAndPreservesProfiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        for screen in ["00008030-001A690E2EC3802E", "8bdbe135bcd781e8215eb391f48b2848608b292c"] {
            try RelativePointerCalibration.markRequired(screenID: screen, directory: directory)
        }
        try RelativePointerCalibration.clearRequirementAfterAbsoluteProof(
            screenID: "00008030-001A690E2EC3802E", directory: directory)
        XCTAssertFalse(
            RelativePointerCalibration.requiresCalibration(
                host: host, screenID: "00008030-001A690E2EC3802E", directory: directory))
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(
                host: host, screenID: "8bdbe135bcd781e8215eb391f48b2848608b292c", directory: directory))
        let brokenProfile = directory.appendingPathComponent(host.uuidString + ".json")
        try Data("broken".utf8).write(to: brokenProfile)
        try RelativePointerCalibration.clearRequirementAfterAbsoluteProof(
            screenID: "00008030-001A690E2EC3802E", directory: directory)
        XCTAssertEqual(try Data(contentsOf: brokenProfile), Data("broken".utf8))
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(
                host: host, screenID: "00008030-001A690E2EC3802E", directory: directory))
    }
}
