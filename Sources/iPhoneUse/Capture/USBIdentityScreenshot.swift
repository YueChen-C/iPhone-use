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
            timeout: 8, diagnostic: handle)
        if status == unavailableExitCode {
            log("capture identity screenshot unavailable for \(physicalID): native service unavailable")
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
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            // Terminate only this worker, never camera assistants or other apps.
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 1)
            }
            return nil
        }
        guard process.terminationReason == .exit else { return nil }
        return process.terminationStatus
    }

    /// Only the isolated worker calls into MobileDevice. Do not attempt pairing,
    /// mount developer images, reset USB, or fall back to a different phone.
    static func write(physicalID: String, output: URL) -> Int32 {
        guard let services = NativeUSBDeviceServices() else { return unavailableExitCode }
        do {
            let data = try services.screenshot(physicalID: physicalID)
            try data.write(to: output, options: .atomic)
            return 0
        } catch NativeUSBDeviceServices.Failure.unavailable {
            return unavailableExitCode
        } catch {
            log("native USB screenshot: \(error)")
            return failedExitCode
        }
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
        if USBIdentityScreenshot.screenshotServiceIsUnavailable(code) { throw Failure.unavailable }
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
