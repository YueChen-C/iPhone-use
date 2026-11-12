import Darwin
import Foundation

/// Resolves NSKeyedArchiver UID references without instantiating archived classes.
/// Unknown custom AX classes stay plain dictionaries. Counts/depth are bounded.
struct AXArchive {
    private let objects: [Any]
    private let root: Any
    private static let uidType: (@convention(c) () -> CFTypeID)? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFKeyedArchiverUIDGetTypeID") else { return nil }
        return unsafeBitCast(p, to: (@convention(c) () -> CFTypeID).self)
    }()
    private static let uidValue: (@convention(c) (CFTypeRef) -> UInt32)? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFKeyedArchiverUIDGetValue") else { return nil }
        return unsafeBitCast(p, to: (@convention(c) (CFTypeRef) -> UInt32).self)
    }()

    init(_ data: Data) throws {
        guard data.count <= AXDTX.limit,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any], !objects.isEmpty, objects.count <= 100_000,
              let top = plist["$top"] as? [String: Any], let root = top["root"] else {
            throw AXDTX.Failure("Invalid AX keyed archive")
        }
        self.objects = objects; self.root = root
    }

    func decode() throws -> Any {
        var budget = 250_000
        return try resolve(root, depth: 0, chain: [], budget: &budget)
    }

    private func resolve(_ value: Any, depth: Int, chain: Set<Int>, budget: inout Int) throws -> Any {
        budget -= 1
        guard budget >= 0, depth < 80 else { throw AXDTX.Failure("AX archive nesting/node limit") }
        if let type = Self.uidType, let uid = Self.uidValue, CFGetTypeID(value as CFTypeRef) == type() {
            let index = Int(uid(value as CFTypeRef))
            guard index < objects.count else { throw AXDTX.Failure("AX archive UID out of bounds") }
            guard !chain.contains(index) else { throw AXDTX.Failure("AX archive UID cycle") }
            if index == 0, objects[index] as? String == "$null" { return NSNull() }
            return try resolve(objects[index], depth: depth + 1, chain: chain.union([index]), budget: &budget)
        }
        if let array = value as? [Any] {
            return try array.map { try resolve($0, depth: depth + 1, chain: chain, budget: &budget) }
        }
        guard let dictionary = value as? [String: Any] else { return value }
        var result: [String: Any] = [:]
        for (key, value) in dictionary where key != "$class" {
            result[key] = try resolve(value, depth: depth + 1, chain: chain, budget: &budget)
        }
        if let keys = result["NS.keys"] as? [Any], let values = result["NS.objects"] as? [Any] {
            guard keys.count == values.count else { throw AXDTX.Failure("Mismatched AX dictionary entries") }
            var fields: [String: Any] = [:]
            for (key, value) in zip(keys, values) {
                if let key = key as? String { fields[key] = value }
                else if let key = key as? NSNumber { fields[key.stringValue] = value }
            }
            return fields
        }
        if let values = result["NS.objects"] { return values }
        for key in ["NS.data", "NS.string", "NS.rectval", "NS.pointval", "NS.sizeval", "NS.intval", "NS.boolval", "NS.real"] {
            if let value = result[key] { return value }
        }
        return result
    }
}

/// Ingest incremental AX attribute messages, then flatten their actual hierarchy.
struct AXTree {
    private struct Node {
        var fields: [String: Any] = [:]
        var raw: [String: Any] = [:]
        var children: [UInt64] = []
        var visible: [UInt64] = []
    }
    private var nodes: [UInt64: Node] = [:]
    private var roots: [(UInt64, UInt64?)] = []
    private var orientation: Any?
    private(set) var revision = 0
    let includeOffscreen: Bool

    init(includeOffscreen: Bool) { self.includeOffscreen = includeOffscreen }

    var ready: Bool { nodes.count > 1 && roots.contains { nodes[$0.0] != nil } }

    mutating func update(_ data: Data) throws {
        let decoded = try AXArchive(data).decode()
        // The DTX argument is an archived NSData wrapping the actual AX archive.
        let inner = try (decoded as? Data).map { try AXArchive($0).decode() } ?? decoded
        guard let root = inner as? [String: Any] else { return }
        try update(root)
    }

    mutating func update(_ root: [String: Any]) throws {
        guard (root["associatedRequestType"] as? NSNumber)?.intValue == 11,
              let result = root["resultData"] as? [String: Any], let dump = result["treeDump"] as? [[String: Any]] else { return }
        for response in dump {
            let kind = (response["associatedRequestType"] as? NSNumber)?.intValue
            if kind == 4, let data = response["resultData"] as? [String: Any], let id = uint(data["objectID"]) {
                if !roots.contains(where: { $0.0 == id }) { roots.append((id, uint(data["pid"]))); revision += 1 }
            } else if kind == 2, (response["attribute"] as? NSNumber)?.intValue == 129 {
                let value = response["resultData"]
                if !NSDictionary(dictionary: ["value": orientation ?? NSNull()]).isEqual(to: ["value": value ?? NSNull()]) { revision += 1 }
                orientation = value
            } else if kind == 5,
                      let object = response["associatedTranslationObject"] as? [String: Any], let id = uint(object["objectID"]),
                      let attributes = response["resultData"] as? [String: Any] {
                var node = nodes[id] ?? Node()
                for (key, value) in attributes {
                    let raw = try AXValues.json(value)
                    if !NSDictionary(dictionary: ["value": node.raw[key] ?? NSNull()]).isEqual(to: ["value": raw]) || node.raw[key] == nil { revision += 1 }
                    node.raw[key] = raw
                    switch Int(key) {
                    case 3, 33:
                        // Reproject the latest valid source; attribute 33 has priority.
                        node.fields["label"] = node.raw["33"] as? String ?? node.raw["3"] as? String
                    case 6: node.fields["bundle_id"] = raw
                    case 23: node.fields["hint"] = raw
                    case 25: node.fields["identifier"] = raw
                    case 42: node.fields["placeholder"] = raw
                    case 53: node.fields["value"] = raw
                    case 120: node.fields["url"] = raw
                    case 8: node.children = ids(value)
                    case 9: node.visible = ids(value)
                    case 21:
                        node.fields["frame"] = AXValues.frame(value)
                    case 1:
                        let n = numbers(value)
                        if n.count == 2 { node.fields["activation_point"] = ["x": n[0], "y": n[1]] }
                    case 45: node.fields["accessibility_role"] = raw
                    case 61: node.fields["element_type"] = raw
                    case 77: node.fields["traits"] = raw
                    case 78: node.fields["trait_names"] = raw
                    case 26, 27, 28, 30:
                        let names = [26: "is_accessibility_element", 27: "enabled", 28: "focused", 30: "selected"]
                        if let key = Int(key), let n = value as? NSNumber { node.fields[names[key]!] = n.boolValue }
                    default: break
                    }
                }
                nodes[id] = node
                guard nodes.count <= 50_000 else { throw AXDTX.Failure("AX element limit exceeded") }
            }
        }
    }

