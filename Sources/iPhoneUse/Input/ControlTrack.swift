import Foundation

enum ControlTrackMode: String, Codable, CaseIterable {
    case standard = "standard"
    case enhanced = "enhanced"
    case auto = "auto"

    static func parse(_ raw: String?) -> ControlTrackMode? {
        guard let raw = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "standard", "retail", "std": return .standard
        case "enhanced", "developer", "dev", "poki": return .enhanced
        case "auto", "dual", "automatic": return .auto
        default: return nil
        }
    }
}

enum ControlTrackState: String, Codable {
    case standardActive = "standard"
    case enhancedActive = "enhanced"
    case degradedToStandard = "degraded"
    case unavailable = "unavailable"
}

struct TrackStatus: Codable {
    let mode: ControlTrackMode
    let state: ControlTrackState
    let enhancedAvailable: Bool
    let degradationReason: String?

    init(
        mode: ControlTrackMode,
        state: ControlTrackState,
        enhancedAvailable: Bool,
        degradationReason: String? = nil
    ) {
        self.mode = mode
        self.state = state
        self.enhancedAvailable = enhancedAvailable
        self.degradationReason = degradationReason
    }

    var json: [String: Any] {
        var dict: [String: Any] = [
            "mode": mode.rawValue,
            "state": state.rawValue,
            "enhanced_available": enhancedAvailable,
        ]
        if let degradationReason {
            dict["degradation_reason"] = degradationReason
        }
        return dict
    }
}

final class EnhancedBridgeProcess {
    static let shared = EnhancedBridgeProcess()

    private let lock = NSLock()
    private var cachedBinaryURL: URL?

    init() {}

    func binaryURL() -> URL? {
        lock.withLock {
            if let cached = cachedBinaryURL, FileManager.default.isExecutableFile(atPath: cached.path) {
                return cached
            }
            if let customPath = ProcessInfo.processInfo.environment["POKI_NATIVE_PATH"],
               FileManager.default.isExecutableFile(atPath: customPath) {
                let url = URL(fileURLWithPath: customPath)
                cachedBinaryURL = url
                return url
            }
            let candidates = [
                Bundle.main.bundleURL.appendingPathComponent("bin/poki-native").path,
                Bundle.main.bundleURL.appendingPathComponent("poki-native").path,
                FileManager.default.currentDirectoryPath + "/bin/poki-native",
                FileManager.default.currentDirectoryPath + "/poki-native",
                "/usr/local/bin/poki-native",
                "/opt/homebrew/bin/poki-native",
            ]
            for candidate in candidates {
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    let url = URL(fileURLWithPath: candidate)
                    cachedBinaryURL = url
                    return url
                }
            }
            return nil
        }
    }

    var isAvailable: Bool {
        binaryURL() != nil
    }

    func run(
        udid: String,
        request: [String: Any],
        timeout: TimeInterval = 30
    ) throws -> [String: Any] {
        guard let executable = binaryURL() else {
            throw DeviceError("Enhanced native bridge (poki-native) binary not found.")
        }
        let inputData = try JSONSerialization.data(withJSONObject: request, options: [])
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--udid", udid]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            throw DeviceError("Failed to launch enhanced bridge process: \(error.localizedDescription)")
        }

        try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
        try stdinPipe.fileHandleForWriting.close()

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if process.isRunning { process.terminate() }
            _ = semaphore.wait(timeout: .now() + 1.0)
            throw DeviceError("Enhanced bridge timed out after \(timeout)s.")
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            if let errObj = (try? JSONSerialization.jsonObject(with: errData)) as? [String: Any],
               let errMsg = errObj["error"] as? String {
                throw DeviceError("Enhanced bridge error: \(errMsg)")
            }
            let errString = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !errString.isEmpty {
                throw DeviceError("Enhanced bridge failed with exit code \(process.terminationStatus): \(errString)")
            }
            throw DeviceError("Enhanced bridge failed with exit code \(process.terminationStatus)")
        }

        guard let json = (try? JSONSerialization.jsonObject(with: outData)) as? [String: Any] else {
            let outString = String(decoding: outData, as: UTF8.self)
            throw DeviceError("Enhanced bridge output was not valid JSON: \(outString)")
        }
        return json
    }
}

