import Foundation

/// iOS 15/16 expose the audit inspector, not the iOS 17+ remoteAXService.
/// Walk inspector focus without activation actions. The legacy daemon may scroll
/// to the focused element; callers must not assume this leaves the viewport fixed.
/// Hierarchy is retained only where the device actually provides it;
/// missing parents/frames stay absent.
final class AXLegacyTree {
    private let send: (Data) throws -> Void
    private let receive: (Int) throws -> Data
    private var nextID: UInt32 = 100
    private var app: [String: Any]?
    private var pendingFocus: [[String: Any]] = []
    private var indices: [Data: Int] = [:]
    private var elements: [[String: Any]] = []
    private var attributeReads = 0

    static func advertisedAttributes(_ focus: [String: Any]) -> [String] {
        let sections = focus["InspectorSectionsValue_v1"] as? [[String: Any]] ?? []
        var result: [String] = []
        for section in sections {
            for fields in section["ElementAttributesValue_v1"] as? [[String: Any]] ?? [] {
                guard let name = fields["AttributeNameValue_v1"] as? String, !name.isEmpty, name.utf8.count <= 256,
                      let action = fields["PerformsActionValue_v1"] as? NSNumber, !action.boolValue,
                      !name.hasPrefix("AXAction-"), !name.hasPrefix("AXCustomAction-"),
                      !result.contains(name) else { continue }
                result.append(name)
            }
        }
        return result
    }

    static func geometry(_ attributes: [String: Any]) -> [String: Double]? {
        // Only explicit geometry attributes, not audit-issue rectangles, captions,
        // pointer highlights or arbitrary numeric descriptions.
        for key in ["Frame", "AXFrame", "accessibilityFrame"] {
            if let value = attributes[key], let frame = AXValues.frame(value) { return frame }
        }
        return nil
    }

    init(send: @escaping (Data) throws -> Void, receive: @escaping (Int) throws -> Data) {
        self.send = send; self.receive = receive
    }

    static func unwrap(_ value: Any, depth: Int = 0) throws -> Any {
        guard depth < 64 else { throw AXDTX.Failure("Legacy AX wrapper nesting limit") }
        if let fields = value as? [String: Any] {
            if fields["ObjectType"] is String {
                return try fields["Value"].map { try unwrap($0, depth: depth + 1) } ?? NSNull()
            }
            return try fields.mapValues { try unwrap($0, depth: depth + 1) }
        }
        if let array = value as? [Any] { return try array.map { try unwrap($0, depth: depth + 1) } }
        return value
    }

    static func wrap(_ value: Any) -> [String: Any] { ["ObjectType": "passthrough", "Value": value] }

    private func command(_ selector: String, _ arguments: [Any] = [], reply: Bool = false) throws -> UInt32 {
        let id = nextID; nextID += 1
        try send(AXDTX.call(id: id, selector: selector, arguments: arguments, reply: reply))
        return id
    }

    private func message() throws -> (AXDTX.Message, Any?, [[String: Any]]) {
        let message = try AXDTX.receive(read: receive)
        let object = try AXDTX.object(message.payload)
        let args = try AXDTX.auxiliaryArchives(message.payload).map { try AXArchive($0).decode() }
        if message.expectsReply {
            guard object as? String == "hostApiVersion" else {
                throw AXDTX.Failure("Unsupported legacy AX host callback")
            }
            try send(AXDTX.response(to: message, object: 6))
        }
        if object as? String == "hostAppStateChanged:", let arg = args.first,
           let state = try Self.unwrap(arg) as? [String: Any], (state["state"] as? NSNumber)?.intValue == 8 {
            var selected: [String: Any] = [:]
            selected["pid"] = state["pid"]; selected["bundle_id"] = state["displayID"]
            selected["name"] = state["appName"]
            app = selected
        }
        if let name = object as? String,
           ["hostInspectorCurrentElementChanged:", "hostInspectorCurrentElementPropertiesChanged:"].contains(name),
           let raw = args.first, var fields = try Self.unwrap(raw) as? [String: Any] {
            guard pendingFocus.count < 512 else { throw AXDTX.Failure("Legacy AX focus event limit") }
            fields["_event"] = name
            pendingFocus.append(fields)
        }
        return (message, object, args.compactMap { $0 as? [String: Any] })
    }

    private func request(_ selector: String, _ arguments: [Any] = []) throws -> Any? {
        let id = try command(selector, arguments, reply: true)
        for _ in 0..<4096 {
            let (m, object, _) = try message()
            if m.identifier == id, m.conversation == 1, m.channel == 0 {
                guard [UInt64(0), 3].contains(try AXDTX.integer(m.payload, 0) & 0xff) else {
                    throw AXDTX.Failure("Legacy AX request failed: \(selector)")
                }
                return object
            }
        }
        throw AXDTX.Failure("Legacy AX reply limit: \(selector)")
    }

