import XCTest
@testable import iPhoneUse

final class USBHardwareButtonTests: XCTestCase {
    func testPinnedIndigoEnvelopeAndMappingsNotKeyboardHome() throws {
        XCTAssertEqual(USBHardwareButton.service, "com.apple.coredevice.hid.indigo")
        for (button, usage) in [(USBHardwareButton.home, UInt64(0x40)), (.power, 0x30), (.volumeUp, 0xE9), (.volumeDown, 0xEA)] {
            XCTAssertEqual(button.usage, usage)
            for state: UInt64 in [1, 2, 3] {
                let request = button.request(state: state)
                guard case .text(let type)? = request["messageType"],
                      case .text(let feature)? = request["featureIdentifier"],
                      case .dictionary(let payload)? = request["payload"] else { return XCTFail("Indigo envelope") }
                XCTAssertEqual(type, "IndigoButtonEvent")
                XCTAssertEqual(feature, "com.apple.coredevice.feature.remote.hid.button")
                XCTAssertEqual(USBXPCValue.dictionary(payload).encode(), USBXPCValue.dictionary([
                    "state": .uint(state), "usagePage": .uint(0x0C), "usageCode": .uint(usage)]).encode())
            }
        }
        XCTAssertEqual(try USBKeyboardRequest.key("home", modifiers: []).code, 0x4A)
    }

    func testButtonValidationRejectsMixedPayloadAndLongHoldsBeforeDispatch() throws {
        for button in USBHardwareButton.allCases {
            try USBTouchRequest.validate(button.rawValue, points: [], duration: 0)
            XCTAssertThrowsError(try USBTouchRequest.validate(button.rawValue, points: [.init(x: 0.5, y: 0.5)], duration: 0))
            XCTAssertThrowsError(try USBTouchRequest.validate(button.rawValue, points: [], duration: 1))
            XCTAssertThrowsError(try USBTouchRequest.validate(button.rawValue, points: [], duration: 0, strokes: []))
        }
        XCTAssertThrowsError(try USBTouchRequest.validate("snapshot", points: [], duration: 0))
        let command = USBTouchWorkerCommand(id: UUID(), operation: "home", points: [], duration: 0)
        XCTAssertEqual(try JSONDecoder().decode(USBTouchWorkerCommand.self, from: JSONEncoder().encode(command)).operation, "home")
    }

    func testPressReleasePingAndSettleBeforeNextButtonOrClose() throws {
        var events: [String] = [], time = 0.0
        let buttons = USBHardwareButtonState(send: { events.append("\($0.rawValue):\($1)") },
            ping: { events.append("ping") }, now: { time }, sleep: { time += $0; events.append("wait") })
        try buttons.press(.home, interrupted: { false })
        XCTAssertEqual(events, ["home:1", "wait", "home:2", "ping", "wait"])
        XCTAssertEqual(time, 0.88, accuracy: 0.0001)
        try buttons.sync(); XCTAssertEqual(events.count, 5) // No unnecessary idle PING.
        try buttons.press(.volumeUp, interrupted: { false })
        XCTAssertEqual(time, 1.76, accuracy: 0.0001)
        XCTAssertTrue(buttons.releaseConfirmed)
    }

    func testTransportTimeCountsTowardSettleButNeverRemovesShortPress() throws {
        var time = 0.0, waits: [Double] = []
        let buttons = USBHardwareButtonState(send: { _, _ in }, ping: { time += 0.9 }, now: { time },
            sleep: { waits.append($0); time += $0 })
        try buttons.press(.home, interrupted: { false })
        XCTAssertEqual(waits, [0.08, 0])
    }

    func testCancelAfterDownUsesSameButtonAndSettlesWithoutUpOrReplay() throws {
        var stopped = false, events: [UInt64] = [], pings = 0, time = 0.0
        let buttons = USBHardwareButtonState(send: { _, state in events.append(state) }, ping: { pings += 1 },
            now: { time }, sleep: { time += $0; stopped = true })
        XCTAssertThrowsError(try buttons.press(.power, interrupted: { stopped }))
        XCTAssertEqual(events, [1, 3]); XCTAssertTrue(buttons.releaseConfirmed)
        try buttons.sync(); XCTAssertEqual(pings, 1); XCTAssertEqual(time, 0.88, accuracy: 0.0001)
        buttons.cancel(); XCTAssertEqual(events, [1, 3])
    }

    func testInterruptionBeforeDownHasNoSideEffects() {
        var sends = 0
        let buttons = USBHardwareButtonState(send: { _, _ in sends += 1 }, ping: {}, now: { 0 }, sleep: { _ in })
        XCTAssertThrowsError(try buttons.press(.home, interrupted: { true }))
        XCTAssertEqual(sends, 0); XCTAssertTrue(buttons.releaseConfirmed)
    }

    func testPartialDownAndFailedUpBothCancelWithoutReplayingPress() throws {
        for failingState: UInt64 in [1, 2] {
            var events: [UInt64] = [], time = 0.0
            let buttons = USBHardwareButtonState(send: { _, state in
                events.append(state)
                if state == failingState { throw AXDTX.Failure("partial write") }
            }, ping: {}, now: { time }, sleep: { time += $0 })
            XCTAssertThrowsError(try buttons.press(.home, interrupted: { false }))
            XCTAssertEqual(events, failingState == 1 ? [1, 3] : [1, 2, 3])
            XCTAssertTrue(buttons.releaseConfirmed); try buttons.sync()
        }
    }

