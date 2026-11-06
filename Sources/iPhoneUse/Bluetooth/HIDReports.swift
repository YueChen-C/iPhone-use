import Foundation

/// Report IDs live in the Report Reference descriptor (0x2908), so notification
/// payloads leave the ID byte out.
enum ReportID: UInt8 {
    case keyboard = 1
    case absolutePointer = 2
    case relativeMouse = 3
    case consumer = 4
}

enum HIDReportMap {
    /// Largest value of the absolute pointer's X and Y axes.
    static let absoluteMax: Int = 32767

    // Separate HID services keep relative axes/buttons out of the absolute
    // pointer's report map. iOS otherwise routes its held touch as relative input.
    // Older hosts need the relative mouse on the first HID service.
    static let primaryReports: [ReportID] = [.keyboard, .relativeMouse, .consumer]
    static let absoluteReports: [ReportID] = [.absolutePointer]

    static func descriptor(for reports: [ReportID]) -> [UInt8] {
        reports.flatMap { id in
            switch id {
            case .keyboard: keyboard
            case .absolutePointer: absolutePointer
            case .relativeMouse: relativeMouse
            case .consumer: consumer
            }
        }
    }

    // 8-byte input: modifiers, reserved, 6 key codes. 1-byte LED output.
    static let keyboard: [UInt8] = [
        // Generic Desktop / Keyboard application collection and report ID.
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x85, ReportID.keyboard.rawValue,
        // Eight modifier bits, one reserved byte, then six key usages.
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        // Five LED output bits followed by three padding bits.
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0xC0,
    ]

    // 5-byte input: buttons, X (u16), Y (u16), both 0...absoluteMax.
    static let absolutePointer: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x85, ReportID.absolutePointer.rawValue,
        0x09, 0x01, 0xA1, 0x00,
        // Three button bits and five padding bits fill the first byte.
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
        0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        // X and Y are absolute unsigned 16-bit values with a 32767 maximum.
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
        0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F,
        0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0xC0, 0xC0,
    ]

    // 4-byte input: buttons, dX, dY, wheel (signed bytes).
    static let relativeMouse: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x85, ReportID.relativeMouse.rawValue,
        0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
        0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        // X, Y and wheel are signed relative counts in the range -127...127.
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0xC0, 0xC0,
    ]

    // 2-byte input: one consumer usage (Home is 0x0223).
    static let consumer: [UInt8] = [
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01,
        0x85, ReportID.consumer.rawValue,
        0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, 0xFF, 0x03,
        0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
        0xC0,
    ]
}

/// Notification payloads corresponding to `HIDReportMap`. Centralizing their
/// byte layout keeps gesture code independent of padding and byte order.
enum HIDReportPayload {
    static func keyboard(modifiers: UInt8 = 0, code: UInt8 = 0) -> [UInt8] {
        [modifiers, 0, code, 0, 0, 0, 0, 0]
    }

    static func absolutePointer(buttons: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        [buttons, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]
    }

    static func relativeMouse(buttons: UInt8, dx: Int = 0, dy: Int = 0) -> [UInt8] {
        [buttons, UInt8(bitPattern: Int8(dx)), UInt8(bitPattern: Int8(dy)), 0]
    }

    static func consumer(_ usage: UInt16) -> [UInt8] {
        [UInt8(usage & 0xFF), UInt8(usage >> 8)]
    }
}
