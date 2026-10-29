import XCTest

@testable import iPhoneUse

final class CaptureIdentityVerifierTests: XCTestCase {
    private func image(inverted: Bool = false) -> CaptureIdentityImage {
        CaptureIdentityImage(
            aspectRatio: 750.0 / 1334,
            pixels: (0..<(CaptureIdentityImage.width * CaptureIdentityImage.height * 3)).map {
                ($0 / 12).isMultiple(of: 2) != inverted ? 210 : 40
            })
    }

    func testMissingVideoStreamDoesNotDiscardTheOtherIndependentlyVerifiedMapping() {
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["se", "i7"], sourceImages: { ["i7": self.image()] },
            isCurrent: { true },
            screenshot: { .image(self.image(inverted: $0 == "i7")) })
        guard case .partiallyVerified(let mapping) = result else { return XCTFail("expected surviving mapping") }
        XCTAssertEqual(mapping, ["se": "i7"])
    }

    func testRecoveredVideoRequiresTwoCompleteAgreeingRounds() {
        var rounds = 0
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["se", "i7"],
            sourceImages: {
                rounds += 1
                return rounds == 1
                    ? ["i7": self.image()]
                    : ["i7": self.image(), "se": self.image(inverted: true)]
            }, isCurrent: { true },
            screenshot: { .image(self.image(inverted: $0 == "i7")) })
        guard case .verified(let mapping) = result else { return XCTFail("expected recovered complete mapping") }
        XCTAssertEqual(rounds, 3)
        XCTAssertEqual(mapping, ["se": "i7", "i7": "se"])
    }

    func testMissingVideoCannotBeInventedByElimination() {
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["se", "i7"], sourceImages: { ["i7": self.image()] },
            isCurrent: { true },
            screenshot: { $0 == "se" ? .image(self.image()) : .unavailable })
        guard case .partiallyVerified(let mapping) = result else { return XCTFail("missing stream must stay blocked") }
        XCTAssertEqual(mapping, ["se": "i7"])
    }

    func testNewPhoneWithoutScreenshotServiceDoesNotDisableTheExistingPhone() {
        var calls: [String] = []
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["new", "se"],
            sourceImages: { ["new": self.image(), "se": self.image(inverted: true)] },
            isCurrent: { true },
            screenshot: { id in
                calls.append(id)
                return id == "new" ? .unavailable : .image(self.image())
            })
        guard case .verified(let mapping) = result else { return XCTFail("expected complete inferred mapping") }
        XCTAssertEqual(mapping, ["se": "new", "new": "se"])
        XCTAssertEqual(calls, ["new", "se", "new", "se"], "two independent rounds must agree")
    }

    func testScreenshotFailureKeepsOnlyTheIndependentlyVerifiedPhoneUsable() {
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["new", "se"],
            sourceImages: { ["new": self.image(inverted: true), "se": self.image()] },
            isCurrent: { true },
            screenshot: { id in
                id == "new" ? .failed : .image(self.image())
            })
        guard case .partiallyVerified(let mapping) = result else { return XCTFail("expected isolated failure") }
        XCTAssertEqual(mapping, ["se": "se"])
    }

    func testAmbiguousStreamsCannotBeApprovedByElimination() {
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["new", "se"], sourceImages: { ["new": self.image(), "se": self.image()] },
            isCurrent: { true },
            screenshot: { id in
                id == "new" ? .unavailable : .image(self.image())
            })
        guard case .failed = result else { return XCTFail("identical streams must remain blocked") }
    }

    func testTopologyChangeInvalidatesPreviouslyCollectedScreenshots() {
        var current = true
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["new", "se"],
            sourceImages: {
                XCTFail()
                return [:]
            },
            isCurrent: { current },
            screenshot: { _ in
                current = false
                return .image(self.image())
            })
        guard case .failed = result else { return XCTFail("stale topology must not publish a mapping") }
    }

    func testAllUnavailableScreensReportTheOptionalCapabilityAsUnavailable() {
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["new", "se"],
            sourceImages: {
                XCTFail()
                return [:]
            },
            isCurrent: { true }, screenshot: { _ in .unavailable })
        guard case .unavailable = result else { return XCTFail("capability absence is distinct from mismatch") }
    }

    func testSparseUnavailableScreenNeedsTwoAgreeingEliminationRounds() {
        var pixels = [UInt8](repeating: 245, count: CaptureIdentityImage.width * CaptureIdentityImage.height * 3)
        for i in 0..<(40 * 3) { pixels[i] = 180 }
        let settings = CaptureIdentityImage(aspectRatio: 1170.0 / 2532, pixels: pixels)
        var rounds = 0
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["new", "se"],
            sourceImages: {
                rounds += 1
                return ["se": settings, "new": self.image()]
            }, isCurrent: { true },
            screenshot: { $0 == "new" ? .unavailable : .image(self.image()) })
        guard case .verified(let mapping) = result else { return XCTFail("expected inferred Settings screen") }
        XCTAssertEqual(rounds, 2)
        XCTAssertEqual(mapping, ["se": "new", "new": "se"])
    }

    func testNewBluetoothSessionRetriesIdentityOnlyOnceAcrossSubscriptionCallbacks() {
        var schedule = CaptureIdentityRetrySchedule()
        let se = UUID()
        let seSession = UUID()
        let new = UUID()
        let newSession = UUID()
        XCTAssertFalse(schedule.update([:]))
        XCTAssertTrue(schedule.update([se: seSession]))
        for _ in 0..<5 { XCTAssertFalse(schedule.update([se: seSession])) }
        XCTAssertTrue(schedule.update([se: seSession, new: newSession]))
        for _ in 0..<5 { XCTAssertFalse(schedule.update([se: seSession, new: newSession])) }
        XCTAssertFalse(schedule.update([se: seSession]), "a removed phone must not restart SE's verification")
        XCTAssertTrue(schedule.update([se: UUID()]), "reconnecting the same host creates a new opportunity")
    }

    func testTransientScreenshotStartupFailureWaitsAndThenRequiresTwoSuccessfulRounds() {
        var waits = 0
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["new", "se"],
            sourceImages: { ["new": self.image(inverted: true), "se": self.image()] },
            isCurrent: { true }, waitForRetry: { waits += 1 },
            screenshot: { id in
                if id == "new" { return .unavailable }
                return waits == 0 ? .failed : .image(self.image())
            })
        guard case .verified(let mapping) = result else { return XCTFail("expected startup recovery") }
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(mapping, ["se": "se", "new": "new"])
    }

    func testDisconnectDuringRetryWaitDoesNotCollectAnotherScreenshot() {
        var current = true
        var screenshots = 0
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["se"], sourceImages: { [:] }, isCurrent: { current },
            waitForRetry: { current = false },
            screenshot: { _ in
                screenshots += 1
                return .failed
            })
        guard case .failed = result else { return XCTFail("stale retry must fail") }
        XCTAssertEqual(screenshots, 1)
    }
}

final class CaptureSourceRecoveryTests: XCTestCase {
    func testRecoveryOnlySelectsNewEmptySourcesAndCannotLoop() {
        var recovery = CaptureSourceRecovery()
        let a = UUID()
        let b = UUID()
        XCTAssertEqual(recovery.take(empty: []), [])
        XCTAssertEqual(recovery.take(empty: [a]), [a])
        XCTAssertEqual(recovery.take(empty: [a]), [])
        XCTAssertEqual(recovery.take(empty: [a, b]), [b])
        XCTAssertEqual(recovery.take(empty: [a, b]), [])
    }

    func testSurvivingSourceDoesNotRegainARetryWhenAnotherPhoneIsReconnected() {
        var recovery = CaptureSourceRecovery()
        let a = UUID()
        let b = UUID()
        XCTAssertEqual(recovery.take(empty: [a, b]), [a, b])
        recovery.retain(sources: [b])
        let reconnectedA = UUID()
        recovery.retain(sources: [reconnectedA, b])
        XCTAssertEqual(recovery.take(empty: [reconnectedA, b]), [reconnectedA])
    }
}
