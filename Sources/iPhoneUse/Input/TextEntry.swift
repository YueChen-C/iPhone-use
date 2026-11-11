import AppKit
import CoreFoundation
import Foundation

enum TextEntry {
    static let textOptions = [
        "clear_before", "commit_ime", "press_enter", "submit", "ensure_chinese_ime", "use_clipboard",
    ]

    static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func writeClipboard(_ text: String) throws {
        let write = {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        let success = Thread.isMainThread ? write() : DispatchQueue.main.sync(execute: write)
        guard success else { throw DeviceError("Could not write clipboard") }
    }
}

enum TextEntryStep {
    case text(String, ensureIME: Bool?)
    case clipboard(String)
    case key(String, [String])

    var path: String {
        if case .key = self { return "/key" }
        return "/type"
    }

    var body: [String: Any] {
        switch self {
        case .text(let text, let ensure):
            var body: [String: Any] = ["text": text]
            if let ensure { body["ensure_chinese_ime"] = ensure }
            return body
        case .clipboard(let text): return ["text": text, "use_clipboard": true]
        case .key(let key, let modifiers): return ["key": key, "modifiers": modifiers]
        }
    }
}

/// One HTTP request validates all options and text before clearing the focused field.
struct TypeTextRequest {
    let actions: [TextEntryStep]
    let ensureChineseIME: Bool
    let ensureASCIIIME: Bool

    init(_ body: [String: Any], language: AppLanguage = .en) throws {
        let table = StringsAPI(language: language)
        guard let text = body["text"] as? String else { throw DeviceError(table.textRequired) }
        for option in TextEntry.textOptions where body[option] != nil {
            guard TextEntry.isBoolean(body[option]) else {
                throw DeviceError(language == .zh ? "\(option) 必须是布尔值" : "\(option) must be a boolean")
            }
        }
        let clipboard = body["use_clipboard"] as? Bool == true
        guard clipboard || KeyboardMap.keyboardText(for: text) != nil else {
            throw DeviceError(
                language == .zh
                    ? "文字必须可转换为美式 ASCII 按键或中文拼音" : "Text must be representable as US ASCII keys or Chinese pinyin")
        }
        var actions: [TextEntryStep] = []
        func key(_ name: String, _ modifiers: [String] = []) -> TextEntryStep {
            .key(name, modifiers)
        }
        if body["clear_before"] as? Bool == true {
            actions += [key("a", ["command"]), key("backspace")]
        }
        actions.append(clipboard ? .clipboard(text) : .text(text, ensureIME: body["ensure_chinese_ime"] as? Bool))
        let submit = body["submit"] as? Bool == true
        // Han runs already commit their candidate in KeyboardMap.keyboardText.
        // submit adds Enter only; preserve an explicitly requested extra Space.
        let commitIME = body["commit_ime"] as? Bool == true
        let pressEnter = (body["press_enter"] as? Bool == true) || submit

        if commitIME { actions.append(key("space")) }
        if pressEnter { actions.append(key("enter")) }
        self.actions = actions
        let explicitChineseIME = body["ensure_chinese_ime"] as? Bool
        let hasHanzi = KeyboardMap.containsHanzi(text)
        ensureChineseIME = !clipboard && (explicitChineseIME ?? hasHanzi)
        ensureASCIIIME = !clipboard && explicitChineseIME != true && !hasHanzi && !text.isEmpty
    }

    func perform(
        on input: DeviceInput,
        ocr: () -> ScreenOCR.Result? = { nil },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        clipboard: (String) throws -> Void = TextEntry.writeClipboard
    ) throws {
        // A clipboard failure must precede clear_before and any other input.
        for action in actions {
            if case .clipboard(let text) = action { try clipboard(text) }
        }
        if ensureChineseIME, let result = ocr(), ChineseIMEHeuristic.isEnglish(result) {
            try input.key("space", modifiers: ["control"])
            sleep(0.25)
        } else if ensureASCIIIME, let result = ocr(), ChineseIMEHeuristic.isChinese(result) {
            try input.key("space", modifiers: ["control"])
            sleep(0.25)
        }
        for action in actions {
            switch action {
            case .text(let text, _): try input.type(text)
            case .clipboard:
                try input.key("v", modifiers: ["command"])
            case .key(let key, let modifiers): try input.key(key, modifiers: modifiers)
            }
        }
    }
}

/// Best-effort keyboard-region heuristic, not a verified iOS input-mode API.
enum ChineseIMEHeuristic {
    static func isEnglish(_ result: ScreenOCR.Result) -> Bool {
        guard result.height > 0 else { return false }
        let labels = result.items.filter { Double($0.y) / Double(result.height) > 0.65 }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !labels.contains(where: { KeyboardMap.containsHanzi($0) }) else { return false }
        let englishLabels: Set<String> = ["return", "search", "go", "space"]
        if labels.contains(where: { englishLabels.contains($0) }) { return true }
        let keys = Set(labels).intersection(["q", "w", "e", "a", "s", "d"])
        return keys.count >= 3
    }

    static func isChinese(_ result: ScreenOCR.Result) -> Bool {
        guard result.height > 0 else { return false }
        let labels = result.items.filter { Double($0.y) / Double(result.height) > 0.65 }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let chineseMarkers: Set<String> = ["空格", "选定", "拼音", "双拼", "双", "中", "中/英", "中英"]
        return labels.contains(where: { chineseMarkers.contains($0) })
    }
}
