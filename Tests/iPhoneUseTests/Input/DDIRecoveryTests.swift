import Darwin
import XCTest
@testable import iPhoneUse

final class DDIRecoveryTests: XCTestCase {
    private var root: URL!
    private var control: URL { root.appendingPathComponent("control") }
    private var pending: DDIProcessLease.Pending {
        .init(transactionPath: "/TRANSACTION ' $(PAYLOAD)\nDATA", planSHA256: String(repeating: "a", count: 64))
    }

    override func setUpWithError() throws {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("ddi-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func writeRecord(_ value: DDIProcessLease.Pending? = nil) throws -> Data {
        let lease = try DDIProcessLease.testLease(exclusive: true, directory: control)
        try lease.markPending(value ?? pending)
        return try Data(contentsOf: control.appendingPathComponent("pending.json"))
    }

    func testAbsentControlDirectoryDoesNotGetCreatedByDiscovery() throws {
        XCTAssertNil(try DDIProcessLease.pendingRecovery(directory: control))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
        XCTAssertEqual(try DDIManagementCLI.parse(["recovery"]), .recovery)
        XCTAssertThrowsError(try DDIManagementCLI.parse(["recovery", "/OTHER_CONTROL"]))
    }

    func testExistingEmptyControlIsUnchanged() throws {
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        XCTAssertNil(try DDIProcessLease.pendingRecovery(directory: control))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: control.path), [])
    }

    func testDiscoveryWorksWithExclusiveOwnerAndNeverClearsPending() throws {
        let lease = try DDIProcessLease.testLease(exclusive: true, directory: control)
        try lease.markPending(pending)
        let before = try Data(contentsOf: control.appendingPathComponent("pending.json"))
        XCTAssertEqual(try DDIProcessLease.pendingRecovery(directory: control), pending)
        XCTAssertEqual(try Data(contentsOf: control.appendingPathComponent("pending.json")), before)
        XCTAssertThrowsError(try DDIProcessLease.testLease(exclusive: false, directory: control))
        withExtendedLifetime(lease) {}
    }

    func testReportUsesLiteralArgumentsWithoutGrantingRestoreOrClaimingTransactionValidation() throws {
        _ = try writeRecord()
        let report = DDIRecoveryReport(pending: try DDIProcessLease.pendingRecovery(directory: control))
        XCTAssertTrue(report.recoveryPending)
        XCTAssertFalse(report.deviceMutation); XCTAssertFalse(report.inputSent); XCTAssertFalse(report.automaticReplay)
        XCTAssertFalse(report.transactionValidated); XCTAssertFalse(report.restoreAuthorized)
        XCTAssertEqual(report.statusArguments, ["ddi", "status", pending.transactionPath])
        XCTAssertEqual(report.restoreArguments, ["ddi", "restore", pending.transactionPath,
                                                "--confirm", pending.planSHA256, "--acknowledge-source-risk"])
        XCTAssertEqual(try DDIManagementCLI.parse(Array(try XCTUnwrap(report.restoreArguments).dropFirst())),
                       .execute(directory: pending.transactionPath, confirmation: pending.planSHA256, restore: true))
        let empty = DDIRecoveryReport(pending: nil)
        XCTAssertFalse(empty.recoveryPending); XCTAssertNil(empty.statusArguments); XCTAssertNil(empty.restoreArguments)
    }

    func testMalformedPendingPathsHashesAndJSONAreErrorsNotNoRecovery() throws {
        let bytes = try writeRecord()
        let file = control.appendingPathComponent("pending.json")
        for invalid in [DDIProcessLease.Pending(transactionPath: "relative", planSHA256: pending.planSHA256),
                        .init(transactionPath: "/TRANSACTION", planSHA256: "main"),
                        .init(transactionPath: "/TRANSACTION", planSHA256: String(repeating: "A", count: 64))] {
            try JSONEncoder().encode(invalid).write(to: file)
            XCTAssertThrowsError(try DDIProcessLease.pendingRecovery(directory: control))
        }
        for data in [Data("not JSON".utf8), Data(repeating: 32, count: 16 * 1024 + 1), Data()] {
            try data.write(to: file)
            XCTAssertThrowsError(try DDIProcessLease.pendingRecovery(directory: control))
        }
        try bytes.write(to: file)
        XCTAssertThrowsError(try DDIProcessLease.testLease(exclusive: false, directory: control))
    }

    func testSymlinkFIFOAndHardLinkPendingRecordsAreRejectedWithoutReadingOrBlocking() throws {
        let bytes = try writeRecord(), file = control.appendingPathComponent("pending.json")
        let other = root.appendingPathComponent("other")
        try bytes.write(to: other)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try DDIProcessLease.pendingRecovery(directory: control))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try DDIProcessLease.pendingRecovery(directory: control))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(link(other.path, file.path), 0)
        XCTAssertThrowsError(try DDIProcessLease.pendingRecovery(directory: control))
    }

    func testPublicControlOrRecordAndSymlinkControlAreRejected() throws {
        _ = try writeRecord()
        let file = control.appendingPathComponent("pending.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try DDIProcessLease.pendingRecovery(directory: control))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: control.path)
        XCTAssertThrowsError(try DDIProcessLease.pendingRecovery(directory: control))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: control)
        XCTAssertThrowsError(try DDIProcessLease.pendingRecovery(directory: alias))
    }
}