    func testFailedCancellationCannotBeClearedByPingOrNewButton() throws {
        var sends: [UInt64] = [], pings = 0
        let buttons = USBHardwareButtonState(send: { _, state in sends.append(state); throw AXDTX.Failure("write failed") },
            ping: { pings += 1 }, now: { 0 }, sleep: { _ in })
        XCTAssertThrowsError(try buttons.press(.home, interrupted: { false }))
        buttons.cancel()
        XCTAssertThrowsError(try buttons.sync())
        XCTAssertThrowsError(try buttons.press(.volumeDown, interrupted: { false }))
        XCTAssertFalse(buttons.releaseConfirmed); XCTAssertEqual(sends, [1, 3]); XCTAssertEqual(pings, 0)
    }

    func testPingFailureCannotAcknowledgeReleaseButFinishCanRetryOnlyPing() throws {
        var failing = true, sends: [UInt64] = [], time = 0.0
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 7,
            readDisplay: { (1170, 2532) }, ping: {}, send: { _, _ in XCTFail("touch sent") }, now: { time },
            sleep: { time += $0 }, sendButton: { _, state in sends.append(state) },
            pingButtons: { if failing { throw AXDTX.Failure("PING failed") } })
        XCTAssertThrowsError(try session.execute("home", points: [], duration: 0))
        XCTAssertThrowsError(try session.finish())
        failing = false; try session.finish()
        XCTAssertEqual(sends, [1, 2]); XCTAssertEqual(time, 0.88, accuracy: 0.0001)
    }

    func testMissingServiceRefusesBeforeInputAndKeepsTouchUsable() throws {
        var checks = 0, sends = 0
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 7,
            readDisplay: { checks += 1; return (1170, 2532) }, ping: {}, send: { _, _ in sends += 1 })
        XCTAssertFalse(session.supportsButtons)
        XCTAssertThrowsError(try session.execute("home", points: [], duration: 0))
        XCTAssertEqual(checks, 0); XCTAssertEqual(sends, 0)
        try session.execute("down", points: [.init(x: 0.5, y: 0.5)], duration: 0)
        try session.finish(); XCTAssertEqual(sends, 2)
    }

    func testHeldPointerBlocksButtonsWithoutCancellingContact() throws {
        var sends = 0, states: [Bool] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 7,
            readDisplay: { (1170, 2532) }, ping: {}, send: { _, down in states.append(down) },
            sendButton: { _, _ in sends += 1 }, pingButtons: {})
        try session.execute("down", points: [.init(x: 0.5, y: 0.5)], duration: 0)
        XCTAssertThrowsError(try session.execute("home", points: [], duration: 0))
        XCTAssertEqual(sends, 0); XCTAssertEqual(states, [true]); try session.finish()
    }

    func testPowerScreenOffDoesNotInvalidateReleaseButTouchStillRequiresDisplay() throws {
        var off = false, time = 0.0, sends: [UInt64] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 7,
            readDisplay: { if off { throw AXDTX.Failure("screen off") }; return (1170, 2532) }, ping: {},
            send: { _, _ in XCTFail("unsafe touch") }, now: { time }, sleep: { time += $0 },
            sendButton: { _, state in sends.append(state); off = true }, pingButtons: {})
        try session.execute("power", points: [], duration: 0)
        time += 1; try session.tick(); try session.finish()
        XCTAssertThrowsError(try session.execute("down", points: [.init(x: 0.5, y: 0.5)], duration: 0))
        XCTAssertEqual(sends, [1, 2])
    }

    func testPublicToolsAndActMapHardwareButtonsToDedicatedRoutes() throws {
        for button in USBHardwareButton.allCases {
            for language: AppLanguage in [.en, .zh] {
                let tool = try XCTUnwrap(MCPToolCatalog.tools(for: language).first { $0["name"] as? String == button.rawValue })
                XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
            }
            let request = try XCTUnwrap(MCPToolRequest.action(named: button.rawValue, arguments: ["device_id": "phone"], longEdge: 1000))
            XCTAssertEqual(request.path, "/" + button.rawValue); XCTAssertEqual(request.body["device"] as? String, "phone")
            let batch = try ActRequest(["steps": [["type": button.rawValue]]])
            XCTAssertEqual(batch.steps.first?["type"] as? String, button.rawValue)
            var paths: [String] = []
            let response = try batch.perform(device: "phone", capture: { _, _ in XCTFail("unexpected capture"); return ("", Data()) },
                execute: { path, _, device in
                    paths.append(path); XCTAssertEqual(device, "phone"); return .json(["ok": true])
                })
            XCTAssertEqual(response.status, 200); XCTAssertEqual(paths, ["/" + button.rawValue])
        }
        let key = try XCTUnwrap(MCPToolRequest.action(named: "press_key", arguments: ["key": "home"], longEdge: 1000))
        XCTAssertEqual(key.path, "/key")
    }
}
