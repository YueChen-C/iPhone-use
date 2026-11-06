import XCTest

@testable import iPhoneUse

final class VectorPointerCalibrationTests: XCTestCase {
    // Physical pixels measured on the paired phone for one axial count/report.
    private let measuredDistances: [Double] = [
        0, 0.53125, 1.28125, 2.1875, 3.28125, 4.5625, 6.03125, 7.65625, 9.5,
        11.508771929824562, 13.708333333333334, 16.1, 18.647058823529413, 21.4,
        24.37037037037037, 27.47826086956522, 30.761904761904763,
        34.31578947368421, 38, 41.86666666666667, 46, 50.15384615384615,
        54.72727272727273, 59.2, 64.2, 69.11111111111111, 74.25, 79.75,
        85.42857142857143, 91.14285714285714, 97.33333333333333,
        103.33333333333333, 109.6,
    ]

    private func profile(model: RelativePointerCalibration.VectorModel? = .radialQuantized)
        -> RelativePointerCalibration
    {
        RelativePointerCalibration(
            host: UUID(), screenWidth: 750, screenHeight: 1334,
            reportInterval: 0.03, distances: measuredDistances,
            screenID: "00008030-001A690E2EC3802E", vectorModel: model)
    }

    func testVerifiedRadialReportUsesWholeVectorMagnitude() throws {
        let calibration = profile()
        try calibration.validate()
        // hypot(12, 16) == 20; the measured travel for magnitude 20 is 46 px.
        let start = CGPoint(x: 100, y: 200)
        let target = CGPoint(x: 127.6, y: 236.8)
        let step = try XCTUnwrap(calibration.trackingStep(from: start, to: target, after: nil))

        XCTAssertEqual(step.report.dx, 12)
        XCTAssertEqual(step.report.dy, 16)
        XCTAssertEqual(step.position.x - start.x, 27.6, accuracy: 1e-10)
        XCTAssertEqual(step.position.y - start.y, 36.8, accuracy: 1e-10)
        XCTAssertNil(calibration.trackingStep(from: step.position, to: target, after: step.report))
    }

    func testFractionalVectorMagnitudeUsesMeasuredIntegerGain() throws {
        let calibration = profile()
        let start = CGPoint(x: 100, y: 200)
        // hypot(16, 16) is 22.627..., but observed iOS travel follows gain at
        // count 22. Continuous interpolation predicts approximately 40.68 px
        // on each axis, while repeated phone measurements were 39.67 px.
        let displacement = measuredDistances[22] / 22 * 16
        let target = CGPoint(x: start.x + displacement, y: start.y + displacement)
        let step = try XCTUnwrap(calibration.trackingStep(from: start, to: target, after: nil))

        XCTAssertEqual(step.report.dx, 16)
        XCTAssertEqual(step.report.dy, 16)
        XCTAssertEqual(step.position.x - start.x, 39.80165289256198, accuracy: 1e-10)
        XCTAssertEqual(step.position.y - start.y, 39.80165289256198, accuracy: 1e-10)
        XCTAssertNil(calibration.trackingStep(from: step.position, to: target, after: step.report))
    }

    func testUnverifiedAndLegacyProfilesNeverEnableCombinedReports() throws {
        let unverified = profile(model: nil)
        let data = try JSONEncoder().encode(unverified)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["vectorModel"])
        let legacy = try JSONDecoder().decode(RelativePointerCalibration.self, from: data)
        XCTAssertNil(legacy.vectorModel)

        let start = CGPoint(x: 100, y: 200)
        let target = CGPoint(x: 127.6, y: 236.8)
        for calibration in [unverified, legacy] {
            let step = try XCTUnwrap(calibration.trackingStep(from: start, to: target, after: nil))
            XCTAssertNotEqual(step.report.dx == 0, step.report.dy == 0)
        }

