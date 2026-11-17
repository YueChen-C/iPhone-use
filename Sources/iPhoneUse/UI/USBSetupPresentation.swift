import Foundation

/// Download preparation is not installation, a mount grant, or input readiness.
enum USBSetupPresentation: Equatable {
    case inspecting, downloading(Int64, Int64), retrying, verifying
    case prepared, cancelled, failed

    var isWorking: Bool {
        switch self {
        case .inspecting, .downloading, .retrying, .verifying: true
        default: false
        }
    }
    var fraction: Double? {
        guard case let .downloading(received, total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }
}
