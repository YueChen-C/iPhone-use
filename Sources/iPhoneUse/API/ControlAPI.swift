import AVFoundation
import CoreFoundation
import Foundation

/// The HTTP API. Every route takes an optional `device` (id or name), required only when
/// more than one phone is plugged in. Tap and swipe coordinates are pixels of the full
/// screen, or of a resized screenshot when `width`/`height` or `maxEdge` say so.
enum ControlAPI {
    /// Only absolute pointer actions require a calibrated, subscribed mouse.
    private enum Action: String {
        case tap = "/tap"
        case swipe = "/swipe"
        case move = "/move"
        case nudge = "/nudge"
        case type = "/type"
        case key = "/key"
        case home = "/home"
        case power = "/power"

        var requiresPointer: Bool {
            switch self {
            case .tap, .swipe, .move: true
            case .nudge, .type, .key, .home, .power: false
            }
        }
    }

    static func handle(_ request: HTTPRequest) -> HTTPResponse {
        handle(request, ocrCapture: captureTextScreen, ocrTap: tapTextPoint)
    }

    static func handle(
        _ request: HTTPRequest,
        ocrCapture: (String?, Int?) throws -> (String, Data),
        ocrTap: (String, Double, Double, Double) throws -> Void = tapTextPoint,
        activity: QuietModeActivityController = .shared
    ) -> HTTPResponse {
        let passive = request.method == "GET" && request.query["wake"] == "0"
        let wasSuspended = passive ? false : activity.requestStarted()
        defer { if !passive { activity.requestFinished() } }
        let body = request.body
        // A body selector takes precedence over the query-string selector.
        let deviceQuery = deviceSelector(body: body, query: request.query)
        if !passive {
            waitForWake(
                request: request, deviceQuery: deviceQuery,
                wasSuspended: wasSuspended || activity.isWithinWakeGraceWindow)
        }
        do {
            switch (request.method, request.path) {
            case ("GET", "/viewer"), ("GET", "/viewer/"):
                return WebPreview.response(for: viewerLanguage(request.query))
            case ("GET", "/config"):
                return .json(["language": AppLanguageStore.shared.language.rawValue])
            case ("GET", "/"), ("GET", "/status"):
                return status()
            case ("GET", "/devices"):
                return deviceList()
            case ("POST", "/match"):
                return match(body)
            case ("POST", "/pair"):
                return try pair(body, deviceQuery: deviceQuery)
            case ("POST", "/calibration/reload"):
                try DeviceRegistry.shared.reloadCalibration(for: DeviceRegistry.shared.find(deviceQuery))
                return status()
            case ("POST", "/calibration/auto"):
                let devices =
                    try deviceQuery.map { [try DeviceRegistry.shared.find($0)] }
                    ?? DeviceRegistry.shared.all()
                for device in devices {
                    DeviceRegistry.shared.automaticallyCalibrate(
                        device, retry: true, verifyOnly: (body["verifyOnly"] as? Bool) ?? false)
                }
                return status()
            case ("GET", "/ocr"), ("POST", "/ocr"):
                var options: [String: Any] = request.query
                if let raw = request.query["maxEdge"] {
                    guard let value = Int(raw), value > 0 else {
                        throw DeviceError(StringsAPI.current.ocrParameterInvalid("maxEdge"))
                    }
                    options["maxEdge"] = value
                }
                options.merge(body) { _, value in value }
                let (id, data) = try ocrCapture(deviceQuery, OCRRequest.maxEdge(options))
                return .json(ScreenOCR.recognize(data, device: id).json(device: id))
            case ("POST", "/act"):
                return try ActRequest(body).perform(
                    device: try DeviceRegistry.shared.find(deviceQuery).id, capture: ocrCapture,
                    execute: { path, body, device in
                        handle(
                            HTTPRequest(
                                method: "POST", path: path, query: [:],
                                body: body.merging(
                                    device.map { ["device": $0] } ?? [:]
                                ) { _, selected in selected }),
                            ocrCapture: ocrCapture, ocrTap: ocrTap, activity: activity)
                    })
            case ("POST", "/tap_text"):
                let tap = try TextTapRequest(body)
                let (id, data) = try ocrCapture(deviceQuery, OCRRequest.maxEdge(body))
                let result = ScreenOCR.recognize(data, device: id)
                let match = try tap.match(result)
                try ocrTap(
                    id, Double(match.x) / Double(result.width), Double(match.y) / Double(result.height), tap.hold)
                return .json(["ok": true, "device": id, "text": match.text, "x": match.x, "y": match.y])
            case ("GET", "/screenshot"):
                return try screenshot(request.query, deviceQuery: deviceQuery)
            default:
                guard request.method == "POST", let action = Action(rawValue: request.path) else {
                    return .error("not found", status: 404)
                }
                return try perform(action, body: body, deviceQuery: deviceQuery)
            }
        } catch DeviceInput.InputError.pointerBusy {
            return .error("\(DeviceInput.InputError.pointerBusy)", status: 409)
        } catch {
            return .error("\(error)")
        }
    }

