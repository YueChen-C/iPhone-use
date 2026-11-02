import Foundation

/// Controls whether closing the last window exits the app (`desktop`) or leaves
/// the local capture/Bluetooth/HTTP service running silently (`residentQuiet`).
enum AppRunMode: String, CaseIterable {
    case desktop
    case residentQuiet

    static let residentQuietFlag = "--resident-quiet"
    static let desktopFlag = "--desktop"

    static func parse(_ rawValue: String) -> AppRunMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case Self.desktop.rawValue:
            return .desktop
        case Self.residentQuiet.rawValue, "resident-quiet":
            return .residentQuiet
        default:
            return nil
        }
    }

    /// Explicit CLI flags override the environment for this process run, which in
    /// turn overrides persisted UserDefaults; unset or invalid values use `desktop`.
    static func resolve(
        arguments: [String] = [],
        environment: [String: String] = [:],
        persistedRawValue: String? = nil
    ) -> AppRunMode {
        var cliOverride: AppRunMode?
        for argument in arguments.dropFirst() {
            if argument == Self.residentQuietFlag {
                cliOverride = .residentQuiet
            } else if argument == Self.desktopFlag {
                cliOverride = .desktop
            }
        }
        if let cliOverride { return cliOverride }
        if let envRaw = environment[AppRunModeStore.environmentKey],
            let envMode = parse(envRaw)
        {
            return envMode
        }
        if let persistedRawValue, let persistedMode = parse(persistedRawValue) {
            return persistedMode
        }
        return .desktop
    }
}

/// Thread-safe run-mode store for the GUI/HTTP process. Startup CLI or environment
/// overrides apply only in memory; explicit menu changes persist to UserDefaults.
final class AppRunModeStore {
    static let shared = AppRunModeStore()
    static let didChangeNotification = Notification.Name("AppRunModeStore.didChange")
    static let defaultsKey = "IPHONE_USE_RUN_MODE"
    static let environmentKey = "IPHONE_USE_RUN_MODE"

    private let lock = NSLock()
    private var current: AppRunMode
    private let defaults: UserDefaults
    private let persistHook: ((AppRunMode) -> Void)?

    var mode: AppRunMode { lock.withLock { current } }

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistHook: ((AppRunMode) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.persistHook = persistHook
        current = AppRunMode.resolve(
            arguments: arguments,
            environment: environment,
            persistedRawValue: defaults.string(forKey: Self.defaultsKey))
    }

    /// Atomically persists an explicit user choice and updates in-memory state;
    /// notifies observers outside the lock only on actual transitions.
    func set(_ mode: AppRunMode) {
        let changed = lock.withLock { () -> Bool in
            defaults.set(mode.rawValue, forKey: Self.defaultsKey)
            persistHook?(mode)
            guard current != mode else { return false }
            current = mode
            return true
        }
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
