import CryptoKit
import Darwin
import XCTest
@testable import iPhoneUse

final class DDIManagementTests: XCTestCase {
    private let product = "iPhone13,2"
    private var root: URL!
    private let image = Data("fixture image; never an Apple payload".utf8)
    private let trust = Data("fixture trustcache".utf8)

    override func setUpWithError() throws {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("iphone-use-ddi-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Restore"), withIntermediateDirectories: true)
        try image.write(to: root.appendingPathComponent("Restore/Image.dmg"))
        try trust.write(to: root.appendingPathComponent("Restore/Image.dmg.trustcache"))
        try writeManifest(manifest())
        try writePlist(["Platform": "iOS", "ProductBuildVersion": "FIXTURE1",
                        "ProjectMetadata": [["Project": "CoreDevice", "Version": "651.32"]]], path: "version.plist")
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private func hex<S: Sequence>(_ value: S) -> String where S.Element == UInt8 {
        value.map { String(format: "%02x", $0) }.joined()
    }
    private func component(_ data: Data, path: String, image: Bool) -> [String: Any] {
        var info: [String: Any] = ["Path": path]
        if image { info["HashMethod"] = "sha2-384" }
        return ["Digest": Data(SHA384.hash(data: data)), "Info": info]
    }
    private func manifest(imagePath: String = "Image.dmg", extra: Bool = false, otherProduct: String? = nil) -> [String: Any] {
        var components: [String: Any] = ["PersonalizedDMG": component(image, path: imagePath, image: true),
                                       "LoadableTrustCache": component(trust, path: "Image.dmg.trustcache", image: false)]
        if extra { components["UnknownExecutable"] = components["PersonalizedDMG"] }
        return ["ProductBuildVersion": "FIXTURE1", "SupportedProductTypes": [product],
                "BuildIdentities": [["Ap,ProductType": otherProduct ?? product, "Manifest": components]]]
    }
    private func writePlist(_ value: [String: Any], path: String) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            .write(to: root.appendingPathComponent(path))
    }
    private func writeManifest(_ value: [String: Any]) throws { try writePlist(value, path: "Restore/BuildManifest.plist") }
    private func receipt(overrides: [String: String] = [:], kind: String = "third-party-mirror",
                         location: String = "https://example.invalid/fixture", revision: String = String(repeating: "a", count: 40)) throws -> DDISourceRecord {
        var hashes: [String: String] = [:]
        for path in ["version.plist", "Restore/BuildManifest.plist", "Restore/Image.dmg", "Restore/Image.dmg.trustcache"] {
            hashes[path] = hex(SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path))))
        }
        hashes.merge(overrides, uniquingKeysWith: { _, new in new })
        return DDISourceRecord(schemaVersion: 1, kind: kind, location: location, revision: revision, sha256: hashes)
    }
    private func inspect(_ source: DDISourceRecord? = nil) throws -> DDIBundlePreflight {
        try DDIBundlePreflight.inspect(bundle: root, source: source ?? receipt(), productType: product)
    }

    func testMatchingPayloadAndReceiptIsReadOnlyNotAuthorization() throws {
        let report = try inspect()
        XCTAssertEqual(report.files.count, 4); XCTAssertEqual(report.build, "FIXTURE1")
        XCTAssertEqual(report.compatibleIdentities, 1); XCTAssertTrue(report.integrityVerified)
        XCTAssertFalse(report.mountAuthorized); XCTAssertFalse(report.provenanceVerified)
        XCTAssertFalse(report.deviceCompatibilityVerified); XCTAssertFalse(report.deviceMutation); XCTAssertFalse(report.inputSent)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Restore/Image.dmg")), image)
    }
    func testReceiptMetadataMismatchRejectedBeforePayloads() throws {
        let source = try receipt()
        try writeManifest(manifest(otherProduct: "iPhone0,0"))
        XCTAssertThrowsError(try inspect(source))
    }
    func testPayloadTamperingRejectedEvenWhenReceiptIsRewritten() throws {
        try Data("tampered".utf8).write(to: root.appendingPathComponent("Restore/Image.dmg"))
        XCTAssertThrowsError(try inspect())
    }
    func testReceiptDigestMismatchRejected() throws {
        XCTAssertThrowsError(try inspect(receipt(overrides: ["Restore/Image.dmg": String(repeating: "0", count: 64)])))
    }
    func testSourceReceiptMustCoverExactlyKnownFiles() throws {
        let source = try receipt()
        var hashes = source.sha256; hashes.removeValue(forKey: "Restore/Image.dmg.trustcache")
        XCTAssertThrowsError(try inspect(DDISourceRecord(schemaVersion: 1, kind: source.kind,
            location: source.location, revision: source.revision, sha256: hashes)))
        XCTAssertThrowsError(try inspect(receipt(overrides: ["unreferenced.dmg": String(repeating: "0", count: 64)])))
    }
    func testUnknownComponentAndUnmatchedProductRejected() throws {
        try writeManifest(manifest(extra: true)); XCTAssertThrowsError(try inspect())
        try writeManifest(manifest(otherProduct: "iPhone0,0")); XCTAssertThrowsError(try inspect())
        try writeManifest(manifest())
        XCTAssertThrowsError(try DDIBundlePreflight.inspect(bundle: root, source: receipt(), productType: "iPhone0,0"))
    }
    func testUnrelatedLegacyAndCryptexIdentitiesAreExplicitlyOutOfScope() throws {
        var value = manifest()
        var identities = value["BuildIdentities"] as! [[String: Any]]
        identities.append(["Ap,ProductType": "iPhone8,1", "Manifest": ["PersonalizedDMG": ["Digest": Data(repeating: 0, count: 20)]]])
        identities.append(["Ap,TargetType": "ioscryptex", "Manifest": ["Cryptex1,GenericDmg": ["Info": ["Path": "other.dmg"]]]])
        value["BuildIdentities"] = identities
        try writeManifest(value)
        let report = try inspect()
        XCTAssertEqual(report.compatibleIdentities, 1); XCTAssertEqual(report.ignoredIdentities, 2)
        XCTAssertEqual(report.validationScope, "matching-product-personalized-image")
    }
    func testMatchingIdentitiesWithConflictingDigestFailClosed() throws {
        var value = manifest()
        var identities = value["BuildIdentities"] as! [[String: Any]]
        identities.append(["Ap,ProductType": product, "Manifest": [
            "PersonalizedDMG": component(Data("other".utf8), path: "Image.dmg", image: true),
            "LoadableTrustCache": component(trust, path: "Image.dmg.trustcache", image: false)]])
        value["BuildIdentities"] = identities
        try writeManifest(value)
        XCTAssertThrowsError(try inspect())
    }
    func testInconsistentVersionMetadataRejected() throws {
        try writePlist(["Platform": "iOS", "ProductBuildVersion": "OTHER",
                        "ProjectMetadata": [["Project": "CoreDevice", "Version": "1"]]], path: "version.plist")
        XCTAssertThrowsError(try inspect())
    }
    func testManifestPathTraversalRejected() throws {
        for path in ["../outside.dmg", "/tmp/absolute", "Firmware/../Image.dmg", "Firmware//Image.dmg", "Firmware\\Image.dmg"] {
            try writeManifest(manifest(imagePath: path)); XCTAssertThrowsError(try inspect())
        }
    }
    func testMalformedDigestHashDialectAndMetadataLimitAreRejected() throws {
        var value = manifest()
        var identity = (value["BuildIdentities"] as! [[String: Any]])[0]
        var components = identity["Manifest"] as! [String: Any]
        components["PersonalizedDMG"] = ["Digest": Data(repeating: 0, count: 20),
                                        "Info": ["Path": "Image.dmg", "HashMethod": "sha1"]]
        identity["Manifest"] = components; value["BuildIdentities"] = [identity]
        try writeManifest(value); XCTAssertThrowsError(try inspect())
        try writeManifest(manifest())
        XCTAssertThrowsError(try DDILocalFile.metadata(root: root, path: "version.plist", limit: 1))
        try Data("not a plist".utf8).write(to: root.appendingPathComponent("version.plist"))
        XCTAssertThrowsError(try inspect())
    }
    func testCanonicalPrivateVarPathIsNotRewrittenToASymlink() throws {
        XCTAssertEqual(try DDILocalFile.absoluteURL("/private/var/ddi").path, "/private/var/ddi")
        for path in ["relative", "/tmp/../ddi", "/tmp//ddi", "/tmp/./ddi", "/tmp/ddi/"] {
            XCTAssertThrowsError(try DDILocalFile.absoluteURL(path))
        }
    }
    func testRootIntermediateAndPayloadSymlinksRejected() throws {
        let source = try receipt()
        let link = root.appendingPathComponent("bundle-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try DDIBundlePreflight.inspect(bundle: link, source: source, productType: product))
        XCTAssertThrowsError(try DDILocalFile.metadata(root: link.appendingPathComponent("Restore"), path: "BuildManifest.plist"))
        let path = root.appendingPathComponent("Restore/Image.dmg")
        try FileManager.default.removeItem(at: path)
        try image.write(to: root.appendingPathComponent("outside.dmg"))
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("outside.dmg"))
        XCTAssertThrowsError(try inspect(source))
    }
    func testNestedDirectorySymlinkAndFIFORejectedWithoutBlocking() throws {
        try FileManager.default.moveItem(at: root.appendingPathComponent("Restore"), to: root.appendingPathComponent("real-restore"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Restore"), withDestinationURL: root.appendingPathComponent("real-restore"))
        XCTAssertThrowsError(try DDILocalFile.metadata(root: root, path: "Restore/BuildManifest.plist"))
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try DDILocalFile.metadata(root: root, path: "pipe"))
    }
    func testMirrorSourceNeedsPinnedRevisionAndCannotClaimAppleProvenance() throws {
        XCTAssertThrowsError(try receipt(revision: "main").validate())
        XCTAssertThrowsError(try receipt(location: "http://example.invalid", revision: String(repeating: "a", count: 40)).validate())
        XCTAssertThrowsError(try receipt(kind: "apple-cdn").validate())
        XCTAssertNoThrow(try receipt(kind: "apple-installed", location: "file:///Library/Developer/InstalledDDI", revision: "1").validate())
    }
    func testFullPhysicalIdentityOnlyAndMutationCommandsAbsent() throws {
        let udid = "12345678-1234567890ABCDEF"
        XCTAssertNoThrow(try NativeDDIInspection.validateIdentity(udid))
        XCTAssertNoThrow(try NativeDDIInspection.validateIdentity(String(repeating: "a", count: 40)))
        for value in ["phone", "12345678", "12345678-1234-1234-1234-123456789012", "12345678-1234567890ABCDEG"] {
            XCTAssertThrowsError(try NativeDDIInspection.validateIdentity(value))
        }
        XCTAssertEqual(try DDIManagementCLI.parse(["inspect", udid]), .inspect(udid))
        for action in ["mount", "unmount", "switch", "restore"] {
            XCTAssertThrowsError(try DDIManagementCLI.parse([action, udid]))
        }
        XCTAssertThrowsError(try DDIManagementCLI.parse(["preflight", "relative", "/source.json", product]))
    }
    func testReceiptFileReadbackAndSymlinkRejected() throws {
        let path = root.appendingPathComponent("source.json")
        try JSONEncoder().encode(receipt()).write(to: path)
        XCTAssertTrue(try DDIBundlePreflight.inspect(bundlePath: root.path, receiptPath: path.path, productType: product).integrityVerified)
        let link = root.appendingPathComponent("receipt-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try DDIBundlePreflight.inspect(bundlePath: root.path, receiptPath: link.path, productType: product))
    }
    func testMountedReplyDistinguishesEmptyFromMalformedAndRetainsVersion() throws {
        XCTAssertTrue(try NativeDDIInspection.mountedImages([] as [[String: Any]]).isEmpty)
        XCTAssertThrowsError(try NativeDDIInspection.mountedImages(nil))
        XCTAssertThrowsError(try NativeDDIInspection.mountedImages([["IsMounted": 1]]))
        let images = try NativeDDIInspection.mountedImages([["MountPath": "/System/Developer", "IsMounted": true,
            "DiskImageType": "Developer", "PersonalizedImageVersion": "651.32",
            "PersonalizedImageVersionInfo": ["ProductBuildVersion": "FIXTURE1"], "ImageSignature": Data([1, 2])]])
        XCTAssertEqual(images.first?.build, "FIXTURE1"); XCTAssertEqual(images.first?.imageSignature, "AQI=")
    }
}
