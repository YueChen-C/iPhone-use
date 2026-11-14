import Foundation

struct USBKeyboardStroke: Codable, Equatable {
    let code: UInt8
    let modifiers: UInt8

    init(code: UInt8, modifiers: UInt8 = 0) { self.code = code; self.modifiers = modifiers }
    init(_ stroke: KeyboardMap.Stroke) { self.init(code: stroke.code, modifiers: stroke.modifiers) }
    func validate() throws {
        guard (4..<0xE0).contains(code) else { throw AXDTX.Failure("Invalid USB keyboard usage") }
    }
}

/// CoreDevice 651.32 KeyboardReport: report ID 1, 232 usage bits, then
/// KeyboardFlags (zero). This is NOT the BLE/USB boot-keyboard 8-byte report.
/// The optional remote timestamp is omitted, as in KeyboardReport.init(usages:).
enum USBKeyboardReport {
    static func encode(code: UInt8? = nil, modifiers: UInt8 = 0) throws -> Data {
        if let code { try USBKeyboardStroke(code: code).validate() }
        var bytes = [UInt8](repeating: 0, count: 31)
        bytes[0] = 1
        if let code { bytes[1 + Int(code) / 8] |= 1 << (code % 8) }
        bytes[29] = modifiers // Keyboard usages E0...E7.
        return Data(bytes)
    }
}

/// Same worker/serial sender as touch. A partial key-down is already input;
/// failure only attempts all-keys-up, never retries the stroke or changes route.
final class USBKeyboardState {
    private let send: (Data) throws -> Void
    private let sleep: (TimeInterval) -> Void
    private(set) var releaseConfirmed = true
    private var held = false

    init(send: @escaping (Data) throws -> Void,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.send = send; self.sleep = sleep
    }
    func press(_ stroke: USBKeyboardStroke, interrupted: () -> Bool) throws {
        try stroke.validate()
        guard releaseConfirmed else { throw AXDTX.Failure("USB keyboard release unconfirmed; reprepare required") }
        guard !interrupted() else { throw AXDTX.Failure("USB keyboard cancelled; replayAllowed=false") }
        do {
            held = true; releaseConfirmed = false
            if stroke.modifiers != 0 {
                try send(USBKeyboardReport.encode(modifiers: stroke.modifiers)); sleep(0.025)
            }
            guard !interrupted() else { throw AXDTX.Failure("USB keyboard cancelled; replayAllowed=false") }
            try send(USBKeyboardReport.encode(code: stroke.code, modifiers: stroke.modifiers)); sleep(0.025)
            try send(USBKeyboardReport.encode(modifiers: stroke.modifiers)); sleep(0.025)
            if stroke.modifiers != 0 { try send(USBKeyboardReport.encode()); sleep(0.025) }
            held = false; releaseConfirmed = true
        } catch { cancel(); throw error }
    }
    func cancel() {
        guard held else { return }
        do { try send(USBKeyboardReport.encode()); releaseConfirmed = true }
        catch { releaseConfirmed = false }
        held = false
    }
}

enum USBKeyboardRequest {
    static let maximumStrokes = 512
    static func validate(_ strokes: [USBKeyboardStroke]) throws {
        guard !strokes.isEmpty, strokes.count <= maximumStrokes else {
            throw AXDTX.Failure("USB keyboard request must contain 1...512 strokes")
        }
        for stroke in strokes { try stroke.validate() }
    }
    static func text(_ text: String, modifiers: [String] = [], convertHanzi: Bool = false) throws -> [USBKeyboardStroke] {
        guard let mask = KeyboardMap.modifierMask(for: modifiers),
              let value = convertHanzi ? KeyboardMap.keyboardText(for: text) : text else {
            throw AXDTX.Failure("Unsupported USB text or modifier")
        }
        let strokes = try value.map { character -> USBKeyboardStroke in
            guard let stroke = KeyboardMap.stroke(for: character) else { throw AXDTX.Failure("Unsupported USB text character") }
            return USBKeyboardStroke(code: stroke.code, modifiers: stroke.modifiers | mask)
        }
        if !strokes.isEmpty { try validate(strokes) }
        return strokes
    }
    static func key(_ name: String, modifiers: [String]) throws -> USBKeyboardStroke {
        guard let code = KeyboardMap.code(for: name), let mask = KeyboardMap.modifierMask(for: modifiers) else {
            throw AXDTX.Failure("Unsupported USB key or modifier")
        }
        return USBKeyboardStroke(code: code, modifiers: mask)
    }
}

/// Window key-repeat must not build a delayed typing backlog behind HTTP text
/// or a slow device. Reserve the whole event (never half a shortcut), bound the
/// outstanding stroke cost, and discard stale events before the first report.
final class USBKeyboardGate {
    struct Ticket { fileprivate let id: UUID; fileprivate let deadline: TimeInterval }
    static let maximumWindowStrokes = 32
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var pending: [UUID: Int] = [:]
    private var cost = 0

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    func begin(strokes: Int) -> Ticket? {
        lock.withLock {
            guard strokes > 0, strokes <= Self.maximumWindowStrokes - cost else { return nil }
            let ticket = Ticket(id: UUID(), deadline: now() + 0.5)
            pending[ticket.id] = strokes; cost += strokes
            return ticket
        }
    }
    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.withLock { pending[ticket.id] != nil && now() <= ticket.deadline }
    }
    func finish(_ ticket: Ticket) {
        lock.withLock { if let strokes = pending.removeValue(forKey: ticket.id) { cost -= strokes } }
    }
    func cancel() { lock.withLock { pending.removeAll(); cost = 0 } }
}