    private func focus(first: Bool, target: Data? = nil) throws -> [String: Any] {
        for _ in 0..<4096 {
            if pendingFocus.isEmpty { _ = try message() }
            guard !pendingFocus.isEmpty else { continue }
            let fields = pendingFocus.removeFirst()
            guard first || fields["_event"] as? String == "hostInspectorCurrentElementChanged:",
                  let element = fields["ElementValue_v1"] as? [String: Any],
                  let token = element["PlatformElementValue_v1"] as? Data, !token.isEmpty else { continue }
            if let target, target != token { continue }
            return fields
        }
        throw AXDTX.Failure("Legacy AX focus response limit")
    }

    private func elementEnvelope(_ fields: [String: Any]) throws -> [String: Any] {
        guard let token = fields["PlatformElementValue_v1"] as? Data, !token.isEmpty, token.count <= 1024 else {
            throw AXDTX.Failure("Invalid legacy AX element token")
        }
        return ["ObjectType": "AXAuditElement_v1", "Value": Self.wrap(["PlatformElementValue_v1": Self.wrap(token)])]
    }

    private func attribute(_ element: [String: Any], _ name: String) throws -> Any? {
        let attr: [String: Any] = ["ObjectType": "AXAuditElementAttribute_v1",
                                  "Value": Self.wrap(["AttributeNameValue_v1": Self.wrap(name)])]
        return try request("deviceElement:valueForAttribute:", [element, attr]).map { try Self.unwrap($0) }
    }

    private func appendHierarchy(_ value: Any, parent: Int? = nil, depth: Int = 0, ancestors: Set<Data> = []) throws {
        guard depth < 64, elements.count < 2048,
              let node = value as? [String: Any], let element = node["AuditElementValue_v1"] as? [String: Any],
              let token = element["PlatformElementValue_v1"] as? Data, !token.isEmpty else {
            throw AXDTX.Failure("Invalid/oversized legacy AX hierarchy")
        }
        guard !ancestors.contains(token) else { return }
        let index: Int
        if let existing = indices[token] { index = existing }
        else {
            index = elements.count; indices[token] = index
            elements.append(["object_id": "legacy-\(index)", "depth": depth,
                             "parent": parent.map { $0 as Any } ?? NSNull(), "role": "Other"])
        }
        var result = elements[index]
        result["raw_hierarchy_node"] = try AXValues.json(node.filter { $0.key != "ChildrenValue_v1" })
        result["description"] = node["HumanReadableDescriptionValue_v1"]
        result["role_description"] = node["HumanReadableRoleDescriptionValue_v1"]
        if let ignored = node["IsIgnoredValue_v1"] as? NSNumber { result["is_accessibility_element"] = !ignored.boolValue }
        elements[index] = result
        for child in node["ChildrenValue_v1"] as? [Any] ?? [] {
            try appendHierarchy(child, parent: index, depth: depth + 1, ancestors: ancestors.union([token]))
        }
    }