        var unknown = json
        unknown["vectorModel"] = "unmeasured-vector-model"
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RelativePointerCalibration.self, from: JSONSerialization.data(withJSONObject: unknown)))
    }

    func testRadialTrackingConvergesWithoutReversalsOrUnmeasuredReportMagnitudes() throws {
        let calibration = profile()
        var paths: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 100, y: 100), CGPoint(x: 600, y: 1100)),
            (CGPoint(x: 600, y: 1100), CGPoint(x: 100, y: 100)),
            (CGPoint(x: 100, y: 1100), CGPoint(x: 600, y: 100)),
            (CGPoint(x: 600, y: 100), CGPoint(x: 100, y: 1100)),
            (CGPoint(x: 350, y: 650), CGPoint(x: 350.1, y: 1000.3)),
            (CGPoint(x: 350, y: 650), CGPoint(x: 350.3, y: 650.3)),
            (CGPoint(x: 350, y: 650), CGPoint(x: 10000, y: -10000)),
        ]
        for i in 0..<48 {
            paths.append(
                (
                    CGPoint(x: Double(i * 97 % 749), y: Double(i * 173 % 1333)),
                    CGPoint(
                        x: Double((i + 13) * 137 % 749) + 0.35,
                        y: Double((i + 19) * 157 % 1333) + 0.15)
                ))
        }
        for (start, target) in paths {
            _ = try trajectory(calibration, from: start, to: target)
        }
    }

    func testRadialTrackingReducesReportsForLongDiagonalMovement() throws {
        let start = CGPoint(x: 100, y: 100)
        let target = CGPoint(x: 600, y: 1100)
        let radial = try trajectory(profile(), from: start, to: target)
        let axial = try trajectory(profile(model: nil), from: start, to: target)

        XCTAssertTrue(radial.contains { $0.dx != 0 && $0.dy != 0 })
        XCTAssertLessThan(
            radial.count, axial.count,
            "the verified vector model must reduce Bluetooth intervals without changing the endpoint")
    }

    func testNarrowDirectionFallsBackToMeasuredAxisReportsAndSettles() throws {
        let calibration = profile()
        let reports = try trajectory(
            calibration, from: CGPoint(x: 300, y: 600),
            to: CGPoint(x: 300.1, y: 650.3))

        XCTAssertFalse(reports.isEmpty)
        XCTAssertTrue(
            reports.allSatisfy { $0.dx == 0 && $0.dy > 0 },
            "the settled axis must not move while the other axis catches up")
    }

    func testRepairedHostPreservesVerifiedVectorModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calibration = profile()
        let originalURL = directory.appendingPathComponent(calibration.host.uuidString + ".json")
        try JSONEncoder().encode(calibration).write(to: originalURL)
        let newHost = UUID()

        let matched = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 750, height: 1334), screenID: "00008030-001A690E2EC3802E",
                directory: directory))
        XCTAssertEqual(matched.vectorModel, .radialQuantized)
        XCTAssertEqual(matched.host, newHost)

        XCTAssertEqual(matched.screenID, calibration.screenID)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RelativePointerCalibration.self, from: Data(contentsOf: originalURL)), calibration)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    directory.appendingPathComponent(newHost.uuidString + ".json").path))
    }

    private func trajectory(
        _ calibration: RelativePointerCalibration, from start: CGPoint, to requested: CGPoint,
        file: StaticString = #filePath, line: UInt = #line
    ) throws
        -> [RelativePointerCalibration.Movement]
    {
        let target = CGPoint(
            x: max(0, min(Double(calibration.screenWidth - 1), requested.x)),
            y: max(0, min(Double(calibration.screenHeight - 1), requested.y)))
        let tolerance = calibration.distances[1] / 2 + 1e-8
        let directionX = target.x - start.x
        let directionY = target.y - start.y
        var position = start
        var reports: [RelativePointerCalibration.Movement] = []
        for _ in 0..<512 {
            guard let step = calibration.trackingStep(from: position, to: target, after: reports.last) else { break }
            XCTAssertLessThanOrEqual(
                hypot(Double(step.report.dx), Double(step.report.dy)),
                Double(calibration.distances.count - 1), file: file, line: line)
            XCTAssertGreaterThanOrEqual(Double(step.report.dx) * directionX, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(Double(step.report.dy) * directionY, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(step.position.x, min(start.x, target.x) - tolerance, file: file, line: line)
            XCTAssertLessThanOrEqual(step.position.x, max(start.x, target.x) + tolerance, file: file, line: line)
            XCTAssertGreaterThanOrEqual(step.position.y, min(start.y, target.y) - tolerance, file: file, line: line)
            XCTAssertLessThanOrEqual(step.position.y, max(start.y, target.y) + tolerance, file: file, line: line)
            XCTAssertLessThan(
                hypot(target.x - step.position.x, target.y - step.position.y),
                hypot(target.x - position.x, target.y - position.y), file: file, line: line)
            reports.append(step.report)
            position = step.position
        }
        XCTAssertLessThan(reports.count, 512, "tracking failed to settle", file: file, line: line)
        XCTAssertEqual(position.x, target.x, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(position.y, target.y, accuracy: tolerance, file: file, line: line)
        XCTAssertNil(calibration.trackingStep(from: position, to: target, after: reports.last), file: file, line: line)
        return reports
    }
}
