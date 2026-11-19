import XCTest
@testable import iPhoneUse

final class USBWorkerLifetimeTests: XCTestCase {
    func testPreSessionFailureRequiresExplicitProofAndExit() {
        var state = USBTouchWorkerLifetime()
        state.exited = true
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = false
        state.unprepared = true
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = true
        XCTAssertTrue(state.retirementConfirmed)
    }

    func testReadOnlyPreparedWorkerCanRetireAfterExitButNotWhileRunning() {
        var state = USBTouchWorkerLifetime(becameReady: true)
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = true
        XCTAssertTrue(state.retirementConfirmed)
    }

    func testAnyDispatchedCommandInvalidatesNoContactProof() {
        var state = USBTouchWorkerLifetime(unprepared: true, exited: true)
        state.commandDispatched = true
        XCTAssertFalse(state.retirementConfirmed)
        state.becameReady = true
        XCTAssertFalse(state.retirementConfirmed)
    }

    func testPreparedSessionStillNeedsReleaseAndExit() {
        var state = USBTouchWorkerLifetime(becameReady: true, commandDispatched: true)
        state.exited = true
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = false
        state.released = true
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = true
        XCTAssertTrue(state.retirementConfirmed)
    }

    func testLatestReleaseAcknowledgementAndExitPermitRetirementAfterTransportLoss() {
        var state = USBTouchWorkerLifetime(becameReady: true)
        let first = UUID(), second = UUID()
        state.dispatch(first)
        state.acknowledge(first, inputReleased: true)
        XCTAssertFalse(state.retirementConfirmed)
        state.exited = true
        XCTAssertTrue(state.retirementConfirmed)
        state.dispatch(second)
        XCTAssertFalse(state.retirementConfirmed)
        state.acknowledge(first, inputReleased: true)
        XCTAssertFalse(state.retirementConfirmed, "a stale release cannot clear a later dispatch")
        state.acknowledge(second, inputReleased: false)
        XCTAssertFalse(state.retirementConfirmed, "down/move acknowledges delivery, not release")
    }

    func testWrongOrMissingReleaseAcknowledgementKeepsUncertainInputGated() {
        var state = USBTouchWorkerLifetime(becameReady: true, exited: true)
        let id = UUID()
        state.dispatch(id)
        state.acknowledge(UUID(), inputReleased: true)
        XCTAssertFalse(state.retirementConfirmed)
        state.acknowledge(id, inputReleased: false)
        state.acknowledge(id, inputReleased: true)
        XCTAssertFalse(state.retirementConfirmed, "duplicate replies cannot upgrade the original proof")
    }

    func testLostReleaseOnlyCancelPreservesIdleButNeverClearsUncertainInput() {
        var idle = USBTouchWorkerLifetime(becameReady: true, exited: true)
        idle.dispatch(UUID(), mayHoldInput: false)
        XCTAssertTrue(idle.retirementConfirmed)
        var held = USBTouchWorkerLifetime(becameReady: true, exited: true)
        held.dispatch(UUID())
        held.dispatch(UUID(), mayHoldInput: false)
        XCTAssertFalse(held.retirementConfirmed)
    }

    func testClientRejectsMissingOrForeignDeviceReleaseProof() throws {
        for proof in ["'physicalID':'other','inputReleased':True", "'physicalID':'target'"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("worker-fixture")
            let script = """
            #!/usr/bin/python3
            import json, sys
            print(json.dumps({'event':'ready','physicalID':'target','width':1170,'height':2532,'session':'\(UUID().uuidString)'}), flush=True)
            for line in sys.stdin:
                c=json.loads(line)
                print(json.dumps({'event':'ack','id':c['id'],\(proof)}), flush=True)
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let client = try USBTouchClient(physicalID: "target", executableURL: executable)
            try client.waitUntilReady()
            // Use a potentially holding command, not the no-contact cancel.
            try client.send("down", points: [.init(x: 0.5, y: 0.5)])
            XCTAssertFalse(client.closeAndWait())
        }
    }

    func testWorkerOnlyMarksSuccessfullyCompletedTerminalOperationsReleased() {
        for operation in ["tap", "swipe", "up", "cancel", "keyboard"] + USBHardwareButton.allCases.map(\.rawValue) {
            let command = USBTouchWorkerCommand(id: UUID(), operation: operation, points: [], duration: 0)
            let ack = USBTouchWorker.acknowledgement(command, physicalID: "target")
            XCTAssertEqual(ack["physicalID"] as? String, "target")
            XCTAssertEqual(ack["id"] as? String, command.id.uuidString)
            XCTAssertEqual(ack["inputReleased"] as? Bool, true)
            XCTAssertEqual(ack["uiVerified"] as? Bool, false)
        }
        for operation in ["down", "move", "future_operation"] {
            let command = USBTouchWorkerCommand(id: UUID(), operation: operation, points: [], duration: 0)
            XCTAssertEqual(USBTouchWorker.acknowledgement(command, physicalID: "target")["inputReleased"] as? Bool, false)
        }
    }

    func testRealClientReadOnlyAndReleasedWorkersRetireWithoutFinalShutdownReply() throws {
        for operation in [nil, "tap", "cancel"] as [String?] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("worker-fixture")
            let script = """
            #!/usr/bin/python3
            import json, sys
            print(json.dumps({'event':'ready','physicalID':'target','width':1170,'height':2532,'session':'\(UUID().uuidString)'}), flush=True)
            for line in sys.stdin:
                c=json.loads(line)
                print(json.dumps({'event':'ack','id':c['id'],'physicalID':'target','inputReleased':True}), flush=True)
            # Simulate lost shutdown reply: no released/unprepared event.
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let client = try USBTouchClient(physicalID: "target", executableURL: executable)
            try client.waitUntilReady()
            if let operation {
                try client.send(operation, points: operation == "tap" ? [.init(x: 0.5, y: 0.5)] : [])
            }
            XCTAssertTrue(client.closeAndWait())
        }
    }
}
