import CoreFoundation
import Foundation

/// Classic (non-personalized) DeveloperDiskImage for iOS 15/16 only. The
/// phone validates Apple's signature; we never unmount or replace an image.
enum LegacyDeveloperImage {
    static let rootVariable = "IPHONE_USE_LEGACY_DDI_ROOT"
    static let imageLimit = 128 * 1024 * 1024
    static let signatureLimit = 4096
    private static let stagingPath = "/private/var/mobile/Media/PublicStaging/staging.dimage"

    struct Image {
        let bytes: Data
        let signature: Data
    }

    private struct LocalImageMissing: Error, CustomStringConvertible {
        let description: String
    }

    static func versionDirectories(_ version: String) throws -> [String] {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        guard [2, 3].contains(fields.count), fields[0] == "15" || fields[0] == "16",
              fields.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { throw AXDTX.Failure("Legacy DeveloperDiskImage requires a valid iOS 15 or 16 version") }
        return fields.count == 2 ? [version] : [version, fields.prefix(2).joined(separator: ".")]
    }

    static func localImage(version: String, roots: [URL]) throws -> Image {
        let directories = try versionDirectories(version)
        for root in roots {
            for directory in directories {
                let prefix = directory + "/DeveloperDiskImage.dmg"
                if let signature = try? DDILocalFile.metadata(root: root, path: prefix + ".signature", limit: signatureLimit),
                   let bytes = try? DDILocalFile.metadata(root: root, path: prefix, limit: imageLimit) {
                    return Image(bytes: bytes, signature: signature)
                }
            }
        }
        throw LocalImageMissing(description: "No local DeveloperDiskImage for iOS \(version); put the .dmg and .dmg.signature in a LegacyDeviceSupport or \(rootVariable) subdirectory named \(directories.last!)")
    }

    static func imageForMount(version: String) throws -> Image {
        try imageForMount(version: version, roots: localRoots()) { try LegacyDDIDownload.image(version: $0) }
    }

    static func imageForMount(version: String, roots: [URL], download: (String) throws -> Image) throws -> Image {
        do { return try localImage(version: version, roots: roots) }
        catch let missing as LocalImageMissing {
            do { return try download(version) }
            catch { throw AXDTX.Failure("\(missing). Gitee fallback failed: \(error)") }
        }
    }

    private static func localRoots() throws -> [URL] {
        if let override = ProcessInfo.processInfo.environment[rootVariable] {
            guard let path = try? DDILocalFile.absoluteURL(override) else {
                throw AXDTX.Failure("\(rootVariable) must be an absolute local directory")
            }
            return [path]
        }
        return [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/iPhoneUse/LegacyDeviceSupport", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport",
                isDirectory: true),
        ]
    }

    /// Must run under the selected phone's exclusive service lease. Inspect before
    /// opening local files or writing anything; even a different mounted DDI stays put.
    @discardableResult
    static func ensureMounted(_ stream: AXByteStream, image: () throws -> Image) throws -> Bool {
        if try mountedSignatures(stream).present { return false }
        let image = try image()
        guard !image.bytes.isEmpty, image.bytes.count <= imageLimit,
              !image.signature.isEmpty, image.signature.count <= signatureLimit else {
            throw AXDTX.Failure("Invalid legacy DeveloperDiskImage payload")
        }
        // Asset lookup can take time; don't upload if an external client just mounted one.
        if try mountedSignatures(stream).present { return false }
        let signature = image.signature
        let receive = try exchange(stream, ["Command": "ReceiveBytes", "ImageSize": image.bytes.count,
                                            "ImageSignature": signature])
        try requireStatus(receive, "ReceiveBytesAck")
        for offset in stride(from: 0, to: image.bytes.count, by: 64 * 1024) {
            try stream.send(image.bytes.subdata(in: offset..<min(offset + 64 * 1024, image.bytes.count)))
        }
        try requireStatus(readReply(stream), "Complete")
        let mount = try exchange(stream, ["Command": "MountImage", "ImagePath": stagingPath, "ImageSignature": signature])
        try requireStatus(mount, "Complete")
        guard try mountedSignatures(stream).values.contains(signature) else {
            throw AXDTX.Failure("Legacy DeveloperDiskImage mount could not be verified; reconnect before retrying")
        }
        return true
    }

    private static func mountedSignatures(_ stream: AXByteStream) throws -> (present: Bool, values: [Data]) {
        let reply = try exchange(stream, ["Command": "LookupImage"])
        try requireStatus(reply, "Complete")
        let signatures: [Data]
        if let value = reply["ImageSignature"] {
            guard let values = value as? [Data], values.count <= 32,
                  values.allSatisfy({ !$0.isEmpty && $0.count <= signatureLimit }) else {
                throw AXDTX.Failure("Invalid legacy DeveloperDiskImage signature list")
            }
            signatures = values
        } else { signatures = [] }
        if let value = reply["ImagePresent"] {
            guard let present = value as? NSNumber, CFGetTypeID(present) == CFBooleanGetTypeID(),
                  present.boolValue || signatures.isEmpty else {
                throw AXDTX.Failure("Invalid legacy DeveloperDiskImage presence flag")
            }
            return (present.boolValue, signatures)
        }
        return (!signatures.isEmpty, signatures)
    }

    private static func exchange(_ stream: AXByteStream, _ fields: [String: Any]) throws -> [String: Any] {
        var request = fields
        request["ImageType"] = "Developer"
        let bytes = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        try stream.send(AXUSBProxy.big(UInt64(bytes.count), 4) + bytes)
        return try readReply(stream)
    }

    private static func readReply(_ stream: AXByteStream) throws -> [String: Any] {
        let header = try stream.read(4)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard header.count == 4, (1...(256 * 1024)).contains(size),
              let reply = try PropertyListSerialization.propertyList(from: stream.read(size), format: nil) as? [String: Any]
        else { throw AXDTX.Failure("Invalid legacy image mounter reply") }
        return reply
    }

    private static func requireStatus(_ reply: [String: Any], _ expected: String) throws {
        if reply["Error"] as? String == "DeviceLocked" {
            throw AXDTX.Failure("Unlock the iPhone before mounting the legacy DeveloperDiskImage")
        }
        if (reply["DetailedError"] as? String)?.localizedCaseInsensitiveContains("developer mode is not enabled") == true {
            throw AXDTX.Failure("Enable Developer Mode on the iPhone before mounting the legacy DeveloperDiskImage")
        }
        guard reply["Error"] == nil, reply["Status"] as? String == expected else {
            throw AXDTX.Failure("Legacy image mounter did not confirm \(expected); check the matching Apple-signed image")
        }
    }
}
