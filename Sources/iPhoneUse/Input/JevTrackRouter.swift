import Foundation

struct JevDecision: Codable {
    let mode: ControlTrackMode
    let confidence: Double
    let probabilities: [String: Double]
    let source: String
    let rationale: String?

    var json: [String: Any] {
        var dict: [String: Any] = [
            "mode": mode.rawValue,
            "confidence": confidence,
            "probabilities": probabilities,
            "source": source,
        ]
        if let rationale {
            dict["rationale"] = rationale
        }
        return dict
    }
}

final class JevTrackRouter {
    static let shared = JevTrackRouter()

    private let endpointURL: URL
    private let apiKey: String?
    private let modelName: String

    init(
        endpoint: String = ProcessInfo.processInfo.environment["JEV_API_URL"] ?? "https://api.typesafe.ai/v1/systemone",
        apiKey: String? = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? ProcessInfo.processInfo.environment["JEV_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["JEV_MODEL"] ?? "jev-latest"
    ) {
        self.endpointURL = URL(string: endpoint) ?? URL(string: "https://api.typesafe.ai/v1/systemone")!
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = model
    }

    func decide(prompt: String, appName: String? = nil, timeout: TimeInterval = 3.0) -> JevDecision {
        let combinedState = [
            "instruction": prompt,
            "target_app": appName ?? "unspecified",
        ]

        if let apiKey = self.apiKey, !apiKey.isEmpty {
            if let onlineDecision = evaluateViaJevAPI(state: combinedState, apiKey: apiKey, timeout: timeout) {
                return onlineDecision
            }
        }

        return evaluateHeuristically(prompt: prompt, appName: appName)
    }

    private func evaluateViaJevAPI(
        state: [String: String],
        apiKey: String,
        timeout: TimeInterval
    ) -> JevDecision? {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let payload: [String: Any] = [
            "model": modelName,
            "state": state,
            "questions": [
                "track_routing": [
                    "type": "choice",
                    "instructions": "Determine which control track should handle this iPhone automation task.",
                    "criteria": [
                        "standard": "Banking, payment, financial, anti-cheat, ride-sharing, food delivery, or sensitive consumer apps where developer tunnel or accessibility injection detection leads to bans or crashes.",
                        "enhanced": "Deep structured extraction, native accessibility tree traversal, long text typing via pasteboard, or rapid table/list inspection.",
                        "auto": "General mobile navigation, simple taps or swipes, ambiguous tasks, or standard third-party apps."
                    ]
                ]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return nil
        }
        request.httpBody = bodyData

        var result: JevDecision?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, let data else {
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let answers = json["answers"] as? [String: Any],
                  let routing = answers["track_routing"] as? [String: Any],
                  let choiceRaw = routing["choice"] as? String,
                  let chosenMode = ControlTrackMode.parse(choiceRaw) else {
                return
            }

            let probabilities = (routing["probabilities"] as? [String: Double]) ?? [:]
            let confidence = probabilities[chosenMode.rawValue] ?? 0.85

            result = JevDecision(
                mode: chosenMode,
                confidence: confidence,
                probabilities: probabilities,
                source: "jev",
                rationale: "Evaluated by TypeSafe Jev System One model (\(json["model"] as? String ?? "jev"))."
            )
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    func evaluateHeuristically(prompt: String, appName: String? = nil) -> JevDecision {
        let text = "\(prompt) \(appName ?? "")".lowercased()

        let standardKeywords = [
            "银行", "招商", "工商", "建设", "农业", "交通银行", "平安", "浦发",
            "支付宝", "微信支付", "买菜", "美团", "拼多多", "滴滴", "京东金融",
            "风控", "防封", "人脸", "实名",
            "bank", "alipay", "wechat pay", "payment", "wallet", "checkout", "anti-cheat"
        ]

        let enhancedKeywords = [
            "ax", "ax_tree", "无障碍", "元素树", "控件树", "结构树", "层级树",
            "大批量", "长文本", "粘贴", "剪贴板", "快速输入", "输入法", "列表遍历", "数据抓取",
            "hierarchy", "dump", "pasteboard", "scrape", "bulk"
        ]

        for kw in standardKeywords {
            if text.contains(kw) {
                return JevDecision(
                    mode: .standard,
                    confidence: 0.92,
                    probabilities: ["standard": 0.92, "enhanced": 0.05, "auto": 0.03],
                    source: "heuristic",
                    rationale: "Detected high-risk or financial keyword '\(kw)'; routed to standard retail track for safety."
                )
            }
        }

        for kw in enhancedKeywords {
            if text.contains(kw) {
                return JevDecision(
                    mode: .enhanced,
                    confidence: 0.90,
                    probabilities: ["standard": 0.05, "enhanced": 0.90, "auto": 0.05],
                    source: "heuristic",
                    rationale: "Detected deep extraction or structured input keyword '\(kw)'; routed to enhanced track."
                )
            }
        }

        return JevDecision(
            mode: .auto,
            confidence: 0.85,
            probabilities: ["standard": 0.15, "enhanced": 0.25, "auto": 0.60],
            source: "heuristic",
            rationale: "General task without explicit risk or extraction markers; defaulted to auto adaptive track."
        )
    }
}
