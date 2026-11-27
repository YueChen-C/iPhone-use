import Darwin
import Foundation

enum NativeAppManagement {
    static let workerArgument = "--app-management-worker"
    enum Operation: String {
        case list = "list_apps"
        case foreground = "get_foreground_app"
        case launch = "launch_app"
        case terminate = "terminate_app"

        var requiresBundleID: Bool { self == .launch || self == .terminate }

        var path: String { "/" + rawValue }

        func validatedURL(_ value: Any?) throws -> String? {
            guard let value else { return nil }
            guard self == .launch else { throw Failure(description: "url is only accepted by launch_app") }
            guard let url = value as? String, NativeAppServices.validLaunchURL(url) else {
                throw Failure(
                    description: "url must be an absolute HTTP or HTTPS URL without credentials "
                        + "(at most \(NativeAppServices.launchURLByteLimit) bytes)")
            }
            return url
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        var outcome = "not_sent"
    }

    static func perform(
        _ operation: Operation, device: String, bundleID: String?, payloadURL: String? = nil,
        capture: (String) throws -> [String: Any] = NativeAXTree.captureForeground
    ) throws -> [String: Any] {
        let payloadURL = try operation.validatedURL(payloadURL)
        try NativeDDIInspection.validateIdentity(device)
        if operation == .foreground {
            return foreground(try capture(device), device: device)
        }
        if operation.requiresBundleID {
            guard let bundleID, NativeAppServices.validBundleID(bundleID) else {
                throw Failure(description: "Invalid bundle_id")
            }
        }
        var result = try run(operation, device: device, bundleID: bundleID, payloadURL: payloadURL)
        if operation == .launch, let bundleID {
            let observation = try? capture(device)
            result["foreground_verified"] = verifiesForeground(
                observation, device: device, bundleID: bundleID, launchPID: result["pid"])
        }
        return result
    }

    static func foreground(_ tree: [String: Any], device: String) -> [String: Any] {
        let app = tree["device"] as? String == device ? tree["foreground_app"] as? [String: Any] : nil
        let bundle = app?["bundle_id"] as? String
        let pid = NativeAppServices.positivePID(app?["pid"])
        return [
            "device": device, "source": "accessibility", "foreground_app": app as Any? ?? NSNull(),
            "known": bundle.map(NativeAppServices.validBundleID) == true || pid != nil,
        ]
    }

    static func verifiesForeground(_ tree: [String: Any]?, device: String, bundleID: String, launchPID: Any?) -> Bool {
        guard let tree, tree["device"] as? String == device,
            let app = tree["foreground_app"] as? [String: Any]
        else { return false }
        let observedBundleID = app["bundle_id"] as? String
        if let observedBundleID, observedBundleID != bundleID { return false }
        if let pid = NativeAppServices.positivePID(launchPID),
            let observedPID = NativeAppServices.positivePID(app["pid"])
        {
            return observedPID == pid
        }
        return observedBundleID == bundleID
    }

    private static func run(
        _ operation: Operation, device: String, bundleID: String?, payloadURL: String?
    ) throws -> [String: Any] {
        guard let executable = Bundle.main.executableURL else {
            throw Failure(description: "App worker executable unavailable")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-use-apps-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.json")
        var arguments = [workerArgument, operation.rawValue, device, output.path] + (bundleID.map { [$0] } ?? [])
        if let payloadURL {
            // A URL can contain a share token. Don't put it on the worker's
            // command line, in logs, or in the response.
            let payload = directory.appendingPathComponent("launch-url")
            guard FileManager.default.createFile(
                atPath: payload.path, contents: Data(payloadURL.utf8), attributes: [.posixPermissions: 0o600])
            else { throw Failure(description: "Could not prepare launch URL for worker") }
            arguments.append(payload.path)
        }
        let diagnostic = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? diagnostic.close() }
        let status = try NativeAXTree.runWorker(
            executable: executable, arguments: arguments, diagnostic: diagnostic, timeout: 14)
        guard status == 0, let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= AXDTX.limit,
            let bytes = try? Data(contentsOf: output),
            let result = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
            result["device"] as? String == device
        else {
            throw Failure(
                description: status == nil ? "App management worker timed out" : "App management worker failed",
                outcome: operation.requiresBundleID ? "unknown" : "not_sent")
        }
        if let error = result["error"] as? String {
            throw Failure(
                description: error, outcome: result["outcome"] as? String == "not_sent" ? "not_sent" : "unknown")
        }
        return result
    }

