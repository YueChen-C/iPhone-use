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

    private var target: DDIFirstMount.Target {
        .init(physicalID: "00008101-0018242C3400001E", productType: product,
              productVersion: "26.5", productBuild: "FIXTURE-OS")
    }

    private func phone(_ images: [NativeDDIInspection.MountedImage] = [], build: String? = nil) -> NativeDDIInspection.Report {
        .init(physicalID: target.physicalID, productType: product, productVersion: target.productVersion,
              productBuild: build ?? target.productBuild, mountedImages: images,
              frameworkVersion: NativeDDIInspection.frameworkVersion)
    }

    private var installedImage: NativeDDIInspection.MountedImage {
        .init(mountPath: "/System/Developer", isMounted: true, imageType: "Personalized",
              build: "FIXTURE1", version: "651.32", imageSignature: Data(SHA384.hash(data: image)).base64EncodedString())
    }

    private var oldImage: NativeDDIInspection.MountedImage {
        .init(mountPath: "/System/Developer", isMounted: true, imageType: "Personalized",
              build: "OLD", version: "397.24", imageSignature: nil)
    }

    func testFirstMountInstallsOnceAndVerifiesReadback() throws {
        let prepared = try inspect()
        var events: [String] = []
        var images: [NativeDDIInspection.MountedImage] = []
        let outcome = try DDIFirstMount.install(target: target, image: prepared, mount: { guardMount in
            events.append("guard mount")
            if try guardMount(phone(images)) { events.append("mount"); images = [installedImage] }
        }, unmount: { _ in XCTFail("Empty slot must not be unmounted") }, inspect: {
            events.append("inspect")
            return phone(images)
        }, progress: { events.append($0.rawValue) })
        XCTAssertEqual(outcome, .installed)
        XCTAssertEqual(events, ["inspect", "guard mount", "installing", "mount", "verifyingInstallation", "inspect"])
    }

    func testFirstMountReplacesDifferentImageThenVerifiesReadback() throws {
        let prepared = try inspect()
        var events: [String] = []
        var images = [oldImage]
        let outcome = try DDIFirstMount.install(target: target, image: prepared, mount: { guardMount in
            events.append("guard mount")
            if try guardMount(phone(images)) { events.append("mount"); images = [installedImage] }
        }, unmount: { guardUnmount in
            events.append("guard unmount")
            try guardUnmount(phone(images)); events.append("unmount"); images = []
        }, inspect: {
            events.append("inspect")
            return phone(images)
        }, progress: { events.append($0.rawValue) })
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(events, ["inspect", "guard unmount", "uninstalling", "unmount", "inspect", "guard mount",
                                "installing", "mount", "verifyingInstallation", "inspect"])
    }

    func testFirstMountReusesExactMatchAndLeavesAmbiguousImagesInPlace() throws {
        let prepared = try inspect()
        let result = try DDIFirstMount.install(target: target, image: prepared,
            mount: { _ in XCTFail("Exact match must be reused") }, unmount: { _ in XCTFail("Exact match must be reused") },
            inspect: { phone([installedImage]) })
        XCTAssertEqual(result, .alreadyInstalled)
        let unidentified = NativeDDIInspection.MountedImage(mountPath: "/System/Developer", isMounted: true,
            imageType: "Personalized", build: installedImage.build, version: installedImage.version, imageSignature: nil)
        for images in [[unidentified], [installedImage, oldImage]] {
            XCTAssertThrowsError(try DDIFirstMount.install(target: target, image: prepared,
                mount: { _ in XCTFail("Ambiguous slot must not be overwritten") },
                unmount: { _ in XCTFail("Ambiguous slot must not be unmounted") }, inspect: { phone(images) }))
        }
    }

    func testFirstMountSkipsMutationIfDeviceOrSlotChanges() throws {
        let prepared = try inspect()
        for changed in [phone([oldImage], build: "ANOTHER-OS"), phone([installedImage])] {
            XCTAssertThrowsError(try DDIFirstMount.install(target: target, image: prepared,
                mount: { _ in XCTFail("Mount must not be attempted") }, unmount: { guardUnmount in
                    try guardUnmount(changed)
                    XCTFail("Unmount guard must reject a changed device or slot")
                }, inspect: { phone([oldImage]) }))
        }
        XCTAssertThrowsError(try DDIFirstMount.install(target: target, image: prepared, mount: { guardMount in
            _ = try guardMount(phone([oldImage]))
            XCTFail("Mount guard must reject an occupied slot")
        }, unmount: { _ in XCTFail("Initially empty slot must not be unmounted") }, inspect: { phone() }))
    }

    func testFirstMountDoesNotInstallWhenUninstallIsUnconfirmed() throws {
        let prepared = try inspect()
        var unmounts = 0
        XCTAssertThrowsError(try DDIFirstMount.install(target: target, image: prepared,
            mount: { _ in XCTFail("Unconfirmed unmount must not be followed by installation") }, unmount: { guardUnmount in
                try guardUnmount(phone([oldImage])); unmounts += 1
            }, inspect: { phone([oldImage]) }))
        XCTAssertEqual(unmounts, 1)
    }

    func testFirstMountRejectsWrongSignatureAfterOneMountAttempt() throws {
        let prepared = try inspect()
        var mounts = 0
        var images: [NativeDDIInspection.MountedImage] = []
        let unverified = NativeDDIInspection.MountedImage(mountPath: "/System/Developer", isMounted: true,
            imageType: "Personalized", build: installedImage.build, version: installedImage.version,
            imageSignature: Data(repeating: 0, count: 48).base64EncodedString())
        XCTAssertThrowsError(try DDIFirstMount.install(target: target, image: prepared, mount: { guardMount in
            if try guardMount(phone(images)) { mounts += 1; images = [unverified] }
        }, unmount: { _ in XCTFail("Empty slot must not be unmounted") }, inspect: { phone(images) }))
        XCTAssertEqual(mounts, 1)
    }

    func testNativeChildDeliversCompleteProgressLinesOnceAndKeepsReply() throws {
        var lines: [String] = []
        let script = "printf 'uninstall'; /bin/sleep 0.15; printf 'ing\\n'; /bin/sleep 0.15; printf 'installing\\nreply\\n'"
        let data = try DDINativeProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script], timeout: 3, observeLine: { lines.append($0) })
        XCTAssertEqual(lines, ["uninstalling", "installing", "reply"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "uninstalling\ninstalling\nreply\n")
    }

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
