import Foundation

enum PairingProbeCalibration {
    case calibrated(RelativePointerCalibration)
    case absolute
    case unavailable
}

/// Profile persistence. The physical UDID selects a curve; Bluetooth selects only its route;
/// live screen dimensions are checked by `DeviceInput` before coordinate control.
extension RelativePointerCalibration {
    static func fileURL(host: UUID) -> URL {
        fileURL(host: host, directory: directoryURL)
    }

    private static func fileURL(host: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(host.uuidString + ".json")
    }

    /// One authoritative measured curve per physical phone, independent of the
    /// Bluetooth identity assigned by a later pairing. Hex encodes the UDID
    /// and prevents path separators from becoming directory components.
    static func screenFileURL(screenID: String, directory: URL) -> URL {
        let name = screenID.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("by-screen", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    private static func screenTemplate(screenID: String, directory: URL) -> Self? {
        guard isDeviceUDID(screenID),
            let data = try? Data(contentsOf: screenFileURL(screenID: screenID, directory: directory)),
            let value = try? JSONDecoder().decode(Self.self, from: data),
            value.screenID == screenID, (try? value.validate()) != nil
        else { return nil }
        return value
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPhoneUse/pointer-calibration", isDirectory: true)
    }

    struct StorageSnapshot: Equatable {
        fileprivate let urls: [URL]
        fileprivate let contents: [Data?]
    }

    static func storageSnapshot(host: UUID, screenID: String, directory: URL? = nil) throws -> StorageSnapshot {
        let root = directory ?? directoryURL
        let template = screenFileURL(screenID: screenID, directory: root)
        let destination = fileURL(host: host, directory: root)
        var urls = [template, destination]
        if !FileManager.default.fileExists(atPath: template.path),
            FileManager.default.fileExists(atPath: root.path)
        {
            // Without an authoritative template, resolution depends on all
            // valid historical candidates, including duplicates and conflicts.
            let history = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            urls += history.filter { url in
                guard url.pathExtension.lowercased() == "json",
                    let owner = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                    let profile = hostProfile(host: owner, directory: root)
                else { return false }
                return profile.screenID == screenID && url != destination
            }.sorted { $0.path < $1.path }
        }
        return StorageSnapshot(
            urls: urls,
            contents: try urls.map { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            })
    }

    /// Called only after native motion and target verification. Preserve both
    /// previous files if either write fails; failed measurement never calls this.
    func saveVerified(directory: URL? = nil, ifUnchanged expected: StorageSnapshot? = nil) throws {
        try validate()
        guard let screenID, Self.isDeviceUDID(screenID) else { throw DeviceError("missing calibration iPhone UDID") }
        let root = directory ?? Self.directoryURL
        if let expected, try Self.storageSnapshot(host: host, screenID: screenID, directory: root) != expected {
            throw DeviceError("pointer calibration files changed during measurement; existing files preserved")
        }
        let urls = [Self.screenFileURL(screenID: screenID, directory: root), Self.fileURL(host: host, directory: root)]
        let previous = try urls.map { url -> Data? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
        let data = try JSONEncoder().encode(self)
        var completed: [Int] = []
        do {
            for (index, url) in urls.enumerated() {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                completed.append(index)
            }
        } catch {
            for index in completed.reversed() {
                if let data = previous[index] {
                    try data.write(to: urls[index], options: .atomic)
                } else {
                    try FileManager.default.removeItem(at: urls[index])
                }
            }
            throw error
        }
    }

    private static func requirementURL(screenID: String, directory: URL) -> URL {
        directory.appendingPathComponent("required", isDirectory: true)
            .appendingPathComponent(screenFileURL(screenID: screenID, directory: directory).lastPathComponent)
    }

    /// A successful relative probe after failed absolute positioning establishes
    /// a movement mode, not a calibrated gain. Persist that distinction across
    /// restarts so a missing profile cannot silently re-enable absolute input.
    static func markRequired(screenID: String, directory: URL? = nil) throws {
        guard !screenID.isEmpty else { throw DeviceError("missing calibration screen identity") }
        let url = requirementURL(screenID: screenID, directory: directory ?? directoryURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "screenID": screenID, "reason": "absolute-probe-failed-relative-probe-verified",
        ])
        try data.write(to: url, options: .atomic)
    }

    /// Only a new absolute landing proof may undo an earlier failed probe.
    /// Measured or damaged profile files remain intact and keep their own gate.
    static func clearRequirementAfterAbsoluteProof(screenID: String, directory: URL? = nil) throws {
        guard !screenID.isEmpty else { throw DeviceError("missing calibration screen identity") }
        let url = requirementURL(screenID: screenID, directory: directory ?? directoryURL)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func load(host: UUID, screenSize: CGSize?, screenID: String? = nil) -> Self? {
        load(host: host, screenSize: screenSize, screenID: screenID, directory: directoryURL)
    }

    /// A current physical identity is required for normal input. A host-only
    /// read is reserved for inspecting an explicitly bound historical profile
    /// during discovery; it never supplies or changes a missing UDID.
    static func load(host: UUID, screenSize: CGSize?, screenID: String? = nil, directory: URL) -> Self? {
        if let screenID {
            return loadMatchingScreen(host: host, screenSize: screenSize, screenID: screenID, directory: directory)
        }
        guard let own = hostProfile(host: host, directory: directory),
            let boundID = own.screenID, isDeviceUDID(boundID)
        else { return nil }
        return loadMatchingScreen(host: host, screenSize: screenSize, screenID: boundID, directory: directory)
    }

    private static func hostProfile(host: UUID, directory: URL) -> Self? {
        let url = fileURL(host: host, directory: directory)
        guard let data = try? Data(contentsOf: url),
            let profile = try? JSONDecoder().decode(Self.self, from: data),
            profile.host == host, (try? profile.validate()) != nil
        else { return nil }
        return profile
    }

    /// A broken profile still opts its phone into calibrated control. Do not
    /// silently switch that phone back to an incompatible absolute HID report.
    static func requiresCalibration(host: UUID, screenID: String?) -> Bool {
        requiresCalibration(host: host, screenID: screenID, directory: directoryURL)
    }

    static func requiresCalibration(host: UUID, screenID: String?, directory: URL) -> Bool {
        if FileManager.default.fileExists(atPath: fileURL(host: host, directory: directory).path) { return true }
        if let screenID, !screenID.isEmpty,
            FileManager.default.fileExists(atPath: requirementURL(screenID: screenID, directory: directory).path)
        {
            return true
        }
        if let screenID, !screenID.isEmpty,
            FileManager.default.fileExists(atPath: screenFileURL(screenID: screenID, directory: directory).path)
        {
            return true
        }
        guard let screenID, !screenID.isEmpty,
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return false }
        return urls.contains { url in
            guard url.pathExtension.lowercased() == "json",
                let data = try? Data(contentsOf: url),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return value["screenID"] as? String == screenID
        }
    }

    /// Only a fully decoded profile with matching host identity is evidence that
    /// a saved pairing points at a different USB screen. Resolution is not used
    /// to infer identity, and legacy or malformed profiles do not trigger repair.
    static func isBoundToDifferentScreen(host: UUID, screenID: String, directory: URL? = nil) -> Bool {
        guard !screenID.isEmpty,
            let storedScreenID = storedScreenID(host: host, directory: directory ?? directoryURL)
        else { return false }
        return storedScreenID != screenID
    }

    /// The screen identity from a fully validated profile, when present.
    /// Registry recovery uses this to load a saved host's calibration by its
    /// proven identity without binding that profile to the newly attached phone.
    static func boundScreenID(host: UUID, directory: URL? = nil) -> String? {
        storedScreenID(host: host, directory: directory ?? directoryURL)
    }

    static func isBoundToScreen(host: UUID, screenID: String, directory: URL? = nil) -> Bool {
        guard !screenID.isEmpty,
            let storedScreenID = storedScreenID(host: host, directory: directory ?? directoryURL)
        else { return false }
        return storedScreenID == screenID
    }

    /// Matching may use a curve only for the physical screen being probed.
    /// Neither a stale host file nor an unknown screen can donate its curve.
    static func pairingProbeCalibration(host: UUID, screenID: String, directory: URL? = nil) -> PairingProbeCalibration
    {
        let root = directory ?? directoryURL
        if let calibration = loadMatchingScreen(host: host, screenSize: nil, screenID: screenID, directory: root) {
            return .calibrated(calibration)
        }
        return requiresCalibration(host: host, screenID: screenID, directory: root) ? .unavailable : .absolute
    }

    /// Discovery without a physical identity uses gain-independent reports.
    /// This selection is read-only, including after a successful motion proof.
    static func probeInputCalibration(
        host: UUID, screenID: String?, directory: URL? = nil
    ) -> (calibration: Self?, required: Bool) {
        let root = directory ?? directoryURL
        let matching = screenID.flatMap {
            loadMatchingScreen(host: host, screenSize: nil, screenID: $0, directory: root)
        }
        return (matching, matching != nil || requiresCalibration(host: host, screenID: screenID, directory: root))
    }

    private static func storedScreenID(host: UUID, directory: URL) -> String? {
        let url = fileURL(host: host, directory: directory)
        guard let data = try? Data(contentsOf: url),
            let profile = try? JSONDecoder().decode(Self.self, from: data),
            profile.host == host,
            let screenID = profile.screenID, isDeviceUDID(screenID),
            (try? profile.validate()) != nil
        else { return nil }
        return screenID
    }

    /// Re-pairing can change CBCentral's identifier. Screen dimensions alone
    /// cannot identify a phone: reuse only a profile bound to this iPhone UDID.
    static func loadMatchingScreen(host: UUID, screenSize: CGSize?, screenID: String? = nil) -> Self? {
        loadMatchingScreen(host: host, screenSize: screenSize, screenID: screenID, directory: directoryURL)
    }

    static func loadMatchingScreen(host: UUID, screenSize: CGSize?, screenID: String? = nil, directory: URL) -> Self? {
        guard let screenID, isDeviceUDID(screenID) else { return nil }
        let templateURL = screenFileURL(screenID: screenID, directory: directory)
        if FileManager.default.fileExists(atPath: templateURL.path) {
            // A damaged or misidentified authoritative template must not expose
            // an older host copy as if it were the current measured curve.
            return screenTemplate(screenID: screenID, directory: directory)?.routed(to: host)
        }
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        let candidates = urls.compactMap { url -> Self? in
            guard url.pathExtension.lowercased() == "json",
                let owner = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                let profile = hostProfile(host: owner, directory: directory), profile.screenID == screenID
            else { return nil }
            return profile
        }
        // Old pairings may contain duplicate copies. Reuse identical curves,
        // but never pick an arbitrary winner among conflicting histories.
        guard let first = candidates.first,
            candidates.allSatisfy({ $0.routed(to: host) == first.routed(to: host) })
        else { return nil }
        return first.routed(to: host)
    }

    /// Only the transport destination may change. There is deliberately no
    /// operation that changes a measured profile's physical screen identity.
    private func routed(to host: UUID) -> Self {
        Self(
            host: host, screenWidth: screenWidth, screenHeight: screenHeight,
            reportInterval: reportInterval, distances: distances, screenID: screenID, vectorModel: vectorModel)
    }
}
