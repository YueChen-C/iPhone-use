import CoreFoundation
import Darwin
import Foundation

/// A one-operation session over Apple's paired Installation Proxy service.
/// Read-only browse and exact bundle lookup; no installation, removal or container access.
enum NativeAppInventory {
    static func browse(_ stream: AXByteStream) throws -> [[String: String]] {
        let keys = [
            "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString",
            "ApplicationType",
        ]
        let request: [String: Any] = ["Command": "Browse", "ClientOptions": ["ReturnAttributes": keys]]
        let data = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        try stream.send(AXUSBProxy.big(UInt64(data.count), 4) + data)
        var apps: [String: [String: String]] = [:]
        var bytes = 0
        for _ in 0..<512 {
            let size = try stream.read(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= AXDTX.limit - bytes else { throw AXDTX.Failure("Invalid app inventory size") }
            bytes += size
            guard
                let reply = try PropertyListSerialization.propertyList(
                    from: stream.read(size), options: [], format: nil)
                    as? [String: Any], reply["Error"] == nil, let status = reply["Status"] as? String,
                status == "BrowsingApplications" || status == "Complete"
            else {
                throw AXDTX.Failure("Installation Proxy rejected or returned an invalid app inventory")
            }
            if let list = reply["CurrentList"] {
                guard let entries = list as? [[String: Any]], entries.count <= 10_000 - apps.count else {
                    throw AXDTX.Failure("Invalid app inventory entries")
                }
                for entry in entries {
                    guard let id = entry["CFBundleIdentifier"] as? String, NativeAppServices.validBundleID(id) else {
                        continue
                    }
                    guard apps[id] == nil else { continue }
                    var app = [
                        "bundle_id": id,
                        "name": entry["CFBundleDisplayName"] as? String ?? entry["CFBundleName"] as? String ?? id,
                    ]
                    app["version"] = entry["CFBundleShortVersionString"] as? String
                    app["application_type"] = entry["ApplicationType"] as? String
                    apps[id] = app
                }
            } else if status != "Complete" {
                throw AXDTX.Failure("Installation Proxy omitted app list")
            }
            if status == "Complete" { return apps.keys.sorted().compactMap { apps[$0] } }
        }
        throw AXDTX.Failure("Installation Proxy app inventory did not finish")
    }

    static func executablePath(_ stream: AXByteStream, bundleID: String) throws -> String {
        guard NativeAppServices.validBundleID(bundleID) else { throw AXDTX.Failure("Invalid bundle_id") }
        let options: [String: Any] = [
            "BundleIDs": [bundleID], "ReturnAttributes": ["CFBundleIdentifier", "Path", "CFBundleExecutable"],
        ]
        let request: [String: Any] = ["Command": "Lookup", "ClientOptions": options]
        let data = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        try stream.send(AXUSBProxy.big(UInt64(data.count), 4) + data)
        let size = try stream.read(4).reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= AXDTX.limit,
            let reply = try PropertyListSerialization.propertyList(from: stream.read(size), options: [], format: nil)
                as? [String: Any], reply["Error"] == nil, reply["Status"] as? String == "Complete",
            let entries = reply["LookupResult"] as? [String: Any],
            let entry = entries[bundleID] as? [String: Any], entry["CFBundleIdentifier"] as? String == bundleID,
            let bundlePath = entry["Path"] as? String, bundlePath.hasSuffix(".app"),
            let executable = entry["CFBundleExecutable"] as? String, !executable.contains("/"),
            let path = NativeAppServices.canonicalPath(bundlePath + "/" + executable)
        else { throw AXDTX.Failure("Installation Proxy did not identify the installed App's main executable") }
        return path
    }
}

enum NativeAppServices {
    static let serviceName = "com.apple.coredevice.appservice"
    static let launchFeature = "com.apple.coredevice.feature.launchapplication"

    static func validBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && value.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy {
                    !$0.isEmpty
                        && $0.utf8.allSatisfy {
                            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                        }
                }
    }

    static let processListFeature = "com.apple.coredevice.feature.listprocesses"
    static let signalFeature = "com.apple.coredevice.feature.sendsignaltoprocess"