    final class WakeWindow {
        private let lock = NSLock()
        private var lastWakeUptime: TimeInterval = -.infinity

        func deadline(wasSuspended: Bool, now: TimeInterval) -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            if wasSuspended { lastWakeUptime = now }
            return lastWakeUptime + 6
        }
    }

    private static let wakeWindow = WakeWindow()

    private static func waitForWake(request: HTTPRequest, deviceQuery: String?, wasSuspended: Bool) {
        let deadline = wakeWindow.deadline(wasSuspended: wasSuspended, now: ProcessInfo.processInfo.systemUptime)
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        let screenPaths: Set<String> = ["/devices", "/status", "/", "/screenshot", "/ocr"]
        let controlPaths: Set<String> = [
            "/move", "/tap", "/tap_text", "/swipe", "/type", "/key", "/home", "/power", "/nudge", "/act",
        ]
        guard screenPaths.contains(request.path) || controlPaths.contains(request.path) else { return }
        waitUntilReady(deadline: deadline) {
            if let target = try? DeviceRegistry.shared.find(deviceQuery) {
                let frameReady = ScreenCaptureManager.shared.all.contains {
                    $0.id == target.screen.id && $0.size != nil
                }
                guard controlPaths.contains(request.path) else { return frameReady }
                return frameReady && target.host != nil
                    && (try? DeviceRegistry.shared.input(for: target).isPointerReady) == true
            }
            return deviceQuery == nil && !controlPaths.contains(request.path)
                && !ScreenCaptureManager.shared.all.isEmpty
                && ScreenCaptureManager.shared.all.allSatisfy { $0.size != nil }
        }
    }

    static func waitUntilReady(
        deadline: TimeInterval, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        ready: () -> Bool
    ) {
        var elapsed = now()
        while elapsed < deadline {
            if ready() { return }
            let delay = min(0.05, deadline - elapsed)
            sleep(delay)
            elapsed = max(elapsed + delay, now())
        }
    }

    /// Body selectors retain precedence; the original name wins within each source.
    static func deviceSelector(body: [String: Any], query: [String: String]) -> String? {
        (body["device"] as? String) ?? (body["device_id"] as? String) ?? query["device"] ?? query["device_id"]
    }

    /// The viewer follows the app's language unless ?lang=zh|en pins one. Invalid
    /// values fall back to the current language rather than 404-ing the page.
    private static func viewerLanguage(_ query: [String: String]) -> AppLanguage {
        AppLanguage(rawValue: query["lang"] ?? "") ?? AppLanguageStore.shared.language
    }

    private static func status() -> HTTPResponse {
        // Bluetooth detail is keyed by host so a phone's subscriptions and
        // pairing can be checked together when input goes to the wrong device.
        var screenByHost: [UUID: [String: Any]] = [:]
        for device in DeviceRegistry.shared.all() {
            if let host = device.host {
                screenByHost[host] = ["id": device.id, "name": device.screen.name]
            }
        }
        let hosts = HIDPeripheral.shared.hostDetails.map { detail -> [String: Any] in
            var info: [String: Any] = [
                "host": detail.host.uuidString,
                "subscribed": detail.channels,
            ]
            if let session = detail.session { info["session"] = session.uuidString }
            if let screen = screenByHost[detail.host] { info["screen"] = screen }
            return info
        }
        return .json([
            "bluetooth": HIDPeripheral.shared.state,
            "bluetoothHosts": hosts,
            "capture": captureStatus(),
            "devices": DeviceRegistry.shared.status(),
            "unmatchedHosts": DeviceRegistry.shared.unmatchedHosts().map(\.uuidString),
        ])
    }

    private static func deviceList() -> HTTPResponse {
        .json(["capture": captureStatus(), "devices": DeviceRegistry.shared.all().map(\.json)])
    }

    /// Nominal acquisition UIDs can differ from independently verified physical
    /// USB identities. Expose both while identity checks are pending or fail too.
    private static func captureStatus() -> [String: Any] {
        let manager = ScreenCaptureManager.shared
        return [
            "idleSuspended": QuietModeActivityController.shared.isSuspended,
            "identityState": manager.identityState.rawValue,
            "permitsPointerAssociation": manager.permitsPointerAssociation,
            "screens": manager.all.map { screen -> [String: Any] in
                var info: [String: Any] = [
                    "physicalID": screen.id,
                    "sourceID": screen.sourceID,
                    "identityVerified": manager.identityVerified(for: screen),
                    "permitsPointerAssociation": manager.permitsPointerAssociation(for: screen),
                ]
                if let error = screen.captureError {
                    info["captureError"] = error
                }
                return info
            },
        ]
    }

    private static func match(_ body: [String: Any]) -> HTTPResponse {
        let found = DeviceRegistry.shared.match(
            force: (body["force"] as? Bool) ?? false, probe: (body["probe"] as? Bool) ?? false)
        return .json([
            "capture": captureStatus(),
            "matched": found.mapValues(\.uuidString),
            "devices": DeviceRegistry.shared.all().map(\.json),
            "unmatchedHosts": DeviceRegistry.shared.unmatchedHosts().map(\.uuidString),
        ])
    }

    private static func pair(_ body: [String: Any], deviceQuery: String?) throws -> HTTPResponse {
        guard let hostString = body["host"] as? String, let host = UUID(uuidString: hostString) else {
            return .error(StringsAPI.current.pairHostRequired)
        }
        DeviceRegistry.shared.pair(try DeviceRegistry.shared.find(deviceQuery), host: host)
        return deviceList()
    }

    private static func screenshot(_ query: [String: String], deviceQuery: String?) throws -> HTTPResponse {
        let device = try DeviceRegistry.shared.find(deviceQuery)
        let includeOCR = query["ocr"] == "1"
        let png = query["format"] == "png" || includeOCR
        let maxWidth = query["maxWidth"].flatMap(Int.init)
        let maxEdge = query["maxEdge"].flatMap(Int.init)
        guard let size = device.screen.size,
            let data = device.screen.snapshot(png: png, maxWidth: maxWidth, maxEdge: maxEdge)
        else {
            if let error = device.screen.captureError {
                return .error(
                    StringsAPI.current.captureFailedFromDevice(device.screen.name, error), status: 503)
            }
            return .error(StringsAPI.current.noFrameFromDevice(device.screen.name), status: 503)
        }
        let image = RequestCoordinates.imageSize(size, maxWidth: maxWidth, maxEdge: maxEdge)
        var headers = [
            "X-Device": device.id,
            "X-Screen-Width": "\(Int(size.width))", "X-Screen-Height": "\(Int(size.height))",
            "X-Image-Width": "\(image.0)", "X-Image-Height": "\(image.1)",
        ]
        if includeOCR {
            // Return OCR of these exact bytes from the app's cache. The stdio process
            // must not repeat Vision work already done here by tap_text.
            let ocr = ScreenOCR.recognize(data, device: device.id)
            headers["X-Screen-OCR"] = try JSONSerialization.data(withJSONObject: ocr.json(device: device.id))
                .base64EncodedString()
        }
        return HTTPResponse(contentType: png ? "image/png" : "image/jpeg", headers: headers, body: data)
    }

    private static func captureTextScreen(_ query: String?, _ maxEdge: Int?) throws -> (String, Data) {
        let device = try DeviceRegistry.shared.find(query)
        guard let data = device.screen.snapshot(png: true, maxEdge: maxEdge) else {
            if let error = device.screen.captureError {
                throw DeviceError(StringsAPI.current.captureFailedFromDevice(device.screen.name, error))
            }
            throw DeviceError(StringsAPI.current.noFrameFromDevice(device.screen.name))
        }
        return (device.id, data)
    }

    private static func tapTextPoint(_ id: String, _ x: Double, _ y: Double, _ hold: Double) throws {
        let device = try DeviceRegistry.shared.find(id)
        DeviceRegistry.shared.cancelBackgroundMotion(for: device)
        let input = try DeviceRegistry.shared.input(for: device)
        guard input.isPointerReady else {
            input.invalidatePointerEstimate()
            throw DeviceError(StringsAPI.current.pointerNotReady)
        }
        try input.tap(x: x, y: y, hold: hold)
    }

    private static func perform(
        _ action: Action, body: [String: Any], deviceQuery: String?
    ) throws -> HTTPResponse {
        let device = try DeviceRegistry.shared.find(deviceQuery)
        // Real input takes priority over background probes and measurement.
        // Cancel before resolving/queuing input, so it cannot wait behind the
        // very measurement that the user is trying to interrupt.
        DeviceRegistry.shared.cancelBackgroundMotion(for: device)
        let input = try DeviceRegistry.shared.input(for: device)
        if action.requiresPointer, !input.isPointerReady {
            // Keep readiness ahead of parameter parsing. API callers may have no window
            // polling readiness, and a lost subscription or screen change invalidates origin.
            input.invalidatePointerEstimate()
            return .error(StringsAPI.current.pointerNotReady, status: 503)
        }

        switch action {
        case .tap:
            let (x, y) = try point(body, "x", "y", on: device)
            try input.tap(x: x, y: y, hold: (body["hold"] as? Double) ?? 0.08)
        case .swipe:
            let swipe = try SwipeRequest(body, screenSize: device.screen.size, screenName: device.screen.name)
            try input.swipe(points: swipe.points, duration: swipe.duration)
        case .move:
            let (x, y) = try point(body, "x", "y", on: device)
            try input.move(x: x, y: y)
        case .nudge:
            try input.nudge(
                dx: (body["dx"] as? Int) ?? 0, dy: (body["dy"] as? Int) ?? 0,
                click: (body["click"] as? Bool) ?? false)
        case .type:
            guard let text = body["text"] as? String else { return .error(StringsAPI.current.textRequired) }
            var parameters = body
            parameters["text"] = text
            try TypeTextRequest(parameters, language: AppLanguageStore.shared.language).perform(
                on: input,
                ocr: {
                    device.screen.snapshot(png: false, maxEdge: 1600).map { ScreenOCR.recognize($0, device: device.id) }
                })
        case .key:
            guard let key = body["key"] as? String else { return .error(StringsAPI.current.keyRequired) }
            try input.key(key, modifiers: (body["modifiers"] as? [String]) ?? [])
        case .home:
            input.consumer(0x0223)
        case .power:
            // Consumer Power is a short, state-dependent key press. Never
            // retry it automatically or claim that an accepted report locked iOS.
            input.consumer(0x0030)
        }
        return .json(["ok": true, "device": device.id])
    }

    private static func point(
        _ body: [String: Any], _ xKey: String, _ yKey: String, on device: Device
    ) throws -> (Double, Double) {
        try RequestCoordinates.point(
            body, xKey, yKey, screenSize: device.screen.size, screenName: device.screen.name)
    }
}

