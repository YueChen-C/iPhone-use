import Darwin
import Foundation
import ImageIO

/// An independent screenshot addressed by physical USB UDID. Uses only macOS's
/// MobileDevice framework; no installed commands, Homebrew paths or bundled dylibs.
/// System calls can block during unplug, so run them in this executable's worker
/// mode with a deadline. The main process keeps its capture and Bluetooth sessions.
enum USBIdentityScreenshot {
    static let workerArgument = "--capture-identity-screenshot"
    static let unavailableExitCode: Int32 = 69
    static let failedExitCode: Int32 = 70

    /// Only kAMDInvalidServiceError means screenshotr is not offered by this
    /// phone. EOF and other transport errors must keep identity checks blocked.
    static func screenshotServiceIsUnavailable(_ code: Int32) -> Bool {
        UInt32(bitPattern: code) == 0xe800_0022
    }

    static func capture(physicalID: String) -> CaptureIdentityVerifier.Screenshot {
        guard let executable = Bundle.main.executableURL else { return .failed }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-use-capture-identity-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch { return .failed }
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("screen.png")
        let diagnostic = directory.appendingPathComponent("diagnostic.txt")
        guard FileManager.default.createFile(atPath: diagnostic.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: diagnostic)
        else { return .failed }
        defer { try? handle.close() }
        let status = run(
            executable: executable, arguments: [workerArgument, physicalID, output.path],
            timeout: 10, diagnostic: handle)
        if status == unavailableExitCode {
            let detail = (try? String(contentsOf: diagnostic, encoding: .utf8)) ?? ""
            log(
                "capture identity screenshot unavailable for \(physicalID): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
            return .unavailable
        }
        guard status == 0,
            let source = CGImageSourceCreateWithURL(output as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let signature = CaptureIdentityImage(image: image)
        else {
            let detail = (try? String(contentsOf: diagnostic, encoding: .utf8)) ?? ""
            log(
                "capture identity screenshot failed for \(physicalID): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
            return .failed
        }
        return .image(signature)
    }

    static func run(
        executable: URL, arguments: [String], timeout: TimeInterval, diagnostic: FileHandle = .nullDevice
    ) -> Int32? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostic
        guard (try? process.run(timeout: timeout)) == true else { return nil }
        guard process.terminationReason == .exit else { return nil }
        return process.terminationStatus
    }

    /// Only the isolated worker calls into MobileDevice. Do not attempt pairing,
    /// mount developer images, reset USB, or fall back to a different phone.
    static func write(physicalID: String, output: URL) -> Int32 {
        do {
            let data = try withDeveloperServiceFallback(legacy: {
                guard let services = NativeUSBDeviceServices() else { throw LegacyServiceUnavailable.notOffered }
                do { return try services.screenshot(physicalID: physicalID) }
                catch NativeUSBDeviceServices.Failure.unavailable { throw LegacyServiceUnavailable.notOffered }
            }, developer: { try CoreDeviceIdentityScreenshot.capture(physicalID: physicalID) })
            try data.write(to: output, options: .atomic)
            return 0
        } catch AXUSBProxy.Unsupported.legacyDevice {
            return unavailableExitCode
        } catch CoreDeviceIdentityScreenshot.Failure.serviceUnavailable {
            return unavailableExitCode
        } catch {
            log("native USB screenshot: \(error)")
            return failedExitCode
        }
    }

    /// The newer service is a capability fallback, not a retry for disconnects,
    /// trust failures, or malformed replies. Both calls stay in the same worker.
    static func withDeveloperServiceFallback(legacy: () throws -> Data, developer: () throws -> Data) throws -> Data {
        do { return try legacy() }
        catch LegacyServiceUnavailable.notOffered { return try developer() }
    }

    enum LegacyServiceUnavailable: Error { case notOffered }
}

/// Only the screenshot channel on the exact phone's own USB CoreDevice tunnel.
/// No input, network fallback, image mounting, or external helper is involved.
enum CoreDeviceIdentityScreenshot {
    enum Failure: Error { case serviceUnavailable, identityMismatch, invalidReply }
    static let service = "com.apple.instruments.dtservicehub"
    private static let screenshotChannel = "com.apple.instruments.server.services.screenshot"

    static func capture(physicalID: String) throws -> Data {
        try NativeDDIInspection.validateIdentity(physicalID)
        let tunnel = try AXUSBProxy(device: physicalID, requireCoreDevice: true)
        let rsd = try AXTunnelSocket(tunnel: tunnel, port: tunnel.rsdPort, local: 52001)
        let peer = try AXRSD.discover(socket: rsd)
        let port = try screenshotPort(peer: peer, physicalID: physicalID)
        let socket = try AXTunnelSocket(tunnel: tunnel, port: port, local: 52003)
        let data = try read(send: socket.send, next: { try AXDTX.receive(read: socket.read) })
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...8192).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...8192).contains(height),
              width * height <= 16_777_216 else { throw Failure.invalidReply }
        return data
    }

