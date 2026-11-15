import Darwin
import Foundation

/// Minimal read-only Remote Service Discovery over HTTP/2. Implements wire
/// primitives locally; no Python/Rust runtime or vendored executable dependency.
protocol AXByteStream: AnyObject {
    func read(_ count: Int) throws -> Data
    func send(_ data: Data) throws
}

// Owns a duplicated broker FD. CoreDevice returns nonblocking sockets; convert
// only this owned descriptor to bounded blocking IO, never reconnect to RSD.
final class AXSocket: AXByteStream {
    private let descriptor: Int32
    init(taking descriptor: Int32) throws {
        guard descriptor >= 0 else { throw AXDTX.Failure("Invalid broker descriptor") }
        do {
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                throw AXDTX.Failure("Broker descriptor blocking mode failed: \(errno)")
            }
            var timeout = timeval(tv_sec: 5, tv_usec: 0), enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw AXDTX.Failure("Broker descriptor socket options failed: \(errno)")
            }
        } catch { close(descriptor); throw error }
        self.descriptor = descriptor
    }
    deinit { close(descriptor) }
    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= AXDTX.limit else { throw AXDTX.Failure("Broker socket read exceeds limit") }
        var bytes = Data(count: count), offset = 0
        while offset < count {
            let n = bytes.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw AXDTX.Failure("Broker socket receive failed/closed: \(n == 0 ? 0 : errno)") }
            offset += n
        }
        return bytes
    }
    func send(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw AXDTX.Failure("Broker socket send failed: \(errno)") }
            offset += n
        }
    }
}

enum AXRSD {
    static func frame(type: UInt8, flags: UInt8 = 0, stream: UInt32 = 0, data: Data = Data()) -> Data {
        let n = data.count
        return Data([UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255), type, flags])
            + Data([UInt8((stream >> 24) & 127), UInt8((stream >> 16) & 255), UInt8((stream >> 8) & 255), UInt8(stream & 255)]) + data
    }
    static func wrapper(flags: UInt64, object: Data? = nil, id: UInt64 = 0) -> Data {
        let payload = object.map { AXDTX.number(0x42133742) + AXDTX.number(5) + $0 } ?? Data()
        return AXDTX.number(0x29b00b92) + AXDTX.number(flags) + AXDTX.number(UInt64(payload.count), bytes: 8)
            + AXDTX.number(id, bytes: 8) + payload
    }
    /// Incomplete frames stay buffered; complete envelopes consume exactly once.
    /// Keepalive wrappers decode to NSNull so callers can continue draining.
    static func decodeWrapper(_ buffer: inout Data, emptyPayloadLimit: UInt64 = 0) throws -> Any? {
        guard buffer.count >= 24 else { return nil }
        guard try AXDTX.integer(buffer, 0) == 0x29b00b92 else { throw AXDTX.Failure("Invalid XPC wrapper") }
        let length = try AXDTX.integer(buffer, 8, 8)
        guard length <= UInt64(AXDTX.limit - 24) else { throw AXDTX.Failure("XPC payload exceeds limit") }
        let end = 24 + Int(length)
        guard buffer.count >= end else { return nil }
        var result: Any = NSNull()
        if length > emptyPayloadLimit {
            guard length >= 8, try AXDTX.integer(buffer, 24) == 0x42133742,
                  try AXDTX.integer(buffer, 28) == 5 else { throw AXDTX.Failure("Invalid XPC payload header") }
            var decoder = AXRSDDecoder(data: buffer.subdata(in: 32..<end))
            result = try decoder.object()
        }
        buffer = Data(buffer.dropFirst(end))
        return result
    }
    static func discover(socket: AXByteStream) throws -> [String: Any] {
        try socket.send(Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8))
        try socket.send(frame(type: 4, data: Data([0, 3, 0, 0, 0, 100, 0, 4, 0, 16, 0, 0])))
        try socket.send(frame(type: 8, data: Data([0, 15, 0, 1])))
        try socket.send(frame(type: 1, flags: 4, stream: 1))
        let empty = AXDTX.number(0xf000) + AXDTX.number(4) + AXDTX.number(0)
        try socket.send(frame(type: 0, stream: 1, data: wrapper(flags: 1, object: empty)))
        try socket.send(frame(type: 0, stream: 1, data: wrapper(flags: 0x201)))
        try socket.send(frame(type: 1, flags: 4, stream: 3))
        try socket.send(frame(type: 0, stream: 3, data: wrapper(flags: 0x400001)))
        var buffers: [UInt32: Data] = [:]
        for _ in 0..<2048 {
            let h = try socket.read(9)
            let size = Int(h[0]) << 16 | Int(h[1]) << 8 | Int(h[2])
            let stream = UInt32(h[5] & 127) << 24 | UInt32(h[6]) << 16 | UInt32(h[7]) << 8 | UInt32(h[8])
            guard size <= 1024 * 1024 else { throw AXDTX.Failure("RSD frame exceeds limit") }
            let bytes = try socket.read(size)
            if h[3] == 4, h[4] & 1 == 0 { try socket.send(frame(type: 4, flags: 1)); continue }
            if h[3] == 6, h[4] & 1 == 0 { try socket.send(frame(type: 6, flags: 1, data: bytes)); continue }
            if h[3] == 7 || h[3] == 3 { throw AXDTX.Failure("RSD closed HTTP/2 stream") }
            guard h[3] == 0, stream == 1 || stream == 3 else { continue }
            var buffer = buffers[stream] ?? Data()
            guard buffer.count <= AXDTX.limit - bytes.count else { throw AXDTX.Failure("RSD message exceeds limit") }
            buffer += bytes
            while let object = try decodeWrapper(&buffer) {
                if let result = object as? [String: Any], result["Services"] != nil { return result }
            }
            buffers[stream] = buffer
        }
        throw AXDTX.Failure("RSD service discovery response limit")
    }
}

