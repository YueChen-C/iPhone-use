import CoreFoundation
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

// Indigo envelope/mappings and settle timing reference sunghyun-k/iphone-use
// HIDService.swift / InputCommands.swift at 63472c34c0891d836ef7607cc88a15df5c7d59be (MIT).
/// Phone buttons use Indigo's consumer page, not keyboard navigation Home or
/// BLE's AC Home usage. Only single short presses are admitted (no combinations).
enum USBHardwareButton: String, Codable, CaseIterable {
    case home, power, volumeUp = "volume_up", volumeDown = "volume_down"
    static let service = "com.apple.coredevice.hid.indigo"
    var usage: UInt64 {
        switch self { case .home: 0x40; case .power: 0x30; case .volumeUp: 0xE9; case .volumeDown: 0xEA }
    }
    func request(state: UInt64) -> [String: USBXPCValue] {
        ["messageType": .text("IndigoButtonEvent"),
         "featureIdentifier": .text("com.apple.coredevice.feature.remote.hid.button"),
         "payload": .dictionary(["state": .uint(state), "usagePage": .uint(0x0C), "usageCode": .uint(usage)])]
    }
}

/// A partial write may already hold the button. Cancel that exact usage and
/// require release/PING before retirement; neither success nor failure replays it.
final class USBHardwareButtonState {
    private let send: (USBHardwareButton, UInt64) throws -> Void
    private let ping: () throws -> Void
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private var held: USBHardwareButton?
    private var releasedAt: TimeInterval?
    private(set) var releaseConfirmed = true
    init(send: @escaping (USBHardwareButton, UInt64) throws -> Void,
         ping: @escaping () throws -> Void,
         now: @escaping () -> TimeInterval, sleep: @escaping (TimeInterval) -> Void) {
        self.send = send; self.ping = ping; self.now = now; self.sleep = sleep
    }
    func press(_ button: USBHardwareButton, interrupted: () -> Bool) throws {
        guard held == nil, releaseConfirmed else { throw AXDTX.Failure("USB button release unconfirmed") }
        try sync() // Complete any prior acknowledged release before another press.
        guard !interrupted() else { throw AXDTX.Failure("USB button cancelled; no replay") }
        held = button; releaseConfirmed = false
        do {
            try send(button, 1)
            sleep(0.08)
            guard !interrupted() else { throw AXDTX.Failure("USB button cancelled; no replay") }
            try send(button, 2)
            held = nil; releaseConfirmed = true; releasedAt = now()
            try sync()
        } catch { cancel(); throw error }
    }
    func cancel() {
        guard let button = held else { return }
        do { try send(button, 3); releaseConfirmed = true; releasedAt = now() }
        catch { releaseConfirmed = false }
        held = nil
    }
    func sync() throws {
        guard releaseConfirmed else { throw AXDTX.Failure("USB button release unconfirmed") }
        guard let releasedAt else { return }
        try ping()
        // Closing/pressing too soon can cancel Home or turn it into a double
        // click. PING proves transport consumption, not SpringBoard completion.
        sleep(max(0, 0.8 - (now() - releasedAt)))
        self.releasedAt = nil
    }
}