    static func screenshotPort(peer: [String: Any], physicalID: String) throws -> UInt16 {
        guard (peer["Properties"] as? [String: Any])?["UniqueDeviceID"] as? String == physicalID else {
            throw Failure.identityMismatch
        }
        guard let services = peer["Services"] as? [String: Any] else { throw Failure.invalidReply }
        guard let endpoint = services[service] else { throw Failure.serviceUnavailable }
        guard let advertised = endpoint as? [String: Any],
              let text = advertised["Port"] as? String, let port = UInt16(text), port > 0 else {
            throw Failure.invalidReply
        }
        return port
    }

    static func read(send: (Data) throws -> Void, next: () throws -> AXDTX.Message) throws -> Data {
        let capabilities = "_notifyOfPublishedCapabilities:"
        try send(request(1, 0, capabilities, aux: archive([
            "com.apple.private.DTXBlockCompression": 0, "com.apple.private.DTXConnection": 1,
        ]), expectsReply: false))
        let hello = try next()
        guard hello.channel == 0, hello.conversation == 0, !hello.expectsReply,
              try (AXDTX.object(hello.payload) as? String) == capabilities else { throw Failure.invalidReply }
        // DVT channel numbers are primitive Int32 auxiliary items, not archived NSNumber.
        let channel = AXDTX.number(10) + AXDTX.number(3) + AXDTX.number(1)
        try send(request(2, 0, "_requestChannelWithCode:identifier:", aux: channel + archive(screenshotChannel)))
        let opened = try next()
        guard reply(opened, id: 2, channel: 0), try AXDTX.object(opened.payload) == nil else { throw Failure.invalidReply }
        try send(request(3, 1, "takeScreenshot"))
        let captured = try next()
        guard reply(captured, id: 3, channel: 1), let data = try AXDTX.object(captured.payload) as? Data,
              !data.isEmpty else { throw Failure.invalidReply }
        return data
    }

    private static func reply(_ message: AXDTX.Message, id: UInt32, channel: UInt32) -> Bool {
        message.identifier == id && message.channel == channel && message.conversation == 1 && !message.expectsReply
    }

    private static func archive(_ object: Any) throws -> Data {
        let data = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
        return AXDTX.number(10) + AXDTX.number(2) + AXDTX.number(UInt64(data.count)) + data
    }

    private static func request(_ id: UInt32, _ channel: UInt32, _ selector: String,
                                aux: Data = Data(), expectsReply: Bool = true) throws -> Data {
        let name = try NSKeyedArchiver.archivedData(withRootObject: selector, requiringSecureCoding: false)
        let args = aux.isEmpty ? Data() : AXDTX.number(0x1f0, bytes: 8) + AXDTX.number(UInt64(aux.count), bytes: 8) + aux
        let payload = AXDTX.number(expectsReply ? 0x1002 : 2) + AXDTX.number(UInt64(args.count))
            + AXDTX.number(UInt64(args.count + name.count), bytes: 8) + args + name
        return AXDTX.packet(id: id, channel: channel, reply: expectsReply, payload: payload)
    }
}