/// Validates the entire path before input begins. Every point uses the same
/// screenshot dimensions, so a malformed later point cannot leave a drag held.
struct SwipeRequest {
    let points: [(Double, Double)]
    let duration: TimeInterval

    init(_ body: [String: Any], screenSize: CGSize?, screenName: String) throws {
        let table = StringsAPI.current
        guard let rawPoints = body["points"] as? [[String: Any]], rawPoints.count >= 2 else {
            throw DeviceError(table.swipePointsMin)
        }
        let coordinates = try rawPoints.enumerated().map { index, point in
            guard let x = Self.finiteNumber(point["x"]), let y = Self.finiteNumber(point["y"]) else {
                throw DeviceError(table.swipePointFinite(index))
            }
            return (x, y)
        }

        if let rawDuration = body["duration"] {
            guard let value = Self.finiteNumber(rawDuration), value > 0 else {
                throw DeviceError(table.swipeDurationInvalid)
            }
            duration = value
        } else {
            duration = 0.3
        }

        // Preserve the existing scaling rules, while rejecting invalid sizes
        // before maxEdge conversion or division can produce an unusable path.
        if (body["fraction"] as? Bool) != true {
            for key in ["width", "height", "maxEdge"] {
                guard let rawValue = body[key] else { continue }
                guard let value = Self.finiteNumber(rawValue), value > 0 else {
                    throw DeviceError(table.swipeSizeKeyInvalid(key))
                }
                if key == "maxEdge", value < 1 || value >= Double(Int.max) {
                    throw DeviceError(table.swipeMaxEdgeRange)
                }
            }
        }

        var coordinateBody = body
        coordinateBody.removeValue(forKey: "points")
        points = try coordinates.map { x, y in
            coordinateBody["x"] = x
            coordinateBody["y"] = y
            let point = try RequestCoordinates.point(
                coordinateBody, "x", "y", screenSize: screenSize, screenName: screenName)
            guard point.0.isFinite, point.1.isFinite else {
                throw DeviceError(table.swipeInvalidDimensions)
            }
            return point
        }
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        // JSON booleans bridge to NSNumber too; they are not coordinates or durations.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }
}

/// Coordinate rules shared by the HTTP action and screenshot endpoints.
/// This layer preserves the API's permissive numeric input; DeviceInput applies pointer limits.
enum RequestCoordinates {
    static func imageSize(_ size: CGSize, maxWidth: Int?, maxEdge: Int?) -> (Int, Int) {
        var scale = 1.0
        if let maxWidth { scale = min(scale, Double(maxWidth) / size.width) }
        if let maxEdge { scale = min(scale, Double(maxEdge) / max(size.width, size.height)) }
        return (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    /// Converts screenshot pixels to screen fractions. Explicit dimensions override
    /// maxEdge-derived dimensions independently. Fraction input does not need a frame.
    static func point(
        _ body: [String: Any], _ xKey: String, _ yKey: String,
        screenSize: @autoclosure () -> CGSize?, screenName: @autoclosure () -> String
    ) throws -> (Double, Double) {
        guard let x = number(body[xKey]), let y = number(body[yKey]) else {
            throw DeviceError(StringsAPI.current.coordinatesRequired(xKey, yKey))
        }
        if (body["fraction"] as? Bool) == true { return (x, y) }
        // Evaluate the capture state only after coordinate validation, as on the API path.
        guard let size = screenSize() else { throw DeviceError(StringsAPI.current.noFrameFromScreen(screenName())) }
        var width = Double(size.width)
        var height = Double(size.height)
        if let maxEdge = number(body["maxEdge"]).map(Int.init) {
            let image = imageSize(size, maxWidth: nil, maxEdge: maxEdge)
            width = Double(image.0)
            height = Double(image.1)
        }
        width = number(body["width"]) ?? width
        height = number(body["height"]) ?? height
        return (x / width, y / height)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// Validate OCR dimensions before the capture pipeline converts them to integers.
enum OCRRequest {
    static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue.isFinite
        else { return nil }
        return value.doubleValue
    }

    static func maxEdge(_ body: [String: Any], table: StringsAPI = .current) throws -> Int? {
        guard let raw = body["maxEdge"] else { return nil }
        guard let value = number(raw), value >= 1, value < Double(Int.max), value.rounded() == value else {
            throw DeviceError(table.ocrParameterInvalid("maxEdge"))
        }
        return Int(value)
    }
}

struct TextTapRequest {
    let text: String
    let exact: Bool
    let index: Int
    let hold: Double

    init(_ body: [String: Any], table: StringsAPI = .current) throws {
        guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceError(table.ocrParameterInvalid("text"))
        }
        self.text = text
        if let raw = body["exact"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw DeviceError(table.ocrParameterInvalid("exact"))
            }
            exact = value.boolValue
        } else {
            exact = false
        }
        if let raw = body["index"] {
            guard let value = OCRRequest.number(raw), value >= 0, value < Double(Int.max), value.rounded() == value
            else {
                throw DeviceError(table.ocrParameterInvalid("index"))
            }
            index = Int(value)
        } else {
            index = 0
        }
        if let raw = body["hold"] {
            guard let value = OCRRequest.number(raw), value >= 0, value <= 60 else {
                throw DeviceError(table.ocrParameterInvalid("hold"))
            }
            hold = value
        } else {
            hold = 0.08
        }
    }

    func match(_ result: ScreenOCR.Result) throws -> ScreenOCR.Item {
        let matches = result.items.filter {
            exact ? $0.text == text : $0.text.range(of: text, options: .caseInsensitive) != nil
        }
        guard result.width > 0, result.height > 0, index < matches.count else {
            throw DeviceError(StringsAPI.current.ocrTextNotFound)
        }
        return matches[index]
    }
}

/// A bounded, fully validated batch. A failed step stops the batch without replay.
struct ActRequest {
    let steps: [[String: Any]]

