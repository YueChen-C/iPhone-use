import XCTest

@testable import iPhoneUse

final class CaptureIdentityVerifierTests: XCTestCase {
    func testFirstFrameSupersedesBackoffAndCoalescesChecks() throws {
        let first = DispatchTime.now()
        var schedule = CaptureIdentityCheckSchedule()
        let backoff = try XCTUnwrap(schedule.request(generation: 1, deadline: first + 30))
        let frame = try XCTUnwrap(schedule.request(generation: 1, deadline: first + 0.12))
        XCTAssertNil(schedule.request(generation: 1, deadline: first + 0.15))
        XCTAssertFalse(schedule.take(ticket: backoff))
        XCTAssertTrue(schedule.take(ticket: frame))
        XCTAssertFalse(schedule.take(ticket: frame))
        let old = try XCTUnwrap(schedule.request(generation: 1, deadline: first + 1))
        let new = try XCTUnwrap(schedule.request(generation: 2, deadline: first + 2))
        XCTAssertFalse(schedule.take(ticket: old))
        XCTAssertTrue(schedule.take(ticket: new))
    }

    func testParallelVerificationDoesNotQueueHealthyShotBehindStalledPeer() {
        let healthy = image()
        let healthyShot = DispatchSemaphore(value: 0)
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["A-stalled", "B-healthy"], sourceImages: { ["B-healthy": healthy] },
            isCurrent: { true }, maxConcurrentScreenshots: 2,
            screenshot: { id in
                if id == "A-stalled" {
                    XCTAssertEqual(healthyShot.wait(timeout: .now() + 2), .success)
                    return .failed
                }
                healthyShot.signal()
                return .image(healthy)
            })
        guard case .partiallyVerified(let mapping) = result else { return XCTFail("stalled phone stays blocked") }
        XCTAssertEqual(mapping, ["B-healthy": "B-healthy"])
    }

    func testFailedIdentityRecoveryDoesNotExpireAndBacksOff() {
        XCTAssertEqual((0..<6).map { CaptureIdentityRecovery.delay(attempt: $0) }, [3, 10, 30, 30, 30, 30])
        for state in [ScreenCaptureIdentityState.failed, .partiallyVerified, .unavailable] {
            XCTAssertTrue(
                CaptureIdentityRecovery.permitsRetry(
                    stopped: false, expected: 7, current: 7, sourceCount: 2, state: state))
        }
        for state in [ScreenCaptureIdentityState.verified, .singleDevice, .pending] {
            XCTAssertFalse(
                CaptureIdentityRecovery.permitsRetry(
                    stopped: false, expected: 7, current: 7, sourceCount: 2, state: state))
        }
        XCTAssertFalse(
            CaptureIdentityRecovery.permitsRetry(
                stopped: true, expected: 7, current: 7, sourceCount: 2, state: .failed))
        XCTAssertFalse(
            CaptureIdentityRecovery.permitsRetry(
                stopped: false, expected: 7, current: 8, sourceCount: 2, state: .failed))
        // A surviving nominal stream after a multi-phone unplug still needs
        // an independent check; failure must keep retrying without showing it.
        XCTAssertTrue(
            CaptureIdentityRecovery.permitsRetry(
                stopped: false, expected: 7, current: 7, sourceCount: 1, state: .failed))
        XCTAssertFalse(
            CaptureIdentityRecovery.permitsRetry(
                stopped: false, expected: 7, current: 7, sourceCount: 0, state: .failed))
    }

    func testTerminalDisplayStatesDoNotLookLikeAnActiveCheck() {
        for language in [AppLanguage.zh, .en] {
            let pending = ScreenCaptureIdentityState.pending.unconfirmedMessage(language: language)
            XCTAssertNotEqual(ScreenCaptureIdentityState.unavailable.unconfirmedMessage(language: language), pending)
            XCTAssertNotEqual(ScreenCaptureIdentityState.failed.unconfirmedMessage(language: language), pending)
            XCTAssertEqual(ScreenCaptureIdentityState.partiallyVerified.unconfirmedMessage(language: language),
                           ScreenCaptureIdentityState.failed.unconfirmedMessage(language: language))
        }
    }

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
        var rounds = 1
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["se", "i7"],
            sourceImages: {
                rounds == 1 ? ["i7": self.image()] : ["i7": self.image(), "se": self.image(inverted: true)]
            }, isCurrent: { true }, waitForRetry: { rounds += 1 },
            screenshot: { .image(self.image(inverted: $0 == "i7")) })
        guard case .verified(let mapping) = result else { return XCTFail("expected recovered complete mapping") }
        XCTAssertEqual(rounds, 3)
        XCTAssertEqual(mapping, ["se": "i7", "i7": "se"])
    }

    func testScreenshotsAreComparedBeforeTheNextPhoneChangesTheFrame() {
        let a = image(), b = image(inverted: true)
        var aFrame = a
        var calls: [String] = []
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["A", "B"], sourceImages: { ["A": aFrame, "B": b] }, isCurrent: { true },
            screenshot: { id in
                calls.append(id)
                if id == "A" { aFrame = a; return .image(a) }
                aFrame = .init(aspectRatio: a.aspectRatio, pixels: .init(repeating: 0, count: a.pixels.count))
                return .image(b)
            })
        guard case .verified(let mapping) = result else { return XCTFail("expected both routes") }
        XCTAssertEqual(mapping, ["A": "A", "B": "B"])
        XCTAssertEqual(calls, ["A", "B", "A", "B"])
    }

    func testBothRetainedRoutesSkipEveryScreenshotAndFrameSample() {
        let retained = ["A": "A", "B": "B"]
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["A", "B"], sourceImages: { XCTFail(); return [:] }, isCurrent: { true }, retained: retained,
            screenshot: { _ in XCTFail(); return .failed })
        guard case .verified(let mapping) = result else { return XCTFail("expected retained routes") }
        XCTAssertEqual(mapping, retained)
    }

    func testOnlyTheUnresolvedPhoneFallsBackAndRecovers() {
        let retained = ["B": "B"]
        var shots: [String] = []
        var evidence = CaptureIdentityVerifier.Evidence()
        func verify(available: Bool) -> CaptureIdentityVerifier.Result {
            CaptureIdentityVerifier.verify(
                physicalIDs: ["A", "B"], sourceImages: { ["A": self.image(), "B": self.image(inverted: true)] },
                isCurrent: { true }, retained: retained, reportEvidence: { evidence = $0 },
                screenshot: { shots.append($0); return available ? .image(self.image()) : .unavailable })
        }
        guard case .partiallyVerified(let surviving) = verify(available: false) else { return XCTFail("B should remain usable") }
        XCTAssertEqual(surviving, retained)
        XCTAssertTrue(evidence.independent.isEmpty)
        guard case .verified(let recovered) = verify(available: true) else { return XCTFail("A should recover") }
        XCTAssertEqual(recovered, ["A": "A", "B": "B"])
        XCTAssertEqual(shots, ["A", "A", "A"])
        XCTAssertEqual(evidence.independent, ["A": "A"])
    }

    func testContradictionInvalidatesOnlyTheRepeatedlyConflictingRetainedRoute() {
        let retained = ["B": "B", "C": "C"]
        var evidence = CaptureIdentityVerifier.Evidence()
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["A", "B", "C"], sourceImages: { ["A": self.image(inverted: true), "B": self.image()] },
            isCurrent: { true }, retained: retained, reportEvidence: { evidence = $0 },
            screenshot: { id in XCTAssertEqual(id, "A"); return .image(self.image()) })
        guard case .failed = result else { return XCTFail("contradicted proof cannot be reused") }
        XCTAssertEqual(evidence.contradicted, ["B"])
        XCTAssertTrue(evidence.independent.isEmpty)
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
        var evidence = CaptureIdentityVerifier.Evidence()
        let result = CaptureIdentityVerifier.verify(
            physicalIDs: ["new", "se"],
            sourceImages: { ["new": self.image(), "se": self.image(inverted: true)] },
            isCurrent: { true }, reportEvidence: { evidence = $0 },
            screenshot: { id in
                calls.append(id)
                return id == "new" ? .unavailable : .image(self.image())
            })
        guard case .verified(let mapping) = result else { return XCTFail("expected complete inferred mapping") }
        XCTAssertEqual(mapping, ["se": "new", "new": "se"])
        XCTAssertEqual(evidence.independent, ["se": "new"], "elimination must not yield a durable proof")
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
        XCTAssertEqual(rounds, 4, "each round samples the direct match and elimination fallback separately")
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
    func testInitialNativeStartIsNotInterruptedByAnEarlyFramelessCheck() {
        XCTAssertFalse(CaptureSourceRecovery.permitsInitialRecovery(startedAt: 20, now: 20.5))
        XCTAssertFalse(CaptureSourceRecovery.permitsInitialRecovery(startedAt: 20, now: 25.99))
        XCTAssertTrue(CaptureSourceRecovery.permitsInitialRecovery(startedAt: 20, now: 26))
    }

    func testUSBAttachmentCountDistinguishesEmptyAndUnreadableTopology() {
        typealias Topology = USBValeriaConfigurator.IOSUSBTopologyObservation
        XCTAssertNil(Topology.unavailable.attachedDeviceCount)
        XCTAssertEqual(Topology.observed(.init(attachedEntryIDs: [], singleDevice: nil)).attachedDeviceCount, 0)
        XCTAssertEqual(Topology.observed(.init(attachedEntryIDs: [1, 2], singleDevice: nil)).attachedDeviceCount, 2)
    }

    func testEmptySourceGetsOneNativeReopenAfterCooldownAndCannotLoop() {
        var recovery = CaptureSourceRecovery()
        let a = UUID(), b = UUID()
        XCTAssertEqual(recovery.take(empty: [], now: 0), [:])
        XCTAssertEqual(recovery.take(empty: [a], now: 0), [a: .restart])
        XCTAssertEqual(recovery.take(empty: [a], now: 9), [:])
        XCTAssertEqual(recovery.take(empty: [a], now: 10), [a: .reopenInput])
        XCTAssertEqual(recovery.take(empty: [a, b], now: 30), [b: .restart])
        XCTAssertEqual(recovery.take(empty: [a], now: 60), [:])
    }

    func testHealthyPeerAndSurvivingSourceDoNotRestartWhenAnotherPhoneReconnects() {
        var recovery = CaptureSourceRecovery()
        let a = UUID(), b = UUID()
        XCTAssertEqual(recovery.take(empty: [a, b], now: 0), [a: .restart, b: .restart])
        XCTAssertEqual(recovery.take(empty: [b], now: 10), [b: .reopenInput])
        recovery.retain(sources: [b])
        let reconnectedA = UUID()
        recovery.retain(sources: [reconnectedA, b])
        XCTAssertEqual(recovery.take(empty: [reconnectedA, b], now: 60), [reconnectedA: .restart])
    }

    func testMultiDeviceRecoveryAllowsNativeInputReopenForTheEmptySource() {
        var recovery = CaptureSourceRecovery()
        let source = UUID()
        XCTAssertEqual(recovery.take(empty: [source], now: 0), [source: .restart])
        XCTAssertEqual(
            recovery.take(empty: [source], now: CaptureSourceRecovery.reopenDelay, allowReopen: false),
            [:])
        XCTAssertEqual(
            recovery.take(empty: [source], now: CaptureSourceRecovery.reopenDelay, allowReopen: true),
            [source: .reopenInput])
    }
}
