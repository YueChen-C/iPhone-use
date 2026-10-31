import XCTest

@testable import iPhoneUse

final class DevicePairingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testPairingFileRemainsAnUnwrappedDeviceToUUIDDictionary() throws {
        let store = DevicePairingStore(file: directory.appendingPathComponent("pairings.json"))
        let host = UUID()
        store.save(["usb-phone": host])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: String]
        XCTAssertEqual(json, ["usb-phone": host.uuidString])
        XCTAssertEqual(store.load(), ["usb-phone": host])
    }

    func testPairingLoadDropsOnlyMalformedUUIDs() throws {
        let store = DevicePairingStore(file: directory.appendingPathComponent("pairings.json"))
        let host = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "valid": host.uuidString.lowercased(), "invalid": "bad-uuid",
        ])
        try data.write(to: store.file)
        XCTAssertEqual(store.load(), ["valid": host])
    }

    func testMissingOrInvalidFileDoesNotReplaceCurrentPairings() throws {
        let store = DevicePairingStore(file: directory.appendingPathComponent("pairings.json"))
        XCTAssertNil(store.load())
        try Data("not json".utf8).write(to: store.file)
        XCTAssertNil(store.load())
        try Data("{\"phone\":123}".utf8).write(to: store.file)
        XCTAssertNil(store.load())
    }

    func testFailedDiscoveryCannotRearmAnEndlessProbeTimer() throws {
        let capture = NSObject()
        let topology = DevicePairingProbeSchedule.Topology(
            screens: ["phone": ObjectIdentifier(capture)], sessions: [UUID(): UUID()])
        var schedule = DevicePairingProbeSchedule()
        XCTAssertTrue(schedule.update(topology))
        let token = try XCTUnwrap(schedule.scheduleRetry())
        XCTAssertNil(schedule.scheduleRetry())
        XCTAssertFalse(schedule.update(topology))
        XCTAssertTrue(schedule.beginRetry(token))
        XCTAssertNil(schedule.scheduleRetry())
        // A redundant subscription notification must not restart discovery.
        XCTAssertFalse(schedule.update(topology))
        XCTAssertNil(schedule.scheduleRetry())
        XCTAssertFalse(schedule.beginRetry(token))
    }

    func testReconnectInvalidatesOldProbeTimerAndAllowsOneFreshRetry() throws {
        let oldCapture = NSObject()
        let newCapture = NSObject()
        let host = UUID()
        let session = UUID()
        var schedule = DevicePairingProbeSchedule()
        schedule.update(
            .init(screens: ["phone": ObjectIdentifier(oldCapture)], sessions: [host: session]))
        let oldToken = try XCTUnwrap(schedule.scheduleRetry())
        XCTAssertTrue(
            schedule.update(.init(screens: ["phone": ObjectIdentifier(newCapture)], sessions: [host: session])))
        let usbToken = try XCTUnwrap(schedule.scheduleRetry())
        XCTAssertFalse(schedule.beginRetry(oldToken))
        XCTAssertTrue(schedule.beginRetry(usbToken))
        XCTAssertNil(schedule.scheduleRetry())
        XCTAssertTrue(
            schedule.update(.init(screens: ["phone": ObjectIdentifier(newCapture)], sessions: [host: UUID()])))
        XCTAssertNotNil(schedule.scheduleRetry())
    }

    func testUserInputCancelsPendingRetryUntilReconnectOrExplicitMatch() throws {
        let capture = NSObject()
        let topology = DevicePairingProbeSchedule.Topology(
            screens: ["phone": ObjectIdentifier(capture)], sessions: [UUID(): UUID()])
        var schedule = DevicePairingProbeSchedule()
        schedule.update(topology)
        let token = try XCTUnwrap(schedule.scheduleRetry())
        schedule.cancel()
        XCTAssertFalse(schedule.beginRetry(token))
        XCTAssertFalse(schedule.update(topology))
        XCTAssertNil(schedule.scheduleRetry())
        XCTAssertTrue(schedule.update(topology, restart: true))
        XCTAssertNotNil(schedule.scheduleRetry())
    }

    func testProbeRequiresChangesAtBothPointerPositions() {
        let before = blankThumbnail()
        var after = before
        mark(&after, x: 27, y: 68, value: 13)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 0)
        mark(&after, x: 62, y: 126, value: 13)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 1)
    }

    func testProbeSubtractsBackgroundChangesAndIgnoresSmallDifferences() {
        let before = blankThumbnail()
        var after = before
        mark(&after, x: 27, y: 68, value: 12)
        mark(&after, x: 62, y: 126, value: 12)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 0)
        mark(&after, x: 27, y: 68, value: 40)
        mark(&after, x: 62, y: 126, value: 40)
        mark(&after, x: 27, y: 126, value: 40)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 0)
    }

    func testUniformScreenChangeCannotBeMistakenForPointerMovement() {
        let before = blankThumbnail()
        let after = [UInt8](repeating: 255, count: before.count)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 0)
    }

    func testWeakBackgroundChangesOnlyRankCandidatesAndCannotVerifyIdentity() {
        let before = blankThumbnail()
        var after = before
        for (x, y) in [(27, 68), (62, 126)] {
            for i in 0..<23 { mark(&after, x: x - 3 + i % 7, y: y - 2 + i / 7, value: 40) }
        }
        let score = PointerScreenMatcher.score(before: before, after: after)
        XCTAssertEqual(score, 23, "the old direct-hit shortcut accepted this background change")
        XCTAssertEqual(PointerScreenMatcher.candidateOrder(scores: [0, score]), [1, 0])
        XCTAssertFalse(PointerScreenMatcher.matchesAbsoluteRoundTrip([before, after, before, before]))
        let animated = (0..<5).map { [UInt8](repeating: UInt8($0 * 40), count: 180 * 320) }
        XCTAssertEqual(DevicePairingRecovery.probeResult(for: animated), .unavailable)
    }

    func testAbsoluteAbilityRequiresCompactCursorMovementAndACompleteReturn() {
        for inverted in [false, true] {
            let a = absolutePointerFrame(27, 68, inverted: inverted)
            let b = absolutePointerFrame(63, 127, inverted: inverted)
            let c = absolutePointerFrame(45, 97, inverted: inverted)
            XCTAssertTrue(PointerScreenMatcher.matchesAbsoluteRoundTrip([a, b, c, a]))
            XCTAssertFalse(PointerScreenMatcher.matchesAbsoluteRoundTrip([a, b, c, b]))
            XCTAssertFalse(
                PointerScreenMatcher.matchesAbsoluteRoundTrip([a, c, b, a]))
            var noisyB = b
            noisyB[0] = inverted ? 240 : 0
            XCTAssertTrue(PointerScreenMatcher.matchesAbsoluteRoundTrip([a, noisyB, c, a]))
            for i in 0..<3 { noisyB[68 * PointerScreenMatcher.width + 27 + i] = inverted ? 230 : 100 }
            XCTAssertFalse(PointerScreenMatcher.matchesAbsoluteRoundTrip([a, noisyB, c, a]))
        }
        XCTAssertFalse(PointerScreenMatcher.matchesAbsoluteRoundTrip([]))
        XCTAssertFalse(PointerScreenMatcher.matchesAbsoluteRoundTrip([[0], [1], [0]]))
    }

    func testOnlyOneCompleteAbsoluteProofCanSkipRelativeDiscovery() {
        XCTAssertEqual(
            DevicePairingRecovery.absoluteProbeResults(verified: [false, true, false]),
            [.unavailable, .hit, .unavailable])
        XCTAssertNil(DevicePairingRecovery.absoluteProbeResults(verified: []))
        XCTAssertNil(DevicePairingRecovery.absoluteProbeResults(verified: [false, false]))
        XCTAssertNil(DevicePairingRecovery.absoluteProbeResults(verified: [true, true]))
    }

    func testAbsoluteProofAllowsAdaptivePointerColorAndClockAnimation() {
        let width = PointerScreenMatcher.width
        let height = PointerScreenMatcher.height
        var background = (0..<(width * height)).map { UInt8($0 / width < 95 ? 235 : 30) }
        func frame(_ x: Int, _ y: Int, pointer: UInt8, clock: UInt8) -> [UInt8] {
            var result = background
            for dy in -2...2 {
                for dx in -2...2 where dx * dx + dy * dy <= 4 {
                    result[(y + dy) * width + x + dx] = pointer
                }
            }
            // A live clock outside the requested landing regions must not
            // determine whether this phone supports absolute HID coordinates.
            for i in 0..<12 { result[140 * width + 70 + i % 3 + (i / 3) * width] = clock }
            return result
        }
        let a = frame(27, 68, pointer: 100, clock: 0)
        let b = frame(63, 127, pointer: 150, clock: 255)
        let c = frame(45, 97, pointer: 150, clock: 100)
        let returned = frame(27, 68, pointer: 100, clock: 200)
        XCTAssertTrue(PointerScreenMatcher.matchesAbsoluteRoundTrip([a, b, c, returned]))
        // Alternating content at two old targets cannot prove a third landing.
        XCTAssertFalse(PointerScreenMatcher.matchesAbsoluteRoundTrip([a, b, a, returned]))
        background[97 * width + 45] = 200
        XCTAssertFalse(PointerScreenMatcher.matchesAbsoluteRoundTrip([a, b, background, returned]))
    }

    func testRecoveryRequiresTheFullRectangleAndTreatsAStableTailAsMiss() {
        let points = [(30, 80), (50, 80), (50, 100), (30, 100), (30, 80)]
        let frames = points.map { relativePointerFrame($0.0, $0.1) }
        XCTAssertEqual(DevicePairingRecovery.probeResult(for: frames), .hit)
        let unchanged = frames[0]
        XCTAssertEqual(DevicePairingRecovery.probeResult(for: Array(repeating: unchanged, count: 5)), .miss)
        XCTAssertEqual(
            DevicePairingRecovery.probeResult(for: [frames[1], frames[2], unchanged, unchanged, unchanged]), .miss)
        var wrongPath = frames
        wrongPath[4] = frames[1]
        XCTAssertEqual(DevicePairingRecovery.probeResult(for: wrongPath), .unavailable)
        XCTAssertEqual(DevicePairingRecovery.probeResult(for: [[0], [1], [0], [1], [0]]), .unavailable)
    }

    func testIdentityVerificationNeverRequiresReplacingAnExistingCurve() {
        XCTAssertFalse(DevicePairingRecovery.shouldRequireCalibration(hasProfile: true, absoluteVerified: false))
        XCTAssertFalse(DevicePairingRecovery.shouldRequireCalibration(hasProfile: true, absoluteVerified: true))
        XCTAssertFalse(DevicePairingRecovery.shouldRequireCalibration(hasProfile: false, absoluteVerified: true))
        XCTAssertTrue(DevicePairingRecovery.shouldRequireCalibration(hasProfile: false, absoluteVerified: false))
    }

    func testBlockedRecoveryStillDiscoversANewUSBPhone() {
        let oldHost = UUID()
        XCTAssertEqual(
            DevicePairingRecovery.matchingScreenIDs(
                screenIDs: ["new-phone"], pairings: ["absent-phone": oldHost],
                connectedHosts: [oldHost, UUID()], recoveryBlocked: true),
            ["new-phone"])
    }

    func testNewPhoneCannotBypassBlockedRecoveryForAnotherSavedScreen() {
        XCTAssertEqual(
            DevicePairingRecovery.matchingScreenIDs(
                screenIDs: ["saved-phone", "new-phone"], pairings: ["saved-phone": UUID()],
                connectedHosts: [UUID()], recoveryBlocked: true),
            ["new-phone"])
        XCTAssertTrue(
            DevicePairingRecovery.matchingScreenIDs(
                screenIDs: ["saved-phone"], pairings: ["saved-phone": UUID()],
                connectedHosts: [UUID()], recoveryBlocked: true
            ).isEmpty)
    }

    func testOrdinaryReconnectMayProbeSavedScreensWhoseHostIsAbsent() {
        let liveHost = UUID()
        XCTAssertEqual(
            DevicePairingRecovery.matchingScreenIDs(
                screenIDs: ["repaired-phone", "connected-phone", "new-phone"],
                pairings: ["repaired-phone": UUID(), "connected-phone": liveHost],
                connectedHosts: [liveHost], recoveryBlocked: false),
            ["repaired-phone", "new-phone"])
    }

    func testRecoveryCandidateRequiresVerifiedScreenMismatch() {
        let oldHost = UUID()
        let newHost = UUID()
        let pairings = ["new-usb-id": oldHost]
        let common: (Set<String>) -> DevicePairingRecovery.Candidate? = { mismatches in
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"], pairings: pairings,
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: mismatches)
        }

        XCTAssertNil(common([]), "a new host alone must not trigger a rematch")
        XCTAssertNotNil(common(["new-usb-id"]))
    }

    func testRecoveryRejectsAHostSavedForMoreThanOneScreen() {
        let oldHost = UUID()
        let newHost = UUID()
        XCTAssertNil(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"],
                pairings: ["new-usb-id": oldHost, "other-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: ["new-usb-id"]))
    }

    func testRecoveryKeepsPairingWhenProbeIsAmbiguousOrOldHostHits() throws {
        let oldHost = UUID()
        let newHost = UUID()
        let candidate = try XCTUnwrap(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"], pairings: ["new-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: ["new-usb-id"]))

        XCTAssertNil(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .hit, newHost: .hit]))
        XCTAssertNil(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .miss, newHost: .unavailable]))
    }

    func testRecoveryReplacesOnlyWhenOldMissesAndOneNewHostHits() throws {
        let oldHost = UUID()
        let newHost = UUID()
        let candidate = try XCTUnwrap(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"], pairings: ["new-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: ["new-usb-id"]))

        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .miss, newHost: .hit]),
            ["new-usb-id": newHost])
    }

    func testRecoveryFindsNewUSBIdentityFromVerifiedAbsentScreenMapping() throws {
        let oldHost = UUID()
        let newHost = UUID()
        let candidate = try XCTUnwrap(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"], pairings: ["old-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: [], verifiedAbsentScreenPairingIDs: ["old-usb-id"]))

        XCTAssertEqual(candidate.screenID, "new-usb-id")
        XCTAssertEqual(candidate.mappedScreenID, "old-usb-id")
        XCTAssertEqual(candidate.mappedHost, oldHost)
        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .miss, newHost: .hit]),
            ["new-usb-id": newHost])
        // A noisy miss from the old host must not strand the screen: the
        // candidate's direct hit is the stronger piece of evidence.
        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .unavailable, newHost: .hit]),
            ["new-usb-id": newHost])
        XCTAssertNil(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .miss, newHost: .unavailable]))
    }

    func testRecoveryRejectsAmbiguousAbsentScreenMappings() {
        let firstOldHost = UUID()
        let secondOldHost = UUID()
        let newHost = UUID()
        XCTAssertNil(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"],
                pairings: ["old-usb-a": firstOldHost, "old-usb-b": secondOldHost],
                connectedHosts: [firstOldHost, secondOldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: [],
                verifiedAbsentScreenPairingIDs: ["old-usb-a", "old-usb-b"]))
    }

    func testRecoveryDoesNotBlockAValidCurrentMappingBecauseOfHistoricalPairings() {
        let currentHost = UUID()
        let oldHost = UUID()
        let pairings = ["new-usb-id": currentHost, "old-usb-id": oldHost]

        XCTAssertFalse(
            DevicePairingRecovery.shouldAttemptRecovery(
                screenID: "new-usb-id", pairings: pairings,
                mismatchedCalibrationScreenIDs: [], verifiedAbsentScreenPairingIDs: ["old-usb-id"]))
        XCTAssertTrue(
            DevicePairingRecovery.shouldAttemptRecovery(
                screenID: "new-usb-id", pairings: pairings,
                mismatchedCalibrationScreenIDs: ["new-usb-id"], verifiedAbsentScreenPairingIDs: []))
        XCTAssertTrue(
            DevicePairingRecovery.shouldAttemptRecovery(
                screenID: "new-usb-id", pairings: [:],
                mismatchedCalibrationScreenIDs: [], verifiedAbsentScreenPairingIDs: ["old-usb-id"]))
    }

    func testRecoveryCanValidateACurrentMappingWithoutAStoredScreenIdentity() throws {
        let oldHost = UUID()
        let newHost = UUID()
        let candidate = try XCTUnwrap(
            DevicePairingRecovery.currentMappingCandidate(
                screenIDs: ["new-usb-id"], pairings: ["new-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost]))

        XCTAssertEqual(candidate.mappedHost, oldHost)
        XCTAssertEqual(candidate.unmatchedHosts, [newHost])
        XCTAssertEqual(
            DevicePairingRecovery.uniqueCandidateHit(
                for: candidate, probeResults: [newHost: .hit]),
            newHost)
        XCTAssertNil(
            DevicePairingRecovery.uniqueCandidateHit(
                for: candidate, probeResults: [newHost: .unavailable]))
        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [newHost: .hit, oldHost: .miss]),
            ["new-usb-id": newHost])
    }

    func testRecoveryDoesNotUseAHostWithAnotherSavedMappingAsCandidate() {
        let currentHost = UUID()
        let savedHost = UUID()
        XCTAssertNil(
            DevicePairingRecovery.currentMappingCandidate(
                screenIDs: ["new-usb-id"],
                pairings: ["new-usb-id": currentHost, "other-usb-id": savedHost],
                connectedHosts: [currentHost, savedHost], unmatchedHosts: [savedHost]))
    }

    func testSingleHostShortcutKeepsAScreenSavedToADisconnectedHost() {
        let owner = UUID()
        let otherHost = UUID()
        // A brand-new screen, or a reconfirmation of the same host, may skip probing.
        XCTAssertTrue(
            DevicePairingRecovery.singleHostShortcutAllowed(
                screenID: "usb-a", pairings: [:], host: otherHost))
        XCTAssertTrue(
            DevicePairingRecovery.singleHostShortcutAllowed(
                screenID: "usb-a", pairings: ["usb-a": otherHost], host: otherHost))
        // The screen belongs to a (currently disconnected) owner: a device swap
        // that leaves only one other host connected must not steal it blindly.
        XCTAssertFalse(
            DevicePairingRecovery.singleHostShortcutAllowed(
                screenID: "usb-a", pairings: ["usb-a": owner], host: otherHost))
    }

    func testVerifiedOwnerClaimRepairsACrossedPairing() {
        let screen = "usb-a"
        let trueOwner = UUID()
        let wrongHost = UUID()
        let unverified = UUID()
        let isVerifiedOwner: (UUID, String) -> Bool = { host, id in host == trueOwner && id == screen }

        // The crossed state: the screen is paired to the wrong connected host
        // while its verified owner is connected but unmatched.
        let candidate = DevicePairingRecovery.verifiedOwnerClaim(
            screenIDs: [screen], pairings: [screen: wrongHost],
            connectedHosts: [wrongHost, trueOwner], isVerifiedOwner: isVerifiedOwner)
        XCTAssertEqual(candidate?.mappedHost, wrongHost)
        XCTAssertEqual(candidate?.unmatchedHosts, [trueOwner])
        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate!, probeResults: [trueOwner: .hit, wrongHost: .miss]),
            [screen: trueOwner])

        // No claim without verified ownership, with a disconnected owner, or
        // while the claimant is already paired to another screen.
        XCTAssertNil(
            DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: [screen], pairings: [screen: wrongHost],
                connectedHosts: [wrongHost, unverified], isVerifiedOwner: isVerifiedOwner))
        XCTAssertNil(
            DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: [screen], pairings: [screen: wrongHost],
                connectedHosts: [wrongHost], isVerifiedOwner: isVerifiedOwner))
        XCTAssertNil(
            DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: [screen], pairings: [screen: wrongHost, "usb-b": trueOwner],
                connectedHosts: [wrongHost, trueOwner], isVerifiedOwner: isVerifiedOwner))
        // Two simultaneous claims stay ambiguous and are left to explicit repair.
        XCTAssertNil(
            DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: [screen, "usb-b"], pairings: [screen: wrongHost],
                connectedHosts: [wrongHost, trueOwner], isVerifiedOwner: isVerifiedOwner))
    }

    func testAutomaticProbeReadinessAndTopologyTracksPointerReportsAndReconnectingHosts() {
        XCTAssertFalse(
            DevicePairingProbeSchedule.isReadyForAutomaticProbe(
                hasCapturedFrame: false, hasReadyPointerHost: true))
        XCTAssertFalse(
            DevicePairingProbeSchedule.isReadyForAutomaticProbe(
                hasCapturedFrame: true, hasReadyPointerHost: false))
        XCTAssertTrue(
            DevicePairingProbeSchedule.isReadyForAutomaticProbe(
                hasCapturedFrame: true, hasReadyPointerHost: true))

        let capture = NSObject()
        let host = UUID()
        let session = UUID()
        let savedHost = UUID()
        var schedule = DevicePairingProbeSchedule()

        // Keyboard-only session followed by pointer report subscription updates topology.
        let keyboardOnly = DevicePairingProbeSchedule.Topology(
            screens: ["phone": ObjectIdentifier(capture)],
            sessions: [host: session],
            pointerReports: [host: []],
            reconnectingHosts: [savedHost])
        XCTAssertTrue(schedule.update(keyboardOnly))
        XCTAssertFalse(schedule.update(keyboardOnly))

        let pointerReady = DevicePairingProbeSchedule.Topology(
            screens: ["phone": ObjectIdentifier(capture)],
            sessions: [host: session],
            pointerReports: [host: [.absolutePointer, .relativeMouse]],
            reconnectingHosts: [savedHost])
        XCTAssertTrue(schedule.update(pointerReady))

        // Clearing an in-flight reconnection after timeout also grants a fresh probe attempt.
        let reconnectFinished = DevicePairingProbeSchedule.Topology(
            screens: ["phone": ObjectIdentifier(capture)],
            sessions: [host: session],
            pointerReports: [host: [.absolutePointer, .relativeMouse]],
            reconnectingHosts: [])
        XCTAssertTrue(schedule.update(reconnectFinished))
    }

    func testProbeResultToleratesSubThresholdNoiseButKeepsSmallCursorMotionUnavailable() {
        let width = RelativePointerScreenMatcher.width
        let base = [UInt8](repeating: 120, count: width * RelativePointerScreenMatcher.height)

        // Sub-threshold compression noise (<= 12) across the screen stays a clean miss.
        var jittered = base
        for i in stride(from: 0, to: jittered.count, by: 7) {
            jittered[i] = 132
        }
        XCTAssertEqual(
            DevicePairingRecovery.probeResult(for: [base, base, base, jittered, base]),
            .miss)

        // A small 2x2 high-contrast block shifting 1px horizontally per frame (e.g. clipped
        // or low-gain cursor motion) must stay `.unavailable`, never a confirmed `.miss`.
        func smallBlockFrame(x: Int, y: Int, value: UInt8 = 220) -> [UInt8] {
            var frame = base
            for dy in 0..<2 {
                for dx in 0..<2 {
                    frame[(y + dy) * width + (x + dx)] = value
                }
            }
            return frame
        }
        let clippedMotion = (0..<5).map { step in smallBlockFrame(x: 40 + step, y: 60) }
        XCTAssertEqual(
            DevicePairingRecovery.probeResult(for: clippedMotion),
            .unavailable)

        // A fading cursor in the tail (> 12 intensity delta) also remains `.unavailable`.
        let fadingTail = [
            base, base,
            smallBlockFrame(x: 2, y: 60, value: 210),
            smallBlockFrame(x: 2, y: 60, value: 160),
            base,
        ]
        XCTAssertEqual(
            DevicePairingRecovery.probeResult(for: fadingTail),
            .unavailable)
    }

    func testCurrentSessionVerifiedAbsoluteMappingSkipsUnidentifiedRecoveryAndWaitsForReconnectingSavedHost() {
        XCTAssertFalse(
            DevicePairingRecovery.shouldVerifyUnidentifiedCurrentMapping(
                isCurrentSessionVerified: true, boundScreenID: nil))
        XCTAssertTrue(
            DevicePairingRecovery.shouldVerifyUnidentifiedCurrentMapping(
                isCurrentSessionVerified: false, boundScreenID: nil))
        XCTAssertFalse(
            DevicePairingRecovery.shouldVerifyUnidentifiedCurrentMapping(
                isCurrentSessionVerified: false, boundScreenID: "usb-a"))

        let savedHost = UUID()
        let watchHost = UUID()
        XCTAssertTrue(
            DevicePairingRecovery.matchingScreenIDs(
                screenIDs: ["usb-a"], pairings: ["usb-a": savedHost],
                connectedHosts: [watchHost], reconnectingHosts: [savedHost],
                recoveryBlocked: false
            ).isEmpty)
        XCTAssertEqual(
            DevicePairingRecovery.matchingScreenIDs(
                screenIDs: ["usb-a"], pairings: ["usb-a": savedHost],
                connectedHosts: [watchHost], reconnectingHosts: [],
                recoveryBlocked: false),
            ["usb-a"])
    }

    func testHomeScreenGutterAndFallbackProbeTargetsAvoidSpringBoardIconBoxesAndDetectPartialMagnetism() {
        let defaultTargets = [
            PointerScreenMatcher.firstPoint,
            PointerScreenMatcher.secondPoint,
            PointerScreenMatcher.thirdPoint,
        ]
        XCTAssertTrue(PointerScreenMatcher.targetsAreValidProbeSet(defaultTargets))
        XCTAssertTrue(PointerScreenMatcher.targetsAreValidProbeSet(PointerScreenMatcher.gutterProbeTargets))
        XCTAssertTrue(PointerScreenMatcher.targetsAreValidProbeSet(PointerScreenMatcher.fallbackProbeTargets))
        XCTAssertFalse(PointerScreenMatcher.targetsAreValidProbeSet([]))
        XCTAssertFalse(
            PointerScreenMatcher.targetsAreValidProbeSet([
                (x: 0.30, y: 0.35), (x: 0.32, y: 0.36), (x: 0.70, y: 0.65),
            ]))
        XCTAssertFalse(
            PointerScreenMatcher.targetsAreValidProbeSet([
                (x: 0.45, y: 0.25), (x: 0.50, y: 0.50), (x: 0.55, y: 0.75),
            ]))

        // Standard 4-column iOS SpringBoard Home Screen icon bounds on the 90x195 thumbnail grid,
        // plus the bottom Dock region (y >= 172). Both gutter triangles must stay in free gutters.
        let iconColumns = [8...20, 28...40, 50...62, 70...82]
        let iconRows = [62...74, 85...97, 108...120, 131...143, 154...166]
        for targets in [PointerScreenMatcher.gutterProbeTargets, PointerScreenMatcher.fallbackProbeTargets] {
            for target in targets {
                let px = Int((target.x * Double(PointerScreenMatcher.width)).rounded())
                let py = Int((target.y * Double(PointerScreenMatcher.height)).rounded())
                let hitsIcon = iconColumns.contains { $0.contains(px) } && iconRows.contains { $0.contains(py) }
                XCTAssertFalse(hitsIcon, "probe target (\(px), \(py)) landed inside a Home Screen icon box")
                XCTAssertLessThan(py, 172, "probe target (\(px), \(py)) entered the Home Screen Dock")
            }
            for inverted in [false, true] {
                let frames = [targets[0], targets[1], targets[2], targets[0]].map { point in
                    absolutePointerFrame(
                        Int((point.x * Double(PointerScreenMatcher.width)).rounded()),
                        Int((point.y * Double(PointerScreenMatcher.height)).rounded()),
                        inverted: inverted)
                }
                XCTAssertTrue(PointerScreenMatcher.matchesAbsoluteRoundTrip(frames, targets: targets))
            }
        }

        // Simulate UIPointerInteraction magnetism at target 0 (a 13x13=169px morphed control highlight
        // shifted toward an adjacent control center) while targets 1 & 2 land as compact cursors:
        // strict `matchesAbsoluteRoundTrip` still rejects the morphed landing (thresholds unweakened),
        // while `hasReversibleTargetActivity` detects the localized reversible activity so the single
        // fallback trajectory runs. Silent Watch frames and non-reversing background shifts stay false.
        let targets = PointerScreenMatcher.gutterProbeTargets
        let width = PointerScreenMatcher.width
        let base = [UInt8](repeating: 240, count: width * PointerScreenMatcher.height)
        var morphedFirst = base
        let x0 = Int(targets[0].x * Double(width))
        let y0 = Int(targets[0].y * Double(PointerScreenMatcher.height))
        for dy in -6...6 {
            for dx in -4...8 {
                let px = min(max(0, x0 + dx), width - 1)
                let py = min(max(0, y0 + dy), PointerScreenMatcher.height - 1)
                morphedFirst[py * width + px] = 110
            }
        }
        let second = absolutePointerFrame(
            Int((targets[1].x * Double(width)).rounded()),
            Int((targets[1].y * Double(PointerScreenMatcher.height)).rounded()))
        let third = absolutePointerFrame(
            Int((targets[2].x * Double(width)).rounded()),
            Int((targets[2].y * Double(PointerScreenMatcher.height)).rounded()))
        let magneticFrames = [morphedFirst, second, third, morphedFirst]
        XCTAssertFalse(PointerScreenMatcher.matchesAbsoluteRoundTrip(magneticFrames, targets: targets))
        XCTAssertTrue(PointerScreenMatcher.hasReversibleTargetActivity(magneticFrames, targets: targets))

        XCTAssertFalse(
            PointerScreenMatcher.hasReversibleTargetActivity(
                [base, base, base, base], targets: targets))
        XCTAssertFalse(
            PointerScreenMatcher.hasReversibleTargetActivity(
                [base, morphedFirst, morphedFirst, morphedFirst], targets: targets))
        XCTAssertFalse(
            PointerScreenMatcher.hasReversibleTargetActivity(
                [base, base, morphedFirst, morphedFirst], targets: targets))
        XCTAssertFalse(
            PointerScreenMatcher.hasReversibleTargetActivity(
                [base, base, base, morphedFirst], targets: targets))
    }

    private func absolutePointerFrame(_ x: Int, _ y: Int, inverted: Bool = false) -> [UInt8] {
        pointerFrame(x, y, width: PointerScreenMatcher.width, height: PointerScreenMatcher.height, inverted: inverted)
    }

    private func relativePointerFrame(_ x: Int, _ y: Int) -> [UInt8] {
        pointerFrame(x, y, width: 180, height: 320, inverted: false)
    }

    private func pointerFrame(_ x: Int, _ y: Int, width: Int, height: Int, inverted: Bool) -> [UInt8] {
        var pixels = [UInt8](repeating: inverted ? 20 : 240, count: width * height)
        for dy in -3...3 {
            for dx in -3...3 where dx * dx + dy * dy <= 9 {
                pixels[(y + dy) * width + x + dx] = inverted ? 230 : 100
            }
        }
        return pixels
    }

    private func blankThumbnail() -> [UInt8] {
        [UInt8](repeating: 0, count: PointerScreenMatcher.width * PointerScreenMatcher.height)
    }

    private func mark(_ pixels: inout [UInt8], x: Int, y: Int, value: UInt8) {
        pixels[y * PointerScreenMatcher.width + x] = value
    }
}
