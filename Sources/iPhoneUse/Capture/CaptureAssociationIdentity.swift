import CoreGraphics
import Foundation

/// A nominal AVFoundation UID is not proof of which phone supplies its pixels.
/// Close only affected gates on topology changes; a proven surviving route may stay open.
/// No image processing, probing or logging runs on the display path.
final class CaptureDisplayIdentity {
    private let lock = NSLock()
    private var confirmed: Bool
    private var revision: UInt64 = 0

    init(confirmed: Bool) { self.confirmed = confirmed }

    func setConfirmed(_ value: Bool) {
        lock.withLock {
            if confirmed != value { revision &+= 1 }
            confirmed = value
        }
    }
    var isConfirmed: Bool { lock.withLock { confirmed } }

    func read<T>(_ value: () -> T?) -> T? {
        guard let expected = lock.withLock({ confirmed ? revision : nil }) else { return nil }
        // Encoding can be expensive. Never hold this gate or the manager lock
        // across image work; discard a result if topology changed meanwhile.
        let result = value()
        return lock.withLock { confirmed && revision == expected ? result : nil }
    }
}

/// Keep the Bluetooth motion proof with the continuously present physical phone,
/// even when AVFoundation reroutes its pixels through another capture source.
/// Capture input permission is checked separately; retaining this identity
/// must never allow input through an unconfirmed video mapping.
struct CaptureAssociationIdentity {
    private var confirmed: [String: UUID] = [:]

    mutating func identity(physicalID: String, isConfirmed: Bool) -> UUID {
        if let previous = confirmed[physicalID] { return previous }
        guard isConfirmed else { return UUID() }
        let identity = UUID()
        confirmed[physicalID] = identity
        return identity
    }

    mutating func retain(physicalIDs: Set<String>) {
        confirmed = confirmed.filter { physicalIDs.contains($0.key) }
    }
}

/// Keep surviving preview mappings during topology verification, including
/// mappings that differ from AVFoundation's nominal device IDs.
enum CaptureScreenMapping {
    struct Source {
        let id: String
        let instance: UUID
    }

    /// A registry entry proves a USB attachment, not what is in an AVFoundation
    /// buffer. Retain an independently verified exact route only on the same run.
    struct USBRoute: Equatable {
        let entryID: UInt64
        let sourceInstance: UUID
        let run: UInt64
    }

    static func usbEntries(
        sourceIDs: Set<String>, devices: [USBValeriaConfigurator.PinnedUSBDevice]
    ) -> [String: UInt64] {
        let normalized = USBValeriaConfigurator.normalizedSerial
        let sources = Dictionary(grouping: sourceIDs.compactMap { id in normalized(id).map { ($0, id) } }) { $0.0 }
        let attached = Dictionary(grouping: devices.compactMap { device in
            normalized(device.serial).map { ($0, device.registryEntryID) }
        }) { $0.0 }
        let entryCounts = Dictionary(grouping: devices, by: \.registryEntryID)
        return sources.reduce(into: [:]) { result, group in
            guard group.value.count == 1, let matches = attached[group.key], matches.count == 1,
                let entry = matches.first?.1, entry != 0, entryCounts[entry]?.count == 1
            else { return }
            result[group.value[0].1] = entry
        }
    }

    /// Bulk enumeration and AVFoundation discovery are independent snapshots.
    /// A missing AV listing is not a detach if the old capture is still live;
    /// when the bulk read fails, use positive per-entry evidence, never cached presence.
    static func refreshUSBEntries(
        discoveredIDs: Set<String>, devices: [USBValeriaConfigurator.PinnedUSBDevice]?,
        confirmedEntries: [String: UInt64], readEntry: (UInt64) -> USBValeriaConfigurator.PinnedUSBDevice?
    ) -> [String: UInt64] {
        let candidates = discoveredIDs.union(confirmedEntries.keys)
        if let devices { return usbEntries(sourceIDs: candidates, devices: devices) }
        let exact = Set(confirmedEntries.values).compactMap { entryID in
            readEntry(entryID).flatMap { $0.registryEntryID == entryID ? $0 : nil }
        }
        return usbEntries(sourceIDs: candidates, devices: exact).filter { confirmedEntries[$0.key] == $0.value }
    }

    static func continuing(
        proven: [String: USBRoute], current: [String: USBRoute],
        expectedSizes: [String: CGSize], sourceSizes: [String: CGSize]
    ) -> [String: String] {
        proven.reduce(into: [:]) { result, pair in
            guard current[pair.key] == pair.value, let expected = expectedSizes[pair.key],
                sourceSizes[pair.key] == expected
            else { return }
            result[pair.key] = pair.key
        }
    }

    static func previews(
        confirmed: [String: String], previous: [String: Source], sources: [String: UUID]
    ) -> [String: String] {
        var mapping = confirmed
        var unused = Set(sources.keys).subtracting(mapping.values)
        for id in sources.keys.sorted() where mapping[id] == nil {
            guard let source = previous[id], sources[source.id] == source.instance,
                unused.remove(source.id) != nil
            else { continue }
            mapping[id] = source.id
        }
        for id in sources.keys.sorted() where mapping[id] == nil {
            guard let sourceID = unused.contains(id) ? id : unused.sorted().first else { continue }
            mapping[id] = sourceID
            unused.remove(sourceID)
        }
        return mapping
    }
}
