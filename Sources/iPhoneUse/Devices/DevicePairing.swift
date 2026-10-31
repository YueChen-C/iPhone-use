import Foundation

/// A connection owned by another saved phone says nothing about this phone's
/// transport. Unknown hosts can still be candidates after a fresh pairing.
enum DeviceBluetoothState: String {
    case connected, unmatched, disconnected

    static func resolve(
        screenID: String, matchedHost: UUID?, pairings: [String: UUID], connectedHosts: Set<UUID>
    ) -> Self {
        if let matchedHost, connectedHosts.contains(matchedHost) { return .connected }
        if let savedHost = pairings[screenID], connectedHosts.contains(savedHost) { return .unmatched }
        let knownHosts = Set(pairings.values)
        return connectedHosts.subtracting(knownHosts).isEmpty ? .disconnected : .unmatched
    }
}

/// The existing USB-device-ID to Bluetooth-host JSON format. Synchronization and
/// calibration migration belong to DeviceRegistry; this type only reads/writes the file.
struct DevicePairingStore {
    let file: URL

    init(file: URL? = nil) {
        if let file {
            self.file = file
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("iPhoneUse", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.file = directory.appendingPathComponent("pairings.json")
        }
    }

    /// Nil leaves the caller's current state intact; invalid UUID entries are
    /// discarded individually, as in the original persisted pairing format.
    func load() -> [String: UUID]? {
        guard let data = try? Data(contentsOf: file),
            let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return saved.compactMapValues(UUID.init(uuidString:))
    }

    func save(_ pairings: [String: UUID]) {
        let encoded = pairings.mapValues(\.uuidString)
        if let data = try? JSONSerialization.data(withJSONObject: encoded, options: [.prettyPrinted]) {
            try? data.write(to: file)
        }
    }
}

/// Pointer discovery is intrusive: a failed observation must not turn into an
/// endless timer that keeps moving a phone the user is trying to use.
struct DevicePairingProbeSchedule {
    struct Topology: Equatable {
        let screens: [String: ObjectIdentifier]
        let sessions: [UUID: UUID]
        var pointerReports: [UUID: Set<ReportID>] = [:]
        var reconnectingHosts: Set<UUID> = []
    }

    private var topology: Topology?
    private var generation: UInt64 = 0
    private var retriesRemaining = 0
    private var pending = false

    /// Each USB capture / Bluetooth session topology gets its initial attempt
    /// and one delayed retry. Explicit matching can start a fresh attempt.
    @discardableResult
    mutating func update(_ topology: Topology, restart: Bool = false) -> Bool {
        guard restart || self.topology != topology else { return false }
        self.topology = topology
        generation &+= 1
        retriesRemaining = 1
        pending = false
        return true
    }

    mutating func scheduleRetry() -> UInt64? {
        guard !pending, retriesRemaining > 0 else { return nil }
        retriesRemaining -= 1
        pending = true
        return generation
    }

    mutating func beginRetry(_ token: UInt64) -> Bool {
        guard pending, token == generation else { return false }
        pending = false
        return true
    }

    /// Automatic background discovery waits for at least one captured USB frame
    /// and one pointer report subscription so transient startup states do not
    /// burn the topology's single delayed retry budget.
    static func isReadyForAutomaticProbe(hasCapturedFrame: Bool, hasReadyPointerHost: Bool) -> Bool {
        hasCapturedFrame && hasReadyPointerHost
    }

    /// User input wins over both the active probe and a queued retry.
    mutating func cancel() {
        generation &+= 1
        retriesRemaining = 0
        pending = false
    }
}

/// Two-frame differences rank candidates only. Identity requires the separate
/// reversible trajectory proof; background animation can score at both targets.
enum PointerScreenMatcher {
    typealias ProbeTarget = (x: Double, y: Double)

    static let width = 90
    static let height = 195
    static let firstPoint: ProbeTarget = (x: 0.3, y: 0.35)
    static let secondPoint: ProbeTarget = (x: 0.7, y: 0.65)
    static let thirdPoint: ProbeTarget = (x: 0.5, y: 0.5)

    /// Primary 3-point trajectory aligned with the inter-column and inter-row
    /// gutters of the 4-column iOS Home Screen grid so SpringBoard `SBIconView`
    /// pointer magnetism does not morph the free cursor into a full-icon highlight.
    static let gutterProbeTargets: [ProbeTarget] = [
        (x: 24.0 / 90.0, y: 103.0 / 195.0),
        (x: 66.0 / 90.0, y: 126.0 / 195.0),
        (x: 45.0 / 90.0, y: 81.0 / 195.0),
    ]

