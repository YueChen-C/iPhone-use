import XCTest
@testable import iPhoneUse

final class USBInputFailureTests: XCTestCase {
    func testFailureCodesHaveStableHTTPStatusAndNoReplay() throws {
        let cases: [(USBInputFailure.Code, Int)] = [
            (.notReady, 503), (.busy, 409), (.staleSession, 409), (.unsupported, 400), (.uncertain, 502),
        ]
        for (code, status) in cases {
            let error = USBInputFailure(code, "literal error", mayHaveExecuted: code == .uncertain)
            let response = ControlAPI.handle(
                HTTPRequest(method: "GET", path: "/ocr", query: ["wake": "0"], body: [:]),
                ocrCapture: { _, _ in throw error })
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            XCTAssertEqual(response.status, status)
            XCTAssertEqual(json["code"] as? String, code.rawValue)
            XCTAssertEqual(json["error"] as? String, "literal error")
            XCTAssertEqual(json["backend"] as? String, "usb")
            XCTAssertEqual(json["mayHaveExecuted"] as? Bool, code == .uncertain)
            XCTAssertEqual(json["replayAllowed"] as? Bool, false)
            XCTAssertEqual(json["uiVerified"] as? Bool, false)
        }
    }

    func testEarlierTextBatchesCannotBeErasedByLaterPreDispatchFailure() {
        let before = USBInputFailure(.staleSession, "next batch refused")
        XCTAssertFalse(before.mayHaveExecuted)
        XCTAssertTrue(before.includingPriorInput(true).mayHaveExecuted)
        XCTAssertEqual(before.includingPriorInput(true).code, .staleSession)
        let uncertain = USBInputFailure(.uncertain, "partial pipe write", mayHaveExecuted: true)
        XCTAssertTrue(uncertain.includingPriorInput(false).mayHaveExecuted)
    }