    init(_ body: [String: Any]) throws {
        guard let steps = body["steps"] as? [[String: Any]], (1...16).contains(steps.count) else {
            throw DeviceError("steps must contain 1...16 actions")
        }
        var waitBudget = 0.0
        for step in steps {
            guard let type = step["type"] as? String,
                ["tap", "tap_text", "swipe", "type", "key", "home", "delay", "wait_text"].contains(type),
                step["device"] == nil, step["device_id"] == nil
            else { throw DeviceError("Invalid act step or nested device selector") }
            _ = try OCRRequest.maxEdge(step)
            if let fraction = step["fraction"], !TextEntry.isBoolean(fraction) {
                throw DeviceError("fraction must be a boolean")
            }
            for key in ["width", "height"] where step[key] != nil {
                guard let value = OCRRequest.number(step[key]), value > 0 else {
                    throw DeviceError("Invalid coordinate dimensions")
                }
            }
            switch type {
            case "type": _ = try TypeTextRequest(step)
            case "tap_text", "wait_text":
                _ = try TextTapRequest(step)
                _ = try OCRRequest.maxEdge(step)
            case "tap":
                let point = try RequestCoordinates.point(
                    step, "x", "y", screenSize: CGSize(width: 1, height: 1), screenName: "")
                guard point.0.isFinite, point.1.isFinite else { throw DeviceError("Invalid tap dimensions") }
                guard OCRRequest.number(step["x"]) != nil, OCRRequest.number(step["y"]) != nil else {
                    throw DeviceError("tap coordinates must be finite numbers")
                }
                _ = try TextTapRequest(step.merging(["text": "tap"]) { _, value in value })
            case "swipe":
                _ = try SwipeRequest(step, screenSize: CGSize(width: 1, height: 1), screenName: "")
            case "key":
                guard let key = step["key"] as? String,
                    KeyboardMap.named[key.lowercased()] != nil || key.count == 1,
                    KeyboardMap.code(for: key) != nil,
                    step["modifiers"] == nil || step["modifiers"] is [String],
                    KeyboardMap.modifierMask(for: step["modifiers"] as? [String] ?? []) != nil
                else { throw DeviceError("Invalid key or modifiers") }
            default: break
            }
            if type == "delay" || type == "wait_text" {
                let raw = step[type == "delay" ? "seconds" : "timeout"] ?? (type == "delay" ? 0 : 6)
                guard let seconds = OCRRequest.number(raw), (0...6).contains(seconds) else {
                    throw DeviceError("delay/timeout must be in 0...6 seconds")
                }
                waitBudget += seconds
            }
        }
        guard waitBudget <= 30 else { throw DeviceError("act wait budget exceeds 30 seconds") }
        self.steps = steps
    }

