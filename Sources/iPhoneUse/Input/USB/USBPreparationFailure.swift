import Foundation

/// Preparation evidence, not a diagnosis inferred from localized error text.
/// In particular, an unavailable service does not prove that DDI, trust or
/// Developer Mode is the cause. No reason grants input or automatic recovery.
struct USBPreparationFailure: Error, CustomStringConvertible, Equatable {
    enum Reason: String, CaseIterable {
        case hostUnavailable = "host_unavailable"
        case hostUnsupported = "host_unsupported"
        case identityUnavailable = "identity_unavailable"
        case identityMismatch = "identity_mismatch"
        case displayUnavailable = "display_unavailable"
        case touchscreenUnavailable = "touchscreen_unavailable"
        case serviceUnavailable = "service_unavailable"
        case timedOut = "preparation_timeout"
        case workerDisconnected = "worker_disconnected"
        case workerProtocol = "worker_protocol"
        case unknown = "preparation_failed"

        var readiness: InputBackendReadiness {
            switch self {
            case .hostUnavailable, .hostUnsupported: .unsupportedHost
            case .identityUnavailable, .identityMismatch: .identityUnverified
            case .workerDisconnected: .disconnected
            default: .failed
            }
        }
    }

    let reason: Reason
    let description: String
    var readiness: InputBackendReadiness { reason.readiness }

    init(_ reason: Reason, _ description: String) {
        self.reason = reason; self.description = description
    }
    init(_ error: Error) {
        self = error as? Self ?? Self(.unknown, "\(error)")
    }
    init(workerEvent: [String: Any]) {
        let message = workerEvent["error"] as? String ?? "USB worker failed"
        // Reject contradictory or unrecognized metadata, including ready. Old
        // workers remain readable but their prose cannot select a typed state.
        guard workerEvent["event"] as? String == "failed",
              let raw = workerEvent["reason"] as? String, let reason = Reason(rawValue: raw),
              workerEvent["state"] as? String == reason.readiness.rawValue else {
            self.init(.unknown, message); return
        }
        self.init(reason, message)
    }
    var workerEvent: [String: Any] {
        ["event": "failed", "error": description, "state": readiness.rawValue,
         "reason": reason.rawValue, "replayAllowed": false]
    }
}
