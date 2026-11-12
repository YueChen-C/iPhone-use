import Darwin
import Foundation

/// Source-built USB CoreDeviceProxy connection. A fresh CDTunnel advertises its
/// actual RSD port; never guess the port of another process's existing tunnel.
final class AXUSBProxy: AXByteStream {
    private(set) var legacy = false
    private var rawSocket: Int32?
    typealias DeviceCall = @convention(c) (UnsafeRawPointer) -> Int32
    private let library: AXMobileDeviceLibrary
    private var devices: CFArray?
    private var device: UnsafeRawPointer?
    private var connection: UnsafeRawPointer?
    private var subscription: UnsafeMutableRawPointer?
    private var session = false
    private let readBytes: @convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer, Int) -> Int
    private let writeBytes: @convention(c) (UnsafeRawPointer, UnsafeRawPointer, Int) -> Int
    private let stop: DeviceCall
    private let disconnect: DeviceCall
    private let invalidate: @convention(c) (UnsafeRawPointer) -> Void
    private let unsubscribe: @convention(c) (UnsafeMutableRawPointer) -> Int32
    private(set) var client = Data(), server = Data()
    private(set) var rsdPort: UInt16 = 0

    init(device id: String) throws {
        let library = try AXMobileDeviceLibrary()
        self.library = library
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(library.handle, name) else { throw AXDTX.Failure("Apple symbol unavailable: \(name)") }
            return unsafeBitCast(p, to: T.self)
        }
        typealias Read = @convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer, Int) -> Int
        typealias Write = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, Int) -> Int
        typealias VoidCall = @convention(c) (UnsafeRawPointer) -> Void
        typealias Unsubscribe = @convention(c) (UnsafeMutableRawPointer) -> Int32
        readBytes = try symbol("AMDServiceConnectionReceive", Read.self)
        writeBytes = try symbol("AMDServiceConnectionSend", Write.self)
        stop = try symbol("AMDeviceStopSession", DeviceCall.self)
        disconnect = try symbol("AMDeviceDisconnect", DeviceCall.self)
        invalidate = try symbol("AMDServiceConnectionInvalidate", VoidCall.self)
        unsubscribe = try symbol("AMDeviceNotificationUnsubscribe", Unsubscribe.self)
        typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        typealias Subscribe = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        typealias List = @convention(c) () -> Unmanaged<CFArray>?
        typealias Identifier = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
        typealias Start = @convention(c) (UnsafeRawPointer, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeRawPointer?>) -> Int32
        let subscribe = try symbol("AMDeviceNotificationSubscribe", Subscribe.self)
        let list = try symbol("AMDCreateDeviceList", List.self)
        let identifier = try symbol("AMDeviceCopyDeviceIdentifier", Identifier.self)
        let interface = try symbol("AMDeviceGetInterfaceType", DeviceCall.self)
        let connect = try symbol("AMDeviceConnect", DeviceCall.self)
        let paired = try symbol("AMDeviceIsPaired", DeviceCall.self)
        let validate = try symbol("AMDeviceValidatePairing", DeviceCall.self)
        let start = try symbol("AMDeviceStartSession", DeviceCall.self)
        let service = try symbol("AMDeviceSecureStartService", Start.self)
        typealias CopyValue = @convention(c) (UnsafeRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
        typealias GetSocket = @convention(c) (UnsafeRawPointer) -> Int32
        let copyValue = try symbol("AMDeviceCopyValue", CopyValue.self)
        let getSocket = try symbol("AMDServiceConnectionGetSocket", GetSocket.self)
        do {
            try check(subscribe({ _, _ in }, 0, 0, nil, &subscription), "USB discovery")
            CFRunLoopRunInMode(.defaultMode, 1, false)
            devices = list()?.takeRetainedValue()
            guard let devices else { throw AXDTX.Failure("USB device list unavailable") }
            for i in 0..<CFArrayGetCount(devices) {
                guard let d = CFArrayGetValueAtIndex(devices, i), interface(d) == 1,
                      identifier(d)?.takeRetainedValue() as String? == id else { continue }
                try check(connect(d), "USB connect")
                device = d
                guard paired(d) == 1 else { throw AXDTX.Failure("Selected iPhone is not trusted") }
                try check(validate(d), "validate pairing")
                try check(start(d), "start session"); session = true
                guard let version = copyValue(d, nil, "ProductVersion" as CFString)?.takeRetainedValue() as? String else {
                    throw AXDTX.Failure("Selected iPhone did not report ProductVersion")
                }
                legacy = try Self.usesLegacyService(version: version)
                let name = legacy ? "com.apple.accessibility.axAuditDaemon.remoteserver"
                                  : "com.apple.internal.devicecompute.CoreDeviceProxy"
                try check(service(d, name as CFString, nil, &connection),
                          legacy ? "Legacy AX service (requires mounted developer image and UI Automation)"
                                 : "CoreDeviceProxy (requires supported iOS/developer services)")
                if legacy, let connection {
                    // This service uses TLS only for startup authentication, then raw DTX.
                    let fd = getSocket(connection)
                    guard fd >= 0 else { throw AXDTX.Failure("Legacy AX service socket unavailable") }
                    rawSocket = fd
                    var noPipe: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
                }
                break
            }
            guard connection != nil else { throw AXDTX.Failure("Selected physical USB iPhone not found") }
            if legacy { return }
            let body = try JSONSerialization.data(withJSONObject: ["type": "clientHandshakeRequest", "mtu": 16000])
            try send(Data("CDTunnel".utf8) + Self.big(UInt64(body.count), 2) + body)
            let header = try receive(10)
            guard header.prefix(8) == Data("CDTunnel".utf8) else { throw AXDTX.Failure("Invalid CDTunnel header") }
            let length = Int(header[8]) * 256 + Int(header[9])
            guard let response = try JSONSerialization.jsonObject(with: receive(length)) as? [String: Any],
                  let parameters = response["clientParameters"] as? [String: Any],
                  let client = parameters["address"] as? String, let server = response["serverAddress"] as? String,
                  let port = response["serverRSDPort"] as? Int, let rsdPort = UInt16(exactly: port), rsdPort > 0 else {
                throw AXDTX.Failure("Invalid CDTunnel negotiated endpoint")
            }
            self.client = try Self.ip(client); self.server = try Self.ip(server); self.rsdPort = rsdPort
        } catch { cleanup(); throw error }
    }
    deinit { cleanup() }
    private func cleanup() {
        if let connection { invalidate(connection); Unmanaged<CFTypeRef>.fromOpaque(connection).release(); self.connection = nil }
        if let device { if session { _ = stop(device) }; _ = disconnect(device); self.device = nil }
        if let subscription { _ = unsubscribe(subscription); self.subscription = nil }
    }
    private func check(_ code: Int32, _ operation: String) throws {
        guard code == 0 else { throw AXDTX.Failure("\(operation): 0x\(String(UInt32(bitPattern: code), radix: 16))") }
    }
    static func usesLegacyService(version: String) throws -> Bool {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(fields[0]), major >= 15 else {
            throw AXDTX.Failure("AX requires a valid iOS version >= 15; received \(version)")
        }
        return major < 17
    }
    func read(_ count: Int) throws -> Data { try receive(count) }
    func receive(_ count: Int) throws -> Data {
        guard let connection, count >= 0, count <= AXDTX.limit else { throw AXDTX.Failure("Invalid USB read") }
        var data = Data(count: count), offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { buffer in
                let p = buffer.baseAddress!.advanced(by: offset)
                if let rawSocket { return Darwin.recv(rawSocket, p, count - offset, 0) }
                return readBytes(connection, p, count - offset)
            }
            guard n > 0, n <= count - offset else { throw AXDTX.Failure("USB tunnel receive failed") }
            offset += n
        }
        return data
    }
    func send(_ data: Data) throws {
        guard let connection else { throw AXDTX.Failure("USB tunnel closed") }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { buffer in
                let p = buffer.baseAddress!.advanced(by: offset)
                if let rawSocket { return Darwin.send(rawSocket, p, data.count - offset, 0) }
                return writeBytes(connection, p, data.count - offset)
            }
            guard n > 0, n <= data.count - offset else { throw AXDTX.Failure("USB tunnel send failed") }
            offset += n
        }
    }
    static func big(_ n: UInt64, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
    }
    private static func ip(_ text: String) throws -> Data {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { throw AXDTX.Failure("Invalid tunnel IPv6") }
        return withUnsafeBytes(of: &address) { Data($0) }
    }
}