    static func port(peer: [String: Any], device: String, requiring features: [String]) throws -> UInt16 {
        guard (peer["Properties"] as? [String: Any])?["UniqueDeviceID"] as? String == device else {
            throw AXDTX.Failure("RSD physical UDID mismatch; refusing AppService operation")
        }
        guard let service = (peer["Services"] as? [String: Any])?[serviceName] as? [String: Any],
            let raw = service["Port"] as? String, let port = UInt16(raw), port > 0
        else {
            throw AXDTX.Failure("iPhone does not advertise AppService; check Developer Mode and developer services")
        }
        if let advertised = service["Features"] as? [String], !advertised.isEmpty,
            let missing = features.first(where: { !advertised.contains($0) })
        {
            throw AXDTX.Failure("iPhone AppService does not advertise \(missing)")
        }
        return port
    }

    static let launchURLByteLimit = 4096

    static func validLaunchURL(_ value: String) -> Bool {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard value.utf8.count <= launchURLByteLimit, !value.contains("\\"),
            value.rangeOfCharacter(from: forbidden) == nil,
            let url = URL(string: value, encodingInvalidCharacters: false),
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
            parts.user == nil, parts.password == nil,
            let host = parts.host, !host.isEmpty,
            host.rangeOfCharacter(from: forbidden.union(CharacterSet(charactersIn: "/\\@?#%"))) == nil
        else { return false }
        if host.contains(":") || host.contains("[") || host.contains("]") {
            guard host.hasPrefix("["), host.hasSuffix("]") else { return false }
            var address = in6_addr()
            guard inet_pton(AF_INET6, String(host.dropFirst().dropLast()), &address) == 1 else { return false }
        }
        // Distinguish omitted ports from ones that overflow Foundation's Int parser.
        if parts.rangeOfPort != nil { return parts.port.map { (1...65535).contains($0) } ?? false }
        return true
    }

    // Existing project RemoteXPC transport; field names follow the documented
    // wire behavior in jkcoxson/idevice's MIT-licensed AppService client.
    static func launchRequest(bundleID: String, payloadURL: String? = nil) throws -> [String: USBXPCValue] {
        guard validBundleID(bundleID) else { throw AXDTX.Failure("Invalid bundle_id") }
        let platformOptions = try PropertyListSerialization.data(
            fromPropertyList: [String: String](), format: .xml, options: 0)
        var options: [String: USBXPCValue] = [
            "arguments": .array([]), "environmentVariables": .dictionary([:]),
            "standardIOUsesPseudoterminals": .bool(true),
            "startStopped": .bool(false), "terminateExisting": .bool(false),
            "user": .dictionary(["active": .bool(true)]),
            "platformSpecificOptions": .data(platformOptions),
        ]
        if let payloadURL {
            guard validLaunchURL(payloadURL) else { throw AXDTX.Failure("Invalid launch URL") }
            // CoreDevice uses the keyed Codable URL form. Pass the original
            // string, preserving percent escapes, path, query and fragment.
            options["payloadURL"] = .dictionary(["relative": .text(payloadURL)])
        }
        return request(launchFeature, input: [
            "applicationSpecifier": .dictionary(["bundleIdentifier": .dictionary(["_0": .text(bundleID)])]),
            "options": .dictionary(options),
            "standardIOIdentifiers": .dictionary([:]),
        ])
    }

    private static func request(_ feature: String, input: [String: USBXPCValue] = [:]) -> [String: USBXPCValue] {
        return [
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int(0),
            "CoreDevice.coreDeviceVersion": .dictionary([
                "components": .array([.uint(629), .uint(3)]), "originalComponentsCount": .int(2),
                "stringValue": .text("629.3"),
            ]),
            "CoreDevice.deviceIdentifier": .text(UUID().uuidString),
            "CoreDevice.invocationIdentifier": .text(UUID().uuidString),
            "CoreDevice.featureIdentifier": .text(feature),
            "CoreDevice.action": .dictionary([:]),
            "CoreDevice.input": .dictionary(input),
        ]
    }

