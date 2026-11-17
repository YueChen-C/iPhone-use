import XCTest
@testable import iPhoneUse

final class USBPreparationFailureTests: XCTestCase {
    func testEveryReasonRoundTripsThroughNativeJSONWithoutChangingEvidence() throws {
        for reason in USBPreparationFailure.Reason.allCases {
            let expected = USBPreparationFailure(reason, "本机准备失败 · \(reason.rawValue)")
            let bytes = try JSONSerialization.data(withJSONObject: expected.workerEvent)
            let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(USBPreparationFailure(workerEvent: event), expected)
            XCTAssertEqual(event["replayAllowed"] as? Bool, false)
            XCTAssertNil(event["inputSent"]) // A failure reason is not retirement proof.
            XCTAssertNil(event["mayHaveExecuted"]) // Nor request delivery evidence.
            XCTAssertNotEqual(expected.readiness, .ready)
        }
    }

    func testOnlyKnownHostAndIdentityEvidenceSelectSpecificReadiness() {
        for reason in [USBPreparationFailure.Reason.hostUnavailable, .hostUnsupported] {
            XCTAssertEqual(reason.readiness, .unsupportedHost)
        }
        for reason in [USBPreparationFailure.Reason.identityUnavailable, .identityMismatch] {
            XCTAssertEqual(reason.readiness, .identityUnverified)
        }
        XCTAssertEqual(USBPreparationFailure.Reason.workerDisconnected.readiness, .disconnected)
        for reason in [USBPreparationFailure.Reason.serviceUnavailable, .displayUnavailable, .touchscreenUnavailable,
                       .timedOut, .workerProtocol, .unknown] {
            XCTAssertEqual(reason.readiness, .failed)
        }
    }

    func testGenericErrorsNeverInferDDITrustDeveloperModeOrCompatibilityFromText() {
        for message in ["requiresDDI", "requiresTrust", "Developer Mode disabled", "unsupportedDevice",
                        "USB service unavailable; check DDI capability", "host_unsupported"] {
            let failure = USBPreparationFailure(AXDTX.Failure(message))
            XCTAssertEqual(failure.reason, .unknown)
            XCTAssertEqual(failure.readiness, .failed)
            XCTAssertEqual(failure.description, message)
        }
    }

    func testLegacyWorkerTextAndUnrecognizedOrContradictoryMetadataRemainUnknown() {
        let cases: [[String: Any]] = [
            ["event": "failed", "error": "requiresDDI"],
            ["event": "failed", "error": "old", "state": "ready", "reason": "identity_mismatch"],
            ["event": "failed", "state": "requiresDDI", "reason": "service_unavailable"],
            ["event": "failed", "state": "ready", "reason": "future_reason"],
            ["event": "ack", "state": "unsupportedHost", "reason": "host_unsupported"],
            ["event": "failed", "state": "failed", "reason": true],
        ]
        for event in cases {
            let failure = USBPreparationFailure(workerEvent: event)
            XCTAssertEqual(failure.reason, .unknown)
            XCTAssertEqual(failure.readiness, .failed)
        }
    }

    func testWrappingTypedFailurePreservesItsExactReason() {
        let failure = USBPreparationFailure(.identityMismatch, "capture changed")
        XCTAssertEqual(USBPreparationFailure(failure), failure)
    }

    func testSurfaceAndDisplayFailuresAreTypedButDoNotDiagnoseDDI() {
        for operation in [
            { _ = try USBTouchSession.touchscreen([:]) },
            { _ = try USBTouchSession.touchscreen(["connectedServices": []]) },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual((error as? USBPreparationFailure)?.reason, .touchscreenUnavailable)
                XCTAssertEqual((error as? USBPreparationFailure)?.readiness, .failed)
            }
        }
        XCTAssertThrowsError(try USBTouchSession.displayDimensions([:])) { error in
            XCTAssertEqual((error as? USBPreparationFailure)?.reason, .displayUnavailable)
            XCTAssertEqual((error as? USBPreparationFailure)?.readiness, .failed)
        }
    }

    func testClientRetainsWorkerReasonAndStillRequiresIndependentRetirementProof() throws {
        for proof in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("worker-fixture")
            let failure = USBPreparationFailure(.identityUnavailable, "fixture identity absent")
            let failedJSON = String(data: try JSONSerialization.data(withJSONObject: failure.workerEvent), encoding: .utf8)!
            let proofLine = proof ? "printf '%s\\n' '{\"event\":\"unprepared\",\"physicalID\":\"fixture\",\"inputSent\":false}'\n" : ""
            // Keep the process alive until parent EOF so the fixture checks the
            // protocol failure, independently of exit/pipe scheduling.
            let script = "#!/bin/sh\nset -eu\n\(proofLine)printf '%s\\n' '\(failedJSON)'\ncat >/dev/null\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let client = try USBTouchClient(physicalID: "fixture", executableURL: executable)
            XCTAssertThrowsError(try client.waitUntilReady()) { error in
                XCTAssertEqual(error as? USBPreparationFailure, failure)
            }
            XCTAssertEqual(client.error, failure)
            XCTAssertNil(client.sessionID)
            XCTAssertNil(client.dimensions)
            XCTAssertFalse(client.supportsKeyboard)
            XCTAssertEqual(client.closeAndWait(), proof)
        }
    }

    func testImmediateWorkerExitDoesNotDiscardItsBufferedTypedFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("worker-fixture")
        let failure = USBPreparationFailure(.hostUnsupported, "fixture host dialect")
        let failedJSON = String(data: try JSONSerialization.data(withJSONObject: failure.workerEvent), encoding: .utf8)!
        try "#!/bin/sh\nprintf '%s\\n' '\(failedJSON)'\nexit 70\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for _ in 0..<8 {
            let client = try USBTouchClient(physicalID: "fixture", executableURL: executable)
            XCTAssertThrowsError(try client.waitUntilReady()) { error in
                XCTAssertEqual(error as? USBPreparationFailure, failure)
            }
        }
    }
}
