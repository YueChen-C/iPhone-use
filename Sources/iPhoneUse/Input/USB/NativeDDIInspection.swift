import Darwin
import Foundation

/// Apple-installed, version-pinned read-only adapter. Mount/unmount symbols are
/// intentionally absent. This runs only in the app's early local CLI process.
enum NativeDDIInspection {
    static let frameworkVersion = "1827.100.17.100.1"
    static let frameworkPath = "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework"
    struct MountedImage: Encodable {
        let mountPath: String
        let isMounted: Bool
        let imageType: String
        let build: String?
        let version: String?
        let imageSignature: String?
    }
    struct Report: Encodable {
        let physicalID: String
        let productType: String
        let productVersion: String
        let productBuild: String
        let mountedImages: [MountedImage]
        let frameworkVersion: String
        let inputSent = false
        let deviceMutation = false
        let externalTool = false
    }

    static func validateIdentity(_ value: String) throws {
        let bytes = Array(value.utf8)
        func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        guard (bytes.count == 40 && bytes.allSatisfy(hex)) ||
              (bytes.count == 25 && bytes[8] == 45 && bytes.enumerated().allSatisfy({ $0.offset == 8 || hex($0.element) })) else {
            throw DDIManagementError("DDI inspection requires a full USB UDID, never a device name, prefix or CoreDevice UUID")
        }
    }

    private typealias DeviceCall = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias Subscribe = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias Unsubscribe = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias List = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Identifier = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
    private typealias CopyValue = @convention(c) (UnsafeRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias Mounted = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Int32>) -> Unmanaged<CFTypeRef>?

    static func inspect(physicalID: String) throws -> Report {
        try validateIdentity(physicalID)
        #if !arch(arm64)
        throw DDIManagementError("Native DDI ABI has only been verified on arm64")
        #else
        guard Bundle(path: frameworkPath)?.infoDictionary?["CFBundleVersion"] as? String == frameworkVersion else {
            throw DDIManagementError("Native DDI ABI requires installed MobileDevice\(frameworkVersion)")
        }
        guard let library = dlopen(frameworkPath + "/MobileDevice", RTLD_NOW | RTLD_LOCAL) else {
            throw DDIManagementError("Apple MobileDevice framework unavailable")
        }
        defer { dlclose(library) }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw DDIManagementError("Missing native DDI symbol: \(name)") }
            return unsafeBitCast(address, to: T.self)
        }
        let subscribe = try symbol("AMDeviceNotificationSubscribe", Subscribe.self)
        let unsubscribe = try symbol("AMDeviceNotificationUnsubscribe", Unsubscribe.self)
        let list = try symbol("AMDCreateDeviceList", List.self)
        let identifier = try symbol("AMDeviceCopyDeviceIdentifier", Identifier.self)
        let interface = try symbol("AMDeviceGetInterfaceType", DeviceCall.self)
        let connect = try symbol("AMDeviceConnect", DeviceCall.self)
        let disconnect = try symbol("AMDeviceDisconnect", DeviceCall.self)
        let paired = try symbol("AMDeviceIsPaired", DeviceCall.self)
        let validate = try symbol("AMDeviceValidatePairing", DeviceCall.self)
        let start = try symbol("AMDeviceStartSession", DeviceCall.self)
        let stop = try symbol("AMDeviceStopSession", DeviceCall.self)
        let copyValue = try symbol("AMDeviceCopyValue", CopyValue.self)
        let mounted = try symbol("AMDeviceCopyMountedDevicesList", Mounted.self)
        func check(_ code: Int32, _ action: String) throws {
            guard code == 0 else { throw DDIManagementError("\(action): 0x\(String(UInt32(bitPattern: code), radix: 16))") }
        }
        var subscription: UnsafeMutableRawPointer?
        try check(subscribe({ _, _ in }, 0, 0, nil, &subscription), "DDI USB discovery")
        defer { if let subscription { _ = unsubscribe(subscription) } }
        CFRunLoopRunInMode(.defaultMode, 1, false)
        guard let devices = list()?.takeRetainedValue() else { throw DDIManagementError("DDI device list unavailable") }
        return try withExtendedLifetime(devices) {
            var matches: [UnsafeRawPointer] = []
            for index in 0..<CFArrayGetCount(devices) {
                if let device = CFArrayGetValueAtIndex(devices, index), interface(device) == 1,
                   identifier(device)?.takeRetainedValue() as String? == physicalID { matches.append(device) }
            }
            guard matches.count == 1, let device = matches.first else {
                throw DDIManagementError("Exact USB device absent or ambiguous; no fallback")
            }
            try check(connect(device), "DDI identity connect")
            defer { _ = disconnect(device) }
            guard identifier(device)?.takeRetainedValue() as String? == physicalID, paired(device) == 1 else {
                throw DDIManagementError("DDI requires an already trusted, exact USB device; pairing refused")
            }
            try check(validate(device), "DDI validate existing pairing")
            try check(start(device), "DDI start existing session")
            var sessionOpen = true
            defer { if sessionOpen { _ = stop(device) } }
            func value(_ key: String) throws -> String {
                guard let result = copyValue(device, nil, key as CFString)?.takeRetainedValue() as? String, !result.isEmpty else {
                    throw DDIManagementError("DDI device metadata unavailable: \(key)")
                }
                return result
            }
            let product = try value("ProductType"), version = try value("ProductVersion"), build = try value("BuildVersion")
            try check(stop(device), "DDI stop inspection session"); sessionOpen = false
            var code: Int32 = 0
            let object = mounted(device, &code)?.takeRetainedValue()
            try check(code, "DDI mounted image inspection")
            let images = try mountedImages(object)
            return Report(physicalID: physicalID, productType: product, productVersion: version,
                          productBuild: build, mountedImages: images, frameworkVersion: frameworkVersion)
        }
        #endif
    }

    static func mountedImages(_ object: Any?) throws -> [MountedImage] {
        guard let entries = object as? [[String: Any]], entries.count <= 32 else {
            throw DDIManagementError("DDI mounted-image reply is invalid")
        }
        return try entries.map { entry in
            guard let path = entry["MountPath"] as? String,
                  let mounted = entry["IsMounted"] as? NSNumber, CFGetTypeID(mounted) == CFBooleanGetTypeID(),
                  let type = entry["DiskImageType"] as? String else {
                throw DDIManagementError("DDI mounted-image metadata is incomplete")
            }
            let metadata = entry["PersonalizedImageVersionInfo"] as? [String: Any]
            return MountedImage(mountPath: path, isMounted: mounted.boolValue, imageType: type,
                                build: metadata?["ProductBuildVersion"] as? String,
                                version: entry["PersonalizedImageVersion"] as? String,
                                imageSignature: (entry["ImageSignature"] as? Data)?.base64EncodedString())
        }
    }
}
