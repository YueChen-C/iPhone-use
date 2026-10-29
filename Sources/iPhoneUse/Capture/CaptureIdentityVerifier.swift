import Foundation

enum ScreenCaptureIdentityState: String {
    case singleDevice
    case pending
    case verified
    case partiallyVerified
    /// The system device framework or the phones' screenshot services are unavailable.
    case unavailable
    /// Independent screenshots did not prove a reliable mapping.
    case failed

    func permitsAssociation(identityVerified: Bool) -> Bool {
        switch self {
        case .singleDevice, .verified, .unavailable: true
        case .partiallyVerified: identityVerified
        case .pending, .failed: false
        }
    }
}

/// Subscription callbacks arrive separately for each HID report. Retry a
/// blocked capture identity once per new BLE session, never once per callback
/// or status poll. Disconnecting another phone does not restart verification.
struct CaptureIdentityRetrySchedule {
    private var sessions: [UUID: UUID] = [:]

    mutating func update(_ current: [UUID: UUID]) -> Bool {
        let hasNewSession = current.contains { sessions[$0.key] != $0.value }
        sessions = current
        return hasNewSession
    }
}

/// A newly attached AVFoundation stream can remain empty after startRunning.
/// Recover only empty streams, once per source instance, without a timer loop.
struct CaptureSourceRecovery {
    private var attempted: Set<UUID> = []

    mutating func take(empty: Set<UUID>) -> Set<UUID> {
        let fresh = empty.subtracting(attempted)
        attempted.formUnion(fresh)
        return fresh
    }

    mutating func retain(sources: Set<UUID>) {
        attempted.formIntersection(sources)
    }
}

/// Runs only after capture topology changes or an explicit matching retry. No
/// subprocess, screenshot, or comparison is performed on the video hot path.
enum CaptureIdentityVerifier {
    enum Result {
        case verified([String: String])
        case partiallyVerified([String: String])
        case unavailable
        case failed
    }

    enum Screenshot {
        case image(CaptureIdentityImage)
        case unavailable
        case failed
    }

    /// Injectable screenshot collection keeps missing screenshotr services and
    /// mixed-device verification covered without requiring physical phones.
    static func verify(
        physicalIDs: [String], sourceImages: () -> [String: CaptureIdentityImage],
        isCurrent: () -> Bool, waitForRetry: () -> Void = {}, screenshot: (String) -> Screenshot
    ) -> Result {
        var previous: [String: String]?
        for attempt in 0..<3 {
            if attempt > 0 { waitForRetry() }
            guard isCurrent() else { return .failed }
            var physical: [String: CaptureIdentityImage] = [:]
            var unavailable: Set<String> = []
            for id in physicalIDs {
                guard isCurrent() else { return .failed }
                switch screenshot(id) {
                case .image(let image): physical[id] = image
                case .unavailable: unavailable.insert(id)
                case .failed: break
                }
            }
            guard isCurrent() else { return .failed }
            if unavailable.count == physicalIDs.count { return .unavailable }
            let mapping = CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: Set(physicalIDs), physical: physical,
                sources: sourceImages(), unavailable: unavailable)
            if !mapping.isEmpty, previous == mapping {
                return mapping.count == physicalIDs.count ? .verified(mapping) : .partiallyVerified(mapping)
            }
            previous = mapping
        }
        return .failed
    }

    static func verify(
        physicalIDs: [String], sourceImages: () -> [String: CaptureIdentityImage],
        isCurrent: () -> Bool
    ) -> Result {
        return verify(
            physicalIDs: physicalIDs, sourceImages: sourceImages, isCurrent: isCurrent,
            waitForRetry: { Thread.sleep(forTimeInterval: 0.5) },
            screenshot: { USBIdentityScreenshot.capture(physicalID: $0) })
    }
}