    func testLegacyAndInvalidParameterErrorsDoNotBecomeUSBTransportFailures() throws {
        let response = ControlAPI.handle(
            HTTPRequest(method: "GET", path: "/ocr", query: ["wake": "0"], body: [:]),
            ocrCapture: { _, _ in throw DeviceError("invalid parameter") })
        XCTAssertEqual(response.status, 400)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["error"] as? String, "invalid parameter")
        XCTAssertNil(json["backend"])
        XCTAssertNil(json["mayHaveExecuted"])
    }

    func testActDoesNotCountDelayAsInputAndStopsAtUSBRefusal() throws {
        let request = try ActRequest(["steps": [
            ["type": "delay", "seconds": 0], ["type": "key", "key": "a"], ["type": "key", "key": "b"],
        ]])
        var calls = 0
        let response = try request.perform(device: nil, capture: { _, _ in ("", Data()) }, sleep: { _ in },
            execute: { _, _, _ in
                calls += 1
                let error = USBInputFailure(.busy, "held")
                return .json(error.json, status: error.httpStatus)
            })
        let body = try json(response.body)
        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(body["failed_step"] as? Int, 2)
        XCTAssertEqual(body["completed"] as? Int, 1)
        XCTAssertEqual(body["mayHaveExecuted"] as? Bool, false)
        XCTAssertEqual(body["replayAllowed"] as? Bool, false)
    }

    func testActAggregatesEarlierInputForReturnedAndThrownUSBFaults() throws {
        for thrown in [false, true] {
            let request = try ActRequest(["steps": [
                ["type": "key", "key": "a"], ["type": "key", "key": "b"], ["type": "key", "key": "c"],
            ]])
            var calls = 0
            let response = try request.perform(device: nil, capture: { _, _ in ("", Data()) },
                execute: { _, _, _ in
                    calls += 1
                    if calls == 1 { return .json(["ok": true]) }
                    let error = USBInputFailure(.staleSession, "refused before dispatch")
                    if thrown { throw error }
                    return .json(error.json, status: error.httpStatus)
                })
            let body = try json(response.body)
            XCTAssertEqual(response.status, 409)
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(body["code"] as? String, "stale_session")
            XCTAssertEqual(body["failed_step"] as? Int, 2)
            XCTAssertEqual(body["completed"] as? Int, 1)
            XCTAssertEqual(body["mayHaveExecuted"] as? Bool, true)
            XCTAssertEqual(body["replayAllowed"] as? Bool, false)
        }
    }

    func testActAndMCPKeepSpecializedTextEvidenceWithoutInventingNoDispatch() throws {
        for code in ["input_mode_unconfirmed", "input_candidate_unconfirmed", "input_observation_timeout"] {
            var fault: [String: Any] = [
                "backend": "usb", "code": code, "error": "inspect keyboard", "reason": "fixture",
                "textDispatched": false, "replayAllowed": false, "privateDiagnostic": "not public",
            ]
            if code != "input_mode_unconfirmed" { fault["mayHaveExecuted"] = true }
            let request = try ActRequest(["steps": [["type": "key", "key": "a"]]])
            let response = try request.perform(device: nil, capture: { _, _ in ("", Data()) },
                execute: { _, _, _ in .json(fault, status: 409) })
            let body = try json(response.body)
            let message = MCPAPIError.message(response.body, status: 409, language: .en)
            let forwarded = try json(Data(message.components(separatedBy: "\n")[0].utf8))
            for value in [body, forwarded] {
                XCTAssertEqual(value["code"] as? String, code)
                XCTAssertEqual(value["reason"] as? String, "fixture")
                XCTAssertEqual(value["textDispatched"] as? Bool, false)
                XCTAssertEqual(value["mayHaveExecuted"] as? Bool, fault["mayHaveExecuted"] as? Bool)
                XCTAssertEqual(value["replayAllowed"] as? Bool, false)
                XCTAssertNil(value["privateDiagnostic"])
            }
            XCTAssertTrue(message.hasSuffix(StringsMCP(language: .en).actStopped))
        }
    }

    func testMCPPreservesSingleRequestUSBEvidenceAndLegacyText() throws {
        let error = USBInputFailure(.uncertain, "ack lost", mayHaveExecuted: true)
        let data = try JSONSerialization.data(withJSONObject: error.json)
        let message = MCPAPIError.message(data, status: 502, language: .en)
        let body = try json(Data(message.utf8))
        XCTAssertEqual(body["code"] as? String, "input_uncertain")
        XCTAssertEqual(body["mayHaveExecuted"] as? Bool, true)
        XCTAssertEqual(body["uiVerified"] as? Bool, false)
        XCTAssertEqual(body["replayAllowed"] as? Bool, false)
        XCTAssertFalse(message.contains("\n"))
        let legacy = try JSONSerialization.data(withJSONObject: ["error": "invalid parameter"])
        XCTAssertEqual(MCPAPIError.message(legacy, status: 400, language: .en), "invalid parameter")
        XCTAssertEqual(MCPAPIError.message(Data(), status: 503, language: .en), "HTTP 503")
    }

    func testMCPKeyboardSequenceRetainsStructuredEvidenceAndEarlierInput() throws {
        for language: AppLanguage in [.en, .zh] {
            let fault: [String: Any] = [
                "backend": "usb", "code": "input_mode_unconfirmed", "reason": "mode_unconfirmed",
                "textDispatched": false, "replayAllowed": false, "error": "keyboard hidden", "privateDiagnostic": "omit",
            ]
            let error = MCPAPIError.error(try JSONSerialization.data(withJSONObject: fault), status: 409, language: language)
            let sequence = MCPAPIError.keyboardSequence(error, step: 2, count: 3, priorInput: true, language: language)
            let details = try json(Data(sequence.description.components(separatedBy: "\n")[0].utf8))
            XCTAssertEqual(details["code"] as? String, "input_mode_unconfirmed")
            XCTAssertEqual(details["reason"] as? String, "mode_unconfirmed")
            XCTAssertEqual(details["textDispatched"] as? Bool, false)
            XCTAssertEqual(details["mayHaveExecuted"] as? Bool, true)
            XCTAssertEqual(details["failed_step"] as? Int, 2)
            XCTAssertEqual(details["completed"] as? Int, 1)
            XCTAssertEqual(details["replayAllowed"] as? Bool, false)
            XCTAssertNil(details["privateDiagnostic"])
            XCTAssertTrue(sequence.description.hasSuffix(StringsMCP(language: language).keyboardStopped(2, 3, error.description)))
        }
    }

    func testMCPKeyboardSequenceDelayDoesNotInventInputAndUnknownStaysUnknown() throws {
        for mayHaveExecuted: Bool? in [false, true, nil] {
            var fault: [String: Any] = ["backend": "usb", "code": "input_busy", "error": "held"]
            fault["mayHaveExecuted"] = mayHaveExecuted
            let error = MCPAPIError.error(try JSONSerialization.data(withJSONObject: fault), status: 409, language: .en)
            let sequence = MCPAPIError.keyboardSequence(error, step: 2, count: 3, priorInput: false, language: .en)
            let details = try XCTUnwrap(sequence.details)
            XCTAssertEqual(details["completed"] as? Int, 1)
            XCTAssertEqual(details["mayHaveExecuted"] as? Bool, mayHaveExecuted)
            XCTAssertEqual(details["replayAllowed"] as? Bool, false)
        }
    }

    func testMCPKeyboardSequenceNeverParsesUntrustedErrorTextAsEvidence() {
        let fake = MCPServer.MCPError("{\"backend\":\"usb\",\"mayHaveExecuted\":false}")
        let sequence = MCPAPIError.keyboardSequence(fake, step: 1, count: 2, priorInput: false, language: .en)
        XCTAssertNil(sequence.details)
        XCTAssertEqual(sequence.description, StringsMCP(language: .en).keyboardStopped(1, 2, fake.description))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