struct AXRSDDecoder {
    let data: Data
    private var offset = 0
    private var budget = 100_000
    init(data: Data) { self.data = data }
    private mutating func number(_ count: Int = 4) throws -> UInt64 {
        let n = try AXDTX.integer(data, offset, count); offset += count; return n
    }
    private mutating func bytes(_ count: Int, align: Bool = false) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw AXDTX.Failure("Truncated RSD XPC object") }
        let result = data.subdata(in: offset..<offset + count); offset += count
        if align { offset = (offset + 3) & ~3 }
        guard offset <= data.count else { throw AXDTX.Failure("Truncated RSD alignment") }
        return result
    }
    mutating func object(depth: Int = 0) throws -> Any {
        budget -= 1
        guard depth < 64, budget >= 0 else { throw AXDTX.Failure("RSD XPC nesting/node limit") }
        switch try number() {
        case 0x1000: return NSNull()
        case 0x2000: return try number() != 0
        case 0x3000: return Int64(bitPattern: try number(8))
        case 0x4000, 0x7000: return try number(8)
        case 0x5000: return Double(bitPattern: try number(8))
        case 0xa000: return try bytes(16)
        case 0x8000, 0x9000:
            let type = try AXDTX.integer(data, offset - 4)
            let length = Int(try number())
            let value = try bytes(length, align: true)
            if type == 0x8000 { return value }
            guard value.last == 0, let text = String(data: value.dropLast(), encoding: .utf8) else { throw AXDTX.Failure("Invalid RSD UTF-8") }
            return text
        case 0xe000, 0xf000:
            let type = try AXDTX.integer(data, offset - 4)
            let size = Int(try number()), start = offset
            guard size >= 4, size <= data.count - offset else { throw AXDTX.Failure("Invalid RSD collection size") }
            let count = Int(try number())
            guard count <= 50_000 else { throw AXDTX.Failure("RSD collection limit") }
            var dictionary: [String: Any] = [:], array: [Any] = []
            for _ in 0..<count {
                if type == 0xf000 {
                    let start = offset
                    while offset < data.count && data[offset] != 0 { offset += 1 }
                    guard offset < data.count, let key = String(data: data.subdata(in: start..<offset), encoding: .utf8) else { throw AXDTX.Failure("Invalid RSD key") }
                    offset = (offset + 4) & ~3
                    dictionary[key] = try object(depth: depth + 1)
                } else { array.append(try object(depth: depth + 1)) }
            }
            guard offset == start + size else { throw AXDTX.Failure("RSD collection size mismatch") }
            return type == 0xf000 ? dictionary : array
        default: throw AXDTX.Failure("Unsupported RSD XPC type")
        }
    }
}
