import Darwin
import Foundation

struct USBTouchPoint: Codable, Equatable {
    let x: Double
    let y: Double

    func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw AXDTX.Failure("USB coordinates must be finite fractions in 0...1")
        }
    }
}

/// Serial, single-contact state machine. A transport failure never replays a
/// contact. The same last position is used for best-effort cancellation release.
final class USBTouchContact {
    private let send: (USBTouchPoint, Bool) throws -> Void
    private(set) var point: USBTouchPoint?
    private(set) var releaseConfirmed = true
    init(send: @escaping (USBTouchPoint, Bool) throws -> Void) { self.send = send }
    func down(_ value: USBTouchPoint) throws {
        try value.validate()
        guard point == nil else { throw AXDTX.Failure("USB contact already held") }
        point = value; releaseConfirmed = false // A partial write may already have reached the device.
        do { try send(value, true) } catch { cancel(); throw error }
    }
    func move(_ value: USBTouchPoint) throws {
        try value.validate()
        guard point != nil else { throw AXDTX.Failure("USB contact is not held") }
        point = value
        do { try send(value, true) } catch { cancel(); throw error }
    }
    func up(_ value: USBTouchPoint) throws {
        try value.validate()
        guard point != nil else { return }
        point = value
        do { try send(value, false); point = nil; releaseConfirmed = true } catch { cancel(); throw error }
    }
    func cancel() {
        if let point {
            do { try send(point, false); releaseConfirmed = true } catch { releaseConfirmed = false }
        }
        point = nil
    }
}

/// Lives only in the app's isolated worker. No global alarm in the GUI process.
final class USBTouchSession {
    let physicalID: String
    let surface: UInt64
    let width: Int
    let height: Int
    private let readDisplay: () throws -> (Int, Int)
    private let ping: () throws -> Void
    private let now: () -> TimeInterval
    private var contact: USBTouchContact!
    private var lastDisplayCheck: TimeInterval = -.infinity
    private var downSince: TimeInterval?
    var interrupted: () -> Bool = { false }

    static func command(_ feature: String, identifier: String) -> [String: USBXPCValue] {
        var result = USBTouchWire.coreDeviceRequest(feature: feature)
        result["CoreDevice.deviceIdentifier"] = .text(identifier)
        return result
    }

    static func display(_ client: USBRemoteXPC, identifier: String) throws -> (Int, Int) {
        let answer = try client.request(command("com.apple.coredevice.feature.getdisplayinfo", identifier: identifier))
        return try displayDimensions(answer)
    }

