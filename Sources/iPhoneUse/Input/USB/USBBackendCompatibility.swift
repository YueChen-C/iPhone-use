import Foundation

/// A window can cancel an in-flight read without changing the selected route.
final class USBBackendSelectionRequest {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Eligibility only: iOS 17+ still needs the existing identity/service gates.
/// The isolated native inspection is read-only, exact-UDID bound and bounded.
enum USBBackendCompatibility {
    enum Failure: Error, CustomStringConvertible {
        case unsupported(String), unavailable
        var description: String {
            switch self {
            case .unsupported(let version): StringsUSBControl.current.requiresiOS17(version)
            case .unavailable: StringsUSBControl.current.versionUnavailable
            }
        }
    }

    static func validate(version: String) throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard version.utf8.count <= 64, (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let major = Int(parts[0]) else { throw Failure.unavailable }
        guard major >= 17 else { throw Failure.unsupported(version) }
    }

    static func require(physicalID: String) throws {
        let version: String
        do {
            guard let executable = Bundle.main.executableURL else { throw Failure.unavailable }
            let result = try DDIReviewClient(executable: executable).run(.inspect(physicalID))
            guard let object = try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any],
                  let value = object["productVersion"] as? String else { throw Failure.unavailable }
            version = value
        } catch { throw Failure.unavailable }
        try validate(version: version)
    }
}
