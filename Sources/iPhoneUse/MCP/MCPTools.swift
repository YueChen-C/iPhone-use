import Foundation

/// Public tool descriptions and input schemas, kept separate from execution.
/// Descriptions are localized per language; names, keys, and constraints stay
/// byte-identical so every client keeps working regardless of language.
enum MCPToolCatalog {
    static func device(for table: StringsMCP) -> [String: Any] {
        ["type": "string", "description": table.deviceParam]
    }

    static func tools(for language: AppLanguage) -> [[String: Any]] {
        let table = StringsMCP(language: language)
        let device = device(for: table)
        let normalized: [String: Any] = ["type": "boolean", "description": table.normalizedParam]
        let includeImage: [String: Any] = ["type": "boolean", "default": true, "description": table.includeImage]
        let maxEdge: [String: Any] = ["type": "integer", "minimum": 1, "default": MCPServer.longEdge]
        return [
            tool("list_devices", table.toolListDevices, [:], readOnly: true),
            tool(
                "screenshot", table.toolScreenshot, ["device": device, "include_image": includeImage], readOnly: true),
            tool("ocr_screen", table.toolOCRScreen, ["device": device, "maxEdge": maxEdge], readOnly: true),
            tool(
                "tap_text", table.toolTapText,
                [
                    "text": ["type": "string", "minLength": 1], "exact": ["type": "boolean", "default": false],
                    "index": ["type": "integer", "minimum": 0, "default": 0],
                    "hold": ["type": "number", "minimum": 0, "maximum": 60, "default": 0.08],
                    "maxEdge": maxEdge, "device": device, "include_image": includeImage,
                ], required: ["text"]),
            tool(
                "move_pointer",
                table.toolMovePointer,
                ["x": number(table.xPixels), "y": number(table.yPixels), "normalized": normalized, "device": device],
                required: ["x", "y"]),
            tool(
                "adjust_pointer",
                table.toolAdjustPointer,
                [
                    "dx": ["type": "integer", "minimum": -32, "maximum": 32],
                    "dy": ["type": "integer", "minimum": -32, "maximum": 32], "device": device,
                ], required: ["dx", "dy"]),
            tool(
                "click_pointer",
                table.toolClickPointer,
                ["device": device]),
            tool(
                "tap", table.toolTap,
                ["x": number(table.xPixels), "y": number(table.yPixels), "normalized": normalized, "device": device],
                required: ["x", "y"]),
            tool(
                "long_press", table.toolLongPress,
                [
                    "x": number(table.xPixels), "y": number(table.yPixels),
                    "seconds": number(table.holdSeconds), "normalized": normalized, "device": device,
                ], required: ["x", "y"]),
            tool(
                "swipe",
                table.toolSwipe,
                [
                    "points": [
                        "type": "array", "minItems": 2,
                        "description": table.swipePointsDesc,
                        "items": [
                            "type": "object",
                            "properties": ["x": number(table.xPixels), "y": number(table.yPixels)],
                            "required": ["x", "y"],
                        ],
                    ],
                    "duration": [
                        "type": "number", "exclusiveMinimum": 0,
                        "description": table.swipeDurationDesc,
                    ],
                    "normalized": normalized,
                    "device": device,
                ], required: ["points"]),
            tool(
                "type_text", table.toolTypeText,
                [
                    "text": ["type": "string"], "device": device,
                    "clear_before": ["type": "boolean"], "commit_ime": ["type": "boolean"],
                    "press_enter": ["type": "boolean"], "ensure_chinese_ime": ["type": "boolean"],
                    "use_clipboard": ["type": "boolean"],
                ], required: ["text"]),
            tool(
                "press_key",
                table.toolPressKey,
                [
                    "key": ["type": "string"], "modifiers": ["type": "array", "items": ["type": "string"]],
                    "device": device,
                ],
                required: ["key"]),
            tool(
                "keyboard_sequence",
                table.toolKeyboardSequence,
                [
                    "steps": MCPKeyboardSequence.schema, "actions": MCPKeyboardSequence.schema,
                    "device": device, "include_image": ["type": "boolean"],
                ]),
            tool("home", table.toolHome, ["device": device]),
            tool(
                "act",
                language == .zh
                    ? "顺序执行点击、文字点击、滑动、输入、按键、主屏幕、延时与等待文字；失败立即停止。"
                    : "Execute ordered tap, tap_text, swipe, type, key, home, delay and wait_text steps; stop on failure.",
                [
                    "steps": actSteps,
                    "device": device,
                ], required: ["steps"]),
        ]
    }