    static func worker(_ args: [String], lease: DDIProcessLease) -> Int32 {
        guard args.count >= 3, let operation = Operation(rawValue: args[0]),
            (operation == .list && args.count == 3) || (operation.requiresBundleID && args.count == 4)
                || (operation == .launch && args.count == 5)
        else { return 64 }
        let device = args[1]
        let output = URL(fileURLWithPath: args[2])
        guard setpgid(0, 0) == 0 else { return 69 }
        signal(SIGPIPE, SIG_IGN)
        var result: [String: Any] = ["device": device]
        var mutationAttempted = false
        do {
            let serviceLease = try lease.deviceService(physicalID: device, exclusive: false)
            try withExtendedLifetime(serviceLease) {
                switch operation {
                case .list:
                    let stream = try AXUSBProxy(device: device, service: .installationProxy)
                    result["apps"] = try NativeAppInventory.browse(stream)
                    result["source"] = "installation_proxy"
                case .launch:
                    let payloadURL = try args.count == 5 ? readLaunchURL(from: args[4]) : nil
                    let request = try NativeAppServices.launchRequest(bundleID: args[3], payloadURL: payloadURL)
                    let client = try appService(device: device, requiring: [NativeAppServices.launchFeature])
                    mutationAttempted = true
                    result["pid"] = try NativeAppServices.launchPID(client.request(request))
                    result["bundle_id"] = args[3]
                    result["outcome"] = "acknowledged"
                    if payloadURL != nil { result["url_requested"] = true }
                    result["source"] = "coredevice_appservice"
                case .terminate:
                    let bundleID = args[3]
                    let client = try appService(
                        device: device, requiring: [NativeAppServices.processListFeature, NativeAppServices.signalFeature])
                    let path = try NativeAppInventory.executablePath(
                        AXUSBProxy(device: device, service: .installationProxy), bundleID: bundleID)
                    switch try NativeAppServices.terminate(
                        executablePath: path, exchange: client.request, willSignal: { mutationAttempted = true })
                    {
                    case .alreadyStopped:
                        result["outcome"] = "already_stopped"
                    case .terminated(let pid):
                        result["pid"] = pid
                        result["outcome"] = "terminated"
                    }
                    result["bundle_id"] = bundleID
                    result["source"] = "coredevice_appservice"
                case .foreground: break  // handled by the isolated AX worker
                }
            }
        } catch {
            result["error"] = error is AXUSBProxy.Unsupported ? "\(operation.rawValue) requires iOS 17 or later" : "\(error)"
            result["outcome"] = mutationAttempted ? "unknown" : "not_sent"
            result["replayAllowed"] = false
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            guard data.count <= AXDTX.limit else { return 69 }
            try data.write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            return 0
        } catch { return 69 }
    }

    private static func readLaunchURL(from path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: NativeAppServices.launchURLByteLimit + 1),
            data.count <= NativeAppServices.launchURLByteLimit,
            let url = String(data: data, encoding: .utf8)
        else { throw Failure(description: "Invalid launch URL payload") }
        return url
    }

    private static func appService(device: String, requiring features: [String]) throws -> USBRemoteXPC {
        let tunnel = try AXUSBProxy(device: device, requireCoreDevice: true)
        let discovery = try AXTunnelSocket(tunnel: tunnel, port: tunnel.rsdPort, local: 52101)
        let peer = try AXRSD.discover(socket: discovery)
        let port = try NativeAppServices.port(peer: peer, device: device, requiring: features)
        return try USBRemoteXPC(socket: AXTunnelSocket(tunnel: tunnel, port: port, local: 52102))
    }
}

/// Do not select the first matching phone or silently substitute another device.
/// The worker independently resolves and verifies the selected physical UDID.
enum AppManagementEndpoint {
    static func resolve(_ selector: String?, devices: [(id: String, name: String)]) throws -> String {
        let candidates = devices.filter { (try? NativeDDIInspection.validateIdentity($0.id)) != nil }
        let matches: [(id: String, name: String)]
        if let selector {
            guard !selector.isEmpty else { throw AXDTX.Failure("Device selector is empty") }
            let key = selector.lowercased()
            let exact = candidates.filter { $0.id.lowercased() == key }
            let names = candidates.filter { $0.name.lowercased() == key }
            matches =
                !exact.isEmpty
                ? exact : !names.isEmpty ? names : candidates.filter { $0.id.lowercased().hasPrefix(key) }
        } else {
            matches = candidates
        }
        guard matches.count == 1 else {
            throw AXDTX.Failure(
                matches.isEmpty
                    ? "No matching physical USB iPhone" : "Device selector is ambiguous; specify the full USB UDID")
        }
        return matches[0].id
    }

    static func response(
        _ request: HTTPRequest, operation: NativeAppManagement.Operation,
        resolve: (String?) throws -> String,
        perform: (NativeAppManagement.Operation, String, String?, String?) throws -> [String: Any]
    ) -> HTTPResponse {
        if ["device", "device_id"].contains(where: { key in request.body[key] != nil && !(request.body[key] is String) }
        ) {
            return .error("Device must be a string")
        }
        let bundleID = operation.requiresBundleID ? request.body["bundle_id"] as? String : nil
        if operation.requiresBundleID {
            guard request.method == "POST" else { return .error("not found", status: 404) }
            guard let bundleID, NativeAppServices.validBundleID(bundleID) else {
                return .error("Valid bundle_id required")
            }
        }
        guard request.query["url"] == nil else { return .error("Send url in the JSON body of POST /launch_app") }
        let payloadURL: String?
        do { payloadURL = try operation.validatedURL(request.body["url"]) } catch { return .error("\(error)") }
        let device: String
        do { device = try resolve(ControlAPI.deviceSelector(body: request.body, query: request.query)) } catch {
            return .error("\(error)")
        }
        do { return .json(try perform(operation, device, bundleID, payloadURL)) } catch let failure as NativeAppManagement.Failure {
            return .json(
                [
                    "error": failure.description, "device": device, "code": "app_management_failed",
                    "outcome": failure.outcome, "replayAllowed": false,
                ], status: 503)
        } catch { return .error("\(error)", status: 503) }
    }
}
