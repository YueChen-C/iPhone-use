import Foundation

/// Product routing policy only. Discovery, DDI changes and report sending belong
/// to adapters, never to route resolution. Existing devices remain BLE by default.
enum InputBackendKind: String, Codable, CaseIterable {
    case ble, usb
}

/// Lock-confined selection state. Both transports are denied until retirement
/// completes; an old completion cannot activate a superseded selection.
struct InputBackendSelection {
    private(set) var backend: InputBackendKind = .ble
    private(set) var generation = UUID()
    private(set) var transitioning = false
    private(set) var failure: String?

    mutating func begin(_ backend: InputBackendKind) -> UUID {
        self.backend = backend; generation = UUID(); transitioning = true; failure = nil
        return generation
    }
    mutating func finish(_ generation: UUID, released: Bool) {
        guard self.generation == generation else { return }
        transitioning = false
        failure = released ? nil : "Previous input release was not confirmed; explicitly reselect to retry"
    }
    func permits(_ backend: InputBackendKind, generation: UUID? = nil) -> Bool {
        self.backend == backend && !transitioning && failure == nil
            && (generation == nil || generation == self.generation)
    }
}

enum InputCapability: String, Codable, CaseIterable {
    case tap, swipe, drag, hover, text, key, home, power, relativePointer
}

enum InputBackendReadiness: String, Codable, CaseIterable {
    case disabled, preparing, requiresTrust, requiresDeveloperMode, requiresDDI
    case unsupportedHost, unsupportedDevice, identityUnverified, ready, disconnected, failed
}

/// An adapter publishes a snapshot for an exact physical device and transport
/// session. USB readiness intentionally contains no Bluetooth host or calibration.
struct InputBackendSnapshot: Equatable {
    let backend: InputBackendKind
    let physicalDeviceID: String
    let sessionID: UUID?
    let readiness: InputBackendReadiness
    let capabilities: Set<InputCapability>
}

/// Must be revalidated immediately before dispatch and at gesture boundaries.
/// A new transport session, capture identity, or backend selection invalidates it.
struct InputRouteLease: Equatable {
    let backend: InputBackendKind
    let physicalDeviceID: String
    let sessionID: UUID
    let generation: UUID
    let capability: InputCapability
}

struct InputRoutingError: Error, Equatable {
    enum Code: String {
        case invalidIdentity, ambiguousIdentity, backendUnavailable
        case inputNotReady, unsupportedCapability, staleSession
    }
    let code: Code
    let backend: InputBackendKind
}

enum InputBackendPolicy {
    static let defaultBackend: InputBackendKind = .ble

    /// No fuzzy matching and no cross-backend fallback. The public API resolves
    /// names/prefixes once; from here on, the full verified physical ID is fixed.
    static func resolve(
        selected: InputBackendKind, physicalDeviceID: String, generation: UUID,
        capability: InputCapability, snapshots: [InputBackendSnapshot]
    ) throws -> InputRouteLease {
        guard !physicalDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputRoutingError(code: .invalidIdentity, backend: selected)
        }
        let matches = snapshots.filter {
            $0.backend == selected && $0.physicalDeviceID == physicalDeviceID
        }
        guard matches.count <= 1 else {
            throw InputRoutingError(code: .ambiguousIdentity, backend: selected)
        }
        guard let snapshot = matches.first else {
            throw InputRoutingError(code: .backendUnavailable, backend: selected)
        }
        guard snapshot.readiness == .ready, let sessionID = snapshot.sessionID else {
            throw InputRoutingError(code: .inputNotReady, backend: selected)
        }
        guard snapshot.capabilities.contains(capability) else {
            throw InputRoutingError(code: .unsupportedCapability, backend: selected)
        }
        return InputRouteLease(
            backend: selected, physicalDeviceID: physicalDeviceID, sessionID: sessionID,
            generation: generation, capability: capability)
    }

    static func validate(
        _ lease: InputRouteLease, generation: UUID, snapshot: InputBackendSnapshot
    ) throws {
        guard lease.generation == generation, lease.backend == snapshot.backend,
            lease.physicalDeviceID == snapshot.physicalDeviceID, lease.sessionID == snapshot.sessionID
        else { throw InputRoutingError(code: .staleSession, backend: lease.backend) }
        guard snapshot.readiness == .ready else {
            throw InputRoutingError(code: .inputNotReady, backend: lease.backend)
        }
        guard snapshot.capabilities.contains(lease.capability) else {
            throw InputRoutingError(code: .unsupportedCapability, backend: lease.backend)
        }
    }
}

/// Transport acknowledgement is not observed UI success. In particular, an
/// uncertain send must never be automatically replayed through another backend.
enum InputExecutionDisposition: String, Codable {
    case notStarted, mayHaveExecuted, acknowledged

    var permitsAutomaticReplay: Bool { false }
}
