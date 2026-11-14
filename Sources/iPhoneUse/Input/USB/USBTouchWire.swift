import Darwin
import Foundation

// Protocol implementation written in Swift; no imported upstream Python code.
indirect enum USBXPCValue {
    case uint(UInt64), int(Int64), bool(Bool), text(String), data(Data), uuid(UUID)
    case array([USBXPCValue]), dictionary([String: USBXPCValue])

    func encode() -> Data {
        func tag(_ n: UInt64) -> Data { AXDTX.number(n) }
        func padded(_ data: Data) -> Data {
            data + Data(repeating: 0, count: (4 - data.count % 4) % 4)
        }
        switch self {
        case .uint(let n): return tag(0x4000) + AXDTX.number(n, bytes: 8)
        case .int(let n): return tag(0x3000) + AXDTX.number(UInt64(bitPattern: n), bytes: 8)
        case .bool(let b): return tag(0x2000) + tag(b ? 1 : 0)
        case .text(let s):
            let b = Data(s.utf8) + Data([0])
            return tag(0x9000) + tag(UInt64(b.count)) + padded(b)
        case .data(let b): return tag(0x8000) + tag(UInt64(b.count)) + padded(b)
        case .uuid(let id):
            var bytes = id.uuid
            return tag(0xa000) + withUnsafeBytes(of: &bytes) { Data($0) }
        case .array(let items):
            let body = tag(UInt64(items.count)) + items.reduce(Data()) { $0 + $1.encode() }
            return tag(0xe000) + tag(UInt64(body.count)) + body
        case .dictionary(let entries):
            var body = tag(UInt64(entries.count))
            for key in entries.keys.sorted() {
                body += padded(Data(key.utf8) + Data([0])) + entries[key]!.encode()
            }
            return tag(0xf000) + tag(UInt64(body.count)) + body
        }
    }
}

// Owns a duplicated broker FD. CoreDevice returns nonblocking sockets; convert
// only this owned descriptor to bounded blocking IO, never reconnect to RSD.
final class USBBrokerSocket: AXByteStream {
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

final class USBRemoteXPC {
    private let socket: AXByteStream
    private var nextID: UInt64 = 1
    private var buffers: [UInt32: Data] = [:]

    static func wrapper(_ object: USBXPCValue?, id: UInt64 = 0, flags: UInt64 = 1) -> Data {
        let body = object.map { AXDTX.number(0x42133742) + AXDTX.number(5) + $0.encode() } ?? Data()
        return AXDTX.number(0x29b00b92) + AXDTX.number(flags)
            + AXDTX.number(UInt64(body.count), bytes: 8) + AXDTX.number(id, bytes: 8) + body
    }

    init(socket: AXByteStream) throws {
        self.socket = socket
        try socket.send(Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8))
        try frame(4, data: Data([0, 3, 0, 0, 0, 100, 0, 4, 0, 16, 0, 0]))
        try frame(8, data: Data([0, 15, 0, 1]))
        try frame(1, flags: 4, stream: 1)
        try frame(0, stream: 1, data: Self.wrapper(.dictionary([:])))
        try frame(1, flags: 4, stream: 3)
        try frame(0, stream: 1, data: Self.wrapper(nil, flags: 0x201))
        try frame(0, stream: 3, data: Self.wrapper(nil, flags: 0x400001))
        for _ in 0..<100 {
            let (type, flags, _, bytes) = try receiveFrame()
            if type == 4 {
                if flags & 1 == 0 { try frame(4, flags: 1) }
                return
            }
            guard type == 8 else { throw AXDTX.Failure("Unexpected RemoteXPC handshake frame \(type): \(bytes.count) bytes") }
        }
        throw AXDTX.Failure("RemoteXPC handshake frame limit")
    }

    private func frame(_ type: UInt8, flags: UInt8 = 0, stream: UInt32 = 0, data: Data = Data()) throws {
        guard data.count <= 16384 else { throw AXDTX.Failure("Experimental XPC frame exceeds 16 KiB") }
        try socket.send(AXRSD.frame(type: type, flags: flags, stream: stream, data: data))
    }

    private func receiveFrame() throws -> (UInt8, UInt8, UInt32, Data) {
        let h = try socket.read(9)
        let size = Int(h[0]) << 16 | Int(h[1]) << 8 | Int(h[2])
        let stream = (5..<9).reduce(UInt32(0)) { ($0 << 8) | UInt32(h[$1]) } & 0x7fff_ffff
        guard size <= 1024 * 1024 else { throw AXDTX.Failure("XPC HTTP/2 frame exceeds limit") }
        let bytes = try socket.read(size)
        guard h[3] != 7, h[3] != 3 else { throw AXDTX.Failure("XPC HTTP/2 closed stream \(stream), payload=\(bytes.map { String(format: "%02x", $0) }.joined())") }
        return (h[3], h[4], stream, bytes)
    }

