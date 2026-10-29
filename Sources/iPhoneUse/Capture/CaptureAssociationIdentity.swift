import Foundation

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
