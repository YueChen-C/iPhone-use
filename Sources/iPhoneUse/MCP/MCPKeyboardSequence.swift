import CoreFoundation
import Foundation

enum MCPKeyboardAction {
    case request(MCPToolRequest)
    case delay(TimeInterval)
}

/// Validate the complete sequence before the server acquires locks or sends input.
enum MCPKeyboardSequence {
    static let textOptions = TextEntry.textOptions

    static let schema: [String: Any] = {
        let seconds: [String: Any] = ["type": "number", "minimum": 0, "maximum": 5]
        var text: [String: Any] = [
            "type": ["enum": ["text"]],
            "text": ["type": "string", "minLength": 1, "maxLength": 256],
        ]
        for option in textOptions { text[option] = ["type": "boolean"] }
        func step(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "properties": properties, "required": required]
        }
        return [
            "type": "array", "minItems": 1, "maxItems": 16,
            "items": [
                "oneOf": [
                    step(text, ["text"]),
                    step(
                        [
                            "type": ["enum": ["key"]], "key": ["type": "string", "minLength": 1],
                            "modifiers": [
                                "type": "array",
                                "items": ["type": "string", "enum": KeyboardMap.modifiers.keys.sorted()],
                            ],
                        ], ["key"]),
                    step(["delay": seconds], ["delay"]),
                    step(["wait": seconds], ["wait"]),
                    step(["type": ["enum": ["delay", "wait"]], "seconds": seconds], ["type", "seconds"]),
                ]
            ],
        ]
    }()

    static func actions(arguments: [String: Any], language: AppLanguage = .en) throws -> [MCPKeyboardAction] {
        let table = StringsMCP(language: language)
        guard
            Set(arguments.keys).isSubset(of: ["steps", "actions", "device", "device_id", "include_image", "observe"]),
            ["device", "device_id"].allSatisfy({ arguments[$0] == nil || arguments[$0] is String }),
            arguments["include_image"] == nil || isBoolean(arguments["include_image"]),
            let steps = (arguments["steps"] ?? arguments["actions"]) as? [[String: Any]],
            (1...16).contains(steps.count)
        else { throw MCPServer.MCPError(table.keyboardSequenceRange) }
        if let original = arguments["steps"], let alias = arguments["actions"],
            !NSDictionary(dictionary: ["steps": original]).isEqual(to: ["steps": alias])
        {
            throw MCPServer.MCPError(table.keyboardSequenceRange)
        }

        var textCount = 0
        return try steps.enumerated().flatMap { index, step -> [MCPKeyboardAction] in
            let label = table.kbStepLabel(index + 1)
            if let text = step["text"] as? String,
                Set(step.keys).isSubset(of: Set(["type", "text"] + textOptions)),
                step["type"] == nil || step["type"] as? String == "text"
            {
                textCount += text.count
                guard !text.isEmpty, textCount <= 256,
                    step["use_clipboard"] as? Bool == true || KeyboardMap.keyboardText(for: text) != nil
                else { throw MCPServer.MCPError(table.kbAscii(label)) }
                _ = try TypeTextRequest(step, language: language)
                // Preserve one validated text transaction. Splitting clear/commit
                // shortcuts here would bypass USB's input-mode/preflight gate.
                var body = step
                body.removeValue(forKey: "type")
                return [.request(MCPToolRequest(path: "/type", body: body))]
            }
            if let key = step["key"] as? String,
                Set(step.keys).isSubset(of: ["type", "key", "modifiers"]),
                step["type"] == nil || step["type"] as? String == "key",
                // Character(String) traps for unknown multi-character names.
                KeyboardMap.named[key.lowercased()] != nil || key.count == 1,
                KeyboardMap.code(for: key) != nil,
                step["modifiers"] == nil || step["modifiers"] is [String]
            {
                let modifiers = step["modifiers"] as? [String] ?? []
                guard KeyboardMap.modifierMask(for: modifiers) != nil else {
                    throw MCPServer.MCPError(table.kbUnknownModifier(label))
                }
                return [.request(MCPToolRequest(path: "/key", body: ["key": key, "modifiers": modifiers]))]
            }
            let rawDelay: Any?
            if Set(step.keys) == ["delay"] {
                rawDelay = step["delay"]
            } else if Set(step.keys) == ["wait"] {
                rawDelay = step["wait"]
            } else if Set(step.keys) == ["type", "seconds"],
                let type = step["type"] as? String, ["delay", "wait"].contains(type)
            {
                rawDelay = step["seconds"]
            } else {
                throw MCPServer.MCPError(table.kbExpected(label))
            }
            guard let seconds = rawDelay as? NSNumber, !isBoolean(seconds),
                seconds.doubleValue.isFinite, (0...5).contains(seconds.doubleValue)
            else { throw MCPServer.MCPError(table.kbDelay(label)) }
            return [.delay(seconds.doubleValue)]
        }
    }

    static func isBoolean(_ value: Any?) -> Bool {
        TextEntry.isBoolean(value)
    }
}