    private static var actSteps: [String: Any] {
        let number: [String: Any] = ["type": "number"]
        let boolean: [String: Any] = ["type": "boolean"]
        let text: [String: Any] = ["type": "string", "minLength": 1]
        let edge: [String: Any] = ["type": "integer", "minimum": 1, "default": MCPServer.longEdge]
        func step(_ type: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            var properties = properties
            properties["type"] = ["type": "string", "enum": [type]]
            return [
                "type": "object", "additionalProperties": false, "properties": properties,
                "required": ["type"] + required,
            ]
        }
        var typing: [String: Any] = ["text": text]
        for option in TextEntry.textOptions { typing[option] = boolean }
        let matching: [String: Any] = [
            "text": text, "exact": boolean, "index": ["type": "integer", "minimum": 0], "maxEdge": edge,
        ]
        var tapText = matching
        tapText["hold"] = ["type": "number", "minimum": 0, "maximum": 60]
        var waiting = matching
        waiting["timeout"] = ["type": "number", "minimum": 0, "maximum": 6, "default": 6]
        return [
            "type": "array", "minItems": 1, "maxItems": 16,
            "items": [
                "oneOf": [
                    step("tap", ["x": number, "y": number, "normalized": boolean, "hold": number], ["x", "y"]),
                    step("tap_text", tapText, ["text"]),
                    step(
                        "swipe",
                        [
                            "points": [
                                "type": "array", "minItems": 2,
                                "items": [
                                    "type": "object", "properties": ["x": number, "y": number], "required": ["x", "y"],
                                ],
                            ], "duration": number, "normalized": boolean,
                        ], ["points"]),
                    step("type", typing, ["text"]),
                    step("key", ["key": text, "modifiers": ["type": "array", "items": text]], ["key"]),
                    step("home", [:]),
                    step("delay", ["seconds": ["type": "number", "minimum": 0, "maximum": 6]], ["seconds"]),
                    step("wait_text", waiting, ["text"]),
                ]
            ],
        ]
    }

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: Any],
        required: [String] = [], readOnly: Bool = false
    ) -> [String: Any] {
        var properties = properties
        properties["device"] = properties["device"] ?? device(for: StringsMCP(language: .en))
        properties["device_id"] = properties["device"]
        properties["include_image"] = [
            "type": "boolean", "default": true, "description": StringsMCP(language: .en).includeImage,
        ]
        if !readOnly {
            properties["observe"] = ["type": "string", "enum": ["full", "ocr_diff", "none"], "default": "full"]
        }
        var schema: [String: Any] = ["type": "object", "properties": properties, "required": required]
        if name == "keyboard_sequence" {
            schema["anyOf"] = [["required": ["steps"]], ["required": ["actions"]]]
        }
        return [
            "name": name, "description": description,
            "inputSchema": schema,
            "annotations": ["readOnlyHint": readOnly],
        ]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }
}

/// An action translated to the app's HTTP API. Building it has no device side effects.
struct MCPToolRequest {
    let path: String
    let body: [String: Any]

