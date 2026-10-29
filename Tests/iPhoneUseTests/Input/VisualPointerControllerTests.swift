import Foundation
import XCTest

@testable import iPhoneUse

final class VisualPointerControllerTests: XCTestCase {
    private final class Phone {
        let width: Int
        let height: Int
        var point = CGPoint(x: 240, y: 360)
        var time = 100.0
        var sequence: UInt64 = 0
        var reports = 0
        var captures = 0
        var historyDependent = false
        var frozen = false
        var animate = false
        var staleSequenceAt: Int?
        var staleTimestampAt: Int?
        var invalidFrameAt: Int?
        var captureDelay = 0.16
        var driftOnCapture: Int?
        var freezeOnCapture: Int?
        var limitStepOnCapture: Int?
        var maximumStep: Double?
        var animateOnCapture: Int?
        var previousCount = 0
        var lastAfter: UInt64?
        var sent: [(Int, Int)] = []
        var unrelatedCirclePath: [CGPoint] = []
        var invisibleTopStripHeight = 0.0
        var hiddenPointerFrames = 0

        init(width: Int = 640, height: Int = 960) {
            self.width = width
            self.height = height
        }

        func send(_ dx: Int, _ dy: Int) {
            reports += 1
            sent.append((dx, dy))
            guard !frozen else { return }
            // The same count has different gain depending on the preceding
            // report. No single calibration curve describes this simulated phone.
            let gain = historyDependent ? (previousCount > 50 ? 1.15 : 0.8) : 1.0
            previousCount = max(abs(dx), abs(dy))
            func step(_ count: Int) -> Double {
                let value = Double(count) * gain
                guard let maximumStep else { return value }
                return max(-maximumStep, min(maximumStep, value))
            }
            point.x = max(0, min(Double(width - 1), point.x + step(dx)))
            point.y = max(0, min(Double(height - 1), point.y + step(dy)))
        }

        func capture(_ after: UInt64?, _ notBefore: TimeInterval) -> VisualPointerFrame {
            captures += 1
            lastAfter = after
            time = max(time, notBefore) + captureDelay
            sequence += 1
            if captures == driftOnCapture { point.x += 12 }
            if captures == freezeOnCapture { frozen = true }
            if captures == limitStepOnCapture { maximumStep = 1 }
            if captures == animateOnCapture { animate = true }
            var pixels = [UInt8](repeating: 240, count: width * height)
            func drawCircle(_ center: CGPoint) {
                let cx = Int(center.x.rounded())
                let cy = Int(center.y.rounded())
                for dy in -9...9 {
                    for dx in -9...9 where dx * dx + dy * dy <= 81 {
                        let x = cx + dx
                        let y = cy + dy
                        if (0..<width).contains(x), (0..<height).contains(y) {
                            pixels[y * width + x] = 110
                        }
                    }
                }
            }
            if point.y >= invisibleTopStripHeight {
                drawCircle(point)
            } else {
                hiddenPointerFrames += 1
            }
            if !unrelatedCirclePath.isEmpty {
                drawCircle(unrelatedCirclePath[min(captures - 1, unrelatedCirclePath.count - 1)])
            }
            if animate {
                // Each adjacent pair differs by two 12x12 strips (288 pixels),
                // exceeding the observer's 256-pixel small-change allowance.
                let left = captures.isMultiple(of: 2) ? 10 : 22
                for y in 50..<62 {
                    for x in left..<(left + 40) where x < width {
                        pixels[y * width + x] = 10
                    }
                }
            }
            let frame = PointerMotionObservation.Frame(
                width: width, height: height,
                pixels: captures == invalidFrameAt ? [] : pixels)
            return VisualPointerFrame(
                frame: frame,
                sequence: captures == staleSequenceAt ? (after ?? 0) : sequence,
                receivedAt: captures == staleTimestampAt ? notBefore - 0.01 : time)
        }

        func controller() -> VisualPointerController {
            VisualPointerController(
                width: width, height: height,
                send: send, capture: capture, now: { self.time })
        }
    }

