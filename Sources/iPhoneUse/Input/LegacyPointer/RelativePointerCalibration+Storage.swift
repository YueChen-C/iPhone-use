import Foundation

enum PairingProbeCalibration {
    case calibrated(RelativePointerCalibration)
    case absolute
    case unavailable
}

/// Profile persistence and identity migration. Screen identity selects a profile;
/// live screen dimensions are checked by `DeviceInput` before coordinate control.
extension RelativePointerCalibration {
    static func fileURL(host: UUID) -> URL {
        fileURL(host: host, directory: directoryURL)
    }

    private static func fileURL(host: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(host.uuidString + ".json")
    }

    /// One authoritative measured curve per physical phone, independent of the
    /// Bluetooth identity assigned by a later pairing. Hex keeps USB IDs opaque
    /// and prevents path separators from becoming directory components.
    static func screenFileURL(screenID: String, directory: URL) -> URL {
        let name = screenID.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("by-screen", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    private static func screenTemplate(screenID: String, directory: URL) -> Self? {
        guard !screenID.isEmpty,
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

    /// Called only after native motion and target verification. Preserve both
    /// previous files if either write fails; failed measurement never calls this.
    func saveVerified(directory: URL? = nil) throws {
        try validate()
        guard let screenID, !screenID.isEmpty else { throw DeviceError("missing calibration screen identity") }
        let root = directory ?? Self.directoryURL
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

    /// A freshly observed motion associates this BLE host with the current
    /// capture. Prefer the capture's stable template; use the host curve only
    /// when the replacement capture has no measured template.
    static func loadVerifiedHost(host: UUID, screenID: String?, directory: URL? = nil) -> Self? {
        guard let screenID, !screenID.isEmpty,
            let own = load(host: host, screenSize: nil, directory: directory ?? directoryURL),
            own.screenID != nil, own.screenID != screenID
        else { return nil }
        let root = directory ?? directoryURL
        // The observed USB screen is the stable physical-phone identity. A
        // reconnected BLE host may carry a valid profile from another phone.
        // Prefer this screen's measured template when one exists; retain the
        // host curve only when a replacement capture has no screen template.
        return (screenTemplate(screenID: screenID, directory: root) ?? own)
            .rebound(to: host, screenID: screenID)
    }

    static func load(host: UUID, screenSize: CGSize?, screenID: String? = nil, directory: URL) -> Self? {
        let url = fileURL(host: host, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            var result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            try result.validate()
            // Capture may have no first frame or start in another orientation.
            // Keep the identity-bound profile; DeviceInput checks the live dimensions
            // before each coordinate operation so it can recover automatically.
            guard result.host == host,
                screenID == nil || result.screenID == nil || result.screenID == screenID
            else {
                throw DeviceError("relative pointer calibration does not match host/screen identity")
            }
            let wasLegacy = result.screenID == nil
            if let boundID = result.screenID ?? screenID,
                let template = screenTemplate(screenID: boundID, directory: directory)
            {
                result = template.rebound(to: host, screenID: boundID)
            }
            if let screenID, !screenID.isEmpty, wasLegacy {
                // The pairing already confirms this host's screen. Upgrade a
                // legacy profile so future host identifiers can find it safely.
                result = result.rebound(to: host, screenID: screenID)
                try JSONEncoder().encode(result).write(to: url, options: .atomic)
            }
            return result
        } catch {
            log("pointer calibration unavailable: \(error)")
            return nil
        }
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

    /// Selects only calibration tied to the screen being probed. Unlike the
    /// regular pairing path, this lookup never writes a legacy profile's screen
    /// identity before a match has been proven.
    static func pairingProbeCalibration(host: UUID, screenID: String) -> PairingProbeCalibration {
        let ownProfile = fileURL(host: host)
        if FileManager.default.fileExists(atPath: ownProfile.path) {
            guard let calibration = load(host: host, screenSize: nil), calibration.screenID == screenID else {
                return .unavailable
            }
            return .calibrated(calibration)
        }

        if let calibration = loadMatchingScreen(host: host, screenSize: nil, screenID: screenID) {
            return .calibrated(calibration)
        }
        return requiresCalibration(host: host, screenID: screenID) ? .unavailable : .absolute
    }

    /// Calibration for a generic matching probe against one known free screen.
    /// Re-pairing gives the phone a new central UUID and no profile of its own;
    /// the unique profile bound to the probed screen is then its only working
    /// movement mode, because those phones ignore the absolute report. The
    /// rebound profile lives in memory for this probe alone — nothing is
    /// written until store() migrates it for a confirmed pairing. A nil
    /// screenID (several free screens in play) keeps the host absolute.
    static func probeInputCalibration(
        host: UUID, screenID: String?, directory: URL? = nil
    ) -> (calibration: Self?, required: Bool) {
        let root = directory ?? directoryURL
        if let own = load(host: host, screenSize: nil, screenID: nil, directory: root) {
            return (own, true)
        }
        if let screenID, !screenID.isEmpty,
            let matching = loadMatchingScreen(host: host, screenSize: nil, screenID: screenID, directory: root)
        {
            return (matching, true)
        }
        // The host's own broken profile still opts it into calibrated control;
        // an ambiguous or absent screen-bound set probes absolute, as before.
        return (nil, requiresCalibration(host: host, screenID: nil, directory: root))
    }

    private static func storedScreenID(host: UUID, directory: URL) -> String? {
        let url = fileURL(host: host, directory: directory)
        guard let data = try? Data(contentsOf: url),
            let profile = try? JSONDecoder().decode(Self.self, from: data),
            profile.host == host,
            let screenID = profile.screenID, !screenID.isEmpty,
            (try? profile.validate()) != nil
        else { return nil }
        return screenID
    }

    /// Re-pairing can change CBCentral's identifier. Screen dimensions alone
    /// cannot identify a phone: reuse only a profile bound to this USB screen.
    static func loadMatchingScreen(host: UUID, screenSize: CGSize?, screenID: String? = nil) -> Self? {
        loadMatchingScreen(host: host, screenSize: screenSize, screenID: screenID, directory: directoryURL)
    }

    static func loadMatchingScreen(host: UUID, screenSize: CGSize?, screenID: String? = nil, directory: URL) -> Self? {
        guard let screenID, !screenID.isEmpty else { return nil }
        if let template = screenTemplate(screenID: screenID, directory: directory) {
            return template.rebound(to: host, screenID: screenID)
        }
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        let candidates = urls.compactMap { url -> Self? in
            guard url.pathExtension.lowercased() == "json",
                let data = try? Data(contentsOf: url),
                let value = try? JSONDecoder().decode(Self.self, from: data),
                value.host != host, value.screenID == screenID
            else { return nil }
            do {
                try value.validate()
                return value
            } catch {
                return nil
            }
        }
        guard candidates.count == 1, let value = candidates.first else { return nil }
        log("reusing pointer calibration from re-paired host \(value.host) for \(host)")
        return value.rebound(to: host, screenID: screenID)
    }

    /// DeviceRegistry already knows the old and new hosts belong to the same USB
    /// screen. Validate the source before atomically writing a profile whose
    /// embedded identity agrees with its new filename.
    @discardableResult
    static func rebind(from oldHost: UUID, to newHost: UUID, screenID: String) throws -> Self? {
        try rebind(from: oldHost, to: newHost, screenID: screenID, directory: directoryURL)
    }

    @discardableResult
    static func rebind(from oldHost: UUID, to newHost: UUID, screenID: String, directory: URL) throws -> Self? {
        let source = fileURL(host: oldHost, directory: directory)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: source))
        try value.validate()
        guard !screenID.isEmpty, value.host == oldHost,
            value.screenID == nil || value.screenID == screenID
        else {
            throw DeviceError("relative pointer calibration does not match the paired screen")
        }
        let latest = screenTemplate(screenID: screenID, directory: directory) ?? value
        let rebound = latest.rebound(to: newHost, screenID: screenID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(rebound).write(to: fileURL(host: newHost, directory: directory), options: .atomic)
        return rebound
    }

    private func rebound(to host: UUID, screenID: String) -> Self {
        Self(
            host: host, screenWidth: screenWidth, screenHeight: screenHeight,
            reportInterval: reportInterval, distances: distances, screenID: screenID, vectorModel: vectorModel)
    }
}
