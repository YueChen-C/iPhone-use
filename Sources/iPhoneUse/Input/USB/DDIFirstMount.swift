import Darwin
import Foundation

/// Installs the app-pinned DDI on one exact device. No offline transaction or USB input.
enum DDIFirstMount {
    static let argument = "--ddi-setup-install"

    enum Outcome: String, Codable { case installed, alreadyInstalled, replaced }
    enum Stage: String { case uninstalling, installing, verifyingInstallation }
    private static let progressPrefix = "DDI-SETUP "

    struct Target: Codable, Equatable {
        let physicalID: String
        let productType: String
        let productVersion: String
        let productBuild: String

        func matches(_ report: NativeDDIInspection.Report) -> Bool {
            self == Self(physicalID: report.physicalID, productType: report.productType,
                         productVersion: report.productVersion, productBuild: report.productBuild)
        }
    }

    private struct Reply: Codable {
        let target: Target
        let outcome: Outcome
    }

    static func install(executable: URL, target: Target, progress: @escaping (Stage) -> Void) throws -> Outcome {
        let data = try DDINativeProcess.run(executable: executable,
            arguments: [argument, target.physicalID, target.productType, target.productVersion, target.productBuild],
            timeout: 125, observeLine: { line in
                if line.hasPrefix(progressPrefix), let stage = Stage(rawValue: String(line.dropFirst(progressPrefix.count))) {
                    progress(stage)
                }
            })
        guard let payload = data.split(separator: 10).last else { throw DDIManagementError("Missing DDI install reply") }
        let reply = try JSONDecoder().decode(Reply.self, from: Data(payload))
        guard reply.target == target else { throw DDIManagementError("DDI install reply identity mismatch") }
        return reply.outcome
    }

    static func run(arguments: [String], inputLease: DDIProcessLease) -> Int32 {
        guard arguments.count == 4 else { return 64 }
        signal(SIGALRM, SIG_DFL); alarm(120)
        defer { alarm(0) }
        let target = Target(physicalID: arguments[0], productType: arguments[1],
                            productVersion: arguments[2], productBuild: arguments[3])
        do {
            try USBBackendCompatibility.validate(version: target.productVersion)
            let lease = try inputLease.deviceService(physicalID: target.physicalID, exclusive: true)
            let outcome = try withExtendedLifetime(lease) {
                try DDIDownload.withVerifiedCache(productType: target.productType) { report in
                    let device = NativeDDITransactionDevice()
                    return try install(target: target, image: report,
                        mount: { guardMount in
                            try device.mount(physicalID: target.physicalID, bundle: URL(fileURLWithPath: report.bundlePath),
                                             shouldMount: guardMount)
                        }, unmount: { guardUnmount in
                            try device.unmountForSetup(physicalID: target.physicalID, check: guardUnmount)
                        }, inspect: { try device.inspect(physicalID: target.physicalID) }, progress: { stage in
                            try FileHandle.standardOutput.write(contentsOf: Data("\(progressPrefix)\(stage.rawValue)\n".utf8))
                        })
                }
            }
            let data = try JSONEncoder().encode(Reply(target: target, outcome: outcome))
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            return 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            return 70
        }
    }

    /// The process holds the physical device lease for all stages. The native
    /// guards recheck the exact device/OS and image immediately before mutation.
    static func install(target: Target, image: DDIBundlePreflight,
                        mount: ((NativeDDIInspection.Report) throws -> Bool) throws -> Void,
                        unmount: ((NativeDDIInspection.Report) throws -> Void) throws -> Void,
                        inspect: () throws -> NativeDDIInspection.Report,
                        progress: @escaping (Stage) throws -> Void = { _ in }) throws -> Outcome {
        guard image.productType == target.productType,
              let digest = image.files.first(where: { $0.path == "Restore/Image.dmg" })?.sha384 else {
            throw DDIManagementError("Pinned personalized DDI payload is unavailable for this device")
        }
        func mounted(_ report: NativeDDIInspection.Report) throws -> [NativeDDIInspection.MountedImage] {
            guard target.matches(report) else { throw DDIManagementError("DDI device or OS changed during setup") }
            return report.mountedImages.filter { $0.isMounted && $0.mountPath == "/System/Developer" }
        }
        func signature(_ item: NativeDDIInspection.MountedImage) -> String? {
            guard let bytes = item.imageSignature.flatMap({ Data(base64Encoded: $0) }), bytes.count == 48 else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        func matches(_ images: [NativeDDIInspection.MountedImage]) -> Bool {
            guard images.count == 1, let item = images.first else { return false }
            return item.imageType == "Personalized" && item.build == image.build && item.version == image.coreDeviceVersion
                && signature(item) == digest
        }
        let previous = try mounted(inspect())
        if matches(previous) { return .alreadyInstalled }
        if !previous.isEmpty {
            guard previous.count == 1, let old = previous.first, old.imageType == "Personalized",
                  old.build.map({ !$0.isEmpty && $0 != image.build }) == true
                    || old.version.map({ !$0.isEmpty && $0 != image.coreDeviceVersion }) == true
                    || signature(old).map({ $0 != digest }) == true else {
                throw DDIManagementError("Existing developer image is ambiguous; it was left in place")
            }
            try unmount { report in
                guard try mounted(report) == previous else {
                    throw DDIManagementError("Mounted DDI changed before uninstall; no mutation")
                }
                try progress(.uninstalling)
            }
            guard try mounted(inspect()).isEmpty else {
                throw DDIManagementError("DDI uninstall was not confirmed by device readback; install skipped")
            }
        }
        try mount { report in
            guard try mounted(report).isEmpty else {
                throw DDIManagementError("Developer image slot is no longer empty; install skipped")
            }
            try progress(.installing)
            return true
        }
        try progress(.verifyingInstallation)
        guard try matches(mounted(inspect())) else {
            throw DDIManagementError("DDI installation was not confirmed by device readback")
        }
        return previous.isEmpty ? .installed : .replaced
    }
}
