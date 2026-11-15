import CoreFoundation
import Foundation

// Pause exactly one production DeviceInput pacing boundary, without timing races.
final class InputPause {
    private let lock = NSLock()
    private var armed = false
    private var timeout = false
    var timedOut: Bool { lock.withLock { timeout } }
    let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { armed = true } }
    func open() { resume.signal() }
    func pause() {
        let stop = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            return true
        }
        guard stop else { return }
        entered.signal()
        if resume.wait(timeout: .now() + 7) != .success { lock.withLock { timeout = true } }
    }
}

// Hardware boundary only: production DeviceInput, HIDConnectionState,
// USBInputController/client/session/worker are compiled unchanged by the runner.
enum AXDTX {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ value: String) { description = value }
    }
}
struct DeviceError: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
final class ScreenCaptureSession {
    let associationIdentity = UUID()
    let size: CGSize? = .init(width: 1170, height: 2532)
}
struct Device {
    let id: String
    let screen: ScreenCaptureSession
}
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    func isCurrent(_ screen: ScreenCaptureSession) -> Bool { true }
    func permitsPointerAssociation(for screen: ScreenCaptureSession) -> Bool { true }
}

// Keep the actual BLE notification FIFO/readiness model; do not substitute an
// always-true release result. Backpressure prevents the simulated notify boundary.
final class HIDPeripheral {
    static let shared = HIDPeripheral()
    private let lock = NSLock()
    private var connections = HIDConnectionState()
    private var blocked: Set<UUID> = []
    private var accepted: [(UUID, ReportID, Data)] = []
    func subscribe(_ host: UUID) -> UUID {
        lock.withLock {
            for report in [ReportID.keyboard, .consumer, .absolutePointer, .relativeMouse] {
                connections.subscribe(.report(report), host: host)
            }
            return connections.sessions[host]!
        }
    }
    func block(_ host: UUID, _ value: Bool) {
        lock.withLock {
            if value { blocked.insert(host) } else { blocked.remove(host) }
            drain()
        }
    }
    func connectionSession(for host: UUID) -> UUID? { lock.withLock { connections.sessions[host] } }
    func isReady(report: ReportID, host: UUID, session: UUID?) -> Bool {
        lock.withLock { connections.isReady(report: report, host: host, session: session) }
    }
    func send(_ id: ReportID, _ bytes: [UInt8], to host: UUID, session: UUID?,
              isAllowed: (() -> Bool)? = nil, absoluteRelease: Bool = false) {
        lock.withLock {
            connections.enqueue(.report(id), data: Data(bytes), host: host, session: session,
                                isAllowed: isAllowed, absoluteRelease: absoluteRelease)
            drain()
        }
    }
    private func drain() {
        while let next = connections.nextPendingReportIndex(excludingHosts: blocked) {
            if case .report(let id) = next.report.channel {
                accepted.append((next.report.host, id, next.report.data))
            }
            connections.removePending(at: next.index)
        }
    }
    func waitForInputDrain(host: UUID, session: UUID?, timeout: TimeInterval = 1) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + min(timeout, 0.1)
        repeat {
            if lock.withLock({ () -> Bool in
                drain()
                return !connections.pending.contains { $0.host == host && $0.session == session && $0.channel.isInput }
            }) { return true }
            Thread.sleep(forTimeInterval: 0.001)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    func reports(_ host: UUID) -> [(ReportID, Data)] {
        lock.withLock { accepted.filter { $0.0 == host }.map { ($0.1, $0.2) } }
    }
    func pending(_ host: UUID) -> Int { lock.withLock { connections.pending.filter { $0.host == host }.count } }
}

// Registry fixture supplies known associations only. It deliberately performs
// no matching/calibration/real capture. Production registry caching is not covered.
final class DeviceRegistry {
    static let shared = DeviceRegistry()
    private let lock = NSLock()
    private var inputs: [String: [DeviceInput]] = [:]
    func retain(_ input: DeviceInput, for device: Device) { lock.withLock { inputs[device.id, default: []].append(input) } }
    func cancelBackgroundMotion(for device: Device) {
        for input in lock.withLock({ inputs[device.id] ?? [] }) { input.cancelBackgroundMotion() }
    }
    func releaseForBackendSwitch(_ device: Device) -> Bool {
        let old = lock.withLock { inputs[device.id] ?? [] }
        let unreleased = old.filter { !$0.releaseForBackendSwitch() }
        lock.withLock { inputs[device.id] = unreleased }
        return unreleased.isEmpty
    }
}

// This broker never opens an Apple framework/socket. The real worker loop and
// session still perform their own command validation, EOF release and PING.
indirect enum USBXPCValue {
    case text(String), dictionary([String: USBXPCValue]), data(Data), uint(UInt64)
}
enum USBTouchWire {
    static let hidService = "fixture.hid"
    static func coreDeviceRequest(feature: String) -> [String: USBXPCValue] { [:] }
    static func report(x: Double, y: Double, touching: Bool, timestamp: UInt64) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["x": x, "y": y, "touching": touching], options: [.sortedKeys])
    }
}
enum CoreDeviceTouchBroker {
    static func withSession(physicalID: String, _ body: (String, DispatchQueue, String, String) throws -> Void) throws {
        try body(physicalID, DispatchQueue(label: "fixture-broker"), physicalID, "fixture")
    }
    static func connect(_ name: String, service: String, queue: DispatchQueue,
                        deviceIdentifier: String, version: String) throws -> USBRemoteXPC {
        if name == USBHardwareButton.service, deviceIdentifier == "without-buttons" {
            throw USBPreparationFailure(.serviceUnavailable, "fixture Indigo absent")
        }
        return USBRemoteXPC(physicalID: deviceIdentifier)
    }
}
final class USBRemoteXPC {
    let physicalID: String
    init(physicalID: String) { self.physicalID = physicalID }
    func request(_ object: [String: USBXPCValue]) throws -> [String: Any] {
        if case .dictionary? = object["payload"] {
            return ["connectedServices": [
                ["_ServiceID": 7, "PrimaryUsagePage": 13, "PrimaryUsage": 4, "UniversalControlBuiltIn": true],
                ["_ServiceID": 8, "PrimaryUsagePage": 0, "PrimaryUsage": 0,
                 "DeviceTypeHint": "Keyboard", "_CoreDevice_codablePropertyStorage": [
                    "UniversalControlVirtualService": ["bool": true],
                    "_CoreDevice_originalUsages": ["array": [["dictionary": [
                        "DeviceUsagePage": ["int": 1], "DeviceUsage": ["int": 6]]]]]]]]]
        }
        return ["CoreDevice.output": ["backlightState": "activeOn", "displays": [[
            "primary": true, "external": false, "currentOrientation": "rot0", "nativeOrientation": "rot0",
            "currentMode": ["size": [1170, 2532]]]]]]
    }
    func send(_ value: [String: USBXPCValue]) throws {
        if case .text("IndigoButtonEvent")? = value["messageType"],
           case .dictionary(let payload)? = value["payload"],
           case .uint(let state)? = payload["state"], case .uint(let page)? = payload["usagePage"],
           case .uint(let usage)? = payload["usageCode"] {
            try record("button:\(page):\(usage):\(state)")
            if physicalID == "button-release-failure", state != 1 { throw AXDTX.Failure("fixture button release failure") }
            return
        }
        guard case .dictionary(let payload)? = value["payload"],
              case .dictionary(let send)? = payload["send"],
              case .data(let data)? = send["_0"],
              case .uint(let surface)? = send["_1"] else { throw AXDTX.Failure("fixture payload") }
        try record("surface:\(surface) report:" + data.base64EncodedString())
    }
    func ping() throws {
        if physicalID == "usb-release-failure" { throw AXDTX.Failure("injected PING failure") }
    }
    private func record(_ value: String) throws {
        guard let root = ProcessInfo.processInfo.environment["INPUT_ROUTING_FIXTURE_ROOT"] else {
            throw AXDTX.Failure("fixture output missing")
        }
        let path = URL(fileURLWithPath: root).appendingPathComponent(physicalID + ".transport")
        if !FileManager.default.fileExists(atPath: path.path) {
            guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
                throw AXDTX.Failure("fixture output creation failed")
            }
        }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((value + "\n").utf8))
    }
}