    func send(_ request: [String: USBXPCValue], reply: Bool = false) throws {
        let data = Self.wrapper(.dictionary(request), id: nextID, flags: reply ? 0x10101 : 0x101)
        try frame(0, stream: 1, data: data)
        nextID &+= 2 // Initiator requests must remain odd; even IDs can abort the daemon.
    }

    // A PING ACK confirms transport consumption, never UI acceptance.
    func ping() throws {
        var nonce = UUID().uuid
        let token = withUnsafeBytes(of: &nonce) { Data($0.prefix(8)) }
        try frame(6, data: token)
        for _ in 0..<4096 {
            let (type, flags, stream, bytes) = try receiveFrame()
            if type == 6 {
                guard bytes.count == 8, stream == 0 else { throw AXDTX.Failure("Invalid HTTP/2 PING") }
                if flags & 1 != 0, bytes == token { return }
                if flags & 1 == 0 { try frame(6, flags: 1, data: bytes) }
            } else if type == 4, flags & 1 == 0 { try frame(4, flags: 1) }
            else if type == 0, !bytes.isEmpty {
                let amount = AXUSBProxy.big(UInt64(bytes.count), 4)
                try frame(8, data: amount); try frame(8, stream: stream, data: amount)
            }
        }
        throw AXDTX.Failure("HTTP/2 PING acknowledgement frame limit")
    }

    func request(_ body: [String: USBXPCValue]) throws -> [String: Any] {
        try send(body, reply: true)
        for _ in 0..<4096 {
            let (type, flags, stream, data) = try receiveFrame()
            if type == 4, flags & 1 == 0 { try frame(4, flags: 1); continue }
            if type == 6, flags & 1 == 0 { try frame(6, flags: 1, data: data); continue }
            guard type == 0, stream == 1 || stream == 3 else { continue }
            if !data.isEmpty {
                let amount = AXUSBProxy.big(UInt64(data.count), 4)
                try frame(8, data: amount); try frame(8, stream: stream, data: amount)
            }
            var buffer = buffers[stream, default: Data()] + data
            guard buffer.count <= AXDTX.limit else { throw AXDTX.Failure("XPC message exceeds limit") }
            while buffer.count >= 24 {
                guard try AXDTX.integer(buffer, 0) == 0x29b00b92 else { throw AXDTX.Failure("Invalid XPC wrapper") }
                let size = try AXDTX.integer(buffer, 8, 8)
                guard size <= UInt64(AXDTX.limit - 24) else { throw AXDTX.Failure("XPC payload exceeds limit") }
                let end = 24 + Int(size)
                if buffer.count < end { break }
                if size > 8 {
                    guard try AXDTX.integer(buffer, 24) == 0x42133742,
                          try AXDTX.integer(buffer, 28) == 5 else { throw AXDTX.Failure("Invalid XPC payload header") }
                    var decoder = AXRSDDecoder(data: buffer.subdata(in: 32..<end))
                    let answer = try decoder.object()
                    buffer = Data(buffer.dropFirst(end)); buffers[stream] = buffer
                    if let object = answer as? [String: Any], !object.isEmpty { return object }
                } else { buffer = Data(buffer.dropFirst(end)) }
            }
            buffers[stream] = buffer
        }
        throw AXDTX.Failure("XPC response frame limit")
    }
}

enum USBTouchWire {
    static let hidService = "com.apple.coredevice.hid.universalhidservice"
    static let displayService = "com.apple.coredevice.displayservice"

    static func coreDeviceRequest(feature: String) -> [String: USBXPCValue] {
        ["CoreDevice.CoreDeviceDDIProtocolVersion": .int(2),
         "CoreDevice.coreDeviceVersion": .dictionary([
            "components": .array([.uint(397), .uint(24)]),
            "originalComponentsCount": .int(2), "stringValue": .text("397.24")]),
         "CoreDevice.deviceIdentifier": .text(UUID().uuidString),
         "CoreDevice.invocationIdentifier": .text(UUID().uuidString),
         "CoreDevice.featureIdentifier": .text(feature),
         "CoreDevice.action": .dictionary([:]), "CoreDevice.input": .dictionary([:])]
    }

    static func report(x: Double, y: Double, touching: Bool, timestamp: UInt64) throws -> Data {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw AXDTX.Failure("Touch coordinates must be finite fractions in 0...1")
        }
        var data = Data(repeating: 0, count: 58)
        data[0] = 9; data[1] = 1; data[2] = 5; data[3] = touching ? 0xc2 : 2
        data.replaceSubrange(4..<6, with: AXDTX.number(UInt64((x * 65535).rounded()), bytes: 2))
        data.replaceSubrange(6..<8, with: AXDTX.number(UInt64((y * 65535).rounded()), bytes: 2))
        data[40] = 2
        data.replaceSubrange(44..<50, with: AXDTX.number(timestamp, bytes: 6))
        return data
    }

}
