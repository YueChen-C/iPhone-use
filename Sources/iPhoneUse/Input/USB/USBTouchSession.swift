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
    private let control: USBRemoteXPC
    private let sender: USBRemoteXPC
    private let identifier: String
    private var contact: USBTouchContact!
    private var lastDisplayCheck = Date.distantPast
    private var downSince: Date?
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

    init(physicalID: String, control: USBRemoteXPC, discovery: USBRemoteXPC,
         sender: USBRemoteXPC, identifier: String) throws {
        self.physicalID = physicalID; self.control = control; self.sender = sender; self.identifier = identifier
        (width, height) = try Self.display(control, identifier: identifier)
        surface = try Self.touchscreen(discovery.request([
            "featureIdentifier": .text("com.apple.coredevice.feature.remote.universalhidservice"),
            "messageType": .text("Request"), "payload": .dictionary(["connectedServices": .dictionary([:])])]))
        // Never query connectedServices on the report-sending connection.
        let target = surface
        contact = USBTouchContact { point, touching in
            let bytes = try USBTouchWire.report(x: point.x, y: point.y, touching: touching,
                                                timestamp: DispatchTime.now().uptimeNanoseconds)
            try sender.send(["featureIdentifier": .text("com.apple.coredevice.feature.remote.universalhidservice"),
                "messageType": .text("Request"), "payload": .dictionary([
                    "send": .dictionary(["_0": .data(bytes), "_1": .uint(target)])])])
        }
        Thread.sleep(forTimeInterval: 0.4)
    }
    deinit { contact?.cancel() }

    func checkDisplay() throws {
        let size = try Self.display(control, identifier: identifier)
        guard size == (width, height) else { throw AXDTX.Failure("USB display changed; reprepare required") }
        lastDisplayCheck = Date()
    }
    func tick() throws {
        if Date().timeIntervalSince(lastDisplayCheck) > 0.5 { try checkDisplay() }
        if let start = downSince, Date().timeIntervalSince(start) > 60 {
            cancel(); throw AXDTX.Failure("USB held contact deadline exceeded")
        }
        if let point = contact.point { try contact.move(point) }
    }
    func cancel() { contact.cancel(); downSince = nil }
    func finish() throws {
        if let point = contact.point { try contact.up(point) }
        guard contact.releaseConfirmed else { throw AXDTX.Failure("USB contact release unconfirmed") }
        downSince = nil
        try sender.ping()
    }
    func execute(_ operation: String, points: [USBTouchPoint], duration: Double) throws {
        for point in points { try point.validate() }
        guard duration.isFinite, (0...60).contains(duration) else { throw AXDTX.Failure("Invalid USB gesture duration") }
        switch operation {
        case "down":
            guard points.count == 1 else { throw AXDTX.Failure("Expected one USB point") }
            try checkDisplay(); try contact.down(points[0]); downSince = Date()
        case "move":
            guard points.count == 1 else { throw AXDTX.Failure("Expected one USB point") }
            try contact.move(points[0])
        case "up":
            guard points.count == 1 else { throw AXDTX.Failure("Expected one USB point") }
            try contact.up(points[0]); downSince = nil; try sender.ping()
        case "cancel": cancel(); try sender.ping()
        case "tap", "swipe":
            guard operation == "tap" ? points.count == 1 : (2...2048).contains(points.count),
                  operation != "swipe" || duration > 0 else { throw AXDTX.Failure("Invalid USB gesture path") }
            try checkDisplay()
            defer { cancel() }
            try contact.down(points[0]); downSince = Date()
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
                if Date().timeIntervalSince(lastDisplayCheck) > 0.5 { try checkDisplay() }
                try contact.move(point)
            }
            try contact.up(points.last!); downSince = nil; try sender.ping()
        default: throw AXDTX.Failure("Unsupported USB touch operation")
        }
    }
}
