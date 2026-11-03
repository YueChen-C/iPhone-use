import Foundation

/// `iphone-use mcp`: an MCP server over stdio that forwards to the running app's HTTP API.
/// Screenshots are scaled so the long edge is at most `longEdge`; tap and swipe
/// coordinates are read in that scaled image's pixels.
enum MCPServer {
    static let longEdge = 1000
    static var base = URL(string: "http://127.0.0.1:7390")!

    /// This process's language, fetched from the app's /config because the stdio
    /// server is a separate process and cannot read the app's UserDefaults.
    /// Stays English until the app answers, including against older apps that
    /// predate the endpoint. Fetched once per process at initialize/tools/list.
    static var language: AppLanguage = .en
    private static var languageLoaded = false
    private static var devicesCache = DeviceListCache()

    struct DeviceListCache {
        private var data: Data?
        private var expires: TimeInterval = 0
        private var origin: String = ""

        mutating func invalidate() { data = nil }

        func isValid(origin: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
            data != nil && self.origin == origin && now < expires
        }

        mutating func load(
            origin: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
            fresh: Bool = false, fetch: () throws -> Data
        ) throws -> Data {
            if !fresh, self.origin == origin, now < expires, let data { return data }
            invalidate()
            let loaded = try fetch()
            data = loaded
            self.origin = origin
            expires = now + 2
            return loaded
        }
    }

    private static var client: MCPHTTPClient { MCPHTTPClient(base: base, language: language) }

    static func run() -> Never {
        if let port = ProcessInfo.processInfo.environment["IPHONE_USE_PORT"] {
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Refresh before protocol handling so response(to:) stays free of I/O.
            if let method = message["method"] as? String,
                method == "initialize" || method == "tools/list"
            {
                refreshLanguage()
            }
            if let response = response(to: message, callTool: call) {
                write(response)
            }
        }
        exit(0)
    }

    /// Best-effort: any failure (app down, old app, bad JSON) keeps the previous
    /// language, so an unreachable app never stalls or breaks the handshake.
    private static func refreshLanguage() {
        guard !languageLoaded else { return }
        guard let (data, http) = try? client.get("/config", timeout: 2), http.statusCode == 200,
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let parsed = (raw["language"] as? String).flatMap(AppLanguage.init(rawValue:))
        else { return }
        language = parsed
        languageLoaded = true
    }