    static func displayDimensions(_ answer: [String: Any]) throws -> (Int, Int) {
        guard answer["CoreDevice.error"] == nil,
              let output = answer["CoreDevice.output"] as? [String: Any],
              let displays = output["displays"] as? [[String: Any]],
              let primary = displays.first(where: { $0["primary"] as? Bool == true }),
              primary["external"] as? Bool == false,
              primary["currentOrientation"] as? String == "rot0",
              primary["nativeOrientation"] as? String == "rot0",
              output["backlightState"] as? String == "activeOn",
              let mode = primary["currentMode"] as? [String: Any], let rawSize = mode["size"] as? [NSNumber],
              rawSize.count == 2 else {
            throw AXDTX.Failure("USB touch requires an active portrait primary display")
        }
        let values = rawSize.map(\.doubleValue)
        guard values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 8192 && $0.rounded() == $0 }),
              values[1] > values[0] else {
            throw AXDTX.Failure("Invalid USB display dimensions")
        }
        let size = values.map { Int($0) }
        return (size[0], size[1])
    }

    static func touchscreen(_ answer: [String: Any]) throws -> UInt64 {
        guard let services = answer["connectedServices"] as? [[String: Any]] else {
            throw AXDTX.Failure("USB HID surfaces unavailable")
        }
        let matches = services.filter {
            ($0["PrimaryUsagePage"] as? NSNumber)?.intValue == 13
                && ($0["PrimaryUsage"] as? NSNumber)?.intValue == 4
                && $0["UniversalControlBuiltIn"] as? Bool == true
        }
        guard matches.count == 1, let number = matches[0]["_ServiceID"] as? NSNumber,
              number.uint64Value > 0 else { throw AXDTX.Failure("USB touchscreen identity ambiguous or unavailable") }
        return number.uint64Value
    }

    convenience init(physicalID: String, control: USBRemoteXPC, discovery: USBRemoteXPC,
         sender: USBRemoteXPC, identifier: String) throws {
        let dimensions = try Self.display(control, identifier: identifier)
        let surface = try Self.touchscreen(discovery.request([
            "featureIdentifier": .text("com.apple.coredevice.feature.remote.universalhidservice"),
            "messageType": .text("Request"), "payload": .dictionary(["connectedServices": .dictionary([:])])]))
        // Never query connectedServices on the report-sending connection.
        let target = surface
        self.init(physicalID: physicalID, dimensions: dimensions, surface: surface,
                  readDisplay: { try Self.display(control, identifier: identifier) },
                  ping: { try sender.ping() }, send: { point, touching in
            let bytes = try USBTouchWire.report(x: point.x, y: point.y, touching: touching,
                                                timestamp: DispatchTime.now().uptimeNanoseconds)
            try sender.send(["featureIdentifier": .text("com.apple.coredevice.feature.remote.universalhidservice"),
                "messageType": .text("Request"), "payload": .dictionary([
                    "send": .dictionary(["_0": .data(bytes), "_1": .uint(target)])])])
        })
        Thread.sleep(forTimeInterval: 0.4)
    }
    /// Transport injection for focused lifecycle tests; production supplies the
    /// same native sockets above. No alternate runtime/helper input path.
    init(physicalID: String, dimensions: (Int, Int), surface: UInt64,
         readDisplay: @escaping () throws -> (Int, Int), ping: @escaping () throws -> Void,
         send: @escaping (USBTouchPoint, Bool) throws -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.physicalID = physicalID; (width, height) = dimensions; self.surface = surface
        self.readDisplay = readDisplay; self.ping = ping; self.now = now
        contact = USBTouchContact(send: send)
    }
    deinit { contact?.cancel() }

    func checkDisplay() throws {
        do {
            let size = try readDisplay()
            guard size == (width, height) else { throw AXDTX.Failure("USB display changed; reprepare required") }
            lastDisplayCheck = now()
        } catch { cancel(); throw error }
    }
    private func validateHeldContact() throws {
        // Commands can arrive faster than the worker's poll timeout, so the
        // idle tick is not a safety boundary for a continuously held drag.
        if now() - lastDisplayCheck >= 0.5 { try checkDisplay() }
        if let start = downSince, now() - start > 60 {
            cancel(); throw AXDTX.Failure("USB held contact deadline exceeded")
        }
    }
    func tick() throws {
        try validateHeldContact()
        if let point = contact.point { try contact.move(point) }
    }
    func cancel() { contact.cancel(); downSince = nil }
    func finish() throws {
        if let point = contact.point { try contact.up(point) }
        guard contact.releaseConfirmed else { throw AXDTX.Failure("USB contact release unconfirmed") }
        downSince = nil
        try ping()
    }
    func execute(_ operation: String, points: [USBTouchPoint], duration: Double) throws {
        for point in points { try point.validate() }
        guard duration.isFinite, (0...60).contains(duration) else { throw AXDTX.Failure("Invalid USB gesture duration") }
        switch operation {
        case "down":
            guard points.count == 1 else { throw AXDTX.Failure("Expected one USB point") }
            try checkDisplay(); try contact.down(points[0]); downSince = now()
        case "move":
            guard points.count == 1 else { throw AXDTX.Failure("Expected one USB point") }
            try validateHeldContact(); try contact.move(points[0])
        case "up":
            guard points.count == 1 else { throw AXDTX.Failure("Expected one USB point") }
            try validateHeldContact(); try contact.up(points[0]); downSince = nil; try ping()
        case "cancel": cancel(); try ping()
        case "tap", "swipe":
            guard operation == "tap" ? points.count == 1 : (2...2048).contains(points.count),
                  operation != "swipe" || duration > 0 else { throw AXDTX.Failure("Invalid USB gesture path") }
            try checkDisplay()
            defer { cancel() }
            try contact.down(points[0]); downSince = now()
            let steps = max(4, Int(ceil(duration / 0.02)))
            for index in 1...steps {
                guard !interrupted() else { throw AXDTX.Failure("USB gesture cancelled; replayAllowed=false") }
                let progress = Double(index) / Double(steps) * Double(points.count - 1)
                let segment = min(points.count - 1, Int(progress))
                let next = min(points.count - 1, segment + 1)
                let fraction = progress - Double(segment)
                let point = USBTouchPoint(x: points[segment].x + (points[next].x - points[segment].x) * fraction,
                                          y: points[segment].y + (points[next].y - points[segment].y) * fraction)
                Thread.sleep(forTimeInterval: max(0.02, duration / Double(steps)))
                try validateHeldContact()
                try contact.move(point)
            }
            try contact.up(points.last!); downSince = nil; try ping()
        default: throw AXDTX.Failure("Unsupported USB touch operation")
        }
    }
}
