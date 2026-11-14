import Darwin
import Foundation

/// Only DDITransaction invokes these mutations after staging, authorization,
/// a persisted input barrier and an offline exclusive process lease.
struct NativeDDITransactionDevice: DDITransactionDevice {
    func inspect(physicalID: String) throws -> NativeDDIInspection.Report {
        try NativeDDIInspection.inspect(physicalID: physicalID)
    }
    func unmount(physicalID: String) throws {
        try NativeDDIInspection.withDevice(physicalID: physicalID) { library, device, _ in
            typealias Unmount = @convention(c) (UnsafeRawPointer, CFString) -> Int32
            guard let symbol = dlsym(library, "AMDeviceUnmountImage") else { throw DDIManagementError("Native DDI unmount unavailable") }
            let code = unsafeBitCast(symbol, to: Unmount.self)(device, "/System/Developer" as CFString)
            guard code == 0 else { throw DDIManagementError("Native DDI unmount: 0x\(String(UInt32(bitPattern: code), radix: 16))") }
        }
    }
    func mount(physicalID: String, bundle: URL) throws {
        try NativeDDIInspection.withDevice(physicalID: physicalID) { library, device, _ in
            typealias Mount = @convention(c) (UnsafeRawPointer, CFURL, CFString, CFDictionary, UnsafeMutablePointer<Unmanaged<CFError>?>) -> Int32
            guard let symbol = dlsym(library, "AMDeviceMountPersonalizedBundle") else { throw DDIManagementError("Native personalized DDI mount unavailable") }
            var error: Unmanaged<CFError>?
            let code = unsafeBitCast(symbol, to: Mount.self)(device, bundle as CFURL, "DeveloperDiskImage" as CFString,
                ["UseCredentials": false, "MountedBundlePath": bundle as NSURL] as CFDictionary, &error)
            let detail = error?.takeRetainedValue()
            guard code == 0 else {
                throw DDIManagementError("Native DDI mount: 0x\(String(UInt32(bitPattern: code), radix: 16)); \(detail.map { String(describing: $0) } ?? "no detail")")
            }
        }
    }
}
