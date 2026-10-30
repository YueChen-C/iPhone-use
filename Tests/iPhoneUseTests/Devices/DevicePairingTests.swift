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
