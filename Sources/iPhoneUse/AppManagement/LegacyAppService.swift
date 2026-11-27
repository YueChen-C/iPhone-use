import CoreFoundation
import Foundation

/// One paired, TLS-backed Instruments DTX session on iOS 15/16. No subprocess or host developer tools.
final class LegacyAppService {
    private static let deviceInfo = "com.apple.instruments.server.services.deviceinfo"
    private static let processControl = "com.apple.instruments.server.services.processcontrol"
    private let stream: AXByteStream
    private var identifier: UInt32 = 0
    private var channels: [String: UInt32] = [:]

    init(stream: AXByteStream) throws {
        self.stream = stream
        // This client only accepts uncompressed payloads; do not advertise DTXBlockCompression.
        try stream.send(AXDTX.call(id: takeIdentifier(), selector: "_notifyOfPublishedCapabilities:",
                                  argument: ["com.apple.private.DTXConnection": 1]))
    }

    func processes() throws -> [NativeAppServices.RunningProcess] {
        try Self.decodeProcesses(call("runningProcesses", channel: channel(Self.deviceInfo)))
    }

    static func decodeProcesses(_ reply: Any?) throws -> [NativeAppServices.RunningProcess] {
        guard let rows = reply as? [[String: Any]], rows.count <= 10_000 else {
            throw AXDTX.Failure("Legacy Instruments returned no valid process list")
        }
        var seen: Set<UInt32> = []
        return try rows.compactMap { row in
            if let pid = row["pid"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
               pid.stringValue == "0", row["isApplication"] as? Bool == false {
                // The kernel is not a launchable application and has no executable path in this snapshot.
                guard seen.insert(0).inserted else { throw AXDTX.Failure("Duplicate legacy kernel entry") }
                return nil
            }
            guard let pid = NativeAppServices.positivePID(row["pid"]), pid <= UInt32(Int32.max),
                  seen.insert(pid).inserted else {
                throw AXDTX.Failure("Invalid or duplicate PID in Legacy Instruments process list")
            }
            let path = (row["realAppName"] as? String).flatMap(NativeAppServices.canonicalPath)
            return .init(pid: pid, path: path)
        }
    }

    func launch(bundleID: String, willLaunch: () -> Void) throws -> UInt32 {
        guard NativeAppServices.validBundleID(bundleID) else { throw AXDTX.Failure("Invalid bundle_id") }
        let control = try channel(Self.processControl)
        let reply = try call(
            "launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:", channel: control,
            arguments: ["", bundleID, [String: String](), [String](), ["StartSuspendedKey": false, "KillExisting": false]],
            willSend: willLaunch)
        guard let pid = NativeAppServices.positivePID(reply), pid > 1, pid <= UInt32(Int32.max) else {
            throw AXDTX.Failure("Legacy Instruments returned no valid launch PID")
        }
        return pid
    }

    func terminate(executablePath: String, willSignal: () -> Void) throws -> NativeAppServices.TerminationResult {
        try NativeAppServices.terminate(executablePath: executablePath, snapshot: processes, signal: { pid in
            let control = try channel(Self.processControl)
            let reply = try call("killPid:", channel: control, arguments: [pid], willSend: willSignal)
            guard reply == nil || reply is NSNull else {
                throw AXDTX.Failure("Legacy Instruments returned an unexpected termination reply")
            }
        })
    }

    private func takeIdentifier() throws -> UInt32 {
        guard identifier < UInt32.max else { throw AXDTX.Failure("Legacy Instruments exhausted DTX identifiers") }
        identifier += 1
        return identifier
    }

    private func channel(_ name: String) throws -> UInt32 {
        if let code = channels[name] { return code }
        let code = UInt32(channels.count + 1)
        let reply = try call("_requestChannelWithCode:identifier:", channel: 0,
                             arguments: [AXDTX.Scalar32(value: code), name])
        guard reply == nil || reply is NSNull else { throw AXDTX.Failure("Legacy Instruments channel was rejected") }
        channels[name] = code
        return code
    }

    private func call(_ selector: String, channel: UInt32, arguments: [Any] = [],
                      willSend: () -> Void = {}) throws -> Any? {
        let id = try takeIdentifier()
        let packet = try AXDTX.call(id: id, selector: selector, arguments: arguments, reply: true, channel: channel)
        willSend()
        try stream.send(packet)
        for _ in 0..<512 {
            let message = try AXDTX.receive(read: stream.read)
            if message.conversation == 0 {
                identifier = max(identifier, message.identifier)
                if message.expectsReply {
                    try stream.send(AXDTX.packet(id: message.identifier, conversation: 1,
                                                channel: message.channel, payload: Data(count: 16)))
                }
                continue
            }
            guard message.identifier == id, message.channel == channel else { continue }
            guard message.conversation == 1,
                  [UInt64(0), 3].contains(try AXDTX.integer(message.payload, 0) & 0xff) else {
                throw AXDTX.Failure("Legacy Instruments rejected \(selector)")
            }
            return try AXDTX.object(message.payload)
        }
        throw AXDTX.Failure("Legacy Instruments reply limit: \(selector)")
    }
}