/// Pure request validation shared by admission, IPC and the worker. Reject bad
/// caller parameters before they can retire an otherwise healthy USB session.
enum USBTouchRequest {
    static func validate(_ operation: String, points: [USBTouchPoint], duration: Double,
                         strokes: [USBKeyboardStroke]? = nil) throws {
        guard duration.isFinite, (0...60).contains(duration) else {
            throw AXDTX.Failure("Invalid USB gesture duration")
        }
        if USBHardwareButton(rawValue: operation) != nil {
            guard points.isEmpty, duration == 0, strokes == nil else { throw AXDTX.Failure("Invalid USB button request") }
            return
        }
        if operation == "keyboard" {
            guard points.isEmpty, duration == 0, let strokes else { throw AXDTX.Failure("Invalid USB keyboard request") }
            try USBKeyboardRequest.validate(strokes); return
        }
        guard strokes == nil else { throw AXDTX.Failure("Unexpected USB keyboard payload") }
        switch operation {
        case "down", "move", "up", "tap":
            guard points.count == 1 else { throw AXDTX.Failure("Expected one USB point") }
        case "swipe":
            guard (2...2048).contains(points.count), duration > 0 else {
                throw AXDTX.Failure("Invalid USB gesture path")
            }
        case "cancel":
            guard points.isEmpty else { throw AXDTX.Failure("USB cancellation takes no points") }
        default: throw AXDTX.Failure("Unsupported USB touch operation")
        }
        for point in points { try point.validate() }
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
        guard releaseConfirmed else { throw AXDTX.Failure("USB prior contact release unconfirmed; reprepare required") }
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
    let keyboardSurface: UInt64?
    private let readDisplay: () throws -> (Int, Int)
    private let ping: () throws -> Void
    private let now: () -> TimeInterval
    private var contact: USBTouchContact!
    private var keyboard: USBKeyboardState?
    private var buttons: USBHardwareButtonState?
    var supportsButtons: Bool { buttons != nil }
    private var displayMaySleep = false
    private var lastDisplayCheck: TimeInterval = -.infinity
    private var downSince: TimeInterval?
    var interrupted: () -> Bool = { false }

    static func hidRequest(_ payload: [String: USBXPCValue]) -> [String: USBXPCValue] {
        ["featureIdentifier": .text("com.apple.coredevice.feature.remote.universalhidservice"),
         "messageType": .text("Request"), "payload": .dictionary(payload)]
    }

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
              displays.allSatisfy({ boolean($0["primary"]) != nil }),
              displays.filter({ boolean($0["primary"]) == true }).count == 1,
              let primary = displays.first(where: { boolean($0["primary"]) == true }),
              boolean(primary["external"]) == false,
              primary["currentOrientation"] as? String == "rot0",
              primary["nativeOrientation"] as? String == "rot0",
              output["backlightState"] as? String == "activeOn",
              let mode = primary["currentMode"] as? [String: Any], let rawSize = mode["size"] as? [NSNumber],
              rawSize.count == 2,
              rawSize.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else {
            throw USBPreparationFailure(.displayUnavailable, "USB touch requires an active portrait primary display")
        }
        let values = rawSize.map(\.doubleValue)
        guard values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 8192 && $0.rounded() == $0 }),
              values[1] > values[0] else {
            throw USBPreparationFailure(.displayUnavailable, "Invalid USB display dimensions")
        }
        let size = values.map { Int($0) }
        return (size[0], size[1])
    }

    /// Preserve wire scalar types: NSNumber conversions otherwise wrap signed
    /// IDs and truncate floats (including usage-page selectors). Bool is not 1.
    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            guard number.int64Value >= 0 else { return nil }
            return UInt64(number.int64Value)
        case "C", "S", "I", "L", "Q": return number.uint64Value
        default: return nil
        }
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func isTrue(_ value: Any?) -> Bool { boolean(value) == true }
    private static func uniqueServiceID(_ service: [String: Any], among services: [[String: Any]]) -> UInt64? {
        guard let id = unsignedInteger(service["_ServiceID"]), id > 0,
              services.filter({ unsignedInteger($0["_ServiceID"]) == id }).count == 1 else { return nil }
        return id
    }

    static func touchscreen(_ answer: [String: Any]) throws -> UInt64 {
        guard let services = answer["connectedServices"] as? [[String: Any]] else {
            throw USBPreparationFailure(.touchscreenUnavailable, "USB HID surfaces unavailable")
        }
        let matches = services.filter {
            unsignedInteger($0["PrimaryUsagePage"]) == 13
                && unsignedInteger($0["PrimaryUsage"]) == 4
                && isTrue($0["UniversalControlBuiltIn"])
        }
        guard matches.count == 1, let id = uniqueServiceID(matches[0], among: services) else {
            throw USBPreparationFailure(.touchscreenUnavailable, "USB touchscreen identity ambiguous or unavailable")
        }
        return id
    }

    static func keyboardSurface(_ answer: [String: Any]) -> UInt64? {
        let services = answer["connectedServices"] as? [[String: Any]] ?? []
        let matches = services.filter { service in
            guard service["DeviceTypeHint"] as? String == "Keyboard",
                  let storage = service["_CoreDevice_codablePropertyStorage"] as? [String: Any],
                  let virtual = storage["UniversalControlVirtualService"] as? [String: Any], isTrue(virtual["bool"]),
                  let original = storage["_CoreDevice_originalUsages"] as? [String: Any],
                  let usages = original["array"] as? [[String: Any]] else { return false }
            // The observed public PrimaryUsage(Page) is 0, NOT 1/6.
            return usages.contains { entry in
                guard let pair = entry["dictionary"] as? [String: Any],
                      let page = pair["DeviceUsagePage"] as? [String: Any],
                      let usage = pair["DeviceUsage"] as? [String: Any] else { return false }
                return unsignedInteger(page["int"]) == 1 && unsignedInteger(usage["int"]) == 6
            }
        }
        guard matches.count == 1 else { return nil }
        return uniqueServiceID(matches[0], among: services)
    }

    convenience init(physicalID: String, control: USBRemoteXPC, discovery: USBRemoteXPC,
         sender: USBRemoteXPC, identifier: String, indigo: USBRemoteXPC? = nil) throws {
        let dimensions = try Self.display(control, identifier: identifier)
        let surfaces = try discovery.request(Self.hidRequest(["connectedServices": .dictionary([:])]))
        let surface = try Self.touchscreen(surfaces)
        let keyboardSurface = Self.keyboardSurface(surfaces)
        // Never query connectedServices on the report-sending connection.
        self.init(physicalID: physicalID, dimensions: dimensions, surface: surface, keyboardSurface: keyboardSurface,
                  readDisplay: { try Self.display(control, identifier: identifier) },
                  ping: { try sender.ping() }, send: { point, touching in
            let bytes = try USBTouchWire.report(x: point.x, y: point.y, touching: touching,
                                                timestamp: DispatchTime.now().uptimeNanoseconds)
            try sender.send(Self.hidRequest(["send": .dictionary(["_0": .data(bytes), "_1": .uint(surface)])]))
        }, sendKeyboard: { bytes in
            guard let keyboardSurface else { throw AXDTX.Failure("USB keyboard surface unavailable") }
            try sender.send(Self.hidRequest(["send": .dictionary(["_0": .data(bytes), "_1": .uint(keyboardSurface)])]))
        }, sendButton: indigo.map { client in { button, state in try client.send(button.request(state: state)) } },
           pingButtons: indigo.map { client in { try client.ping() } })
        Thread.sleep(forTimeInterval: 0.4)
    }
    /// Transport injection for focused lifecycle tests; production supplies the
    /// same native sockets above. No alternate runtime/helper input path.
    init(physicalID: String, dimensions: (Int, Int), surface: UInt64, keyboardSurface: UInt64? = nil,
         readDisplay: @escaping () throws -> (Int, Int), ping: @escaping () throws -> Void,
         send: @escaping (USBTouchPoint, Bool) throws -> Void,
         sendKeyboard: ((Data) throws -> Void)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         sendButton: ((USBHardwareButton, UInt64) throws -> Void)? = nil,
         pingButtons: (() throws -> Void)? = nil) {
        self.physicalID = physicalID; (width, height) = dimensions; self.surface = surface
        self.readDisplay = readDisplay; self.ping = ping; self.now = now
        contact = USBTouchContact(send: send)
        self.keyboardSurface = keyboardSurface
        if keyboardSurface != nil, let sendKeyboard { keyboard = USBKeyboardState(send: sendKeyboard) }
        if let sendButton, let pingButtons {
            buttons = USBHardwareButtonState(send: sendButton, ping: pingButtons, now: now, sleep: sleep)
        }
    }
    deinit { contact?.cancel(); keyboard?.cancel(); buttons?.cancel() }

    func checkDisplay() throws {
        do {
            let size = try readDisplay()
            guard size == (width, height) else { throw AXDTX.Failure("USB display changed; reprepare required") }
            lastDisplayCheck = now(); displayMaySleep = false
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
        // Power can legitimately turn the display off. Release verification
        // must not depend on backlight; coordinate input still checks it anew.
        if !displayMaySleep || contact.point != nil { try validateHeldContact() }
        if let point = contact.point { try contact.move(point) }
    }
    func cancel() { contact.cancel(); keyboard?.cancel(); buttons?.cancel(); downSince = nil }
    func finish() throws {
        if let point = contact.point { try contact.up(point) }
        guard contact.releaseConfirmed else { throw AXDTX.Failure("USB contact release unconfirmed") }
        keyboard?.cancel()
        guard keyboard?.releaseConfirmed != false else { throw AXDTX.Failure("USB keyboard release unconfirmed") }
        buttons?.cancel(); try buttons?.sync()
        downSince = nil
        try ping()
    }
    func execute(_ operation: String, points: [USBTouchPoint], duration: Double,
                 strokes: [USBKeyboardStroke]? = nil) throws {
        try USBTouchRequest.validate(operation, points: points, duration: duration, strokes: strokes)
        guard keyboard?.releaseConfirmed != false else { throw AXDTX.Failure("USB keyboard release unconfirmed") }
        guard buttons?.releaseConfirmed != false else { throw AXDTX.Failure("USB button release unconfirmed") }
        try buttons?.sync()
        if let button = USBHardwareButton(rawValue: operation) {
            guard let buttons else { throw AXDTX.Failure("USB Indigo button service unavailable") }
            guard contact.point == nil, contact.releaseConfirmed else { throw AXDTX.Failure("USB pointer busy or release unconfirmed") }
            if button == .power { displayMaySleep = true }
            try buttons.press(button, interrupted: interrupted)
            return
        }
        switch operation {
        case "keyboard":
            guard let keyboard, let strokes else { throw AXDTX.Failure("USB keyboard surface unavailable") }
            guard contact.point == nil, contact.releaseConfirmed else { throw AXDTX.Failure("USB pointer busy or release unconfirmed") }
            try checkDisplay()
            for stroke in strokes {
                try validateHeldContact()
                try keyboard.press(stroke, interrupted: interrupted)
            }
            try ping()
        case "down":
            try checkDisplay(); try contact.down(points[0]); downSince = now()
        case "move":
            try validateHeldContact(); try contact.move(points[0])
        case "up":
            try validateHeldContact(); try contact.up(points[0]); downSince = nil; try ping()
        case "cancel": cancel(); try finish()
        case "tap", "swipe":
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
