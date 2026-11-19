import Foundation

/// Read-only UI interpretation of an adapter snapshot. This never prepares a
/// worker, changes a backend, grants input or diagnoses from error prose.
struct ControlUSBPresentation: Equatable {
    enum Recovery {
        case wait, connect, identity, display, services, host, device
        case trust, developerMode, ddi, select
    }
    let state: InputBackendReadiness
    let reason: USBPreparationFailure.Reason?
    let hasScreen: Bool
    let keyboardReady: Bool
    let buttonsReady: Bool
    let detail: String

    init(snapshot: [String: Any], inputReady: Bool, hasScreen: Bool) {
        self.hasScreen = hasScreen
        let advertised = (snapshot["state"] as? String).flatMap(InputBackendReadiness.init(rawValue:)) ?? .failed
        // The display text must not turn a stale ready snapshot into readiness.
        state = !hasScreen ? .disconnected : (advertised == .ready && !inputReady ? .failed : advertised)
        let reported = (snapshot["reason"] as? String).flatMap(USBPreparationFailure.Reason.init(rawValue:))
        reason = hasScreen && state != .ready && reported?.readiness == state ? reported : nil
        let capabilities = Set(snapshot["capabilities"] as? [String] ?? [])
        keyboardReady = state == .ready && inputReady && capabilities.isSuperset(of: ["text", "key"])
        buttonsReady = state == .ready && inputReady && capabilities.isSuperset(of: USBHardwareButton.allCases.map(\.rawValue))
        // Complete diagnostics remain in /status. Keep potentially large XPC
        // descriptions out of the visible card and bounded in its tooltip.
        detail = String((snapshot["detail"] as? String ?? "").prefix(4096))
    }

    var showsOverlay: Bool { state != .ready }
    // Service absence is an offer to inspect/setup, never a diagnosis or grant
    // to replace an image. Trust/identity/host/display errors keep their own gates.
    var offersUSBSetup: Bool {
        hasScreen && (state == .requiresDDI || recovery == .services)
    }
    /// Explicit connection preparation only; never resumes an earlier input.
    var offersPreparationRetry: Bool {
        guard hasScreen else { return false }
        switch state {
        case .failed, .disconnected, .identityUnverified, .requiresTrust, .requiresDeveloperMode, .requiresDDI: return true
        default: return false
        }
    }
    var recovery: Recovery {
        if !hasScreen { return .connect }
        if reason == .displayUnavailable { return .display }
        if reason == .serviceUnavailable || reason == .touchscreenUnavailable { return .services }
        switch state {
        case .preparing: return .wait
        case .identityUnverified: return .identity
        case .unsupportedHost: return .host
        case .unsupportedDevice: return .device
        case .requiresTrust: return .trust
        case .requiresDeveloperMode: return .developerMode
        case .requiresDDI: return .ddi
        default: return .select
        }
    }
}
