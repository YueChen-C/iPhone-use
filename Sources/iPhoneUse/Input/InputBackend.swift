import Foundation

/// Explicit choices override the version-based default for each full physical ID.
enum InputBackendKind: String, Codable, CaseIterable {
    case ble, usb

    static func defaultForIOSVersion(_ version: String) -> Self {
        guard (try? USBBackendCompatibility.validate(version: version)) != nil,
              let major = version.split(separator: ".").first.flatMap({ Int($0) }), major >= 26
        else { return .ble }
        return .usb
    }
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
    mutating func fail(_ generation: UUID, message: String) {
        guard self.generation == generation else { return }
        transitioning = false
        failure = message
    }
    func permits(_ backend: InputBackendKind, generation: UUID? = nil) -> Bool {
        self.backend == backend && !transitioning && failure == nil
            && (generation == nil || generation == self.generation)
    }
}

enum InputBackendReadiness: String, Codable, CaseIterable {
    case disabled, preparing, requiresTrust, requiresDeveloperMode, requiresDDI
    case unsupportedHost, unsupportedDevice, identityUnverified, ready, disconnected, failed
}
