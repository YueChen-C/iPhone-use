import XCTest

@testable import iPhoneUse

final class AutomaticPointerCalibrationTests: XCTestCase {
    final class Phone {
        let width = 375, height = 667
        var x = 350.0, y = 340.0
        var verticalScale = 1.0
        var animate = false
        var animateClock = false
        var radial = false
        var reports = 0
        var captures = 0

        func distance(_ count: Int) -> Double {
            let n = Double(abs(count))
            return (0.3 * n + 0.07 * n * n) * Double(count.signum())
        }

        func send(_ dx: Int, _ dy: Int) {
            reports += 1
            let count = Int(hypot(Double(dx), Double(dy)))
            let gain = count == 0 ? 0 : distance(count) / Double(count)
            x = max(0, min(Double(width - 1), x + (radial ? gain * Double(dx) : distance(dx))))
            y = max(0, min(Double(height - 1), y + (radial ? gain * Double(dy) : distance(dy)) * verticalScale))
        }

        func frame() -> PointerMotionObservation.Frame {
            captures += 1
            var pixels = [UInt8](repeating: 240, count: width * height)
            let cx = Int(x.rounded())
            let cy = Int(y.rounded())
            for dy in -9...9 {
                for dx in -9...9 where dx * dx + dy * dy <= 81 {
                    let px = cx + dx
                    let py = cy + dy
                    if (0..<width).contains(px), (0..<height).contains(py) {
                        pixels[py * width + px] = 110
                    }
                }
            }
            if animate {
                for py in 80..<140 {
                    for px in 10..<100 { pixels[py * width + px] = captures % 2 == 0 ? 10 : 240 }
                }
            }
            if animateClock {
                for py in 20..<35 {
                    for px in 10..<40 { pixels[py * width + px] = captures % 2 == 0 ? 10 : 240 }
                }
            }
            return .init(width: width, height: height, pixels: pixels)
        }
    }

    private func measure(_ phone: Phone) throws -> RelativePointerCalibration {
        try AutomaticPointerCalibration(
            host: UUID(), screenID: "phone", width: phone.width, height: phone.height,
            send: phone.send, capture: phone.frame
        ).measure()
    }

    private func profile(_ phone: Phone, scale: Double = 1) -> RelativePointerCalibration {
        RelativePointerCalibration(
            host: UUID(), screenWidth: phone.width, screenHeight: phone.height,
            reportInterval: 0.03, distances: (0...32).map { phone.distance($0) * scale },
            screenID: "phone", vectorModel: phone.radial ? .radialQuantized : nil)
    }

    private func resolve(
        _ phone: Phone, existing: RelativePointerCalibration, onMismatch: () -> Void = {},
        progress: @escaping (Int) -> Void = { _ in }
    ) throws -> AutomaticPointerCalibration.Resolution {
        try AutomaticPointerCalibration(
            host: existing.host, screenID: "phone", width: phone.width, height: phone.height,
            send: phone.send, capture: phone.frame, progress: progress
        ).resolve(existing: existing, onMismatch: onMismatch)
    }

    func testValidAxisCurveSurvivesUnsupportedDiagonalModel() throws {
        let phone = AutomaticPointerCalibrationTests.Phone()
        func step(_ count: Int) -> Double {
            let n = Double(abs(count))
            let excess = max(0, n - 10)
            return (0.8 * n + 0.04 * excess * excess) * Double(count.signum())
        }
        let runner = AutomaticPointerCalibration(
            host: UUID(), screenID: "00008030-001A690E2EC3802E", width: phone.width, height: phone.height,
            send: { dx, dy in
                phone.x = max(0, min(Double(phone.width - 1), phone.x + step(dx)))
                phone.y = max(0, min(Double(phone.height - 1), phone.y + step(dy)))
            }, capture: phone.frame)
        do {
            let profile = try runner.measure()
            print("REVIEW AXIS curve32=\(profile.distances[32]) vector=\(String(describing: profile.vectorModel))")
            XCTAssertEqual(profile.distances[32], step(32), accuracy: 0.5)
            XCTAssertNil(profile.vectorModel)
        } catch {
            print("REVIEW AXIS noProfile error=\(error)")
            XCTFail("Verified axial calibration must survive unsupported optional diagonal gain: \(error)")
        }
    }