/// Small synchronous TCP endpoint carried by a reliable, ordered USB stream.
/// Only one active connection is consumed at a time. Unexpected sequence/flags
/// fail closed rather than silently corrupting an AX snapshot.
final class AXTunnelSocket: AXByteStream {
    private let tunnel: AXUSBProxy
    private let remote: UInt16
    private let local: UInt16
    private var sequence = UInt32.random(in: 1...0x7fff_ffff)
    private var acknowledgement: UInt32 = 0
    private var pending = Data()
    private var closed = false
    private let stateLock = NSRecursiveLock()
    init(tunnel: AXUSBProxy, port: UInt16, local: UInt16) throws {
        self.tunnel = tunnel; remote = port; self.local = local
        try segment(flags: 2)
        sequence &+= 1
        let packet = try next()
        guard packet.flags & 0x12 == 0x12, packet.ack == sequence else { throw AXDTX.Failure("Invalid tunnel TCP SYN ACK") }
        acknowledgement = packet.seq &+ 1
        try segment(flags: 16)
    }
    deinit { try? segment(flags: 4 | 16) }
    func send(_ bytes: Data) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { throw AXDTX.Failure("Tunnel TCP closed") }
        var offset = 0
        while offset < bytes.count {
            let size = min(1200, bytes.count - offset)
            try segment(flags: 24, payload: bytes.subdata(in: offset..<offset + size))
            sequence &+= UInt32(size); offset += size
        }
    }
    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= AXDTX.limit else { throw AXDTX.Failure("Tunnel TCP read exceeds limit") }
        while pending.count < count {
            guard !closed else { throw AXDTX.Failure("Tunnel TCP closed before full AX message") }
            let packet = try next()
            if packet.flags & 4 != 0 { throw AXDTX.Failure("Tunnel TCP reset") }
            if !packet.payload.isEmpty {
                guard packet.seq == acknowledgement else { throw AXDTX.Failure("Tunnel TCP out-of-order data") }
                guard pending.count <= AXDTX.limit - packet.payload.count else { throw AXDTX.Failure("Tunnel TCP buffer limit") }
                pending += packet.payload
                // Serialize ACK/sequence state and USB writes with the caller's
                // subscribe/unsubscribe/DTX replies while receive is pending.
                stateLock.lock()
                acknowledgement &+= UInt32(packet.payload.count)
                defer { stateLock.unlock() }
                try segment(flags: 16)
            }
            if packet.flags & 1 != 0 {
                stateLock.lock()
                defer { stateLock.unlock() }
                acknowledgement &+= 1; closed = true; try segment(flags: 16)
            }
        }
        let result = pending.prefix(count); pending = Data(pending.dropFirst(count)); return Data(result)
    }
    private func segment(flags: UInt8, payload: Data = Data()) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        var tcp = AXUSBProxy.big(UInt64(local), 2) + AXUSBProxy.big(UInt64(remote), 2)
        tcp += AXUSBProxy.big(UInt64(sequence), 4) + AXUSBProxy.big(UInt64(acknowledgement), 4)
        tcp += Data([0x50, flags, 0xff, 0xff, 0, 0, 0, 0]) + payload
        let pseudo = tunnel.client + tunnel.server + AXUSBProxy.big(UInt64(tcp.count), 4) + Data([0, 0, 0, 6])
        let sum = Self.checksum(pseudo + tcp)
        tcp[16] = UInt8(sum >> 8); tcp[17] = UInt8(sum & 255)
        let ipv6 = Data([0x60, 0, 0, 0]) + AXUSBProxy.big(UInt64(tcp.count), 2) + Data([6, 64]) + tunnel.client + tunnel.server
        try tunnel.send(ipv6 + tcp)
    }
    private func next() throws -> (seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) {
        for _ in 0..<8192 {
            let header = try tunnel.receive(40)
            let length = Int(header[4]) << 8 | Int(header[5])
            guard header[0] >> 4 == 6, length <= 16000 else { throw AXDTX.Failure("Invalid tunnel IPv6 packet") }
            let body = try tunnel.receive(length)
            guard header[6] == 6, length >= 20,
                  header.subdata(in: 8..<24) == tunnel.server, header.subdata(in: 24..<40) == tunnel.client else { continue }
            let source = Int(body[0]) << 8 | Int(body[1]), dest = Int(body[2]) << 8 | Int(body[3])
            guard source == Int(remote), dest == Int(local) else { continue }
            let offset = Int(body[12] >> 4) * 4
            guard offset >= 20, offset <= body.count else { throw AXDTX.Failure("Invalid tunnel TCP header") }
            let pseudo = tunnel.server + tunnel.client + AXUSBProxy.big(UInt64(body.count), 4) + Data([0, 0, 0, 6])
            guard Self.checksum(pseudo + body) == 0 else { throw AXDTX.Failure("Invalid tunnel TCP checksum") }
            func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(body[offset + $1]) } }
            return (u32(4), u32(8), body[13], body.subdata(in: offset..<body.count))
        }
        throw AXDTX.Failure("Tunnel TCP packet limit exceeded")
    }
    static func checksum(_ bytes: Data) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[i]) << 8 | (i + 1 < bytes.count ? UInt32(bytes[i + 1]) : 0)
        }
        while sum >> 16 != 0 { sum = (sum & 65535) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

/// Own dlopen through throwing initializers as well as successful sessions.
private final class AXMobileDeviceLibrary {
    let handle: UnsafeMutableRawPointer
    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_LOCAL) else {
            throw AXDTX.Failure("Apple MobileDevice unavailable")
        }
        self.handle = handle
    }
    deinit { dlclose(handle) }
}
