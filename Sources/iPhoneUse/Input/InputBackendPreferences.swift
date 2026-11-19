import Foundation

/// Only an explicit, accepted transport choice is stored. Readiness, failures,
/// launch overrides and discovered defaults must never overwrite a user choice.
final class InputBackendPreferences {
    static let shared = InputBackendPreferences(defaults: .standard)
    static let defaultsKey = "IPHONE_USE_INPUT_BACKENDS"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> [String: InputBackendKind] {
        lock.withLock { read() }
    }

    func save(_ backend: InputBackendKind, physicalID: String) {
        guard (try? NativeDDIInspection.validateIdentity(physicalID)) != nil else { return }
        lock.withLock {
            var values = read()
            values[physicalID] = backend
            defaults.set(values.mapValues(\.rawValue), forKey: Self.defaultsKey)
        }
    }

    private func read() -> [String: InputBackendKind] {
        guard let values = defaults.dictionary(forKey: Self.defaultsKey) else { return [:] }
        var result: [String: InputBackendKind] = [:]
        for (id, value) in values {
            guard (try? NativeDDIInspection.validateIdentity(id)) != nil,
                let value = value as? String, let backend = InputBackendKind(rawValue: value) else { continue }
            result[id] = backend
        }
        return result
    }
}