    func perform(
        device: String?, capture: (String?, Int?) throws -> (String, Data),
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        execute: (String, [String: Any], String?) throws -> HTTPResponse
    ) throws -> HTTPResponse {
        for (index, step) in steps.enumerated() {
            do {
                let type = step["type"] as! String
                if type == "delay" {
                    sleep((step["seconds"] as? NSNumber)?.doubleValue ?? 0)
                } else if type == "wait_text" {
                    let match = try TextTapRequest(step)
                    let timeout = (step["timeout"] as? NSNumber)?.doubleValue ?? 6
                    let start = now()
                    var elapsed = 0.0
                    while true {
                        let (id, data) = try capture(device, OCRRequest.maxEdge(step))
                        if (try? match.match(ScreenOCR.recognize(data, device: id))) != nil { break }
                        elapsed = max(elapsed, now() - start)
                        guard elapsed < timeout else { throw DeviceError("wait_text timed out") }
                        let delay = min(0.1, timeout - elapsed)
                        sleep(delay)
                        elapsed += delay
                    }
                } else {
                    let response = try execute("/" + type, step, device)
                    if response.status != 200 {
                        return .json(
                            [
                                "ok": false, "failed_step": index + 1, "completed": index,
                                "error": String(decoding: response.body, as: UTF8.self),
                            ], status: response.status)
                    }
                }
            } catch {
                return .json(
                    ["ok": false, "failed_step": index + 1, "completed": index, "error": "\(error)"], status: 400)
            }
        }
        return .json(["ok": true, "completed": steps.count])
    }
}