    /// Disjoint backup trajectory used at most once when the primary probe
    /// observed localized reversible UI activity (for example, a UIKit control
    /// with `UIPointerInteraction` morphing at one of the primary targets)
    /// without completing all three compact cursor landings.
    static let fallbackProbeTargets: [ProbeTarget] = [
        (x: 24.0 / 90.0, y: 159.0 / 195.0),
        (x: 66.0 / 90.0, y: 103.0 / 195.0),
        (x: 45.0 / 90.0, y: 126.0 / 195.0),
    ]

    struct ChangeMetrics: Equatable {
        let signal: Int
        let noise: Int
    }

    /// Buffers come from ScreenCaptureSession.thumbnail and contain width * height gray pixels.
    static func score(
        before: [UInt8],
        after: [UInt8],
        first: ProbeTarget = firstPoint,
        second: ProbeTarget = secondPoint
    ) -> Int {
        let metrics = changeMetrics(before: before, after: after, first: first, second: second)
        return metrics.signal - metrics.noise
    }

    /// Separates changes around the two pointer targets from changes in the
    /// crossed control regions. A zero score alone is not enough to prove a
    /// miss: background activity can cancel a real signal.
    static func changeMetrics(
        before: [UInt8],
        after: [UInt8],
        first: ProbeTarget = firstPoint,
        second: ProbeTarget = secondPoint
    ) -> ChangeMetrics {
        let a = first
        let b = second
        let signal = min(changed(before, after, around: a), changed(before, after, around: b))
        let noise = max(changed(before, after, around: (a.x, b.y)), changed(before, after, around: (b.x, a.y)))
        return ChangeMetrics(signal: signal, noise: noise)
    }

    static func candidateOrder(scores: [Int]) -> [Int] {
        scores.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
    }

    static func targetsAreValidProbeSet(_ targets: [ProbeTarget]) -> Bool {
        guard targets.count == 3,
            targets.allSatisfy({
                $0.x.isFinite && $0.y.isFinite
                    && (0.05...0.95).contains($0.x)
                    && (0.05...0.95).contains($0.y)
            })
        else { return false }
        let pixels = targets.map { (x: $0.x * Double(width), y: $0.y * Double(height)) }
        for i in 0..<pixels.count {
            for j in (i + 1)..<pixels.count {
                if hypot(pixels[i].x - pixels[j].x, pixels[i].y - pixels[j].y) < 20 {
                    return false
                }
            }
        }
        let xs = pixels.map(\.x)
        let ys = pixels.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
            let minY = ys.min(), let maxY = ys.max()
        else { return false }
        return (maxX - minX) >= 30 && (maxY - minY) >= 35
    }

    /// Confirms three requested landings and the return independently of identity
    /// discovery. iOS changes pointer color with its background: arrival and
    /// departure can have the same polarity at different targets. Require local
    /// reversal at each target instead of opposite polarities across the screen.
    static func matchesAbsoluteRoundTrip(
        _ frames: [[UInt8]],
        targets: [ProbeTarget] = [firstPoint, secondPoint, thirdPoint]
    ) -> Bool {
        guard frames.count == 4,
            frames.allSatisfy({ $0.count == width * height }),
            targetsAreValidProbeSet(targets)
        else { return false }
        for (corner, point) in targets.enumerated() {
            let x = Int(point.x * Double(width))
            let y = Int(point.y * Double(height))
            // At this target only its own frame (and A's return) may contain
            // the cursor. Both other frames must show the restored background.
            let absent = (0..<3).filter { $0 != corner }
            let occupied = frames[corner]
            let before = frames[absent[0]]
            let after = frames[absent[1]]
            var arrival: Set<Int> = []
            var departure: Set<Int> = []
            var backgroundChanges = 0
            var returnChanges = 0
            for py in max(0, y - 7)...min(height - 1, y + 7) {
                for px in max(0, x - 7)...min(width - 1, x + 7) {
                    let i = py * width + px
                    if abs(Int(occupied[i]) - Int(before[i])) > 12 { arrival.insert(i) }
                    if abs(Int(occupied[i]) - Int(after[i])) > 12 { departure.insert(i) }
                    if abs(Int(before[i]) - Int(after[i])) > 12 { backgroundChanges += 1 }
                    if abs(Int(frames[0][i]) - Int(frames[3][i])) > 12 { returnChanges += 1 }
                }
            }
            let common = arrival.intersection(departure)
            guard (3...150).contains(arrival.count), (3...150).contains(departure.count),
                common.count * 4 >= max(arrival.count, departure.count) * 3,
                backgroundChanges <= 2, returnChanges <= 2
            else { return false }
            let center = CGPoint(
                x: Double(common.reduce(0) { $0 + $1 % width }) / Double(common.count),
                y: Double(common.reduce(0) { $0 + $1 / width }) / Double(common.count))
            guard hypot(center.x - point.x * Double(width), center.y - point.y * Double(height)) <= 3,
                common.allSatisfy({ hypot(Double($0 % width) - center.x, Double($0 / width) - center.y) <= 6 })
            else { return false }
        }
        return true
    }

