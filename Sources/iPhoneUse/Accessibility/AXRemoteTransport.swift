import Darwin
import Foundation

/// Apple's own RemoteServiceDiscovery transport, not a bundled helper binary.
/// Resolve by physical UDID, never by mutable device name or 'first device'.
final class AXRemoteTransport {
    private let socket: AXByteStream
    let legacy: Bool

    static func resolve(device: String, list: String, property: (String) throws -> String) throws -> String {
        var matches: [String] = []
        for line in list.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, UUID(uuidString: String(fields[0])) != nil,
                  fields[1].hasPrefix("coredevice-") else { continue }
            let name = String(fields[1])
            if try property(name).trimmingCharacters(in: .whitespacesAndNewlines) == device { matches.append(name) }
        }
        guard matches.count == 1 else {
            throw AXDTX.Failure(matches.isEmpty
                ? "No trusted CoreDevice tunnel for selected UDID; requires iOS 17+, Developer Mode and developer services"
                : "Ambiguous CoreDevice tunnel for selected UDID")
        }
        return matches[0]
    }

    init(device: String) throws {
        let tunnel = try AXUSBProxy(device: device)
        legacy = tunnel.legacy
        if legacy { socket = tunnel; return }
        let discovery = try AXTunnelSocket(tunnel: tunnel, port: tunnel.rsdPort, local: 52001)
        let peer = try AXRSD.discover(socket: discovery)
        guard (peer["Properties"] as? [String: Any])?["UniqueDeviceID"] as? String == device else {
            throw AXDTX.Failure("RSD physical UDID mismatch; refusing AX connection")
        }
        guard let services = peer["Services"] as? [String: Any],
              let service = services["com.apple.accessibility.axAuditDaemon.remoteAXService"] as? [String: Any],
              let rawPort = service["Port"] as? String, let port = UInt16(rawPort), port > 0 else {
            throw AXDTX.Failure("Selected iPhone does not advertise remote AX service; check developer services/UI Automation")
        }
        socket = try AXTunnelSocket(tunnel: tunnel, port: port, local: 52002)
    }

    func read(_ count: Int) throws -> Data { try socket.read(count) }
    func send(_ data: Data) throws { try socket.send(data) }

    private static func devicectl(_ arguments: [String], output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl"] + arguments + ["--json-output", output.path, "--timeout", "6"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw AXDTX.Failure("Apple devicectl discovery failed; install/select full Xcode and trust the device")
        }
        guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= AXDTX.limit else {
            throw AXDTX.Failure("CoreDevice inventory exceeds limit")
        }
    }
}