    /// Nil means the name is not an action tool. Listing and screenshots have no POST body.
    /// `language` defaults to English so direct callers (tests, embeddings) stay stable.
    static func action(
        named name: String, arguments: [String: Any], longEdge: Int, language: AppLanguage = .en
    ) throws -> MCPToolRequest? {
        let device = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
        switch name {
        case "act":
            let batch = try ActRequest(arguments)
            let steps = try batch.steps.map { step -> [String: Any] in
                let type = step["type"] as! String
                if ["tap", "swipe", "tap_text"].contains(type) {
                    var translated = try action(named: type, arguments: step, longEdge: longEdge, language: language)!
                        .body
                    translated["type"] = type
                    if type == "tap", let hold = step["hold"] { translated["hold"] = hold }
                    return translated
                }
                var translated = step
                if type == "wait_text", translated["maxEdge"] == nil { translated["maxEdge"] = longEdge }
                return translated
            }
            return MCPToolRequest(path: "/act", body: withDevice(["steps": steps], device))
        case "ocr_screen", "tap_text":
            let table = StringsAPI(language: language)
            let edge = try OCRRequest.maxEdge(arguments, table: table) ?? longEdge
            if name == "tap_text" { _ = try TextTapRequest(arguments, table: table) }
            var body: [String: Any] = ["maxEdge": edge]
            for key in ["text", "exact", "index", "hold"] where arguments[key] != nil {
                if name == "tap_text" { body[key] = arguments[key] }
            }
            return MCPToolRequest(path: name == "ocr_screen" ? "/ocr" : "/tap_text", body: withDevice(body, device))
        case "move_pointer":
            let body = try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language)
            for key in ["x", "y"] {
                guard let value = arguments[key] as? NSNumber,
                    CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0
                else {
                    throw MCPServer.MCPError(StringsMCP(language: language).coordinateFinite(key))
                }
            }
            return MCPToolRequest(path: "/move", body: body)
        case "adjust_pointer":
            var body: [String: Any] = ["click": false]
            for key in ["dx", "dy"] {
                guard let value = arguments[key] as? NSNumber,
                    CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                    (-32...32).contains(value.doubleValue), value.doubleValue.rounded() == value.doubleValue
                else { throw MCPServer.MCPError(StringsMCP(language: language).hidCountRange(key)) }
                body[key] = value.intValue
            }
            return MCPToolRequest(path: "/nudge", body: withDevice(body, device))
        case "click_pointer":
            return MCPToolRequest(path: "/nudge", body: withDevice(["dx": 0, "dy": 0, "click": true], device))
        case "tap":
            return MCPToolRequest(
                path: "/tap", body: try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language))
        case "long_press":
            var body = try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language)
            body["hold"] = arguments["seconds"] ?? 1.0
            return MCPToolRequest(path: "/tap", body: body)
        case "swipe":
            var body = try scaled(arguments, ["points"], longEdge: longEdge, language: language)
            body["duration"] = arguments["duration"] ?? 0.3
            return MCPToolRequest(path: "/swipe", body: body)
        case "type_text":
            var body: [String: Any] = ["text": arguments["text"] ?? ""]
            for option in TextEntry.textOptions {
                if let value = arguments[option] {
                    guard TextEntry.isBoolean(value) else {
                        throw MCPServer.MCPError(StringsMCP(language: language).booleanRequired(option))
                    }
                    body[option] = value
                }
            }
            return MCPToolRequest(path: "/type", body: withDevice(body, device))
        case "press_key":
            return MCPToolRequest(
                path: "/key",
                body: withDevice(["key": arguments["key"] ?? "", "modifiers": arguments["modifiers"] ?? []], device))
        case "home":
            return MCPToolRequest(path: "/home", body: withDevice([:], device))
        default:
            return nil
        }
    }

    /// Pixel coordinates keep the HTTP API's existing rules. Explicit normalized
    /// coordinates use 0...1000 on each axis, independent of screenshot aspect ratio.
    private static func scaled(
        _ arguments: [String: Any], _ keys: [String], longEdge: Int, language: AppLanguage
    ) throws -> [String: Any] {
        var body: [String: Any] = ["maxEdge": longEdge]
        let table = StringsMCP(language: language)
        var normalized = false
        if let raw = arguments["normalized"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw MCPServer.MCPError(table.normalizedBoolean)
            }
            normalized = value.boolValue
        }
        func coordinate(_ value: Any?, key: String) throws -> Double {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, (0...1000).contains(number.doubleValue)
            else { throw MCPServer.MCPError(table.normalizedRange(key)) }
            return number.doubleValue / 1000.0
        }
        for key in keys {
            guard let value = arguments[key] else {
                throw MCPServer.MCPError(StringsMCP(language: language).parameterRequired(key))
            }
            if normalized, key == "points" {
                guard let points = value as? [[String: Any]], points.count >= 2 else {
                    throw MCPServer.MCPError(table.normalizedPoints)
                }
                body[key] = try points.map { point in
                    ["x": try coordinate(point["x"], key: "x"), "y": try coordinate(point["y"], key: "y")]
                }
            } else if normalized {
                body[key] = try coordinate(value, key: key)
            } else {
                body[key] = value
            }
        }
        if normalized { body["fraction"] = true }
        return withDevice(body, (arguments["device"] as? String) ?? (arguments["device_id"] as? String))
    }

    private static func withDevice(_ body: [String: Any], _ device: String?) -> [String: Any] {
        guard let device else { return body }
        return body.merging(["device": device]) { $1 }
    }
}
