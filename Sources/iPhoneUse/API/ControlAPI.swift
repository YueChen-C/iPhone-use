import CoreFoundation
import Foundation

/// The HTTP API. Every route takes an optional `device` (id or name), required only when
/// more than one phone is plugged in. Tap and swipe coordinates are pixels of the full
/// screen, or of a resized screenshot when `width`/`height` or `maxEdge` say so.
enum ControlAPI {
    /// Coordinate actions use their existing mapping, or observed USB feedback.
    enum Action: String {
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
        let body = request.body
        // A body selector takes precedence over the query-string selector.
        let deviceQuery = (body["device"] as? String) ?? request.query["device"]
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
        let png = query["format"] == "png"
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
        return HTTPResponse(
            contentType: png ? "image/png" : "image/jpeg",
            headers: [
                "X-Device": device.id,
                "X-Screen-Width": "\(Int(size.width))", "X-Screen-Height": "\(Int(size.height))",
                "X-Image-Width": "\(image.0)", "X-Image-Height": "\(image.1)",
            ],
            body: data)
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
        switch action {
        case .tap, .swipe, .move:
            let failure = try performPointerAction(
                action, body: body, input: input, screenSize: device.screen.size, screenName: device.screen.name,
                capture: { after, notBefore in
                    guard ScreenCaptureManager.shared.isCurrent(device.screen),
                        ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen)
                    else { throw DeviceError("USB capture identity changed") }
                    return try device.screen.pointerFrame(after: after, notBefore: notBefore)
                })
            if let failure { return failure }
        case .nudge:
            try input.nudge(
                dx: (body["dx"] as? Int) ?? 0, dy: (body["dy"] as? Int) ?? 0,
                click: (body["click"] as? Bool) ?? false)
        case .type:
            guard let text = body["text"] as? String else { return .error(StringsAPI.current.textRequired) }
            try input.type(text)
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

    /// Executes the same coordinate path used by HTTP, independent of discovery.
    /// A ready mapping retains its existing behavior; visual feedback is a fallback.
    /// Nil means the action completed; transport unavailability returns the original 503.
    static func performPointerAction(
        _ action: Action, body: [String: Any], input: DeviceInput,
        screenSize: CGSize?, screenName: String,
        capture: @escaping (UInt64?, TimeInterval) throws -> VisualPointerFrame,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws -> HTTPResponse? {
        guard action.requiresPointer else { throw DeviceError("not a coordinate pointer action") }
        let mapped = input.isPointerReady
        guard mapped || input.visualPointerTransportAvailable else {
            // Preserve readiness priority over malformed parameters, including
            // callers without a window polling subscription or capture changes.
            input.invalidatePointerEstimate()
            return .error(StringsAPI.current.pointerNotReady, status: 503)
        }

        switch action {
        case .tap:
            let (x, y) = try RequestCoordinates.point(
                body, "x", "y", screenSize: screenSize, screenName: screenName)
            if mapped {
                try input.tap(x: x, y: y, hold: (body["hold"] as? Double) ?? 0.08)
            } else {
                let hold: Double
                if let raw = body["hold"] {
                    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                        number.doubleValue.isFinite, (0...10).contains(number.doubleValue)
                    else { throw DeviceError("hold must be a finite duration between 0 and 10 seconds") }
                    hold = number.doubleValue
                } else {
                    hold = 0.08
                }
                guard let screenSize else { throw DeviceError("no USB frame for visual pointer") }
                try input.visualTap(x: x, y: y, hold: hold, size: screenSize, capture: capture, now: now)
            }
        case .move:
            let (x, y) = try RequestCoordinates.point(
                body, "x", "y", screenSize: screenSize, screenName: screenName)
            if mapped {
                try input.move(x: x, y: y)
            } else {
                guard let screenSize else { throw DeviceError("no USB frame for visual pointer") }
                try input.visualMove(x: x, y: y, size: screenSize, capture: capture, now: now)
            }
        case .swipe:
            let swipe = try SwipeRequest(body, screenSize: screenSize, screenName: screenName)
            if mapped {
                try input.swipe(points: swipe.points, duration: swipe.duration)
            } else {
                guard let screenSize else { throw DeviceError("no USB frame for visual pointer") }
                try input.visualSwipe(
                    points: swipe.points, duration: swipe.duration, size: screenSize, capture: capture, now: now)
            }
        default:
            throw DeviceError("not a coordinate pointer action")
        }
        return nil
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
