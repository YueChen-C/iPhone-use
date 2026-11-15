import Foundation

/// Request-scoped delivery evidence, never inferred from an error's text or a
/// previous request on this worker. No failure permits automatic input replay.
struct USBInputFailure: Error, CustomStringConvertible {
    enum Code: String {
        case notReady = "input_not_ready"
        case busy = "input_busy"
        case staleSession = "stale_session"
        case unsupported = "unsupported_capability"
        case uncertain = "input_uncertain"
    }
    let code: Code
    let description: String
    var mayHaveExecuted = false

    init(_ code: Code, _ description: String, mayHaveExecuted: Bool = false) {
        self.code = code; self.description = description; self.mayHaveExecuted = mayHaveExecuted
    }
    var httpStatus: Int {
        switch code {
        case .notReady: 503
        case .busy, .staleSession: 409
        case .unsupported: 400
        case .uncertain: 502
        }
    }
    var json: [String: Any] {
        ["error": description, "code": code.rawValue, "backend": "usb",
         "mayHaveExecuted": mayHaveExecuted, "replayAllowed": false, "uiVerified": false]
    }
    func includingPriorInput(_ dispatched: Bool) -> Self {
        Self(code, description, mayHaveExecuted: mayHaveExecuted || dispatched)
    }

    /// Forward only the public evidence contract, including specialized IME
    /// failures. An absent delivery flag stays unknown, never becomes false.
    static func metadata(from body: [String: Any], priorInput: Bool = false) -> [String: Any] {
        guard body["backend"] as? String == "usb" else { return [:] }
        var result: [String: Any] = [:]
        for key in ["backend", "code", "reason", "textDispatched", "mayHaveExecuted", "replayAllowed", "uiVerified"] {
            result[key] = body[key]
        }
        if priorInput { result["mayHaveExecuted"] = true }
        result["replayAllowed"] = false
        return result
    }
}
