import Foundation
import XCTest

@testable import iPhoneUse

final class MCPProtocolTests: XCTestCase {
    func testScreenshotLongEdgeAndNormalizedSchemaForAllCoordinateTools() throws {
        XCTAssertEqual(MCPServer.longEdge, 1000)
        for language: AppLanguage in [.en, .zh] {
            for tool in MCPToolCatalog.tools(for: language)
            where ["move_pointer", "tap", "long_press", "swipe"].contains(tool["name"] as? String ?? "") {
                let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
                let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
                XCTAssertEqual(properties["normalized"]?["type"] as? String, "boolean")
                XCTAssertFalse((schema["required"] as? [String] ?? []).contains("normalized"))
            }
        }
    }

    func testNormalizedCoordinateToolsConvertEachAxisAndPreserveOptions() throws {
        for name in ["move_pointer", "tap", "long_press", "swipe"] {
            let action = try XCTUnwrap(
                MCPToolRequest.action(
                    named: name,
                    arguments: [
                        "x": 250, "y": 750, "normalized": true, "device": "phone", "seconds": 2.0,
                        "duration": 0.8, "points": [["x": 0, "y": 1000], ["x": 250, "y": 750]],
                    ], longEdge: MCPServer.longEdge))
            XCTAssertEqual(action.body["fraction"] as? Bool, true)
            XCTAssertEqual(action.body["device"] as? String, "phone")
            XCTAssertEqual(action.body["maxEdge"] as? Int, 1000)
            if name == "swipe" {
                XCTAssertEqual(
                    action.body["points"] as? [[String: Double]], [["x": 0, "y": 1], ["x": 0.25, "y": 0.75]])
                XCTAssertEqual(action.body["duration"] as? Double, 0.8)
            } else {
                XCTAssertEqual(action.body["x"] as? Double, 0.25)
                XCTAssertEqual(action.body["y"] as? Double, 0.75)
                if name == "long_press" { XCTAssertEqual(action.body["hold"] as? Double, 2) }
            }
            let pixels = try XCTUnwrap(
                MCPToolRequest.action(
                    named: name,
                    arguments: [
                        "x": 250, "y": 750, "normalized": false, "points": [["x": 0, "y": 0], ["x": 250, "y": 750]],
                    ],
                    longEdge: MCPServer.longEdge))
            XCTAssertNil(pixels.body["fraction"])
            if name != "swipe" { XCTAssertEqual(pixels.body["x"] as? Int, 250) }
        }
    }

    func testNormalizedInputsRejectInvalidFlagsCoordinatesAndPaths() {
        for name in ["move_pointer", "tap", "long_press", "swipe"] {
            var arguments: [String: Any] = ["x": 0, "y": 0, "points": [["x": 0, "y": 0], ["x": 1, "y": 1]]]
            for invalid: Any in [1, 0, "true", NSNull()] {
                arguments["normalized"] = invalid
                XCTAssertThrowsError(try MCPToolRequest.action(named: name, arguments: arguments, longEdge: 1000))
            }
            arguments["normalized"] = true
            for invalid: Any in [true, "500", NSNull(), -1, 1001, Double.nan, Double.infinity] {
                for axis in ["x", "y"] {
                    var malformed = arguments
                    malformed[axis] = invalid
                    var point: [String: Any] = ["x": 0, "y": 0]
                    point[axis] = invalid
                    malformed["points"] = [["x": 0, "y": 0], point]
                    XCTAssertThrowsError(try MCPToolRequest.action(named: name, arguments: malformed, longEdge: 1000))
                }
            }
        }
        for points: Any in [[], [["x": 0, "y": 0]], "bad", [["x": 0, "y": 0], ["x": 1]]] {
            XCTAssertThrowsError(
                try MCPToolRequest.action(
                    named: "swipe", arguments: ["points": points, "normalized": true], longEdge: 1000))
        }
    }

    func testNotificationsAndMalformedMessagesProduceNoReplyOrToolCall() {
        let call: (String, [String: Any]) -> [String: Any] = { _, _ in
            XCTFail("A notification must not execute a tool")
            return [:]
        }
        XCTAssertNil(MCPServer.response(to: ["method": "tools/call"], callTool: call))
        XCTAssertNil(MCPServer.response(to: ["id": 1], callTool: call))
        XCTAssertNil(MCPServer.response(to: ["id": 1, "method": 99], callTool: call))
    }

