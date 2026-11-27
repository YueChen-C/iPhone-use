import CryptoKit
import Foundation

/// Classic iOS 15/16 images only. This mirror is not Apple provenance: the
/// embedded ZIP pins protect delivery and cache reuse; iOS verifies the image signature.
enum LegacyDDIDownload {
    struct Asset {
        let bytes: Int
        let sha256: String
        var blob: String? = nil
        var directory: String? = nil

        var transferLimit: Int {
            // Only the four >10 MB archives use Gitee's public base64 Git blob API.
            blob == nil ? bytes : 4 * ((bytes + 2) / 3) + 4096
        }

        func verified(_ data: Data) -> Bool {
            data.count == bytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
        }
    }

    private struct GitBlob: Decodable {
        let sha: String
        let size: Int
        let encoding: String
        let content: String
    }

    private static let revision = "c77f23d126d618553512ec91c73f073c7c63dfc9"
    private static let repository = "ios_shen/iOSDeviceSupport"
    static let assets: [String: Asset] = [
        "15.0": .init(bytes: 11_866_237, sha256: "62b31779aa6faa4ab5437211b1e231f7d09ffc7878a87d687d5b85d28e56c438", blob: "a91df8220b97923ca9f6b6df405d616b252a5345"),
        "15.1": .init(bytes: 11_866_285, sha256: "afe6ae29369b9da99f9910f3bad0921d18b339e949867565413d0454fba1f4a1", blob: "bd078733e9169a34431be2a185cce751c4776d34", directory: "15.1 (19B74)"),
        "15.2": .init(bytes: 11_953_979, sha256: "16789a146f8ccca691a0a286f5ebaeffef31b9d3adbee930d57eb63589a65f67", blob: "ab952144facec8fedf34c122ad9916d7c44fb407"),
        "15.3": .init(bytes: 11_955_051, sha256: "73dc9de36125b27188b9719d82aa12e6811bc83a77f88a5756cafb28a391b073", blob: "e61612f709ffeecac7af53e0d5ae79101a4f664e"),
        "15.4": .init(bytes: 9_120_796, sha256: "35d6cc8d694d42db639c32c451ef5fcfb4679daf2c3c5bb295cc7391e317128e"),
        "15.5": .init(bytes: 9_092_125, sha256: "d8d626b1e9c1d7eeec32b9c92d3fe24d8912ce834bf6ddb9d2193a2faf7dbe3c"),
        "15.6": .init(bytes: 9_085_705, sha256: "68ac765c401d6085e4e80069878340a43c4a4fd67c3b6891e4968492db978980"),
        "15.7": .init(bytes: 9_092_125, sha256: "5a9f8d246ee74177e342094a1a558e06a49b48b4f6310007f764e8400dd43f6a"),
        "15.8": .init(bytes: 9_051_989, sha256: "7458c09a25c090b0286cd64b50f3821c211a6b002b0c628a6a9b1eab41024e08"),
        "16.0": .init(bytes: 8_409_901, sha256: "acd0dc1cb48305d35c2ddeb4bb9b7895eb3ec2dfe14dd49544efdb520106f889"),
        "16.1": .init(bytes: 8_454_092, sha256: "2220c814b1b4beb387254e4fbf3e85001595fdaf54173c948027c23f58943a06"),
        "16.2": .init(bytes: 8_455_227, sha256: "02370f0c799d3dd02597a96be5e760a8dbefe26dc1d8b166a8f6b920e0c77e3a"),
        "16.3": .init(bytes: 8_455_227, sha256: "141a788fb5973386be60f8d7103db2e4632b55c584b54b43d7c65b40736f1ccf"),
        "16.4": .init(bytes: 7_422_275, sha256: "f549dd866703f6dffb6ca70a6ca6b5f3d8fbc672cf69eb6475f3a9ac3c08800d"),
        "16.5": .init(bytes: 7_421_435, sha256: "7269eedea393349b60ef5efd39e0ed7228e649aea3a28af2fd4c3cfcfb8bdecb"),
        "16.6": .init(bytes: 7_426_102, sha256: "bc56a2c5dc2cf31a6728dcd64449dd9e0bd77cb678af90a2ff4fb3bb627bb2ac"),
        "16.7": .init(bytes: 7_426_102, sha256: "ce3129b8b85b40a5d8e5563fd2ed08e05f9b766ea43b4065203d300786886277"),
    ]

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPhoneUse/LegacyDDI", isDirectory: true)
    }

    typealias Fetch = (URL, URL, Int64) throws -> Void

    static func image(version: String, cache: URL = cacheDirectory, catalog: [String: Asset] = assets,
                      fetch: Fetch? = nil) throws -> LegacyDeveloperImage.Image {
        guard let minor = try LegacyDeveloperImage.versionDirectories(version).last, let asset = catalog[minor] else {
            throw DDIManagementError("No pinned Gitee DeveloperDiskImage for iOS \(version)")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try DDILocalFile.withDirectory(cache) { root in
            let lock = try DDIFileLock(directory: root, name: "\(minor).lock", exclusive: true,
                                       unavailable: "An iOS \(minor) DDI download is in progress; refresh after it completes")
            return try withExtendedLifetime(lock) {
                let work = cache.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? fm.removeItem(at: work) }
                let name = "\(minor).zip"
                if let cached = try? DDILocalFile.metadata(root: cache, path: name, limit: asset.bytes), asset.verified(cached) {
                    return try extract(cached, directory: asset.directory ?? minor, in: work)
                }

                let download = work.appendingPathComponent("response")
                let path: String
                if let blob = asset.blob {
                    path = "/api/v5/repos/\(repository)/git/blobs/\(blob)"
                } else {
                    path = "/\(repository)/raw/\(revision)/iOS\(minor.prefix(2))/\(name)"
                }
                let url = URL(string: "https://gitee.com" + path)!
                try (fetch ?? fetchFromGitee)(url, download, Int64(asset.transferLimit))
                let response = try DDILocalFile.metadata(root: work, path: "response", limit: asset.transferLimit)
                let archive = try archiveBytes(response, asset: asset)
                guard asset.verified(archive) else { throw DDIManagementError("Gitee DDI archive size or SHA-256 mismatch") }
                let image = try extract(archive, directory: asset.directory ?? minor, in: work)
                try archive.write(to: cache.appendingPathComponent(name), options: .atomic)
                return image
            }
        }
    }

    private static func fetchFromGitee(_ url: URL, _ destination: URL, _ limit: Int64) throws {
        do {
            // Leave time for USB upload, mount and DVT reconnect in the app worker.
            try DDIDownloadTransfer(destination: destination, limit: limit, timeout: 18,
                                    allowedHosts: ["gitee.com", "raw.giteeusercontent.com"]) { _, _ in }.run(url)
        } catch let error as URLError {
            // Don't expose the signed CDN redirect URL from Foundation's error metadata.
            throw DDIManagementError("Gitee DDI download failed (network error \(error.code.rawValue))")
        }
    }

    private static func archiveBytes(_ response: Data, asset: Asset) throws -> Data {
        guard let expected = asset.blob else { return response }
        guard let blob = try? JSONDecoder().decode(GitBlob.self, from: response),
              blob.sha == expected, blob.size == asset.bytes, blob.encoding == "base64",
              let archive = Data(base64Encoded: blob.content) else {
            throw DDIManagementError("Gitee DDI Git blob response is invalid")
        }
        return archive
    }

    private static func extract(_ bytes: Data, directory: String, in work: URL) throws -> LegacyDeveloperImage.Image {
        // Only re-open the pinned bytes in an app-owned staging directory, never
        // a mutable cache path. No archive entries other than the signed pair are extracted.
        let zip = work.appendingPathComponent("verified.zip")
        try bytes.write(to: zip, options: .withoutOverwriting)
        let prefix = directory + "/DeveloperDiskImage.dmg"
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zip.path, prefix, prefix + ".signature", "-d", work.path]
        unzip.environment = ["LANG": "C"]
        unzip.standardInput = FileHandle.nullDevice
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        guard try unzip.run(timeout: 3), unzip.terminationStatus == 0 else {
            throw DDIManagementError("Cannot extract the signed image pair from the pinned Gitee DDI")
        }
        return try .init(bytes: DDILocalFile.metadata(root: work, path: prefix, limit: LegacyDeveloperImage.imageLimit),
                         signature: DDILocalFile.metadata(root: work, path: prefix + ".signature", limit: LegacyDeveloperImage.signatureLimit))
    }
}