    func read(device: String, includeOffscreen: Bool) throws -> [String: Any] {
        guard !includeOffscreen else {
            throw AXDTX.Failure("include_offscreen=true is unsupported by the iOS 15/16 audit inspector")
        }
        _ = try command("_notifyOfPublishedCapabilities:", [["com.apple.private.DTXBlockCompression": 0,
                                                           "com.apple.private.DTXConnection": 1]])
        // The daemon asks hostApiVersion on connection; request() services that
        // callback while waiting, including a fully archived API version reply.
        _ = try request("deviceInspectorShowVisuals:", [0])
        var cleanedUp = false
        defer {
            if !cleanedUp {
                _ = try? command("deviceSetAppMonitoringEnabled:", [false])
                _ = try? command("devicePerformFinalCleanup")
            }
        }
        _ = try request("deviceSetAppMonitoringEnabled:", [true])
        _ = try request("deviceInspectorSetMonitoredEventType:", [0])
        guard let first = try request("deviceFetchSpecialElement:", [0]),
              let fields = try Self.unwrap(first) as? [String: Any],
              let firstToken = fields["PlatformElementValue_v1"] as? Data, !firstToken.isEmpty else {
            throw AXDTX.Failure("Legacy AX inspector returned no first element; unlock the iPhone")
        }
        _ = try command("deviceInspectorFocusOnElement:", [try elementEnvelope(fields)])
        var current = try focus(first: true, target: firstToken)
        var focusTokens: Set<Data> = []
        let started = ProcessInfo.processInfo.systemUptime
        var reason = "focus-limit", traversalComplete = false
        for _ in 0..<512 {
            guard let element = current["ElementValue_v1"] as? [String: Any],
                  let token = element["PlatformElementValue_v1"] as? Data else {
                throw AXDTX.Failure("Invalid legacy AX focus")
            }
            if !focusTokens.insert(token).inserted {
                guard !elements.isEmpty else { throw AXDTX.Failure("Legacy AX inspector returned no hierarchy") }
                traversalComplete = token == firstToken
                reason = traversalComplete ? "returned-to-first" : "revisited-focus-node"
                break
            }
            if ProcessInfo.processInfo.systemUptime - started > 12 || attributeReads >= 4096 {
                reason = "capture-budget"
                break
            }
            let envelope = try elementEnvelope(element)
            guard let hierarchy = try attribute(envelope, "_AXHierarchyElementsAttribute") else {
                throw AXDTX.Failure("Legacy AX inspector did not provide hierarchy")
            }
            try appendHierarchy(hierarchy)
            guard let index = indices[token] else {
                throw AXDTX.Failure("Legacy AX hierarchy contains no element")
            }
            elements[index]["raw_inspector_focus"] = try AXValues.json(current.filter { $0.key != "_event" })
            let advertised = Self.advertisedAttributes(current)
            var names: [String] = []
            for name in ["Label", "Value", "Identifier", "Hint", "Traits"] + advertised where !names.contains(name) { names.append(name) }
            var raw: [String: Any] = ["_AXHierarchyElementsAttribute": try AXValues.json(hierarchy)]
            var unavailable: [String] = [], deferred: [String] = []
            for name in names where name != "_AXHierarchyElementsAttribute" {
                if ProcessInfo.processInfo.systemUptime - started > 12 || attributeReads >= 4096 {
                    deferred.append(name); continue
                }
                attributeReads += 1
                let value = try attribute(envelope, name) ?? NSNull()
                raw[name] = try AXValues.json(value)
                if value is NSNull { unavailable.append(name) }
                else {
                    let keys = ["Label": "label", "Value": "value", "Identifier": "identifier", "Hint": "hint", "Traits": "traits"]
                    if let key = keys[name] { elements[index][key] = try AXValues.json(value) }
                }
            }
            elements[index]["raw_attributes"] = raw
            elements[index]["attribute_status"] = ["advertised_readable": advertised,
                                                   "unavailable": unavailable, "deferred": deferred]
            if let frame = Self.geometry(raw) {
                elements[index]["frame"] = frame
                elements[index]["geometry_source"] = "advertised-attribute"
            }
            if let traits = elements[index]["traits"] as? NSNumber {
                let bits = traits.uint64Value
                for (bit, role) in [(5, "Key"), (10, "SearchField"), (18, "TextField"), (53, "Switch"),
                                    (12, "Adjustable"), (1, "Link"), (0, "Button"), (2, "Image"), (6, "StaticText")] {
                    if bits & (UInt64(1) << bit) != 0 { elements[index]["role"] = role; break }
                }
            }
            if elements[index]["label"] == nil { elements[index]["description"] = current["CaptionTextValue_v1"] }
            let options = Self.wrap(["direction": Self.wrap(4), "includeContainers": Self.wrap(1), "allowNonAX": Self.wrap(0)])
            pendingFocus.removeAll()
            _ = try command("deviceInspectorMoveWithOptions:", [options])
            current = try focus(first: false)
        }
        guard !elements.isEmpty else { throw AXDTX.Failure("Legacy AX inspector returned no hierarchy") }
        _ = try request("deviceSetAppMonitoringEnabled:", [false])
        _ = try request("devicePerformFinalCleanup")
        cleanedUp = true
        let missingFrames = elements.filter { $0["frame"] == nil }.compactMap { $0["object_id"] as? String }
        let uninspected = elements.filter { $0["raw_attributes"] == nil }.compactMap { $0["object_id"] as? String }
        let apps = app.map { [$0] } ?? []
        return ["source": "accessibility", "device": device, "elements": elements,
                "applications": apps, "foreground_app": app.map { $0 as Any } ?? NSNull(), "orientation": NSNull(),
                "coordinate_space": "ax_native", "include_offscreen": false, "snapshot_complete": false,
                "transport": "lockdown-audit", "scope": "inspector-focusable-elements",
                "hierarchy_complete": false, "geometry_available": missingFrames.count < elements.count,
                "text_may_be_truncated": true, "cleanup_acknowledged": true,
                "inspector_focus_changed": true, "viewport_may_change": true,
                "geometry_simultaneous": false, "traversal_complete": traversalComplete,
                "termination_reason": reason,
                "coverage": ["nodes_received": elements.count, "nodes_with_frame": elements.count - missingFrames.count,
                             "missing_frame_ids": missingFrames, "uninspected_ids": uninspected,
                             "attribute_reads": attributeReads,
                             "geometry_capability": missingFrames.count == elements.count ? "not-observed" : "observed-per-focus"]]
    }
}
