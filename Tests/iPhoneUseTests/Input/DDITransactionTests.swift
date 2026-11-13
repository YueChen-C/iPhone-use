import CryptoKit
import Darwin
import XCTest
@testable import iPhoneUse

final class DDITransactionTests: XCTestCase {
    private let id = "12345678-1234567890ABCDEF", product = "iPhone13,2"
    private var root: URL!
    private var candidate: DDIBundlePreflight!
    private var baseline: DDIBundlePreflight!
    private var device: FakeDevice!
    private var directory: URL { root.appendingPathComponent("transaction") }

    final class FakeDevice: DDITransactionDevice {
        var report: NativeDDIInspection.Report
        var calls: [String] = []
        var failMount = false, lieOnMount = false, lieOnUnmount = false, failInspect = false
        var beforeMutation: (() throws -> Void)?
        init(report: NativeDDIInspection.Report) { self.report = report }
        func inspect(physicalID: String) throws -> NativeDDIInspection.Report {
            calls.append("inspect:" + physicalID)
            if failInspect { throw DDIManagementError("fixture disconnected") }
            return report
        }
        func unmount(physicalID: String) throws {
            try beforeMutation?(); calls.append("unmount:" + physicalID)
            if !lieOnUnmount { report = copy(images: []) }
        }
        func mount(physicalID: String, bundle: URL) throws {
            try beforeMutation?(); calls.append("mount:" + bundle.lastPathComponent)
            if failMount { throw DDIManagementError("fixture uncertain mount") }
            if !lieOnMount {
                let bytes = try Data(contentsOf: bundle.appendingPathComponent("Restore/Image.dmg"))
                let versionBytes = try Data(contentsOf: bundle.appendingPathComponent("version.plist"))
                let version = try PropertyListSerialization.propertyList(from: versionBytes, format: nil) as! [String: Any]
                let build = version["ProductBuildVersion"] as! String
                report = copy(images: [.init(mountPath: "/System/Developer", isMounted: true, imageType: "Personalized",
                    build: build, version: build == "OLD" ? "397.24" : "651.32",
                    imageSignature: Data(SHA384.hash(data: bytes)).base64EncodedString())])
            }
        }
        func copy(images: [NativeDDIInspection.MountedImage]? = nil, id: String? = nil) -> NativeDDIInspection.Report {
            .init(physicalID: id ?? report.physicalID, productType: report.productType, productVersion: report.productVersion,
                  productBuild: report.productBuild, mountedImages: images ?? report.mountedImages,
                  frameworkVersion: report.frameworkVersion)
        }
    }
    override func setUpWithError() throws {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(path) }
        root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("ddi-transaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        baseline = try fixture(name: "old-source", build: "OLD", core: "397.24")
        candidate = try fixture(name: "new-source", build: "NEW", core: "651.32")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: baseline.bundlePath).appendingPathComponent("Restore/Image.dmg"))
        device = FakeDevice(report: .init(physicalID: id, productType: product, productVersion: "26.5", productBuild: "23F77",
            mountedImages: [.init(mountPath: "/System/Developer", isMounted: true, imageType: "Personalized", build: "OLD",
                                 version: "397.24", imageSignature: Data(SHA384.hash(data: bytes)).base64EncodedString())],
            frameworkVersion: NativeDDIInspection.frameworkVersion))
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private func fixture(name: String, build: String, core: String) throws -> DDIBundlePreflight {
        let bundle = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Restore"), withIntermediateDirectories: true)
        let image = Data((build + " fixture image").utf8), trust = Data((build + " trust fixture").utf8)
        try image.write(to: bundle.appendingPathComponent("Restore/Image.dmg"))
        try trust.write(to: bundle.appendingPathComponent("Restore/Trust"))
        let manifest: [String: Any] = ["ProductBuildVersion": build, "SupportedProductTypes": [product],
            "BuildIdentities": [["Ap,ProductType": product, "Manifest": [
                "PersonalizedDMG": ["Info": ["Path": "Image.dmg", "HashMethod": "sha2-384"], "Digest": Data(SHA384.hash(data: image))],
                "LoadableTrustCache": ["Info": ["Path": "Trust"], "Digest": Data(SHA384.hash(data: trust))]]]]]
        let version: [String: Any] = ["ProductBuildVersion": build, "Platform": "iOS",
                                     "ProjectMetadata": [["Project": "CoreDevice", "Version": core]]]
        for (path, value) in [("version.plist", version), ("Restore/BuildManifest.plist", manifest)] {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: bundle.appendingPathComponent(path))
        }
        var hashes: [String: String] = [:]
        for path in ["version.plist", "Restore/BuildManifest.plist", "Restore/Image.dmg", "Restore/Trust"] {
            hashes[path] = DDITransactionStore.digest(try Data(contentsOf: bundle.appendingPathComponent(path)))
        }
        return try DDIBundlePreflight.inspect(bundle: bundle, source: .init(schemaVersion: 1, kind: "third-party-mirror",
            location: "https://example.invalid/fixture", revision: String(repeating: "a", count: 40), sha256: hashes), productType: product)
    }
    private func plan() throws -> DDITransaction.Summary {
        try DDITransaction.plan(physicalID: id, candidate: candidate, baseline: baseline, directory: directory, device: device)
    }
    private func execute(_ hash: String, restore: Bool = false, acknowledge: Bool = true,
                         mark: (DDIProcessLease.Pending) throws -> Void = { _ in },
                         clear: (DDIProcessLease.Pending) throws -> Void = { _ in }) throws -> DDITransaction.Summary {
        try DDITransaction.execute(directory: directory, confirmation: hash, acknowledgeSourceRisk: acknowledge,
                                   restore: restore, device: device, markPending: mark, clearPending: clear)
    }
    func testPlanStagesIndependentCopiesWithoutDeviceMutationAndPinsSource() throws {
        let value = try plan()
        XCTAssertEqual(value.journal.phase, .preflight); XCTAssertFalse(value.deviceMutation)
        XCTAssertFalse(value.sourceAuthenticated); XCTAssertEqual(value.plan.currentImage.build, "OLD")
        XCTAssertEqual(value.planSHA256.count, 64); XCTAssertEqual(device.calls, ["inspect:" + id])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: candidate.bundlePath))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: baseline.bundlePath))
        XCTAssertEqual(try execute(value.planSHA256).journal.phase, .independentlyVerified)
    }
    func testApplyAndWholeRestorePersistIntentBeforeEachMutationAndReadBack() throws {
        let value = try plan()
        var pending = false
        device.beforeMutation = {
            XCTAssertTrue(pending)
            let data = try Data(contentsOf: self.directory.appendingPathComponent("journal.json"))
            let journal = try JSONDecoder().decode(DDITransaction.Journal.self, from: data)
            XCTAssertTrue([.unmounting, .mounting, .restoreUnmounting, .restoring].contains(journal.phase))
        }
        let result = try execute(value.planSHA256, mark: { _ in pending = true }, clear: { _ in pending = false })
        XCTAssertEqual(result.journal.events.map(\.phase), [.preflight, .authorized, .unmounting, .unmounted, .mounting, .mounted, .independentlyVerified])
        XCTAssertEqual(device.report.mountedImages.first?.build, "NEW"); XCTAssertFalse(pending)
        let restored = try execute(value.planSHA256, restore: true, mark: { _ in pending = true }, clear: { _ in pending = false })
        XCTAssertEqual(restored.journal.phase, .restored); XCTAssertEqual(device.report.mountedImages.first?.build, "OLD")
        XCTAssertFalse(pending); XCTAssertEqual(device.calls.filter { $0.hasPrefix("mount:") }, ["mount:candidate", "mount:baseline"])
    }
    func testExactConfirmationAndSourceAcknowledgementAreRequiredBeforeDeviceCalls() throws {
        let value = try plan(); device.calls = []
        XCTAssertThrowsError(try execute(String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try execute(value.planSHA256, acknowledge: false))
        XCTAssertTrue(device.calls.isEmpty)
    }
    func testBaselineMustMatchActualCurrentImageSignature() throws {
        XCTAssertThrowsError(try DDITransaction.plan(physicalID: id, candidate: candidate, baseline: candidate,
            directory: directory, device: device))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testDeviceIdentityChangeFailsBeforeUnmountAndKeepsSnapshot() throws {
        let value = try plan(); device.report = device.copy(id: "87654321-1234567890ABCDEF"); device.calls = []
        XCTAssertThrowsError(try execute(value.planSHA256))
        XCTAssertFalse(device.calls.contains { $0.hasPrefix("unmount") })
    }
    func testTamperedPlanOrSnapshotNeverUnmounts() throws {
        let value = try plan(); device.calls = []
        let snapshot = directory.appendingPathComponent("candidate/Restore/Image.dmg")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        try Data("tamper".utf8).write(to: snapshot)
        XCTAssertThrowsError(try execute(value.planSHA256)); XCTAssertTrue(device.calls.isEmpty)
        let planFile = directory.appendingPathComponent("plan.json")
        var data = try Data(contentsOf: planFile); data.append(32); try data.write(to: planFile)
        XCTAssertThrowsError(try execute(value.planSHA256)); XCTAssertTrue(device.calls.isEmpty)
    }
    func testUncertainMountPersistsRecoveryAndNeverReplaysApply() throws {
        let value = try plan(); device.failMount = true
        var pending = false
        XCTAssertThrowsError(try execute(value.planSHA256, mark: { _ in pending = true }, clear: { _ in pending = false }))
        XCTAssertTrue(pending)
        let status = try DDITransaction.status(directory: directory)
        XCTAssertEqual(status.journal.phase, .mounting); XCTAssertNotNil(status.journal.events.last?.error)
        let before = device.calls
        XCTAssertThrowsError(try execute(value.planSHA256)); XCTAssertEqual(before, device.calls)
        device.failMount = false
        XCTAssertEqual(try execute(value.planSHA256, restore: true).journal.phase, .restored)
        XCTAssertEqual(device.report.mountedImages.first?.build, "OLD")
    }
    func testFalseUnmountAndMountReturnsCannotClearRecoveryBarrier() throws {
        let value = try plan(); device.lieOnUnmount = true
        var cleared = false
        XCTAssertThrowsError(try execute(value.planSHA256, clear: { _ in cleared = true }))
        XCTAssertFalse(cleared); XCTAssertEqual(try DDITransaction.status(directory: directory).journal.phase, .unmounting)
        device.lieOnUnmount = false; device.lieOnMount = true
        XCTAssertThrowsError(try execute(value.planSHA256, restore: true, clear: { _ in cleared = true }))
        XCTAssertFalse(cleared); XCTAssertEqual(try DDITransaction.status(directory: directory).journal.phase, .restoreMounted)
    }
    func testRecoveryDoesNotNeedCorruptCandidateButDoesRequireBaseline() throws {
        let value = try plan(); _ = try execute(value.planSHA256)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("candidate"))
        XCTAssertEqual(try execute(value.planSHA256, restore: true).journal.phase, .restored)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("baseline"))
        device.calls = []
        XCTAssertThrowsError(try execute(value.planSHA256, restore: true)); XCTAssertTrue(device.calls.isEmpty)
    }
    func testVerifiedRecoveryCanFinishInterruptedBarrierCleanupWithoutRemounting() throws {
        let value = try plan(); _ = try execute(value.planSHA256)
        XCTAssertThrowsError(try execute(value.planSHA256, restore: true, clear: { _ in throw DDIManagementError("fixture sync failure") }))
        XCTAssertEqual(try DDITransaction.status(directory: directory).journal.phase, .restored)
        device.calls = []; var cleared = false
        let result = try execute(value.planSHA256, restore: true, clear: { _ in cleared = true })
        XCTAssertTrue(cleared); XCTAssertFalse(result.deviceMutation)
        XCTAssertEqual(device.calls, ["inspect:" + id])
    }
    func testDurableBarrierWriteFailurePreventsAllMutation() throws {
        let value = try plan(); device.calls = []
        XCTAssertThrowsError(try execute(value.planSHA256, mark: { _ in throw DDIManagementError("fixture full disk") }))
        XCTAssertEqual(device.calls, ["inspect:" + id]); XCTAssertEqual(try DDITransaction.status(directory: directory).journal.phase, .preflight)
    }
    func testTransactionDirectoryIsPrivateLockedAndCannotBeOverwritten() throws {
        _ = try plan()
        let first = try DDITransactionStore(root: directory, create: false)
        XCTAssertThrowsError(try DDITransactionStore(root: directory, create: false))
        XCTAssertThrowsError(try DDITransactionStore(root: directory, create: true))
        withExtendedLifetime(first) {}
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try DDITransactionStore(root: directory, create: false))
    }
    func testUnrelatedCurrentImageCannotBeOverwrittenByRecovery() throws {
        let value = try plan()
        device.report = device.copy(images: [.init(mountPath: "/System/Developer", isMounted: true, imageType: "Personalized",
            build: "UNRELATED", version: "999", imageSignature: Data(repeating: 9, count: 48).base64EncodedString())])
        device.calls = []
        XCTAssertThrowsError(try execute(value.planSHA256, restore: true))
        XCTAssertEqual(device.calls, ["inspect:" + id])
    }
    func testDisconnectedDeviceCannotStartMutation() throws {
        let value = try plan(); device.failInspect = true; device.calls = []
        XCTAssertThrowsError(try execute(value.planSHA256))
        XCTAssertEqual(device.calls, ["inspect:" + id]); XCTAssertEqual(try DDITransaction.status(directory: directory).journal.phase, .preflight)
    }
    func testSymlinkAndFIFOControlLocksAreRejectedWithoutBlocking() throws {
        let control = root.appendingPathComponent("bad-control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let lock = control.appendingPathComponent("input.lock")
        let other = root.appendingPathComponent("other")
        try Data("fixture".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: other)
        XCTAssertThrowsError(try DDIProcessLease.testLease(exclusive: true, directory: control))
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(mkfifo(lock.path, 0o600), 0)
        XCTAssertThrowsError(try DDIProcessLease.testLease(exclusive: true, directory: control))
    }
    func testSharedInputLeaseAndPersistentPendingBarrierBlockManagementAndRestart() throws {
        let control = root.appendingPathComponent("control")
        var input: DDIProcessLease? = try DDIProcessLease.testLease(exclusive: false, directory: control)
        XCTAssertThrowsError(try DDIProcessLease.testLease(exclusive: true, directory: control))
        input = nil
        var management: DDIProcessLease? = try DDIProcessLease.testLease(exclusive: true, directory: control)
        XCTAssertThrowsError(try DDIProcessLease.testLease(exclusive: false, directory: control))
        let pending = DDIProcessLease.Pending(transactionPath: directory.path, planSHA256: String(repeating: "a", count: 64))
        try management?.markPending(pending); management = nil
        XCTAssertThrowsError(try DDIProcessLease.testLease(exclusive: false, directory: control))
        management = try DDIProcessLease.testLease(exclusive: true, directory: control)
        XCTAssertThrowsError(try management?.clearPending(.init(transactionPath: "OTHER", planSHA256: pending.planSHA256)))
        try management?.clearPending(pending); management = nil
        input = try DDIProcessLease.testLease(exclusive: false, directory: control)
        withExtendedLifetime(input) {}
    }
    func testCLIRequiresExactFlagsAndOnlyLocalTransactionPaths() throws {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(try DDIManagementCLI.parse(["apply", "/transaction", "--confirm", hash, "--acknowledge-source-risk"]),
                       .execute(directory: "/transaction", confirmation: hash, restore: false))
        for args in [["apply", "/transaction", "--confirm", hash], ["restore", "https://example.invalid/tx", "--confirm", hash, "--acknowledge-source-risk"],
                     ["apply", "/transaction", "--confirm", "main", "--acknowledge-source-risk"]] {
            XCTAssertThrowsError(try DDIManagementCLI.parse(args))
        }
    }
}