    /// Detects localized arrival-and-departure pixel reversal at one or more
    /// probe targets so a single backup trajectory can run when a primary target
    /// hit a `UIPointerInteraction` morphing control, without re-probing silent
    /// unrelated BLE hosts (such as an Apple Watch).
    static func hasReversibleTargetActivity(
        _ frames: [[UInt8]],
        targets: [ProbeTarget] = [firstPoint, secondPoint, thirdPoint]
    ) -> Bool {
        guard frames.count == 4,
            frames.allSatisfy({ $0.count == width * height }),
            targetsAreValidProbeSet(targets)
        else { return false }
        for (corner, point) in targets.enumerated() {
            let x = Int(point.x * Double(width))
            let y = Int(point.y * Double(height))
            let absent = (0..<3).filter { $0 != corner }
            let occupied = frames[corner]
            let before = frames[absent[0]]
            let after = frames[absent[1]]
            var arrival: Set<Int> = []
            var departure: Set<Int> = []
            var backgroundChanges = 0
            var returnChanges = 0
            for py in max(0, y - 7)...min(height - 1, y + 7) {
                for px in max(0, x - 7)...min(width - 1, x + 7) {
                    let i = py * width + px
                    if abs(Int(occupied[i]) - Int(before[i])) > 12 { arrival.insert(i) }
                    if abs(Int(occupied[i]) - Int(after[i])) > 12 { departure.insert(i) }
                    if abs(Int(before[i]) - Int(after[i])) > 12 { backgroundChanges += 1 }
                    if abs(Int(frames[0][i]) - Int(frames[3][i])) > 12 { returnChanges += 1 }
                }
            }
            let common = arrival.intersection(departure)
            if arrival.count >= 3,
                departure.count >= 3,
                common.count * 2 >= max(arrival.count, departure.count),
                backgroundChanges <= 4,
                returnChanges <= max(4, common.count / 4)
            {
                return true
            }
        }
        return false
    }

    /// Count pixels above the original noise threshold in a 15-by-15 region.
    private static func changed(_ before: [UInt8], _ after: [UInt8], around point: (Double, Double)) -> Int {
        let radius = 7
        let centerX = Int(point.0 * Double(width))
        let centerY = Int(point.1 * Double(height))
        var count = 0
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let index = y * width + x
                if abs(Int(before[index]) - Int(after[index])) > 12 { count += 1 }
            }
        }
        return count
    }
}

/// Selects a narrowly-scoped recovery when a still-connected saved host's
/// calibration proves that the current USB screen belongs to another phone.
/// The probe result is deliberately required before replacing any saved match.
enum DevicePairingRecovery {
    /// A blocked recovery must protect existing identities, while absent
    /// phones' historical records must not prevent discovering a new screen.
    /// Screens whose saved host has an active outbound BLE reconnection wait
    /// for that bounded attempt before probing unrelated connected hosts.
    static func matchingScreenIDs(
        screenIDs: [String], pairings: [String: UUID], connectedHosts: [UUID],
        reconnectingHosts: Set<UUID> = [], recoveryBlocked: Bool
    ) -> [String] {
        screenIDs.filter { id in
            guard let host = pairings[id] else { return true }
            return !recoveryBlocked && !connectedHosts.contains(host) && !reconnectingHosts.contains(host)
        }
    }

    enum ProbeResult: Equatable {
        case hit
        case miss
        case unavailable
    }

    /// A complete absolute trajectory already identifies the driven screen.
    /// Scores or ambiguous trajectories must still use relative discovery.
    static func absoluteProbeResults(verified: [Bool]) -> [ProbeResult]? {
        guard verified.filter({ $0 }).count == 1 else { return nil }
        return verified.map { $0 ? .hit : .unavailable }
    }