    func testInitializeEchoesTheRequestedVersionAndSuppliesTheExistingDefault() throws {
        for version in [nil, "2024-11-05"] as [String?] {
            var message: [String: Any] = ["id": 7, "method": "initialize"]
            if let version { message["params"] = ["protocolVersion": version] }
            let reply = try XCTUnwrap(MCPServer.response(to: message) { _, _ in [:] })
            let result = try XCTUnwrap(reply["result"] as? [String: Any])
            XCTAssertEqual(reply["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(reply["id"] as? Int, 7)
            XCTAssertEqual(result["protocolVersion"] as? String, version ?? "2025-06-18")
            XCTAssertEqual(result["serverInfo"] as? [String: String], ["name": "iphone-use", "version": "0.2.0"])
        }
    }

    func testUnknownMethodUsesJSONRPCErrorAndPreservesTheID() throws {
        let reply = try XCTUnwrap(MCPServer.response(to: ["id": "request", "method": "unknown"]) { _, _ in [:] })
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(reply["id"] as? String, "request")
        XCTAssertEqual(error["code"] as? Int, -32601)
        XCTAssertEqual(error["message"] as? String, "method not found: unknown")
        XCTAssertNil(reply["result"])
    }

    func testToolCallsKeepEmptyParameterDefaultsAndReturnTheToolResult() throws {
        var receivedName: String?
        var receivedArguments: [String: Any]?
        let reply = try XCTUnwrap(
            MCPServer.response(to: ["id": 1, "method": "tools/call", "params": ["arguments": []]]) {
                name, arguments in
                receivedName = name
                receivedArguments = arguments
                return ["isError": true]
            })
        XCTAssertEqual(receivedName, "")
        XCTAssertTrue(try XCTUnwrap(receivedArguments).isEmpty)
        XCTAssertEqual(reply["result"] as? [String: Bool], ["isError": true])
    }

    func testTapAndLongPressPreserveScalingDeviceAndDurationDefaults() throws {
        let args: [String: Any] = ["x": 50, "y": 80, "device": "phone"]
        let tap = try XCTUnwrap(MCPToolRequest.action(named: "tap", arguments: args, longEdge: 1000))
        XCTAssertEqual(tap.path, "/tap")
        XCTAssertEqual(tap.body["maxEdge"] as? Int, 1000)
        XCTAssertEqual(tap.body["device"] as? String, "phone")
        XCTAssertEqual(tap.body["x"] as? Int, 50)
        XCTAssertNil(tap.body["hold"])

        let longPress = try XCTUnwrap(MCPToolRequest.action(named: "long_press", arguments: args, longEdge: 1000))
        XCTAssertEqual(longPress.path, "/tap")
        XCTAssertEqual(longPress.body["hold"] as? Double, 1.0)
    }

    func testSwipeSchemaRequiresAnOrderedPointArrayAndPositiveDuration() throws {
        let reply = try XCTUnwrap(
            MCPServer.response(to: ["id": 1, "method": "tools/list"]) { _, _ in
                XCTFail("Listing tools must not execute an action")
                return [:]
            })
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let swipe = try XCTUnwrap(tools.first { $0["name"] as? String == "swipe" })
        let schema = try XCTUnwrap(swipe["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["points"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(
            Set(properties.keys),
            ["points", "duration", "normalized", "device", "device_id", "include_image", "observe"])
        let points = try XCTUnwrap(properties["points"])
        XCTAssertEqual(points["type"] as? String, "array")
        XCTAssertEqual(points["minItems"] as? Int, 2)
        let point = try XCTUnwrap(points["items"] as? [String: Any])
        XCTAssertEqual(point["type"] as? String, "object")
        XCTAssertEqual(point["required"] as? [String], ["x", "y"])
        let coordinates = try XCTUnwrap(point["properties"] as? [String: [String: Any]])
        XCTAssertEqual(coordinates["x"]?["type"] as? String, "number")
        XCTAssertEqual(coordinates["y"]?["type"] as? String, "number")
        XCTAssertEqual(properties["duration"]?["type"] as? String, "number")
        XCTAssertEqual(properties["duration"]?["exclusiveMinimum"] as? Int, 0)
    }

    func testSwipePreservesPointOrderScalingDeviceAndExplicitDuration() throws {
        let points = [["x": 300.5, "y": 900.0], ["x": 100.0, "y": 600.25], ["x": 400.0, "y": 300.0]]
        let args: [String: Any] = ["points": points, "duration": 0.8, "device": "phone"]
        let swipe = try XCTUnwrap(MCPToolRequest.action(named: "swipe", arguments: args, longEdge: 1000))
        XCTAssertEqual(swipe.path, "/swipe")
        XCTAssertEqual(swipe.body["points"] as? [[String: Double]], points)
        XCTAssertEqual(swipe.body["duration"] as? Double, 0.8)
        XCTAssertEqual(swipe.body["maxEdge"] as? Int, 1000)
        XCTAssertEqual(swipe.body["device"] as? String, "phone")
        XCTAssertEqual(Set(swipe.body.keys), ["points", "duration", "maxEdge", "device"])
    }

    func testSwipeDefaultsDurationWithoutAcceptingTheFormerSecondsParameter() throws {
        let points = [["x": 1, "y": 2], ["x": 3, "y": 4]]
        for arguments: [String: Any] in [["points": points], ["points": points, "seconds": 9.0]] {
            let swipe = try XCTUnwrap(MCPToolRequest.action(named: "swipe", arguments: arguments, longEdge: 1000))
            XCTAssertEqual(swipe.body["duration"] as? Double, 0.3)
            XCTAssertNil(swipe.body["seconds"])
            XCTAssertNil(swipe.body["device"])
        }
    }

    func testSwipeRequiresPointsEvenWhenFormerEndpointParametersArePresent() {
        let oldArguments: [String: Any] = ["x1": 1, "y1": 2, "x2": 3, "y2": 4, "seconds": 0.5]
        for arguments in [[:], oldArguments] {
            XCTAssertThrowsError(try MCPToolRequest.action(named: "swipe", arguments: arguments, longEdge: 1000)) {
                error in
                XCTAssertEqual(String(describing: error), "points is required")
            }
        }
    }

    func testMissingCoordinatesReportTheFirstMissingKeyButPresentNullIsForwarded() throws {
        XCTAssertThrowsError(try MCPToolRequest.action(named: "tap", arguments: ["x": 1], longEdge: 1000)) { error in
            XCTAssertEqual(String(describing: error), "y is required")
        }
        let action = try XCTUnwrap(
            MCPToolRequest.action(
                named: "tap", arguments: ["x": NSNull(), "y": "unchecked"], longEdge: 1000))
        XCTAssertTrue(action.body["x"] is NSNull)
        XCTAssertEqual(action.body["y"] as? String, "unchecked")
    }

    func testKeyboardAndHomeDefaultsKeepTheirHTTPMappings() throws {
        let type = try XCTUnwrap(MCPToolRequest.action(named: "type_text", arguments: [:], longEdge: 1000))
        XCTAssertEqual(type.path, "/type")
        XCTAssertEqual(type.body["text"] as? String, "")
        let key = try XCTUnwrap(MCPToolRequest.action(named: "press_key", arguments: [:], longEdge: 1000))
        XCTAssertEqual(key.path, "/key")
        XCTAssertEqual(key.body["key"] as? String, "")
        XCTAssertEqual(key.body["modifiers"] as? [String], [])
        let home = try XCTUnwrap(MCPToolRequest.action(named: "home", arguments: ["device": "phone"], longEdge: 1000))
        XCTAssertEqual(home.path, "/home")
        XCTAssertEqual(home.body as? [String: String], ["device": "phone"])
        XCTAssertNil(try MCPToolRequest.action(named: "unknown", arguments: [:], longEdge: 1000))
    }
}

final class MCPOCRTests: XCTestCase {
    func testOCRToolsForwardOnlySupportedParameters() throws {
        let ocr = try XCTUnwrap(
            MCPToolRequest.action(named: "ocr_screen", arguments: ["device": "phone"], longEdge: 1200))
        XCTAssertEqual(ocr.path, "/ocr")
        XCTAssertEqual(ocr.body["maxEdge"] as? Int, 1200)
        XCTAssertEqual(ocr.body["device"] as? String, "phone")
        let tap = try XCTUnwrap(
            MCPToolRequest.action(
                named: "tap_text",
                arguments: [
                    "text": "设置", "exact": true, "index": 2, "hold": 0.4, "maxEdge": 800,
                    "device": "phone", "include_image": false,
                ], longEdge: 1200))
        XCTAssertEqual(tap.path, "/tap_text")
        XCTAssertEqual(tap.body["text"] as? String, "设置")
        XCTAssertEqual(tap.body["exact"] as? Bool, true)
        XCTAssertEqual(tap.body["index"] as? Int, 2)
        XCTAssertEqual(tap.body["hold"] as? Double, 0.4)
        XCTAssertEqual(tap.body["maxEdge"] as? Int, 800)
        XCTAssertNil(tap.body["include_image"])
        XCTAssertThrowsError(try MCPToolRequest.action(named: "tap_text", arguments: [:], longEdge: 1200))
        XCTAssertThrowsError(try MCPToolRequest.action(named: "ocr_screen", arguments: ["maxEdge": 0], longEdge: 1200))
    }

    func testScreenshotCanOmitImageAndAppendEscapedCompactOCR() throws {
        let item = ScreenOCR.Item(
            text: "say \"hello\"\n世界", box: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2), width: 100, height: 200)
        let ocr = ScreenOCR.Result(width: 100, height: 200, items: [item])
        for includeImage in [true, false] {
            let result = MCPServer.screenshotContent(
                image: Data([1, 2, 3]), device: "phone", width: "100", height: "200", includeImage: includeImage,
                ocr: ocr)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertEqual(content.count, includeImage ? 2 : 1)
            XCTAssertEqual(content.filter { $0["type"] as? String == "image" }.count, includeImage ? 1 : 0)
            let text = try XCTUnwrap(content.last?["text"] as? String)
            XCTAssertTrue(text.contains("\nOCR (x,y): "))
            XCTAssertTrue(text.contains("(20,40)"))
            XCTAssertTrue(text.contains("\\n"))
            XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        }
    }

    func testEmptyOCRKeepsScreenshotSuccessfulWithoutSummary() throws {
        let result = MCPServer.screenshotContent(
            image: Data(), device: "phone", width: "100", height: "200", includeImage: false,
            ocr: ScreenOCR.recognize(Data()))
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertFalse(try XCTUnwrap(content.first?["text"] as? String).contains("OCR (x,y)"))
    }

    func testOCRSchemasExposeReadOnlyRecognitionAndOptionalImage() throws {
        let tools = MCPToolCatalog.tools(for: .en)
        for name in ["ocr_screen", "tap_text", "screenshot"] {
            let tool = try XCTUnwrap(tools.first { $0["name"] as? String == name })
            XCTAssertEqual((tool["annotations"] as? [String: Bool])?["readOnlyHint"], name != "tap_text")
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            XCTAssertEqual(properties["include_image"]?["type"] as? String, "boolean")
            XCTAssertEqual(properties["include_image"]?["default"] as? Bool, true)
            if name != "screenshot" { XCTAssertEqual(properties["maxEdge"]?["default"] as? Int, 1000) }
            if name == "tap_text" { XCTAssertEqual(schema["required"] as? [String], ["text"]) }
        }
    }
}

final class MCPKeyboardAliasTests: XCTestCase {
    func testEveryToolAdvertisesDeviceAliasAndOriginalWins() throws {
        let tools = MCPToolCatalog.tools(for: .en)
        XCTAssertEqual(tools.count, 16)
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertNotNil(properties["device_id"], "\(tool["name"]!)")
            let image = try XCTUnwrap(properties["include_image"] as? [String: Any])
            XCTAssertEqual(image["type"] as? String, "boolean")
            XCTAssertFalse((schema["required"] as? [String] ?? []).contains("include_image"))
        }
        let cases: [(String, [String: Any])] = [
            ("move_pointer", ["x": 1, "y": 2]), ("adjust_pointer", ["dx": 0, "dy": 0]),
            ("click_pointer", [:]), ("tap", ["x": 1, "y": 2]), ("long_press", ["x": 1, "y": 2]),
            ("swipe", ["points": [["x": 0, "y": 0], ["x": 1, "y": 1]]]),
            ("type_text", ["text": "nihao"]), ("press_key", ["key": "enter"]), ("home", [:]),
            ("ocr_screen", [:]), ("tap_text", ["text": "Confirm"]),
        ]
        for (name, parameters) in cases {
            var arguments = parameters
            arguments["device_id"] = "alias"
            XCTAssertEqual(
                try MCPToolRequest.action(named: name, arguments: arguments, longEdge: 1200)?.body["device"] as? String,
                "alias")
            arguments["device"] = "original"
            XCTAssertEqual(
                try MCPToolRequest.action(named: name, arguments: arguments, longEdge: 1200)?.body["device"] as? String,
                "original")
        }
    }

    func testSequenceAliasesAndAllDelayForms() throws {
        let steps: [[String: Any]] = [
            ["type": "text", "text": "nihao", "clear_before": true, "commit_ime": true, "press_enter": true],
            ["type": "key", "key": "tab", "modifiers": ["shift"]],
            ["delay": 0], ["wait": 5], ["type": "delay", "seconds": 0.25], ["type": "wait", "seconds": 1],
        ]
        let actions = try MCPKeyboardSequence.actions(arguments: ["actions": steps, "device_id": "phone"])
        let requests = actions.compactMap { action -> MCPToolRequest? in
            if case .request(let request) = action { return request }
            return nil
        }
        XCTAssertEqual(requests.map(\.path), ["/key", "/key", "/type", "/key", "/key", "/key"])
        XCTAssertEqual(requests.compactMap { $0.body["key"] as? String }, ["a", "backspace", "space", "enter", "tab"])
        XCTAssertEqual(requests[0].body["modifiers"] as? [String], ["command"])
        let delays = actions.compactMap { action -> Double? in
            if case .delay(let seconds) = action { return seconds }
            return nil
        }
        XCTAssertEqual(delays, [0, 5, 0.25, 1])
        XCTAssertEqual(try MCPKeyboardSequence.actions(arguments: ["steps": steps, "actions": steps]).count, 10)
        XCTAssertThrowsError(try MCPKeyboardSequence.actions(arguments: ["steps": steps, "actions": [["wait": 0]]]))
    }

    func testChineseSequenceForwardsTextAndIMEOption() throws {
        let actions = try MCPKeyboardSequence.actions(arguments: [
            "steps": [
                ["text": "蓝牙", "ensure_chinese_ime": false]
            ]
        ])
        guard case .request(let request) = try XCTUnwrap(actions.first) else { return XCTFail("expected request") }
        XCTAssertEqual(request.path, "/type")
        XCTAssertEqual(request.body["text"] as? String, "蓝牙")
        XCTAssertEqual(request.body["ensure_chinese_ime"] as? Bool, false)
        XCTAssertEqual(try TypeTextRequest(request.body).actions.first?.body["text"] as? String, "蓝牙")
    }

    func testInvalidSequenceFormsAreRejectedBeforeExecution() {
        let invalid: [[String: Any]] = [
            ["type": "key", "text": "x"], ["type": "text", "key": "enter"],
            ["type": 1, "text": "x"], ["delay": 1, "wait": 1], ["seconds": 1],
            ["type": "delay", "seconds": 1, "text": "x"],
            ["text": "x", "clear_before": 1], ["key": "enter", "commit_ime": true],
        ]
        for step in invalid {
            XCTAssertThrowsError(try MCPKeyboardSequence.actions(arguments: ["actions": [["text": "ok"], step]]))
        }
        for value: Any in [true, false, -0.1, 5.1, Double.nan, Double.infinity, "1", NSNull()] {
            for step: [String: Any] in [["delay": value], ["wait": value], ["type": "wait", "seconds": value]] {
                XCTAssertThrowsError(try MCPKeyboardSequence.actions(arguments: ["steps": [step]]))
            }
        }
        for arguments: [String: Any] in [
            [:], ["actions": []], ["actions": [["wait": 0]], "device_id": 1],
            ["steps": [["text": "ok"]], "actions": "invalid"],
            ["actions": [["wait": 0]], "include_image": 1],
        ] {
            XCTAssertThrowsError(try MCPKeyboardSequence.actions(arguments: arguments))
        }
    }

    func testTypeTextForwardsStrictBooleanOptions() throws {
        let arguments: [String: Any] = [
            "text": "nihao", "clear_before": true, "commit_ime": true, "press_enter": false,
            "ensure_chinese_ime": true, "device_id": "phone",
        ]
        let request = try XCTUnwrap(MCPToolRequest.action(named: "type_text", arguments: arguments, longEdge: 1200))
        XCTAssertEqual(request.body["device"] as? String, "phone")
        for option in MCPKeyboardSequence.textOptions {
            XCTAssertEqual(request.body[option] as? Bool, arguments[option] as? Bool)
            for invalid: Any in [0, 1, "true", NSNull()] {
                XCTAssertThrowsError(
                    try MCPToolRequest.action(
                        named: "type_text", arguments: ["text": "x", option: invalid], longEdge: 1200))
            }
        }
    }
}