final class EnhancedInputDriver {
    let udid: String
    private let bridge: EnhancedBridgeProcess

    init(udid: String, bridge: EnhancedBridgeProcess = .shared) {
        self.udid = udid
        self.bridge = bridge
    }

    var isAvailable: Bool {
        bridge.isAvailable
    }

    func checkReadiness() -> Bool {
        guard bridge.isAvailable else { return false }
        do {
            _ = try bridge.run(udid: udid, request: ["op": "display_info"], timeout: 4)
            return true
        } catch {
            return false
        }
    }

    func normalize(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double
    ) throws -> (Int, Int) {
        guard screenWidth > 1, screenHeight > 1 else {
            throw DeviceError("Invalid screen dimensions for enhanced input coordinate normalization.")
        }
        let fracX: Double
        let fracY: Double
        if x >= 0.0, x <= 1.0, y >= 0.0, y <= 1.0 {
            fracX = x
            fracY = y
        } else {
            fracX = max(0, min(1.0, x / (screenWidth - 1)))
            fracY = max(0, min(1.0, y / (screenHeight - 1)))
        }
        let normX = Int(round(fracX * 65535.0))
        let normY = Int(round(fracY * 65535.0))
        return (normX, normY)
    }

    func tap(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double,
        durationMs: Int = 50
    ) throws {
        let (nx, ny) = try normalize(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        _ = try bridge.run(
            udid: udid,
            request: ["op": "tap", "x": nx, "y": ny, "duration_ms": durationMs]
        )
    }

    func doubleTap(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double,
        durationMs: Int = 50
    ) throws {
        let (nx, ny) = try normalize(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        _ = try bridge.run(
            udid: udid,
            request: ["op": "double_tap", "x": nx, "y": ny, "duration_ms": durationMs]
        )
    }

    func hold(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double,
        durationMs: Int = 600
    ) throws {
        let (nx, ny) = try normalize(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        _ = try bridge.run(
            udid: udid,
            request: ["op": "long_press", "x": nx, "y": ny, "duration_ms": durationMs]
        )
    }

    func swipe(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        screenWidth: Double,
        screenHeight: Double,
        durationMs: Int = 500
    ) throws {
        let (x1, y1) = try normalize(x: fromX, y: fromY, screenWidth: screenWidth, screenHeight: screenHeight)
        let (x2, y2) = try normalize(x: toX, y: toY, screenWidth: screenWidth, screenHeight: screenHeight)
        _ = try bridge.run(
            udid: udid,
            request: [
                "op": "drag",
                "x1": x1, "y1": y1,
                "x2": x2, "y2": y2,
                "duration_ms": durationMs,
            ]
        )
    }

    func type(
        text: String,
        clear: Bool = false,
        submit: Bool = false,
        target: [String: Any]? = nil
    ) throws {
        var req: [String: Any] = [
            "op": "type_text",
            "text": text,
            "clear": clear,
            "submit": submit,
        ]
        if let target {
            req["target"] = target
        }
        _ = try bridge.run(udid: udid, request: req)
    }

    func key(
        name: String,
        modifiers: [String] = [],
        count: Int = 1
    ) throws {
        _ = try bridge.run(
            udid: udid,
            request: [
                "op": "key",
                "key": name,
                "modifiers": modifiers,
                "count": count,
            ]
        )
    }

    func button(
        name: String,
        count: Int = 1
    ) throws {
        _ = try bridge.run(
            udid: udid,
            request: [
                "op": "button",
                "button": name,
                "count": count,
            ]
        )
    }

    func inspectHierarchy(includeOffscreen: Bool = false) throws -> [String: Any] {
        return try bridge.run(
            udid: udid,
            request: ["op": "ax_tree", "include_offscreen": includeOffscreen],
            timeout: 25
        )
    }
}

final class DualTrackInputCoordinator {
    let udid: String
    let enhancedDriver: EnhancedInputDriver
    let standardInputResolver: () throws -> DeviceInput

    private let lock = NSLock()
    private var _mode: ControlTrackMode
    private var _state: ControlTrackState
    private var _degradationReason: String?

    init(
        udid: String,
        mode: ControlTrackMode = .auto,
        enhancedDriver: EnhancedInputDriver? = nil,
        standardInputResolver: @escaping () throws -> DeviceInput
    ) {
        self.udid = udid
        self._mode = mode
        self.enhancedDriver = enhancedDriver ?? EnhancedInputDriver(udid: udid)
        self.standardInputResolver = standardInputResolver
        if mode == .enhanced {
            self._state = .enhancedActive
        } else if mode == .standard {
            self._state = .standardActive
        } else {
            self._state = .enhancedActive
        }
    }

    var mode: ControlTrackMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    var state: ControlTrackState {
        lock.withLock { _state }
    }

    var degradationReason: String? {
        lock.withLock { _degradationReason }
    }

    var status: TrackStatus {
        lock.withLock {
            TrackStatus(
                mode: _mode,
                state: _state,
                enhancedAvailable: enhancedDriver.isAvailable,
                degradationReason: _degradationReason
            )
        }
    }

    func switchMode(_ target: ControlTrackMode) {
        lock.withLock {
            _mode = target
            switch target {
            case .standard:
                _state = .standardActive
                _degradationReason = nil
            case .enhanced:
                _state = .enhancedActive
                _degradationReason = nil
            case .auto:
                _state = .enhancedActive
                _degradationReason = nil
            }
        }
    }

    private func executeWithFallback<T>(
        actionName: String,
        enhanced: () throws -> T,
        standard: (DeviceInput) throws -> T
    ) throws -> T {
        let currentMode = mode
        let currentState = state

        if currentMode == .standard {
            let stdInput = try standardInputResolver()
            lock.withLock { _state = .standardActive }
            return try standard(stdInput)
        }

        if currentMode == .enhanced {
            lock.withLock { _state = .enhancedActive }
            return try enhanced()
        }

        // Mode is auto
        if currentState != .degradedToStandard && enhancedDriver.isAvailable {
            do {
                let result = try enhanced()
                lock.withLock { _state = .enhancedActive }
                return result
            } catch {
                let reason = "Enhanced track failed on \(actionName): \(error.localizedDescription). Degraded to standard track."
                lock.withLock {
                    _state = .degradedToStandard
                    _degradationReason = reason
                }
                let stdInput = try standardInputResolver()
                return try standard(stdInput)
            }
        } else {
            let stdInput = try standardInputResolver()
            lock.withLock { _state = .degradedToStandard }
            return try standard(stdInput)
        }
    }

    private func toFractions(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> (Double, Double) {
        if x >= 0.0, x <= 1.0, y >= 0.0, y <= 1.0 {
            return (x, y)
        }
        guard screenWidth > 1, screenHeight > 1 else {
            return (max(0, min(1, x)), max(0, min(1, y)))
        }
        return (
            max(0, min(1.0, x / (screenWidth - 1))),
            max(0, min(1.0, y / (screenHeight - 1)))
        )
    }

    func tap(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double,
        hold: TimeInterval = 0.08
    ) throws {
        let (fx, fy) = toFractions(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        try executeWithFallback(
            actionName: "tap",
            enhanced: {
                try enhancedDriver.tap(
                    x: fx, y: fy,
                    screenWidth: screenWidth, screenHeight: screenHeight,
                    durationMs: Int(hold * 1000)
                )
            },
            standard: { std in
                try std.tap(x: fx, y: fy, hold: hold)
            }
        )
    }

    func doubleTap(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double,
        hold: TimeInterval = 0.22,
        gap: TimeInterval = 0.12
    ) throws {
        let (fx, fy) = toFractions(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        try executeWithFallback(
            actionName: "doubleTap",
            enhanced: {
                try enhancedDriver.doubleTap(
                    x: fx, y: fy,
                    screenWidth: screenWidth, screenHeight: screenHeight,
                    durationMs: Int(hold * 1000)
                )
            },
            standard: { std in
                try std.doubleTap(x: fx, y: fy, hold: hold, gap: gap)
            }
        )
    }

    func tripleTap(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double,
        hold: TimeInterval = 0.22,
        gap: TimeInterval = 0.12
    ) throws {
        let (fx, fy) = toFractions(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        try executeWithFallback(
            actionName: "tripleTap",
            enhanced: {
                try enhancedDriver.tap(x: fx, y: fy, screenWidth: screenWidth, screenHeight: screenHeight, durationMs: Int(hold * 1000))
                Thread.sleep(forTimeInterval: gap)
                try enhancedDriver.tap(x: fx, y: fy, screenWidth: screenWidth, screenHeight: screenHeight, durationMs: Int(hold * 1000))
                Thread.sleep(forTimeInterval: gap)
                try enhancedDriver.tap(x: fx, y: fy, screenWidth: screenWidth, screenHeight: screenHeight, durationMs: Int(hold * 1000))
            },
            standard: { std in
                try std.tripleTap(x: fx, y: fy, hold: hold, gap: gap)
            }
        )
    }

    func hold(
        x: Double,
        y: Double,
        screenWidth: Double,
        screenHeight: Double,
        duration: TimeInterval = 1.0
    ) throws {
        let (fx, fy) = toFractions(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        try executeWithFallback(
            actionName: "hold",
            enhanced: {
                try enhancedDriver.hold(
                    x: fx, y: fy,
                    screenWidth: screenWidth, screenHeight: screenHeight,
                    durationMs: Int(duration * 1000)
                )
            },
            standard: { std in
                try std.hold(x: fx, y: fy, duration: duration)
            }
        )
    }

    func swipe(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        screenWidth: Double,
        screenHeight: Double,
        duration: TimeInterval = 0.5
    ) throws {
        let (fx1, fy1) = toFractions(x: fromX, y: fromY, screenWidth: screenWidth, screenHeight: screenHeight)
        let (fx2, fy2) = toFractions(x: toX, y: toY, screenWidth: screenWidth, screenHeight: screenHeight)
        try executeWithFallback(
            actionName: "swipe",
            enhanced: {
                try enhancedDriver.swipe(
                    fromX: fx1, fromY: fy1,
                    toX: fx2, toY: fy2,
                    screenWidth: screenWidth, screenHeight: screenHeight,
                    durationMs: Int(duration * 1000)
                )
            },
            standard: { std in
                try std.swipe(points: [(fx1, fy1), (fx2, fy2)], duration: duration)
            }
        )
    }

    func type(
        text: String,
        clear: Bool = false,
        submit: Bool = false
    ) throws {
        try executeWithFallback(
            actionName: "type",
            enhanced: {
                try enhancedDriver.type(text: text, clear: clear, submit: submit)
            },
            standard: { std in
                try std.type(text)
            }
        )
    }

    func key(
        name: String,
        modifiers: [String] = []
    ) throws {
        try executeWithFallback(
            actionName: "key",
            enhanced: {
                try enhancedDriver.key(name: name, modifiers: modifiers)
            },
            standard: { std in
                try std.key(name, modifiers: modifiers)
            }
        )
    }

    func button(name: String) throws {
        try executeWithFallback(
            actionName: "button",
            enhanced: {
                try enhancedDriver.button(name: name)
            },
            standard: { std in
                if name == "home" {
                    std.consumer(0x0040)
                } else {
                    throw DeviceError("Button '\(name)' not supported on standard track.")
                }
            }
        )
    }

    func getAXTree(includeOffscreen: Bool = false) throws -> [String: Any] {
        if mode == .standard {
            throw DeviceError("AX Tree inspection is disabled in standard mode to preserve retail channel isolation.")
        }
        if !enhancedDriver.isAvailable {
            throw DeviceError("AX Tree inspection requires enhanced track with Developer Mode.")
        }
        return try enhancedDriver.inspectHierarchy(includeOffscreen: includeOffscreen)
    }
}
