import Foundation

/// Small, bounded DTX codec for the native AX service. No third-party runtime,
/// dynamic Objective-C class decoding, or downloaded executables are involved.
enum AXDTX {
    static let limit = 16 * 1024 * 1024
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    struct Message {
        let identifier: UInt32
        let conversation: UInt32
        let channel: UInt32
        let expectsReply: Bool
        let payload: Data
    }

    static func integer(_ data: Data, _ offset: Int, _ bytes: Int = 4) throws -> UInt64 {
        guard offset >= 0, bytes > 0, bytes <= 8, offset <= data.count - bytes else {
            throw Failure("Truncated AX DTX integer")
        }
        return (0..<bytes).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }

    static func number(_ value: UInt64, bytes: Int = 4) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    static func packet(id: UInt32, conversation: UInt32 = 0, channel: UInt32 = 0,
                       reply: Bool = false, payload: Data) -> Data {
        var data = number(0x1f3d5b79) + number(32)
        data += number(0, bytes: 2) + number(1, bytes: 2) + number(UInt64(payload.count))
        data += number(UInt64(id)) + number(UInt64(conversation)) + number(UInt64(channel))
        data += number(reply ? 1 : 0)
        return data + payload
    }

    static func call(id: UInt32, selector: String, argument: Any) throws -> Data {
        try call(id: id, selector: selector, arguments: [argument])
    }

    static func call(id: UInt32, selector: String, arguments: [Any] = [], reply: Bool = false) throws -> Data {
        let selector = try NSKeyedArchiver.archivedData(withRootObject: selector, requiringSecureCoding: false)
        var entries = Data()
        for argument in arguments {
            let value = try NSKeyedArchiver.archivedData(withRootObject: argument, requiringSecureCoding: false)
            entries += number(10) + number(2) + number(UInt64(value.count)) + value
        }
        let aux = entries.isEmpty ? Data() : number(0x1f0, bytes: 8) + number(UInt64(entries.count), bytes: 8) + entries
        let payload = number(2) + number(UInt64(aux.count)) + number(UInt64(aux.count + selector.count), bytes: 8)
            + aux + selector
        return packet(id: id, reply: reply, payload: payload)
    }

    static func object(_ payload: Data) throws -> Any? {
        // Validate the envelope using the same bounds as auxiliary decoding.
        _ = try auxiliaryArchives(payload)
        let start = 16 + Int(try integer(payload, 4))
        return start == payload.count ? nil : try AXArchive(payload.subdata(in: start..<payload.count)).decode()
    }

    static func response(to message: Message, object: Any) throws -> Data {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
        let payload = number(3) + number(0) + number(UInt64(archive.count), bytes: 8) + archive
        return packet(id: message.identifier, conversation: message.conversation &+ 1,
                      channel: message.channel, payload: payload)
    }

    static func receive(read: (Int) throws -> Data) throws -> Message {
        var full = Data()
        var identifier: UInt32 = 0, conversation: UInt32 = 0, channel: UInt32 = 0
        var expectsReply = false
        var expectedCount: Int?
        for index in 0..<1024 {
            let header = try read(32)
            guard try integer(header, 0) == 0x1f3d5b79, try integer(header, 4) == 32 else {
                throw Failure("Invalid AX DTX header")
            }
            let fragment = Int(try integer(header, 8, 2))
            let count = Int(try integer(header, 10, 2))
            let length = Int(try integer(header, 12))
            let id = UInt32(try integer(header, 16))
            let conv = UInt32(try integer(header, 20))
            let ch = UInt32(try integer(header, 24))
            guard count > 0, count <= 1024, fragment == index, length <= limit,
                  expectedCount == nil || expectedCount == count else {
                throw Failure("Invalid AX DTX fragments")
            }
            if index == 0 {
                expectedCount = count
                identifier = id; conversation = conv; channel = ch
                expectsReply = try integer(header, 28) != 0
            } else if id != identifier || conv != conversation || ch != channel {
                throw Failure("Mismatched AX DTX fragments")
            }
            // A multipart first fragment advertises the total length but has no body.
            if count > 1 && index == 0 { continue }
            guard full.count <= limit - length else { throw Failure("AX DTX message exceeds limit") }
            let bytes = try read(length)
            guard bytes.count == length else { throw Failure("Truncated AX DTX payload") }
            full += bytes
            if index == count - 1 {
                return Message(identifier: identifier, conversation: conversation, channel: channel,
                               expectsReply: expectsReply, payload: full)
            }
        }
        throw Failure("Too many AX DTX fragments")
    }

    static func auxiliaryArchives(_ payload: Data) throws -> [Data] {
        guard payload.count >= 16 else { throw Failure("Truncated AX DTX payload header") }
        let flags = try integer(payload, 0)
        guard flags & 0xff000 == 0 else { throw Failure("Compressed AX DTX payload unsupported") }
        let auxSize = Int(try integer(payload, 4))
        let total = try integer(payload, 8, 8)
        guard total == UInt64(payload.count - 16), auxSize <= payload.count - 16 else {
            throw Failure("Invalid AX DTX payload length")
        }
        if auxSize == 0 { return [] }
        // The low byte identifies a primitive dictionary; the upper bits are
        // flags (real devices also send values such as 0x79f0). Do not treat
        // the common writer value 0x1f0 as an exact wire magic.
        guard auxSize >= 16, try integer(payload, 16) & 0xff == 0xf0,
              try integer(payload, 20) == 0,
              try integer(payload, 24, 8) == UInt64(auxSize - 16) else { throw Failure("Invalid AX DTX auxiliary size=\(auxSize) head=\(payload.prefix(48).map { String(format: "%02x", $0) }.joined())") }
        var offset = 32
        let end = 16 + auxSize
        var archives: [Data] = []
        while offset < end {
            guard offset + 8 <= end, try integer(payload, offset) == 10 else {
                throw Failure("Invalid AX DTX argument")
            }
            let type = try integer(payload, offset + 4)
            offset += 8
            switch type {
            case 2:
                guard offset + 4 <= end else { throw Failure("Truncated AX argument size") }
                let size = Int(try integer(payload, offset)); offset += 4
                guard size <= end - offset else { throw Failure("Truncated AX archive") }
                archives.append(payload.subdata(in: offset..<offset + size)); offset += size
            case 3: offset += 4
            case 6: offset += 8
            default: throw Failure("Unsupported AX auxiliary type \(type)")
            }
            guard offset <= end else { throw Failure("Truncated AX scalar argument") }
        }
        return archives
    }
}
