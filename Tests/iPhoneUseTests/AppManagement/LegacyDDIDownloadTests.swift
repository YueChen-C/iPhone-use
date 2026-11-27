import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import iPhoneUse

final class LegacyDDIDownloadTests: XCTestCase {
    private let image = Data([0x44, 0x4d, 0x47])
    private let signature = Data(repeating: 0x31, count: 128)

    func testPatchVersionDownloadsPinnedArchiveAndReusesVerifiedCache() throws {
        try withDirectory { root in
            let archive = try fixture(in: root)
            let cache = root.appendingPathComponent("cache", isDirectory: true)
            let catalog = ["15.4": asset(archive)]
            var fetched = 0
            let fetch: LegacyDDIDownload.Fetch = { url, destination, limit in
                fetched += 1
                XCTAssertEqual(url.host, "gitee.com")
                XCTAssertTrue(url.path.hasSuffix("/iOS15/15.4.zip"))
                XCTAssertFalse(url.path.contains("master"))
                XCTAssertEqual(limit, Int64(archive.count))
                try archive.write(to: destination)
            }
            let initial = try LegacyDDIDownload.image(version: "15.4.1", cache: cache, catalog: catalog, fetch: fetch)
            XCTAssertEqual(initial.bytes, image)
            XCTAssertEqual(initial.signature, signature)
            let cached = try LegacyDDIDownload.image(version: "15.4.2", cache: cache, catalog: catalog, fetch: fetch)
            XCTAssertEqual(cached.bytes, initial.bytes)
            XCTAssertEqual(fetched, 1)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)), ["15.4.zip", "15.4.lock"])

            // Same-sized tampering must not be accepted, even offline.
            let target = cache.appendingPathComponent("15.4.zip")
            try Data(repeating: 0x33, count: archive.count).write(to: target)
            XCTAssertThrowsError(try LegacyDDIDownload.image(version: "15.4", cache: cache, catalog: catalog) { _, _, _ in
                throw URLError(.notConnectedToInternet)
            })
            XCTAssertEqual(try LegacyDDIDownload.image(version: "15.4", cache: cache, catalog: catalog, fetch: fetch).bytes, image)
            XCTAssertEqual(fetched, 2)
            XCTAssertEqual(try Data(contentsOf: target), archive)
        }
    }

    func testPublicBlobEndpointDecodesBoundedResponseAndHandlesBuildDirectory() throws {
        try withDirectory { root in
            let directory = "15.1 (19B74)"
            let archive = try fixture(in: root, directory: directory)
            let blob = String(repeating: "a", count: 40)
            let cache = root.appendingPathComponent("cache", isDirectory: true)
            let asset = asset(archive, blob: blob, directory: directory)
            let got = try LegacyDDIDownload.image(version: "15.1.1", cache: cache, catalog: ["15.1": asset]) { url, dest, limit in
                XCTAssertEqual(url.path, "/api/v5/repos/ios_shen/iOSDeviceSupport/git/blobs/\(blob)")
                let json = try JSONSerialization.data(withJSONObject: ["size": archive.count, "sha": blob,
                                                                        "encoding": "base64", "content": archive.base64EncodedString()])
                XCTAssertEqual(limit, Int64(asset.transferLimit))
                XCTAssertLessThan(json.count, Int(limit))
                try json.write(to: dest)
            }
            XCTAssertEqual(got.bytes, image)
            XCTAssertEqual(got.signature, signature)
            XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent("15.1.zip")), archive)
        }
    }

    func testBadDownloadNeverPublishesAndUnknownVersionsNeverFetch() throws {
        try withDirectory { root in
            let archive = try fixture(in: root)
            let cache = root.appendingPathComponent("cache", isDirectory: true)
            for version in ["15.9", "16.8", "17.4", "15.4/../"] {
                XCTAssertThrowsError(try LegacyDDIDownload.image(version: version, cache: cache) { _, _, _ in
                    XCTFail("unexpected request for \(version)")
                })
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))

            for bad in [Data([0]), Data(repeating: 0xff, count: archive.count), archive + Data([0])] {
                XCTAssertThrowsError(try LegacyDDIDownload.image(version: "15.4", cache: cache, catalog: ["15.4": asset(archive)]) { _, out, _ in
                    try bad.write(to: out)
                })
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), ["15.4.lock"])
        }
    }

    func testLiveGiteeDownloadsWhenExplicitlyEnabled() throws {
        guard let setting = ProcessInfo.processInfo.environment["IPHONE_USE_TEST_LEGACY_GITEE"], !setting.isEmpty else {
            throw XCTSkip("Set IPHONE_USE_TEST_LEGACY_GITEE to comma-separated iOS versions for a live Gitee test")
        }
        let versions = setting.split(separator: ",").map(String.init)
        try withDirectory { root in
            for version in versions {
                let image = try LegacyDDIDownload.image(version: version, cache: root)
                XCTAssertGreaterThan(image.bytes.count, 1_000_000)
                XCTAssertEqual(image.signature.count, 128)
                let cached = try LegacyDDIDownload.image(version: version, cache: root) { _, _, _ in XCTFail("expected cache reuse") }
                XCTAssertEqual(cached.bytes, image.bytes)
                XCTAssertEqual(cached.signature, image.signature)
            }
        }
    }

    private func asset(_ bytes: Data, blob: String? = nil, directory: String? = nil) -> LegacyDDIDownload.Asset {
        .init(bytes: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
              blob: blob, directory: directory)
    }

    private func fixture(in root: URL, directory: String = "15.4") throws -> Data {
        let payload = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        try image.write(to: payload.appendingPathComponent("DeveloperDiskImage.dmg"))
        try signature.write(to: payload.appendingPathComponent("DeveloperDiskImage.dmg.signature"))
        try Data([0]).write(to: payload.appendingPathComponent("ignored"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qr", "fixture.zip", directory]
        zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        guard try zip.run(timeout: 3), zip.terminationStatus == 0 else { throw DDIManagementError("Could not build ZIP fixture") }
        return try Data(contentsOf: root.appendingPathComponent("fixture.zip"))
    }

    private func withDirectory(_ use: (URL) throws -> Void) throws {
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try use(root)
    }
}
