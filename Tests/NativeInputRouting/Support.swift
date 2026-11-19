import CoreFoundation
import Foundation

// Keep diagnostics visible without compiling the application lifecycle entry.
func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

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
// Only the native metadata-read boundary is simulated. The real compatibility
// policy, localized errors and controller admission remain under test.
enum DDIReviewRequest { case inspect(String) }
struct DDIReviewResult { let json: String }
struct DDIReviewClient {
    init(executable: URL) {}
    func run(_ request: DDIReviewRequest) throws -> DDIReviewResult {
        let versions = ["target": "26.5", "usb-release-failure": "26.5", "without-buttons": "26.5",
                        "button-release-failure": "26.5", "ios15": "15.4", "ios16": "16.7.12",
                        "ios17": "17.0", "unknown-version": "unknown"]
        let id: String
        switch request { case .inspect(let value): id = value }
        guard let version = versions[id] else { throw AXDTX.Failure("fixture inspection unavailable") }
        let data = try JSONSerialization.data(withJSONObject: ["productVersion": version])
        return DDIReviewResult(json: String(decoding: data, as: UTF8.self))
    }
}
struct DeviceError: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
final class ScreenCaptureSession {
    fileprivate(set) var id = ""
    let associationIdentity = UUID()
    let size: CGSize? = .init(width: 1170, height: 2532)
}
struct Device {
    let id: String
    let screen: ScreenCaptureSession
    init(id: String, screen: ScreenCaptureSession) {
        self.id = id; self.screen = screen
        screen.id = id
        ScreenCaptureManager.shared.register(screen)
    }
}
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    private let lock = NSLock()
    private var screens: [String: ScreenCaptureSession] = [:]
    var all: [ScreenCaptureSession] { lock.withLock { Array(screens.values) } }
    func register(_ screen: ScreenCaptureSession) { lock.withLock { screens[screen.id] = screen } }
    func isCurrent(_ screen: ScreenCaptureSession) -> Bool {
        lock.withLock { screens[screen.id] === screen }
    }
    func permitsPointerAssociation(for screen: ScreenCaptureSession) -> Bool { isCurrent(screen) }
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
    private var devices: [String: Device] = [:]
    func all() -> [Device] { lock.withLock { Array(devices.values) } }
    func retain(_ input: DeviceInput, for device: Device) {
        lock.withLock {
            devices[device.id] = device
            inputs[device.id, default: []].append(input)
        }
    }
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
