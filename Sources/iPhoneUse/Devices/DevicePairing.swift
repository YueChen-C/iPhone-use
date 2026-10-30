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
    static let width = 90
    static let height = 195
    static let firstPoint = (x: 0.3, y: 0.35)
    static let secondPoint = (x: 0.7, y: 0.65)
    static let thirdPoint = (x: 0.5, y: 0.5)

    struct ChangeMetrics: Equatable {
        let signal: Int
        let noise: Int
    }

    /// Buffers come from ScreenCaptureSession.thumbnail and contain width * height gray pixels.
    static func score(before: [UInt8], after: [UInt8]) -> Int {
        let metrics = changeMetrics(before: before, after: after)
        return metrics.signal - metrics.noise
    }

    /// Separates changes around the two pointer targets from changes in the
    /// crossed control regions. A zero score alone is not enough to prove a
    /// miss: background activity can cancel a real signal.
    static func changeMetrics(before: [UInt8], after: [UInt8]) -> ChangeMetrics {
        let a = firstPoint
        let b = secondPoint
        let signal = min(changed(before, after, around: a), changed(before, after, around: b))
        let noise = max(changed(before, after, around: (a.x, b.y)), changed(before, after, around: (b.x, a.y)))
        return ChangeMetrics(signal: signal, noise: noise)
    }

    static func candidateOrder(scores: [Int]) -> [Int] {
        scores.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
    }

    /// Confirms three requested landings and the return independently of identity
    /// discovery. iOS changes pointer color with its background: arrival and
    /// departure can have the same polarity at different targets. Require local
    /// reversal at each target instead of opposite polarities across the screen.
    static func matchesAbsoluteRoundTrip(_ frames: [[UInt8]]) -> Bool {
        guard frames.count == 4, frames.allSatisfy({ $0.count == width * height }) else { return false }
        for (corner, point) in [firstPoint, secondPoint, thirdPoint].enumerated() {
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
    static func matchingScreenIDs(
        screenIDs: [String], pairings: [String: UUID], connectedHosts: [UUID], recoveryBlocked: Bool
    ) -> [String] {
        screenIDs.filter { id in
            guard let host = pairings[id] else { return true }
            return !recoveryBlocked && !connectedHosts.contains(host)
        }
    }

    enum ProbeResult: Equatable {
        case hit
        case miss
        case unavailable
    }

    static func probeResult(for frames: [[UInt8]]) -> ProbeResult {
        guard frames.count == 5,
            frames.allSatisfy({ $0.count == RelativePointerScreenMatcher.width * RelativePointerScreenMatcher.height })
        else { return .unavailable }
        if RelativePointerScreenMatcher.matches(frames) { return .hit }
        // A previous candidate's pointer can fade during the first capture.
        // The stable tail still covers two distinct requested directions.
        let tail = frames.suffix(3)
        return tail.allSatisfy({ $0 == tail.first! }) ? .miss : .unavailable
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