/// The screenshot service's DeviceLink exchange, separate from the system ABI
/// so malformed replies and version negotiation can be checked without a phone.
enum DeviceLinkScreenshot {
    enum Failure: Error { case invalidReply, unsupportedVersion }

    static func read(send: ([Any]) throws -> Void, receive: () throws -> [Any]) throws -> Data {
        let greeting = try receive()
        guard greeting.count == 3, greeting[0] as? String == "DLMessageVersionExchange",
            let major = greeting[1] as? Int, let minor = greeting[2] as? Int,
            major >= 0, minor >= 0
        else { throw Failure.invalidReply }
        guard major < 400 || (major == 400 && minor == 0) else { throw Failure.unsupportedVersion }
        try send(["DLMessageVersionExchange", "DLVersionsOk", 400])
        let ready = try receive()
        guard ready.first as? String == "DLMessageDeviceReady" else { throw Failure.invalidReply }
        try send(["DLMessageProcessMessage", ["MessageType": "ScreenShotRequest"]])
        let reply = try receive()
        guard reply.count == 2, reply[0] as? String == "DLMessageProcessMessage",
            let message = reply[1] as? [String: Any], message["MessageType"] as? String == "ScreenShotReply",
            let data = message["ScreenShotData"] as? Data, !data.isEmpty
        else { throw Failure.invalidReply }
        return data
    }
}

/// These private system symbols are resolved at runtime rather than linked.
/// Missing frameworks/symbols disable only independent identity screenshots.
/// Keep the handle alive until every copied CF object has been released.
private final class NativeUSBDeviceServices {
    enum Failure: Error {
        case unavailable
        case deviceNotFound
        case operation(String, Int32)
        case invalidReply
    }

    private typealias DeviceCall = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias CreateDevices = @convention(c) () -> Unmanaged<CFArray>?
    private typealias CopyIdentifier = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
    private typealias StartService = @convention(c)
    (UnsafeRawPointer, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeRawPointer?>) -> Int32
    private typealias Receive = @convention(c)
    (UnsafeRawPointer, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>, UnsafeMutablePointer<CFPropertyListFormat>?) ->
        Int32
    private typealias Send = @convention(c) (UnsafeRawPointer, CFPropertyList, CFPropertyListFormat) -> Int32
    private typealias Invalidate = @convention(c) (UnsafeRawPointer) -> Void

    private let library: UnsafeMutableRawPointer
    private let createDevices: CreateDevices
    private let copyIdentifier: CopyIdentifier
    private let interfaceType: DeviceCall
    private let connect: DeviceCall
    private let isPaired: DeviceCall
    private let validatePairing: DeviceCall
    private let startSession: DeviceCall
    private let stopSession: DeviceCall
    private let disconnect: DeviceCall
    private let startService: StartService
    private let receive: Receive
    private let send: Send
    private let invalidate: Invalidate

