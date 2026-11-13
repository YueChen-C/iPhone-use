import Darwin
import XCTest
@testable import iPhoneUse

final class DDIInputAdmissionTests: XCTestCase {
    private let entries: [[String]] = [
        [], ["--desktop"], ["mcp"], ["--usb-touch-worker", "DEVICE"],
        ["--ax-server", "DEVICE", "7392"],
        ["--ax-tree", "DEVICE", "/OUTPUT", "0"],
        ["--capture-identity-screenshot", "DEVICE", "/OUTPUT"], ["unknown-entry"]
    ]

    private func controlDirectory() throws -> URL {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path)).appendingPathComponent("ddi-admission-" + UUID().uuidString)
    }

    func testEveryNonManagementEntryIsDeniedDuringExclusiveManagement() throws {
        let directory = try controlDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let management = try DDIProcessLease.testLease(exclusive: true, directory: directory)
        for arguments in entries {
            XCTAssertThrowsError(try DDIInputAdmission.acquire(arguments: arguments, lease: {
                try DDIProcessLease.testLease(exclusive: false, directory: directory)
            }), "entry must not bypass offline admission: \(arguments)")
        }
        withExtendedLifetime(management) {}
    }

    func testPendingRecoveryBlocksEveryEntryAfterManagementExitAndAllowsExplicitRecovery() throws {
        let directory = try controlDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = DDIProcessLease.Pending(transactionPath: "/TRANSACTION", planSHA256: String(repeating: "a", count: 64))
        do {
            let management = try DDIProcessLease.testLease(exclusive: true, directory: directory)
            try management.markPending(pending)
        }
        for arguments in entries {
            XCTAssertThrowsError(try DDIInputAdmission.acquire(arguments: arguments, lease: {
                try DDIProcessLease.testLease(exclusive: false, directory: directory)
            }))
        }
        do {
            let recovery = try DDIProcessLease.testLease(exclusive: true, directory: directory)
            try recovery.clearPending(pending)
        }
        for arguments in entries {
            let owner = try XCTUnwrap(DDIInputAdmission.acquire(arguments: arguments, lease: {
                try DDIProcessLease.testLease(exclusive: false, directory: directory)
            }))
            XCTAssertThrowsError(try DDIProcessLease.testLease(exclusive: true, directory: directory))
            withExtendedLifetime(owner) {}
        }
        _ = try DDIProcessLease.testLease(exclusive: true, directory: directory)
    }

    func testLocalManagementBypassesOnlySharedInputAdmissionNotItsOwnAuthorization() throws {
        for operation in ["inspect", "preflight", "plan", "status", "apply", "restore"] {
            var requestedInput = false
            XCTAssertNil(try DDIInputAdmission.acquire(arguments: ["ddi", operation], lease: {
                requestedInput = true
                throw DDIManagementError("must not use input lease for local management")
            }))
            XCTAssertFalse(requestedInput)
        }
        // The local CLI still owns parsing, plan-bound consent and exclusive
        // mutation admission; this helper grants none of those permissions.
        XCTAssertThrowsError(try DDIManagementCLI.parse(["apply", "/TRANSACTION"]))
    }
}