    func json(device: String) -> [String: Any] {
        var elements: [[String: Any]] = [], visited: Set<UInt64> = []
        var stack: [(UInt64, Int?, Int)] = roots.reversed().map { ($0.0, nil, 0) }
        while let (id, parent, depth) = stack.popLast() {
            guard visited.insert(id).inserted, let node = nodes[id] else { continue }
            var fields = node.fields
            fields["object_id"] = "o\(id)"; fields["parent"] = parent.map { $0 as Any } ?? NSNull()
            fields["depth"] = depth; fields["role"] = role(id, node.fields)
            fields["raw_attributes"] = node.raw
            let index = elements.count
            elements.append(fields)
            // A reported empty visible set means no visible children, not unknown visibility.
            let children = includeOffscreen || node.raw["9"] == nil ? node.children : node.visible
            stack += children.reversed().map { ($0, index, depth + 1) }
        }
        let unresolved = nodes.keys.sorted().flatMap { id in
            Set(nodes[id]!.children + nodes[id]!.visible).sorted().filter { nodes[$0] == nil }.map { child in
                ["parent_id": "o\(id)", "child_id": "o\(child)"]
            }
        }
        let missingFrames = elements.filter { $0["frame"] == nil }.compactMap { $0["object_id"] as? String }
        let unreturned: [[String: Any]] = nodes.keys.sorted().filter { !visited.contains($0) }.map { id in
            var fields = nodes[id]!.fields
            fields["object_id"] = "o\(id)"; fields["raw_attributes"] = nodes[id]!.raw
            return fields
        }
        let apps: [[String: Any]] = roots.map { id, pid in
            var app: [String: Any] = ["object_id": "o\(id)"]
            if let pid { app["pid"] = pid }
            if let label = nodes[id]?.fields["label"] { app["name"] = label }
            if let bundle = nodes[id]?.fields["bundle_id"] { app["bundle_id"] = bundle }
            return app
        }
        return ["source": "accessibility", "device": device, "elements": elements, "applications": apps,
                "foreground_app": apps.count == 1 ? apps[0] : NSNull(), "orientation": orientation ?? NSNull(),
                "coordinate_space": "ax_native", "include_offscreen": includeOffscreen,
                "snapshot_complete": false, "transport": "coredevice-rsd", "scope": "received-ax-hierarchy",
                "hierarchy_complete": false, "unreturned_elements": unreturned,
                "coverage": ["nodes_received": nodes.count, "nodes_returned": elements.count,
                             "nodes_with_frame": elements.count - missingFrames.count,
                             "missing_frame_ids": missingFrames, "unresolved_children": unresolved,
                             "children_not_reported_ids": nodes.keys.sorted().filter { nodes[$0]!.raw["8"] == nil }.map { "o\($0)" },
                             "active_attribute_query_performed": false]]
    }

    private func role(_ id: UInt64, _ fields: [String: Any]) -> String {
        if roots.contains(where: { $0.0 == id }) { return "Application" }
        let traits = uint(fields["traits"]) ?? 0
        for (bit, role) in [(5, "Key"), (10, "SearchField"), (18, "TextField"), (53, "Switch"),
                            (12, "Adjustable"), (1, "Link"), (0, "Button")] {
            if traits & (UInt64(1) << bit) != 0 { return role }
        }
        let roles = [2: "Button", 3: "Switch", 6: "StaticText", 8: "Link", 13: "Adjustable", 14: "StaticText", 15: "TextField"]
        if let number = fields["accessibility_role"] as? NSNumber, let role = roles[number.intValue] { return role }
        if traits & (1 << 2) != 0 { return "Image" }
        if traits & ((1 << 6) | (1 << 16)) != 0 { return "StaticText" }
        return "Other"
    }

    private func uint(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0,
              n.doubleValue.isFinite, n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
        return UInt64(n.stringValue)
    }
    private func ids(_ value: Any) -> [UInt64] {
        (value as? [Any] ?? []).compactMap { uint($0) ?? uint(($0 as? [String: Any])?["objectID"]) }
    }
    private func numbers(_ value: Any) -> [Double] {
        guard let text = value as? String else { return [] }
        return text.components(separatedBy: CharacterSet(charactersIn: "0123456789.eE+-").inverted)
            .compactMap(Double.init).filter(\.isFinite)
    }
}