    static func launchPID(_ reply: [String: Any]) throws -> UInt32 {
        guard reply["CoreDevice.error"] == nil,
            let token = (reply["CoreDevice.output"] as? [String: Any])?["processToken"] as? [String: Any],
            let pid = positivePID(token["processIdentifier"])
        else {
            throw AXDTX.Failure("AppService returned no valid launch receipt")
        }
        return pid
    }

    private struct RunningProcess {
        let pid: UInt32
        let path: String?
    }

    enum TerminationResult {
        case alreadyStopped
        case terminated(UInt32)
    }

    // These paths refer to the iPhone, never resolve them on the Mac. Only fold the known /var alias.
    fileprivate static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
            path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return path.hasPrefix("/var/") ? "/private" + path : path
    }

    private static func executableURLPath(_ value: Any?) -> String? {
        guard let relative = (value as? [String: Any])?["relative"] as? String,
            let url = URLComponents(string: relative), url.scheme == "file",
            url.host == nil || url.host == "", url.port == nil, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil, !url.percentEncodedPath.lowercased().contains("%2f")
        else { return nil }
        return canonicalPath(url.path)
    }

    private static func processes(_ reply: [String: Any]) throws -> [RunningProcess] {
        guard reply["CoreDevice.error"] == nil,
            let tokens = (reply["CoreDevice.output"] as? [String: Any])?["processTokens"] as? [[String: Any]],
            tokens.count <= 10_000
        else { throw AXDTX.Failure("AppService returned no valid process list") }
        var seen: Set<UInt32> = []
        return try tokens.map { token in
            guard let pid = positivePID(token["processIdentifier"]), pid <= UInt32(Int32.max),
                seen.insert(pid).inserted
            else { throw AXDTX.Failure("Invalid or duplicate PID in AppService process list") }
            return RunningProcess(pid: pid, path: executableURLPath(token["executableURL"]))
        }
    }

    static func terminate(
        executablePath: String,
        exchange: ([String: USBXPCValue]) throws -> [String: Any],
        willSignal: () -> Void,
        wait: () -> Void = { Thread.sleep(forTimeInterval: 0.2) }
    ) throws -> TerminationResult {
        func snapshot() throws -> [RunningProcess] { try processes(exchange(request(processListFeature))) }
        let before = try snapshot()
        func matchesApp(_ process: RunningProcess) -> Bool {
            process.path?.utf8.elementsEqual(executablePath.utf8) == true
        }
        let matches = before.filter(matchesApp)
        guard matches.count <= 1 else { throw AXDTX.Failure("Multiple processes match the App's main executable") }
        guard let target = matches.first else {
            guard before.allSatisfy({ $0.path != nil }) else {
                throw AXDTX.Failure("Cannot prove the App is stopped: a running process has no usable executable path")
            }
            return .alreadyStopped
        }
        guard target.pid > 1 else { throw AXDTX.Failure("Refusing to signal a reserved PID") }
        let signal = request(signalFeature, input: [
            "process": .dictionary(["processIdentifier": .int(Int64(target.pid))]),
            "signal": .int(Int64(SIGKILL)),
        ])
        willSignal()
        let reply = try exchange(signal)
        guard reply["CoreDevice.error"] == nil, let output = reply["CoreDevice.output"] as? [String: Any],
            let process = output["process"] as? [String: Any], positivePID(process["processIdentifier"]) == target.pid,
            positivePID(output["signal"]) == UInt32(SIGKILL)
        else { throw AXDTX.Failure("AppService returned no matching termination receipt") }
        for attempt in 0..<5 {
            if attempt > 0 { wait() }
            let after = try snapshot()
            if after.allSatisfy({ $0.pid != target.pid && $0.path != nil && !matchesApp($0) }) {
                return .terminated(target.pid)
            }
        }
        throw AXDTX.Failure("Termination was acknowledged but the App's exit could not be verified")
    }

    static func positivePID(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let pid = UInt32(number.stringValue), pid > 0
        else { return nil }
        return pid
    }
}