    static func probeResult(for frames: [[UInt8]]) -> ProbeResult {
        guard frames.count == 5,
            frames.allSatisfy({ $0.count == RelativePointerScreenMatcher.width * RelativePointerScreenMatcher.height })
        else { return .unavailable }
        if RelativePointerScreenMatcher.matches(frames) { return .hit }
        // A previous candidate's pointer can fade during the first capture.
        // The stable tail still covers two distinct requested directions, while
        // ignoring only sub-threshold video compression jitter (<= 12). Any
        // above-threshold pixel change remains `.unavailable` so clipped or
        // low-gain cursor motion is never misclassified as a confirmed `.miss`.
        return isStableTail(Array(frames.suffix(3))) ? .miss : .unavailable
    }

    private static func isStableTail(_ tail: [[UInt8]]) -> Bool {
        guard tail.count == 3 else { return false }
        let a = tail[0]
        let b = tail[1]
        let c = tail[2]
        for i in a.indices {
            if abs(Int(b[i]) - Int(a[i])) > 12
                || abs(Int(c[i]) - Int(b[i])) > 12
                || abs(Int(c[i]) - Int(a[i])) > 12
            {
                return false
            }
        }
        return true
    }

    /// An association already proven by motion in the live BLE session is not an
    /// unidentified legacy mapping, even when it uses absolute mode without a
    /// persisted relative calibration file.
    static func shouldVerifyUnidentifiedCurrentMapping(
        isCurrentSessionVerified: Bool, boundScreenID: String?
    ) -> Bool {
        !isCurrentSessionVerified && boundScreenID == nil
    }

    static func shouldRequireCalibration(hasProfile: Bool, absoluteVerified: Bool) -> Bool {
        !hasProfile && !absoluteVerified
    }

    struct Candidate: Equatable {
        let screenID: String
        let mappedScreenID: String
        let mappedHost: UUID
        let unmatchedHosts: [UUID]
    }

    static func shouldAttemptRecovery(
        screenID: String, pairings: [String: UUID], mismatchedCalibrationScreenIDs: Set<String>,
        verifiedAbsentScreenPairingIDs: Set<String>
    ) -> Bool {
        // Keep historical absent-screen records after recovery, but do not let
        // them repeatedly block matching once the current screen has a valid
        // pairing. A mismatched current mapping still needs recovery evidence.
        if pairings[screenID] != nil, !mismatchedCalibrationScreenIDs.contains(screenID) {
            return false
        }
        return !mismatchedCalibrationScreenIDs.isEmpty || !verifiedAbsentScreenPairingIDs.isEmpty
    }

    /// The single-screen/single-host shortcut may skip probing only when the
    /// screen is genuinely new or already saved to this very host. A saved
    /// pairing to a disconnected host is evidence the screen belongs to that
    /// phone: a device swap that briefly leaves one other host connected must
    /// not steal the screen without a probe.
    static func singleHostShortcutAllowed(screenID: String, pairings: [String: UUID], host: UUID) -> Bool {
        pairings[screenID].map { $0 == host } ?? true
    }

    /// A stored pairing can name the wrong host after a device swap (for
    /// example through shortcut matching on older releases). A connected host
    /// whose saved calibration was measured on the currently paired screen is
    /// stronger evidence than that pairing. Returns the candidate whose probe
    /// results can justify repairing the mapping.
    static func verifiedOwnerClaim(
        screenIDs: [String], pairings: [String: UUID], connectedHosts: [UUID],
        isVerifiedOwner: (UUID, String) -> Bool
    ) -> Candidate? {
        guard screenIDs.count == 1, let screenID = screenIDs.first,
            let pairedHost = pairings[screenID], connectedHosts.contains(pairedHost)
        else { return nil }
        // Exactly one other connected host, not itself paired to any screen,
        // must own a calibration measured on this very screen.
        let claimants = connectedHosts.filter { host in
            host != pairedHost
                && !pairings.values.contains(host)
                && isVerifiedOwner(host, screenID)
        }
        guard claimants.count == 1 else { return nil }
        return Candidate(
            screenID: screenID, mappedScreenID: screenID, mappedHost: pairedHost,
            unmatchedHosts: claimants)
    }