    private func assertFailure(
        _ expected: VisualPointerController.Failure,
        phone: Phone, target: CGPoint = CGPoint(x: 450, y: 700),
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try phone.controller().move(to: target), file: file, line: line) { error in
            XCTAssertEqual(error as? VisualPointerController.Failure, expected, file: file, line: line)
        }
    }

    func testMeasuredFeedbackConvergesWithHistoryDependentGain() throws {
        let phone = Phone()
        phone.historyDependent = true
        let target = CGPoint(x: 470, y: 720)
        let observed = try phone.controller().move(to: target)
        XCTAssertLessThanOrEqual(hypot(observed.x - target.x, observed.y - target.y), 5)
        XCTAssertLessThanOrEqual(hypot(phone.point.x - target.x, phone.point.y - target.y), 5)
        XCTAssertLessThanOrEqual(phone.reports, 304)
        XCTAssertLessThan(phone.time - 100, 30)
        XCTAssertEqual(phone.lastAfter, phone.sequence - 1)
        // After bootstrap, every report operates only one axis.
        let firstSingleAxis = try XCTUnwrap(phone.sent.firstIndex { $0.0 == 0 || $0.1 == 0 })
        XCTAssertTrue(phone.sent[firstSingleAxis...].allSatisfy { $0.0 == 0 || $0.1 == 0 })
    }

    func testClippedUnknownStartIsObservedAfterEnteringInterior() throws {
        let phone = Phone()
        phone.point = CGPoint(x: 0, y: 0)
        let target = CGPoint(x: 430, y: 650)
        let observed = try phone.controller().move(to: target)
        XCTAssertLessThanOrEqual(hypot(observed.x - target.x, observed.y - target.y), 5)
    }

    func testLandingReturnsGainsMeasuredDuringVerifiedMove() throws {
        let phone = Phone()
        let target = CGPoint(x: 480, y: 680)
        let landing = try phone.controller().land(to: target)
        XCTAssertLessThanOrEqual(hypot(landing.point.x - target.x, landing.point.y - target.y), 3)
        XCTAssertLessThanOrEqual(hypot(phone.point.x - target.x, phone.point.y - target.y), 5)
        XCTAssertEqual(landing.gainX, 1, accuracy: 0.001)
        XCTAssertEqual(landing.gainY, 1, accuracy: 0.001)
    }

    func testHighestProbeTierCanExitAWideUnobservableInitialStrip() throws {
        let phone = Phone(width: 1000, height: 1400)
        phone.point = CGPoint(x: 100, y: 0)
        phone.invisibleTopStripHeight = 600
        let target = CGPoint(x: 800, y: 1100)
        let observed = try phone.controller().move(to: target)
        XCTAssertGreaterThan(phone.hiddenPointerFrames, 0)
        XCTAssertLessThanOrEqual(hypot(observed.x - target.x, observed.y - target.y), 3)
        XCTAssertLessThanOrEqual(hypot(phone.point.x - target.x, phone.point.y - target.y), 5)
        // The former three-report excursions never reached a visible triple.
        var consecutive = 0
        var longest = 0
        for report in phone.sent {
            consecutive = report.0 == 127 && report.1 == 127 ? consecutive + 1 : 0
            longest = max(longest, consecutive)
        }
        XCTAssertGreaterThan(longest, 3)
        XCTAssertLessThanOrEqual(longest, 8)
        XCTAssertLessThanOrEqual(phone.reports, 304)
        XCTAssertLessThan(phone.time - 100, 30)
    }

    func testSequenceAndTimestampAreIndependentlyValidated() {
        let oldSequence = Phone()
        oldSequence.staleSequenceAt = 2
        assertFailure(.staleFrame, phone: oldSequence)
        let oldTimestamp = Phone()
        oldTimestamp.staleTimestampAt = 1
        assertFailure(.staleFrame, phone: oldTimestamp)
        XCTAssertEqual(oldTimestamp.reports, 0)
    }

    func testInvalidCaptureFailsWithoutSendingInput() {
        let phone = Phone()
        phone.invalidFrameAt = 1
        assertFailure(.invalidFrame, phone: phone)
        XCTAssertEqual(phone.reports, 0)
    }

    func testAnimationCannotEstablishAnAbsolutePosition() {
        let phone = Phone()
        phone.animate = true
        assertFailure(.probeFailed, phone: phone)
        XCTAssertEqual(phone.reports, 68)
        XCTAssertLessThan(phone.time - 100, 30)
    }

    func testNoMotionHasABoundedProbeBudget() {
        let phone = Phone()
        phone.frozen = true
        assertFailure(.probeFailed, phone: phone)
        XCTAssertEqual(phone.reports, 68)
        XCTAssertEqual(phone.captures, 69)
    }

    func testCaptureTimeoutDoesNotSendAnotherReport() {
        let phone = Phone()
        phone.captureDelay = 31
        assertFailure(.timeout, phone: phone)
        XCTAssertEqual(phone.reports, 0)
        XCTAssertEqual(phone.captures, 1)
    }

    func testBootstrapPositionRequiresLaterStableConfirmation() {
        let phone = Phone()
        // 16-count probes overlap, so the first observed triple is produced
        // by 32-count probes: (240,360), (272,392), (304,424).
        // The two reverse-axis challenges return to (272,392). This target is
        // intentionally that endpoint. The later confirmation frame drifts.
        phone.driftOnCapture = 18
        assertFailure(.noProgress, phone: phone, target: CGPoint(x: 272.5, y: 392.5))
    }

    func testObservationFailureAfterBootstrapDoesNotReturnPrediction() {
        let phone = Phone()
        phone.animateOnCapture = 18
        assertFailure(.observationFailed, phone: phone)
    }

    func testStalledCorrectionsStopAfterThreeObservedFailures() {
        let phone = Phone()
        phone.freezeOnCapture = 17
        assertFailure(.noProgress, phone: phone)
        XCTAssertEqual(phone.captures, 20)
    }

    func testCorrectionBudgetIsBoundedEvenWhileSomeProgressOccurs() {
        let phone = Phone()
        phone.limitStepOnCapture = 17
        assertFailure(.budgetExceeded, phone: phone, target: CGPoint(x: 600, y: 900))
        XCTAssertEqual(phone.captures, 33)
        XCTAssertLessThanOrEqual(phone.reports, 304)
    }

    func testOutOfBoundsTargetDoesNotCaptureOrSend() {
        let phone = Phone()
        assertFailure(.invalidTarget, phone: phone, target: CGPoint(x: -.infinity, y: 10))
        XCTAssertEqual(phone.reports, 0)
        XCTAssertEqual(phone.captures, 0)
    }

    func testFrozenPointerAndCircleThatMovesToTargetThenStopsAreRejected() {
        let phone = Phone()
        phone.frozen = true
        phone.unrelatedCirclePath = [
            CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 140),
            CGPoint(x: 180, y: 180), CGPoint(x: 180, y: 180),
        ]
        assertFailure(.causalityFailed, phone: phone, target: CGPoint(x: 180.5, y: 180.5))
        XCTAssertEqual(phone.point, CGPoint(x: 240, y: 360))
        XCTAssertEqual(phone.reports, 3)
        XCTAssertEqual(phone.captures, 4)
        XCTAssertEqual(phone.sent.last?.0, -16)
        XCTAssertEqual(phone.sent.last?.1, 0)
    }

    func testFrozenPointerAndContinuingDiagonalCircleFailAxisChallenge() {
        let phone = Phone()
        phone.frozen = true
        phone.unrelatedCirclePath = [
            CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 140),
            CGPoint(x: 180, y: 180), CGPoint(x: 220, y: 220),
        ]
        assertFailure(.causalityFailed, phone: phone, target: CGPoint(x: 220.5, y: 220.5))
        XCTAssertEqual(phone.reports, 3)
    }

    func testCircleMustAlsoRespondToTheSecondIndependentAxisChallenge() {
        let phone = Phone()
        phone.frozen = true
        phone.unrelatedCirclePath = [
            CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 140),
            CGPoint(x: 180, y: 180), CGPoint(x: 140, y: 180),
            CGPoint(x: 140, y: 180),
        ]
        assertFailure(.causalityFailed, phone: phone, target: CGPoint(x: 140.5, y: 180.5))
        XCTAssertEqual(phone.reports, 4)
        XCTAssertEqual(phone.captures, 5)
        XCTAssertEqual(phone.sent.last?.0, 0)
        XCTAssertEqual(phone.sent.last?.1, -16)
    }
}
