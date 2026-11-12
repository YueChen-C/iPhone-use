import Foundation

/// JSON-safe, inert wire values. Unknown attributes are retained, not instantiated
/// as Objective-C objects. Binary values have an explicit reversible encoding.
enum AXValues {
    static func json(_ value: Any) throws -> Any {
        var budget = 250_000
        return try json(value, depth: 0, budget: &budget)
    }
    private static func json(_ value: Any, depth: Int, budget: inout Int) throws -> Any {
        budget -= 1
        guard depth < 80, budget >= 0 else { throw AXDTX.Failure("AX raw attribute nesting/node limit") }
        if value is NSNull { return NSNull() }
        if let data = value as? Data { return ["$type": "data", "encoding": "base64", "value": data.base64EncodedString()] }
        if let date = value as? Date { return ["$type": "date", "value": date.timeIntervalSince1970] }
        if let number = value as? NSNumber {
            guard number.doubleValue.isFinite else { throw AXDTX.Failure("Non-finite AX attribute") }
            return number
        }
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] {
            return try dictionary.mapValues { try json($0, depth: depth + 1, budget: &budget) }
        }
        if let array = value as? [Any] { return try array.map { try json($0, depth: depth + 1, budget: &budget) } }
        throw AXDTX.Failure("Unsupported inert AX attribute type")
    }

    static func frame(_ value: Any) -> [String: Double]? {
        var values: [Double] = []
        if let dictionary = value as? [String: Any] {
            for key in ["x", "y", "width", "height"] {
                guard let n = dictionary[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
                values.append(n.doubleValue)
            }
        } else if let string = value as? String {
            // Only a four-component CGRect spelling, not arbitrary description text.
            let pattern = #"^\s*\{\s*\{\s*([-+0-9.eE]+)\s*,\s*([-+0-9.eE]+)\s*\}\s*,\s*\{\s*([-+0-9.eE]+)\s*,\s*([-+0-9.eE]+)\s*\}\s*\}\s*$"#
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let match = re.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
            for i in 1...4 {
                guard let range = Range(match.range(at: i), in: string), let n = Double(string[range]) else { return nil }
                values.append(n)
            }
        }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] >= 0, values[3] >= 0 else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(["x", "y", "width", "height"], values))
    }
}