    /// Builds one JSON-RPC reply. Notifications and malformed envelopes are silent.
    /// Injecting tool execution keeps protocol handling independent of the HTTP bridge.
    static func response(
        to message: [String: Any], callTool: (String, [String: Any]) -> [String: Any]
    ) -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "iphone-use", "version": "0.2.0"],
                "instructions": StringsMCP(language: language).instructions,
            ]
        case "tools/list":
            // Rebuilt per request so a process that loaded one language at
            // initialize serves a fresher one if the app switched in between.
            result = ["tools": MCPToolCatalog.tools(for: language)]
        case "tools/call":
            result = callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        case "ping":
            result = [:]
        default:
            let error: [String: Any] = ["code": -32601, "message": "method not found: \(method)"]
            return ["jsonrpc": "2.0", "id": id, "error": error]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let table = StringsMCP(language: language)
        do {
            let observe = arguments["observe"] as? String ?? "full"
            guard arguments["observe"] == nil || arguments["observe"] is String,
                ["full", "ocr_diff", "none"].contains(observe)
            else { throw MCPError("observe must be full, ocr_diff or none") }
            let includeImage: Bool
            if let raw = arguments["include_image"] {
                guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw MCPError(StringsAPI(language: language).ocrParameterInvalid("include_image"))
                }
                includeImage = value.boolValue
            } else {
                includeImage = true
            }
            let actions: [MCPKeyboardAction]
            if name == "keyboard_sequence" {
                actions = try MCPKeyboardSequence.actions(arguments: arguments, language: language)
            } else {
                let action = try MCPToolRequest.action(
                    named: name, arguments: arguments, longEdge: longEdge, language: language)
                guard name == "list_devices" || name == "screenshot" || action != nil else {
                    return failure(table.unknownTool(name))
                }
                actions = action.map { [.request($0)] } ?? []
            }
            return try MCPAccess.withService(port: base.port ?? 7390, language: language) {
                let usedCache = name != "list_devices" && devicesCache.isValid(origin: base.absoluteString)
                let data = try devicesCache.load(origin: base.absoluteString, fresh: name == "list_devices") {
                    try client.get("/devices").0
                }
                if name == "list_devices" {
                    return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
                }
                let query = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
                let device: String
                do {
                    device = try resolveDevice(query, data: data)
                } catch {
                    devicesCache.invalidate()
                    guard usedCache else { throw error }
                    let fresh = try devicesCache.load(origin: base.absoluteString) { try client.get("/devices").0 }
                    device = try resolveDevice(query, data: fresh)
                }
                return try MCPAccess.withDevice(port: base.port ?? 7390, id: device, language: language) {
                    if name == "ocr_screen", case .request(let action) = actions.first {
                        var body = action.body
                        body["device"] = device
                        let data = try client.post(action.path, body)
                        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
                    }
                    for (index, action) in actions.enumerated() {
                        do {
                            switch action {
                            case .delay(let seconds):
                                Thread.sleep(forTimeInterval: seconds)
                            case .request(let request):
                                var body = request.body
                                body["device"] = device
                                try client.post(request.path, body)
                            }
                        } catch {
                            guard name == "keyboard_sequence" else { throw error }
                            throw MCPError(
                                table.keyboardStopped(index + 1, actions.count, "\(error)"))
                        }
                        if index < actions.count - 1 {
                            // Let focus changes settle without capturing every intermediate field.
                            Thread.sleep(forTimeInterval: 0.15)
                        }
                    }
                    if observe == "none"
                        || (name == "keyboard_sequence" && arguments["include_image"] as? Bool == false
                            && arguments["observe"] == nil)
                    {
                        return ["content": [["type": "text", "text": "{\"ok\":true}"]]]
                    }
                    if !actions.isEmpty {
                        // Keep the device lock through settling and final observation.
                        waitForStableFrame { remaining in
                            let encoded =
                                device.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? device
                            guard
                                let data = try? client.get(
                                    "/screenshot?maxEdge=64&device=\(encoded)&stability=1", timeout: remaining
                                ).0
                            else { return nil }
                            let hash = ScreenOCR.screenHash(data)
                            return hash.isEmpty ? nil : hash
                        }
                    }
                    if observe == "ocr_diff" {
                        return try screenshot(device, includeImage: false, diff: true)
                    }
                    return try screenshot(device, includeImage: includeImage)
                }
            }
        } catch {
            devicesCache.invalidate()
            return failure("\(error)")
        }
    }

    /// Bounded accumulated delays keep injected no-op sleep closures deterministic.
    static func waitForStableFrame(
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        frame: (TimeInterval) -> String?
    ) {
        let start = now()
        sleep(0.15)
        var elapsed = max(0.15, now() - start)
        guard elapsed < 0.6 else { return }
        var previous = frame(0.6 - elapsed)
        elapsed = max(elapsed, now() - start)
        if previous == nil {
            sleep(max(0, min(0.1, 0.6 - elapsed)))
            return
        }
        while elapsed < 0.6 {
            let interval = min(0.08, 0.6 - elapsed)
            sleep(interval)
            elapsed = max(elapsed + interval, now() - start)
            guard elapsed < 0.6 else { return }
            let current = frame(0.6 - elapsed)
            if let current, current == previous { return }
            previous = current
            elapsed = max(elapsed, now() - start)
        }
    }

    private static func resolveDevice(_ query: String?, data: Data) throws -> String {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = response["devices"] as? [[String: Any]]
        else { throw MCPError(StringsMCP(language: language).invalidDeviceList) }
        var matches = devices
        if let query, !query.isEmpty {
            let q = query.lowercased()
            let exact = devices.filter { ($0["id"] as? String)?.lowercased() == q }
            let named = devices.filter { ($0["name"] as? String)?.lowercased() == q }
            matches =
                !exact.isEmpty
                ? exact
                : !named.isEmpty
                    ? named
                    : devices.filter {
                        ($0["id"] as? String)?.lowercased().hasPrefix(q) == true
                    }
        }
        guard matches.count == 1, let id = matches.first?["id"] as? String, !id.isEmpty else {
            throw MCPError(StringsMCP(language: language).expectedOneMatch(matches.count))
        }
        return id
    }

    private static func screenshot(_ device: String?, includeImage: Bool, diff: Bool = false) throws -> [String: Any] {
        var path = "/screenshot?maxEdge=\(longEdge)"
        if let device, let encoded = device.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&device=\(encoded)"
        }
        path += "&ocr=1"
        let (image, response) = try client.get(path)
        let width = response.value(forHTTPHeaderField: "X-Image-Width") ?? "?"
        let height = response.value(forHTTPHeaderField: "X-Image-Height") ?? "?"
        let id = response.value(forHTTPHeaderField: "X-Device") ?? ""
        let serverOCR = response.value(forHTTPHeaderField: "X-Screen-OCR")
            .flatMap { Data(base64Encoded: $0) }.flatMap(ScreenOCR.decode)
        let ocr = serverOCR ?? ScreenOCR.recognize(image, device: id)
        if diff {
            guard !ocr.screenHash.isEmpty else { throw MCPError("OCR observation unavailable") }
            return ["content": [["type": "text", "text": ScreenOCR.summaryDiff(for: ocr, device: id)]]]
        }
        if !ocr.screenHash.isEmpty { _ = ScreenOCR.diff(device: id, current: ocr) }
        return screenshotContent(
            image: image, device: id, width: width, height: height,
            includeImage: includeImage, ocr: ocr,
            mimeType: response.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg")
    }

    /// Shared by image and text-only screenshots; OCR describes these exact bytes.
    static func screenshotContent(
        image: Data, device: String, width: String, height: String,
        includeImage: Bool, ocr: ScreenOCR.Result, mimeType: String = "image/jpeg"
    ) -> [String: Any] {
        var content: [[String: Any]] = []
        if includeImage {
            content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": mimeType])
        }
        let caption = StringsMCP(language: language).screenshotCaption(device, width, height)
        content.append(["type": "text", "text": caption + (ocr.items.isEmpty ? "" : ocr.summary)])
        return ["content": content]
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    struct MCPError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The stdio server's synchronous bridge to the app's local HTTP API.
/// Keep the semaphore wait and URLSession callback together: each MCP tool completes
/// its HTTP action before the server reads and processes the next input line.
private struct MCPHTTPClient {
    let base: URL
    let language: AppLanguage

    func get(_ path: String, timeout: TimeInterval = 60) throws -> (Data, HTTPURLResponse) {
        try request(URLRequest(url: URL(string: path, relativeTo: base)!), timeout: timeout)
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]) throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try self.request(request, timeout: 60).0
    }

    private func request(_ request: URLRequest, timeout: TimeInterval) throws -> (Data, HTTPURLResponse) {
        let table = StringsMCP(language: language)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(MCPServer.MCPError(table.noResponse))
        let done = DispatchSemaphore(value: 0)
        var request = request
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(MCPServer.MCPError(table.appNotRunning(error.localizedDescription)))
            } else if let data, let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    result = .success((data, http))
                } else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
                    result = .failure(MCPServer.MCPError(message as? String ?? "HTTP \(http.statusCode)"))
                }
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}