    init?() {
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_LOCAL)
        else { return nil }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw Failure.unavailable }
            return unsafeBitCast(address, to: T.self)
        }
        do {
            createDevices = try symbol("AMDCreateDeviceList", CreateDevices.self)
            copyIdentifier = try symbol("AMDeviceCopyDeviceIdentifier", CopyIdentifier.self)
            interfaceType = try symbol("AMDeviceGetInterfaceType", DeviceCall.self)
            connect = try symbol("AMDeviceConnect", DeviceCall.self)
            isPaired = try symbol("AMDeviceIsPaired", DeviceCall.self)
            validatePairing = try symbol("AMDeviceValidatePairing", DeviceCall.self)
            startSession = try symbol("AMDeviceStartSession", DeviceCall.self)
            stopSession = try symbol("AMDeviceStopSession", DeviceCall.self)
            disconnect = try symbol("AMDeviceDisconnect", DeviceCall.self)
            startService = try symbol("AMDeviceSecureStartService", StartService.self)
            receive = try symbol("AMDServiceConnectionReceiveMessage", Receive.self)
            send = try symbol("AMDServiceConnectionSendMessage", Send.self)
            invalidate = try symbol("AMDServiceConnectionInvalidate", Invalidate.self)
            library = handle
        } catch {
            dlclose(handle)
            return nil
        }
    }

    deinit { dlclose(library) }

    func screenshot(physicalID: String) throws -> Data {
        guard let devices = createDevices()?.takeRetainedValue() else { throw Failure.deviceNotFound }
        // Keep the array (and its device references) alive throughout the session.
        return try withExtendedLifetime(devices) {
            for index in 0..<CFArrayGetCount(devices) {
                guard let device = CFArrayGetValueAtIndex(devices, index), interfaceType(device) == 1,
                    let identifier = copyIdentifier(device)?.takeRetainedValue(), identifier as String == physicalID
                else { continue }
                return try screenshot(device: device)
            }
            throw Failure.deviceNotFound
        }
    }

    private func check(_ code: Int32, _ operation: String) throws {
        guard code == 0 else { throw Failure.operation(operation, code) }
    }

    private func screenshot(device: UnsafeRawPointer) throws -> Data {
        try check(connect(device), "connect")
        defer { _ = disconnect(device) }
        guard isPaired(device) == 1 else { throw Failure.operation("device not trusted", -1) }
        try check(validatePairing(device), "validate pairing")
        try check(startSession(device), "start session")
        defer { _ = stopSession(device) }
        var connection: UnsafeRawPointer?
        let code = startService(device, "com.apple.mobile.screenshotr" as CFString, nil, &connection)
        // kAMDInvalidServiceError means this phone does not expose screenshotr.
        // Trust/lock/transport failures must not be treated as missing capability.
        if USBIdentityScreenshot.screenshotServiceIsUnavailable(code) {
            log("native USB screenshot service not offered: code=\(String(UInt32(bitPattern: code), radix: 16))")
            throw Failure.unavailable
        }
        try check(code, "start screenshot service")
        guard let connection else { throw Failure.invalidReply }
        defer {
            invalidate(connection)
            Unmanaged<CFTypeRef>.fromOpaque(connection).release()
        }
        return try DeviceLinkScreenshot.read(
            send: { message in
                try self.check(self.send(connection, message as CFArray, .binaryFormat_v1_0), "send")
            },
            receive: {
                var message: Unmanaged<CFPropertyList>?
                var format: CFPropertyListFormat = .binaryFormat_v1_0
                let code = self.receive(connection, &message, &format)
                let value = message?.takeRetainedValue()
                try self.check(code, "receive")
                guard let array = value as? [Any] else { throw Failure.invalidReply }
                return array
            })
    }
}

extension Process {
    /// Deadline for a directly owned child only; never terminates other sessions.
    /// Launch errors, timeout and signal exit remain distinct to each caller.
    func run(timeout: TimeInterval, onPoll: (() -> Void)? = nil) throws -> Bool {
        let finished = DispatchSemaphore(value: 0)
        terminationHandler = { _ in finished.signal() }
        try run()
        let deadline = DispatchTime.now() + timeout
        if let onPoll {
            while true {
                if finished.wait(timeout: min(deadline, .now() + .milliseconds(100))) == .success { return true }
                if DispatchTime.now() >= deadline { break }
                onPoll()
            }
        } else if finished.wait(timeout: deadline) == .success { return true }
        if isRunning { terminate() }
        if finished.wait(timeout: .now() + 1) == .timedOut {
            if isRunning { kill(processIdentifier, SIGKILL) }
            _ = finished.wait(timeout: .now() + 1)
        }
        return false
    }
}