    func testMatchingSavedCurveIsReusedWithoutMeasuringAllCounts() throws {
        let phone = Phone()
        phone.radial = true
        let existing = profile(phone)
        let result = try resolve(
            phone, existing: existing,
            onMismatch: { XCTFail("valid curve must not be rejected") },
            progress: { _ in XCTFail("valid curve must not be remeasured") })
        XCTAssertTrue(result.reused)
        XCTAssertEqual(result.profile, existing)
        XCTAssertEqual(phone.x, Double(phone.width) * 0.4, accuracy: 3)
        XCTAssertEqual(phone.y, Double(phone.height) * 0.5, accuracy: 3)
    }

    func testMatchingAxisCurveUpgradesOnlyAfterMeasuringDiagonalResponse() throws {
        let phone = Phone()
        let existing = profile(phone)
        phone.radial = true
        let result = try resolve(
            phone, existing: existing,
            onMismatch: { XCTFail("valid axial distances must not be rejected") },
            progress: { _ in XCTFail("valid axial distances must not be remeasured") })

        XCTAssertFalse(result.reused, "the upgraded model must be persisted")
        XCTAssertEqual(result.profile.distances, existing.distances)
        XCTAssertEqual(result.profile.host, existing.host)
        XCTAssertEqual(result.profile.screenID, existing.screenID)
        XCTAssertEqual(result.profile.vectorModel, .radialQuantized)
        XCTAssertEqual(phone.x, Double(phone.width) * 0.4, accuracy: 3)
        XCTAssertEqual(phone.y, Double(phone.height) * 0.5, accuracy: 3)
    }

    func testNewRadialCurveDoesNotDowngradeToSingleAxisTracking() throws {
        let phone = Phone()
        phone.radial = true
        let result = try measure(phone)

        XCTAssertEqual(result.vectorModel, .radialQuantized)
        XCTAssertEqual(phone.x, Double(phone.width) * 0.4, accuracy: 3)
        XCTAssertEqual(phone.y, Double(phone.height) * 0.5, accuracy: 3)
    }

    func testMatchingAxisOnlyPhoneKeepsItsVerifiedAxisModel() throws {
        let phone = Phone()
        let existing = profile(phone)
        let result = try resolve(
            phone, existing: existing,
            onMismatch: { XCTFail("valid axis-only curve must not be rejected") },
            progress: { _ in XCTFail("valid curve must not be remeasured") })

        XCTAssertTrue(result.reused)
        XCTAssertEqual(result.profile, existing)
    }

    func testUnobservableOptionalDiagonalRechecksAndKeepsVerifiedAxisCurve() throws {
        let phone = Phone()
        let existing = profile(phone)
        phone.radial = true
        var diagonal = false
        var obscured = false
        let runner = AutomaticPointerCalibration(
            host: existing.host, screenID: "phone", width: phone.width, height: phone.height,
            send: { dx, dy in
                if dx != 0 && dy != 0 { diagonal = true }
                phone.send(dx, dy)
            },
            capture: {
                if diagonal && !obscured {
                    obscured = true
                    return .init(
                        width: phone.width, height: phone.height,
                        pixels: [UInt8](repeating: 240, count: phone.width * phone.height))
                }
                return phone.frame()
            })
        let result = try runner.resolve(existing: existing)
        XCTAssertTrue(obscured)
        XCTAssertTrue(result.reused)
        XCTAssertEqual(result.profile, existing)
        XCTAssertEqual(phone.x, Double(phone.width) * 0.4, accuracy: 3)
        XCTAssertEqual(phone.y, Double(phone.height) * 0.5, accuracy: 3)
    }

