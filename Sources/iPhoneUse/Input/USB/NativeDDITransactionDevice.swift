import Darwin
import Foundation

/// Native DDI adapter shared by the setup flow and offline transaction.
struct NativeDDITransactionDevice: DDITransactionDevice {
    func inspect(physicalID: String) throws -> NativeDDIInspection.Report {
        try NativeDDIInspection.inspect(physicalID: physicalID)
    }
    func unmount(physicalID: String) throws {
        try unmount(physicalID: physicalID, check: { _, _ in })
    }
    func unmountForSetup(physicalID: String, check: (NativeDDIInspection.Report) throws -> Void) throws {
        try unmount(physicalID: physicalID) { library, report in
            guard dlsym(library, "AMDeviceMountPersonalizedBundle") != nil else {
                throw DDIManagementError("Native personalized DDI mount unavailable; no uninstall")
            }
            try check(report)
        }
    }
    private func unmount(physicalID: String, check: (UnsafeMutableRawPointer, NativeDDIInspection.Report) throws -> Void) throws {
        try NativeDDIInspection.withDevice(physicalID: physicalID) { library, device, report in
            typealias Unmount = @convention(c) (UnsafeRawPointer, CFString) -> Int32
            guard let symbol = dlsym(library, "AMDeviceUnmountImage") else { throw DDIManagementError("Native DDI unmount unavailable") }
            try check(library, report)
            let code = unsafeBitCast(symbol, to: Unmount.self)(device, "/System/Developer" as CFString)
            guard code == 0 else { throw DDIManagementError("Native DDI unmount: 0x\(String(UInt32(bitPattern: code), radix: 16))") }
        }
    }
    func mount(physicalID: String, bundle: URL) throws {
        try mount(physicalID: physicalID, bundle: bundle) { _ in true }
    }
    /// The caller can reject a mount using the exact-device pre-mutation readback.
    func mount(physicalID: String, bundle: URL,
               shouldMount: (NativeDDIInspection.Report) throws -> Bool) throws {
        try NativeDDIInspection.withDevice(physicalID: physicalID) { library, device, report in
            guard try shouldMount(report) else { return }
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
