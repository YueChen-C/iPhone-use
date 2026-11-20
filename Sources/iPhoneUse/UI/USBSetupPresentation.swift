import Foundation

/// Progress for the explicit USB setup action; only a ready input session can
/// produce `.complete`. Native installation has no measurable byte progress.
enum USBSetupPresentation: Equatable {
    case inspecting, downloading(Int64, Int64), retrying, verifying
    case checkingImage, uninstalling, installing, verifyingInstallation, connecting
    case complete, cancelled, failed, installFailed, connectionFailed

    var canCancel: Bool {
        switch self {
        case .inspecting, .downloading, .retrying, .verifying: true
        default: false
        }
    }
    var isWorking: Bool {
        switch self {
        case .checkingImage, .uninstalling, .installing, .verifyingInstallation, .connecting: true
        default: canCancel
        }
    }
    var fraction: Double? {
        if self == .complete { return 1 }
        guard case let .downloading(received, total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }
}