    func testOptionalDiagonalDoesNotSwallowCancellationOrSessionLoss() {
        for failInCapture in [false, true] {
            let phone = Phone()
            let existing = profile(phone)
            phone.radial = true
            var diagonal = false
            var reportsAtFailure: Int?
            let runner = AutomaticPointerCalibration(
                host: existing.host, screenID: "phone", width: phone.width, height: phone.height,
                send: { dx, dy in
                    if dx != 0 && dy != 0 {
                        diagonal = true
                        if !failInCapture {
                            reportsAtFailure = phone.reports
                            throw DeviceError("cancelled diagonal report")
                        }
                    }
                    phone.send(dx, dy)
                },
                capture: {
                    if diagonal && failInCapture {
                        reportsAtFailure = phone.reports
                        throw DeviceError("lost session during diagonal capture")
                    }
                    return phone.frame()
                })
            XCTAssertThrowsError(try runner.resolve(existing: existing)) { error in
                XCTAssertTrue(String(describing: error).contains(failInCapture ? "lost session" : "cancelled"))
            }
            XCTAssertNotNil(reportsAtFailure)
            XCTAssertEqual(phone.reports, reportsAtFailure, "fallback must not send reports after cancellation")
        }
    }

    func testFailedRadialLandingsRecheckAxisModelBeforeFallback() throws {
        let phone = Phone()
        let existing = profile(phone)
        phone.radial = true
        var lastReport = (0, 0)
        var testingRadialTargets = false
        var fallbackStarted = false
        let runner = AutomaticPointerCalibration(
            host: existing.host, screenID: "phone", width: phone.width, height: phone.height,
            send: { dx, dy in
                lastReport = (dx, dy)
                if testingRadialTargets && dx == -127 { fallbackStarted = true }
                let before = CGPoint(x: phone.x, y: phone.y)
                phone.send(dx, dy)
                if testingRadialTargets && !fallbackStarted && dx != 0 && dy != 0 {
                    phone.x = before.x + (phone.x - before.x) * 1.3
                    phone.y = before.y + (phone.y - before.y) * 1.3
                }
            },
            capture: {
                let frame = phone.frame()
                if lastReport == (-12, -16) { testingRadialTargets = true }
                return frame
            })
        let result = try runner.resolve(existing: existing)
        XCTAssertTrue(testingRadialTargets)
        XCTAssertTrue(fallbackStarted)
        XCTAssertTrue(result.reused)
        XCTAssertEqual(result.profile, existing)
        XCTAssertEqual(phone.x, Double(phone.width) * 0.4, accuracy: 3)
        XCTAssertEqual(phone.y, Double(phone.height) * 0.5, accuracy: 3)
    }

    func testStaleCurveIsRemeasuredAndKeepsOnlyVerifiedDiagonalTracking() throws {
        let phone = Phone()
        phone.radial = true
        let existing = profile(phone, scale: 0.7)
        var rejected = false
        var measured: [Int] = []
        let result = try resolve(
            phone, existing: existing, onMismatch: { rejected = true },
            progress: { measured.append($0) })
        XCTAssertTrue(rejected)
        XCTAssertFalse(result.reused)
        XCTAssertEqual(measured, Array(1...32))
        XCTAssertEqual(result.profile.vectorModel, .radialQuantized)
        for count in 1...32 {
            XCTAssertEqual(result.profile.distances[count], phone.distance(count), accuracy: 0.8)
        }
        XCTAssertEqual(phone.x, Double(phone.width) * 0.4, accuracy: 3)
        XCTAssertEqual(phone.y, Double(phone.height) * 0.5, accuracy: 3)
    }

    func testChangedDiagonalResponseFallsBackToVerifiedAxisTracking() throws {
        let phone = Phone()
        phone.radial = true
        let oldRadial = profile(phone)
        phone.radial = false
        var rejected = false
        let result = try resolve(phone, existing: oldRadial, onMismatch: { rejected = true })
        XCTAssertTrue(rejected)
        XCTAssertFalse(result.reused)
        XCTAssertNil(result.profile.vectorModel)
    }

