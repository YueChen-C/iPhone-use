import CryptoKit
import Darwin
import Foundation

struct DDIManagementError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// An externally pinned local receipt, not an Apple signature or a mount grant.
struct DDISourceRecord: Codable {
    let schemaVersion: Int
    let kind: String
    let location: String
    let revision: String
    let sha256: [String: String]

    func validate() throws {
        guard schemaVersion == 1, !sha256.isEmpty, sha256.count <= 256,
              sha256.values.allSatisfy({ Self.isDigest($0) }),
              let url = URL(string: location), location.utf8.count <= 2048 else {
            throw DDIManagementError("Invalid DDI source receipt or SHA256 allowlist")
        }
        switch kind {
        case "third-party-mirror":
            guard url.scheme == "https", url.host != nil,
                  revision.count == 40, revision.utf8.allSatisfy(Self.isHex) else {
                throw DDIManagementError("Mirror provenance requires HTTPS and an exact commit; it is not Apple CDN provenance")
            }
        case "apple-installed":
            guard url.isFileURL, url.path.hasPrefix("/"), !revision.isEmpty, revision.utf8.count <= 128 else {
                throw DDIManagementError("Installed provenance requires a local source URL and version")
            }
        default: throw DDIManagementError("Unknown DDI source kind")
        }
        for path in sha256.keys { try DDILocalFile.validateRelativePath(path) }
    }

    private static func isHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...102).contains(byte) }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy(isHex) }
}

/// Read through directory-relative descriptors. No symlink component, socket,
/// device or unbounded in-memory image read is accepted. This is preflight only:
/// a future mutation must stage/revalidate bytes instead of trusting an old report.
enum DDILocalFile {
    static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024,
              !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DDIManagementError("DDI file path must stay within its bundle")
        }
    }

    static func withFile<T>(root: URL, path: String, _ body: (FileHandle, UInt64) throws -> T) throws -> T {
        try validateRelativePath(path)
        return try withDirectory(root) { directory in
            var directory = dup(directory)
            guard directory >= 0 else { throw DDIManagementError("Cannot duplicate DDI directory descriptor") }
            defer { close(directory) }
            let components = path.split(separator: "/").map(String.init)
            for component in components.dropLast() {
                let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw DDIManagementError("DDI directory path is missing or contains a symlink") }
                close(directory); directory = next
            }
            return try readFile(directory: directory, name: components.last!, body)
        }
    }

    static func withDirectory<T>(_ root: URL, _ body: (Int32) throws -> T) throws -> T {
        guard root.path.hasPrefix("/") else { throw DDIManagementError("DDI root must be absolute") }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw DDIManagementError("Cannot open DDI directory without following links") }
        defer { close(directory) }
        for component in root.path.split(separator: "/").map(String.init) {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw DDIManagementError("DDI root is missing or contains a symlink") }
            close(directory); directory = next
        }
        return try body(directory)
    }

    private static func readFile<T>(directory: Int32, name: String, _ body: (FileHandle, UInt64) throws -> T) throws -> T {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw DDIManagementError("DDI file is missing or contains a symlink: \(name)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 4 * 1024 * 1024 * 1024 else {
            throw DDIManagementError("DDI input must be a nonempty bounded regular file: \(name)")
        }
        let result = try body(handle, UInt64(before.st_size))
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DDIManagementError("DDI file changed during inspection: \(name)")
        }
        return result
    }

    static func metadata(root: URL, path: String, limit: Int = 8 * 1024 * 1024) throws -> Data {
        try withFile(root: root, path: path) { handle, size in
            guard size <= limit else { throw DDIManagementError("DDI metadata exceeds limit") }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count == size, data.count <= limit else { throw DDIManagementError("DDI metadata changed or was truncated") }
            return data
        }
    }

    static func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw DDIManagementError("DDI management accepts only absolute local paths")
        }
        try validateRelativePath(String(path.dropFirst()))
        // standardizedFileURL rewrites /private/var to the symlink /var on
        // macOS. Keep literal components for the no-symlink descriptor walk.
        return URL(fileURLWithPath: path)
    }
}

struct DDIBundlePreflight: Encodable {
    struct FileDigest: Codable, Equatable {
        let path: String
        let bytes: UInt64
        let sha256: String
        let sha384: String
    }
    let schemaVersion = 1
    let bundlePath: String
    let productType: String
    let build: String
    let coreDeviceVersion: String
    let compatibleIdentities: Int
    let ignoredIdentities: Int
    let validationScope = "matching-product-personalized-image"
    let source: DDISourceRecord
    let files: [FileDigest]
    let integrityVerified = true
    // A receipt and matching hashes do not authenticate its author or grant
    // permission to execute the image. No management mutation exists here yet.
    let provenanceVerified = false
    let mountAuthorized = false
    let deviceCompatibilityVerified = false
    let inputSent = false
    let deviceMutation = false