    static func candidate(
        screenIDs: [String], pairings: [String: UUID], connectedHosts: [UUID],
        unmatchedHosts: [UUID], mismatchedCalibrationScreenIDs: Set<String>,
        verifiedAbsentScreenPairingIDs: Set<String> = []
    ) -> Candidate? {
        guard screenIDs.count == 1,
            Set(unmatchedHosts).isSubset(of: Set(connectedHosts))
        else { return nil }

        guard let screenID = screenIDs.first else { return nil }
        if pairings[screenID] != nil, !mismatchedCalibrationScreenIDs.contains(screenID) {
            return nil
        }
        let connected = Set(connectedHosts)
        let suspects = pairings.compactMap { mappedScreenID, host -> (String, UUID)? in
            let isWrongCurrentMapping =
                mappedScreenID == screenID
                && mismatchedCalibrationScreenIDs.contains(mappedScreenID)
            let isVerifiedAbsentScreenMapping =
                !screenIDs.contains(mappedScreenID)
                && verifiedAbsentScreenPairingIDs.contains(mappedScreenID)
            guard isWrongCurrentMapping || isVerifiedAbsentScreenMapping, connected.contains(host)
            else { return nil }
            return (mappedScreenID, host)
        }
        guard suspects.count == 1, let (mappedScreenID, mappedHost) = suspects.first,
            pairings.values.filter({ $0 == mappedHost }).count == 1
        else { return nil }

        let savedHosts = Set(pairings.values)
        let candidates = unmatchedHosts.filter { !savedHosts.contains($0) }
        guard !candidates.isEmpty else { return nil }
        return Candidate(
            screenID: screenID, mappedScreenID: mappedScreenID, mappedHost: mappedHost,
            unmatchedHosts: candidates)
    }

    /// Builds the narrowly-scoped candidate used to validate a currently
    /// mapped screen when its saved host has no calibration identity. The
    /// current host is retained as the mapped host; only hosts that are both
    /// connected and absent from every saved pairing may be candidates.
    static func currentMappingCandidate(
        screenIDs: [String], pairings: [String: UUID], connectedHosts: [UUID], unmatchedHosts: [UUID]
    ) -> Candidate? {
        guard screenIDs.count == 1,
            let screenID = screenIDs.first, let mappedHost = pairings[screenID], connectedHosts.contains(mappedHost),
            Set(unmatchedHosts).isSubset(of: Set(connectedHosts)),
            pairings.values.filter({ $0 == mappedHost }).count == 1
        else { return nil }

        let savedHosts = Set(pairings.values)
        let candidates = unmatchedHosts.filter { !savedHosts.contains($0) }
        guard !candidates.isEmpty else { return nil }
        return Candidate(
            screenID: screenID, mappedScreenID: screenID, mappedHost: mappedHost, unmatchedHosts: candidates)
    }

    /// A replacement is safe when every probe completed, the old host does not
    /// itself hit the screen, and exactly one unmatched host clearly did. A
    /// noisy `.unavailable` from the old host must not strand the screen: the
    /// candidate's direct hit is stronger evidence than the absent-screen
    /// hypothesis it replaces. Only a competing hit is truly ambiguous.
    static func replacement(for candidate: Candidate, probeResults: [UUID: ProbeResult]) -> [String: UUID]? {
        let expectedHosts = Set(candidate.unmatchedHosts).union([candidate.mappedHost])
        guard Set(probeResults.keys) == expectedHosts,
            probeResults[candidate.mappedHost] != .hit,
            let host = uniqueCandidateHit(for: candidate, probeResults: probeResults)
        else { return nil }
        return [candidate.screenID: host]
    }

    /// Returns a candidate only when every unmatched host was probed, exactly
    /// one clearly hit this screen, and the others clearly missed. Recovery
    /// uses this before probing the already-mapped host to avoid moving the
    /// current phone's pointer unless a replacement is plausible.
    static func uniqueCandidateHit(
        for candidate: Candidate, probeResults: [UUID: ProbeResult]
    ) -> UUID? {
        let expectedHosts = Set(candidate.unmatchedHosts)
        guard !expectedHosts.isEmpty, Set(probeResults.keys).isSuperset(of: expectedHosts) else { return nil }
        let results = candidate.unmatchedHosts.compactMap { probeResults[$0] }
        guard results.count == expectedHosts.count, results.allSatisfy({ $0 != .unavailable }) else { return nil }
        let matches = candidate.unmatchedHosts.filter { probeResults[$0] == .hit }
        guard matches.count == 1 else { return nil }
        return matches.first
    }
}