    func testUnrelatedClockAnimationDoesNotHideStaleCurveOrPreventRecovery() throws {
        let phone = Phone()
        phone.radial = true
        phone.animateClock = true
        var rejected = false
        let result = try resolve(phone, existing: profile(phone, scale: 1.4), onMismatch: { rejected = true })
        XCTAssertTrue(rejected)
        XCTAssertFalse(result.reused)
        XCTAssertEqual(result.profile.distances[32], phone.distance(32), accuracy: 0.8)
    }

    func testUnobservableScreenDoesNotRejectOrReplaceSavedCurve() {
        let phone = Phone()
        phone.animate = true
        var rejected = false
        XCTAssertThrowsError(try resolve(phone, existing: profile(phone), onMismatch: { rejected = true }))
        XCTAssertFalse(rejected)
    }

    func testDisconnectAfterMismatchDoesNotReturnAPartiallyMeasuredReplacement() {
        let phone = Phone()
        let existing = profile(phone, scale: 0.7)
        var rejected = false
        let runner = AutomaticPointerCalibration(
            host: existing.host, screenID: "phone", width: phone.width, height: phone.height,
            send: { dx, dy in
                guard !rejected else { throw DeviceError("disconnected") }
                phone.send(dx, dy)
            }, capture: phone.frame)
        XCTAssertThrowsError(try runner.resolve(existing: existing, onMismatch: { rejected = true }))
        XCTAssertTrue(rejected)
    }

    func testNonlinearPhoneAtRightEdgeMeasuresWithoutWebOrExistingProfile() throws {
        let phone = Phone()
        let result = try measure(phone)
        try result.validate()
        XCTAssertEqual(result.screenID, "phone")
        XCTAssertNil(result.vectorModel)
        for count in 1...32 {
            XCTAssertEqual(result.distances[count], phone.distance(count), accuracy: 0.8)
        }
        XCTAssertEqual(phone.x, Double(phone.width) * 0.4, accuracy: 3)
        XCTAssertEqual(phone.y, Double(phone.height) * 0.5, accuracy: 3)
    }

    func testAnimatedBackgroundAndDifferentVerticalGainCannotProduceAProfile() {
        let animated = Phone()
        animated.animate = true
        XCTAssertThrowsError(try measure(animated))
        let anisotropic = Phone()
        anisotropic.verticalScale = 1.5
        XCTAssertThrowsError(try measure(anisotropic))
    }

    func testLostSessionStopsBeforeFurtherReportsOrSaving() {
        let phone = Phone()
        let runner = AutomaticPointerCalibration(
            host: UUID(), screenID: "phone", width: phone.width, height: phone.height,
            send: { dx, dy in
                guard phone.reports < 5 else { throw DeviceError("disconnected") }
                phone.send(dx, dy)
            }, capture: phone.frame)
        XCTAssertThrowsError(try runner.measure())
        XCTAssertEqual(phone.reports, 5)
        XCTAssertEqual(phone.captures, 0)
    }

    func testOverlappingPointersAndClippedShapesAreNotDisplacementMeasurements() {
        let phone = Phone()
        phone.x = 150
        let before = phone.frame()
        phone.x += 3
        XCTAssertNil(PointerMotionObservation.motion(from: before, to: phone.frame(), direction: CGPoint(x: 1, y: 0)))
        phone.x = 160
        XCTAssertNil(PointerMotionObservation.motion(from: before, to: phone.frame(), direction: CGPoint(x: 1, y: 0)))
        phone.x = 374
        XCTAssertNil(PointerMotionObservation.motion(from: before, to: phone.frame(), direction: CGPoint(x: 1, y: 0)))
        phone.x = 220
        let motion = PointerMotionObservation.motion(from: before, to: phone.frame(), direction: CGPoint(x: 1, y: 0))
        XCTAssertEqual(motion?.delta.x, 70)
        XCTAssertEqual(motion?.delta.y, 0)
    }
}