    static func inspect(bundlePath: String, receiptPath: String, productType: String) throws -> Self {
        let receipt = try DDILocalFile.absoluteURL(receiptPath)
        let data = try DDILocalFile.metadata(root: receipt.deletingLastPathComponent(),
                                            path: receipt.lastPathComponent, limit: 64 * 1024)
        return try inspect(bundle: DDILocalFile.absoluteURL(bundlePath),
                           source: JSONDecoder().decode(DDISourceRecord.self, from: data), productType: productType)
    }

    static func inspect(bundle: URL, source: DDISourceRecord, productType: String) throws -> Self {
        try source.validate()
        guard !productType.isEmpty, productType.utf8.count <= 128 else { throw DDIManagementError("Product type required") }
        // Preserve the supplied final component: resolving a bundle symlink here
        // would silently authorize a different directory. open(O_NOFOLLOW) checks it.
        let root = try DDILocalFile.absoluteURL(bundle.path)
        let manifestPath = "Restore/BuildManifest.plist"
        let manifestBytes = try DDILocalFile.metadata(root: root, path: manifestPath)
        let versionBytes = try DDILocalFile.metadata(root: root, path: "version.plist")
        func plist(_ bytes: Data) throws -> [String: Any] {
            guard let object = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else {
                throw DDIManagementError("DDI plist must contain a dictionary")
            }
            return object
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
            digest.map { String(format: "%02x", $0) }.joined()
        }
        guard source.sha256[manifestPath] == hex(SHA256.hash(data: manifestBytes)),
              source.sha256["version.plist"] == hex(SHA256.hash(data: versionBytes)) else {
            throw DDIManagementError("DDI metadata differs from the external source receipt")
        }
        let manifest = try plist(manifestBytes), version = try plist(versionBytes)
        guard let identities = manifest["BuildIdentities"] as? [[String: Any]], !identities.isEmpty, identities.count <= 2048,
              let supported = manifest["SupportedProductTypes"] as? [String], supported.contains(productType),
              let build = manifest["ProductBuildVersion"] as? String, !build.isEmpty,
              version["ProductBuildVersion"] as? String == build, version["Platform"] as? String == "iOS",
              let projects = version["ProjectMetadata"] as? [[String: Any]],
              let coreDevice = projects.first(where: { $0["Project"] as? String == "CoreDevice" })?["Version"] as? String else {
            throw DDIManagementError("DDI manifest/version/product compatibility metadata is invalid")
        }
        var expected: [String: Data] = [:]
        let compatible = identities.filter { $0["Ap,ProductType"] as? String == productType }
        guard !compatible.isEmpty else { throw DDIManagementError("No DDI identity matches the exact product type") }
        // Manifests also contain unrelated legacy SHA1 and Cryptex identities.
        // They are not the selected personalized-image variant; do not require
        // their different payloads or claim to have verified those identities.
        for identity in compatible {
            guard let components = identity["Manifest"] as? [String: Any],
                  Set(components.keys) == Set(["PersonalizedDMG", "LoadableTrustCache"]) else {
                throw DDIManagementError("Unsupported DDI component dialect")
            }
            for key in ["PersonalizedDMG", "LoadableTrustCache"] {
                guard let item = components[key] as? [String: Any], let info = item["Info"] as? [String: Any],
                      let path = info["Path"] as? String, let digest = item["Digest"] as? Data, digest.count == 48,
                      info["HashMethod"] == nil || info["HashMethod"] as? String == "sha2-384" else {
                    throw DDIManagementError("DDI component requires a path and SHA384 digest")
                }
                try DDILocalFile.validateRelativePath(path)
                let relative = "Restore/" + path
                guard expected[relative] == nil || expected[relative] == digest else {
                    throw DDIManagementError("DDI identities disagree about a payload digest")
                }
                expected[relative] = digest
            }
        }
        let paths = Set(expected.keys).union([manifestPath, "version.plist"])
        guard Set(source.sha256.keys) == paths else {
            throw DDIManagementError("Source receipt must pin exactly the metadata and all referenced payload files")
        }
        var files: [FileDigest] = []
        for path in paths.sorted() {
            let file = try DDILocalFile.withFile(root: root, path: path) { handle, size -> FileDigest in
                var sha256 = SHA256(), sha384 = SHA384(), total: UInt64 = 0
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    total += UInt64(chunk.count)
                    guard total <= size else { throw DDIManagementError("DDI payload grew during hashing") }
                    sha256.update(data: chunk); sha384.update(data: chunk)
                }
                guard total == size else { throw DDIManagementError("DDI payload was truncated") }
                return FileDigest(path: path, bytes: total, sha256: hex(sha256.finalize()), sha384: hex(sha384.finalize()))
            }
            guard source.sha256[path] == file.sha256,
                  expected[path].map({ hex($0) == file.sha384 }) ?? true else {
                throw DDIManagementError("DDI payload digest mismatch: \(path)")
            }
            files.append(file)
        }
        return Self(bundlePath: root.path, productType: productType, build: build,
                    coreDeviceVersion: coreDevice, compatibleIdentities: compatible.count,
                    ignoredIdentities: identities.count - compatible.count, source: source, files: files)
    }
}
