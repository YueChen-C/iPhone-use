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
        case unsupported(String), unavailable, inspection(String)
        var description: String {
            switch self {
            case .unsupported(let version): StringsUSBControl.current.requiresiOS17(version)
            case .unavailable: StringsUSBControl.current.versionUnavailable
            case .inspection(let diagnostic): StringsUSBControl.current.versionUnavailable + "\n" + diagnostic
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
        try validate(version: version(physicalID: physicalID))
    }

    /// Keep the original child/transport diagnostic. A read failure does not
    /// establish a DDI, trust or Developer Mode fault.
    static func version(physicalID: String, inspect: (String) throws -> String = inspectVersion) throws -> String {
        do {
            let json = try inspect(physicalID)
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let value = object["productVersion"] as? String else { throw Failure.unavailable }
            return value
        } catch let error as Failure { throw error }
        catch { throw Failure.inspection(String(describing: error)) }
    }

    private static func inspectVersion(physicalID: String) throws -> String {
        guard let executable = Bundle.main.executableURL else { throw Failure.unavailable }
        return try DDIReviewClient(executable: executable).run(.inspect(physicalID)).json
    }
}
