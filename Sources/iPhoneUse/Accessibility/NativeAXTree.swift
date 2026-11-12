import Darwin
import Foundation

/// Worker isolation bounds blocking Apple service calls without touching the
/// running GUI, Bluetooth sessions or other phones. Uses this same executable.
enum NativeAXTree {
    static let workerArgument = "--ax-tree"

    static func capture(device: String, includeOffscreen: Bool) throws -> [String: Any] {
        guard let executable = Bundle.main.executableURL else { throw AXDTX.Failure("AX executable unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-use-ax-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("tree.json")
        let diagnostic = directory.appendingPathComponent("error.txt")
        FileManager.default.createFile(atPath: diagnostic.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: diagnostic)
        defer { try? handle.close() }
        let status = try runWorker(executable: executable,
            arguments: [workerArgument, device, output.path, includeOffscreen ? "1" : "0"], diagnostic: handle)
        guard status == 0 else {
            let detail = (try? String(contentsOf: diagnostic, encoding: .utf8)) ?? ""
            throw AXDTX.Failure(status == nil ? "AX worker timed out (25s); check developer services and UI Automation"
                : "AX unavailable: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= AXDTX.limit,
              let result = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any],
              result["source"] as? String == "accessibility", result["device"] as? String == device else {
            throw AXDTX.Failure("Invalid AX worker result")
        }
        return result
    }

    private static func runWorker(executable: URL, arguments: [String], diagnostic: FileHandle) throws -> Int32? {
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostic
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // The worker creates its own process group before starting Apple helpers.
        // Kill the group, not just its leader, so timeout never leaves a netcat child.
        defer { kill(-process.processIdentifier, SIGKILL) }
        guard finished.wait(timeout: .now() + 25) == .success else {
            kill(-process.processIdentifier, SIGTERM)
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(-process.processIdentifier, SIGKILL)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            return nil
        }
        return process.terminationReason == .exit ? process.terminationStatus : nil
    }

    static func write(device: String, output: URL, includeOffscreen: Bool) -> Int32 {
        do {
            guard setpgid(0, 0) == 0 else { throw AXDTX.Failure("Cannot isolate AX worker process group") }
            signal(SIGPIPE, SIG_IGN)
            let transport = try AXRemoteTransport(device: device)
            let result = try transport.legacy
                ? AXLegacyTree(send: transport.send, receive: transport.read).read(device: device, includeOffscreen: includeOffscreen)
                : read(device: device, includeOffscreen: includeOffscreen, send: transport.send, receive: transport.read)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            guard data.count <= AXDTX.limit else { throw AXDTX.Failure("AX JSON exceeds limit") }
            try data.write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 69
        }
    }

    static func read(device: String, includeOffscreen: Bool, send: (Data) throws -> Void,
                     receive: @escaping (Int) throws -> Data) throws -> [String: Any] {
        let reader = AXMessageReader { try AXDTX.receive(read: receive) }
        return try collect(device: device, includeOffscreen: includeOffscreen, send: send,
                           next: { try reader.next(timeout: $0) })
    }

    /// The remote service has not supplied a proven snapshot-complete marker.
    /// Merge changes until a bounded quiet window, never label this a full tree.
    static func collect(device: String, includeOffscreen: Bool, send: (Data) throws -> Void,
                        next: (TimeInterval) throws -> AXDTX.Message?,
                        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        quietWindow: TimeInterval = 0.6, maximumDuration: TimeInterval = 8) throws -> [String: Any] {
        try send(AXDTX.call(id: 1, selector: "_notifyOfPublishedCapabilities:",
                           argument: ["com.apple.private.DTXBlockCompression": 0, "com.apple.private.DTXConnection": 1]))
        try send(AXDTX.call(id: 2, selector: "clientNeedsAccessibility:", argument: true))
        defer { try? send(AXDTX.call(id: 3, selector: "clientNeedsAccessibility:", argument: false)) }
        var tree = AXTree(includeOffscreen: includeOffscreen)
        let started = clock()
        var changed = started, messages = 0, reason = "message-limit"
        for _ in 0..<4096 {
            let now = clock(), remaining = maximumDuration - (now - started)
            if remaining <= 0 { reason = "capture-deadline"; break }
            if tree.ready && now - changed >= quietWindow { reason = "quiet-window"; break }
            let wait = tree.ready ? min(remaining, max(0.001, quietWindow - (now - changed))) : remaining
            guard let message = try next(wait) else {
                reason = tree.ready && wait < remaining ? "quiet-window" : "capture-deadline"
                break
            }
            messages += 1
            if message.expectsReply {
                let ack = AXDTX.number(0) + AXDTX.number(0) + AXDTX.number(0, bytes: 8)
                try send(AXDTX.packet(id: message.identifier, conversation: message.conversation &+ 1,
                                      channel: message.channel, payload: ack))
            }
            let previous = tree.revision
            for archive in try AXDTX.auxiliaryArchives(message.payload) { try tree.update(archive) }
            if previous != tree.revision { changed = clock() }
        }
        guard tree.ready else { throw AXDTX.Failure("AX response ended before a usable hierarchy arrived") }
        var result = tree.json(device: device)
        result["capture"] = ["termination_reason": reason, "messages_received": messages,
                             "attribute_revisions": tree.revision, "quiet_window_ms": Int(quietWindow * 1000),
                             "elapsed_ms": Int(max(0, clock() - started) * 1000),
                             "completion_basis": "bounded-observation-not-snapshot-marker"]
        return result
    }

}

struct AXTreeOptions {
    let includeOffscreen: Bool
    init(body: [String: Any], query: [String: String]) throws {
        if let raw = body["include_offscreen"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                throw AXDTX.Failure("include_offscreen must be boolean")
            }
            includeOffscreen = n.boolValue
        } else if let raw = query["include_offscreen"] {
            guard ["true", "false", "0", "1"].contains(raw) else {
                throw AXDTX.Failure("include_offscreen must be true, false, 0 or 1")
            }
            includeOffscreen = raw == "true" || raw == "1"
        } else { includeOffscreen = false }
    }
}

/// Shared HTTP implementation; device resolution is injectable for tests and
/// the explicitly addressed, AX-only listener (which never opens USB video/BLE).
enum AXTreeEndpoint {
    static func response(_ request: HTTPRequest, resolve: (String?) throws -> String,
                         capture: (String, Bool) throws -> [String: Any] = NativeAXTree.capture) -> HTTPResponse {
        do {
            let options = try AXTreeOptions(body: request.body, query: request.query)
            let selector = ControlAPI.deviceSelector(body: request.body, query: request.query)
            let id = try resolve(selector)
            do { return .json(try capture(id, options.includeOffscreen)) }
            catch { return .error("\(error)", status: 503) }
        } catch { return .error("\(error)") }
    }

    static func serve(device: String, port: UInt16) throws {
        let server = HTTPServer(port: port) { request in
            switch (request.method, request.path) {
            case ("GET", "/config"): return .json(["language": "en"])
            case ("GET", "/status"): return .json(["mode": "ax-only", "device": device])
            case ("GET", "/devices"): return .json(["devices": [["id": device, "name": device]]])
            case ("GET", "/ax_tree"), ("POST", "/ax_tree"):
                return response(request, resolve: { selector in
                    guard selector == nil || selector == device else {
                        throw AXDTX.Failure("AX-only listener accepts only configured UDID")
                    }
                    return device
                })
            default: return .error("not found", status: 404)
            }
        }
        try server.start()
        withExtendedLifetime(server) { RunLoop.main.run() }
    }
}
