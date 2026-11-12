import Foundation
import XCTest
@testable import iPhoneUse

final class AXTreeTests: XCTestCase {
    func testOptionsAndMCPTranslationAreStrict() throws {
        XCTAssertFalse(try AXTreeOptions(body: [:], query: [:]).includeOffscreen)
        XCTAssertTrue(try AXTreeOptions(body: [:], query: ["include_offscreen": "1"]).includeOffscreen)
        XCTAssertFalse(try AXTreeOptions(body: ["include_offscreen": false], query: ["include_offscreen": "true"]).includeOffscreen)
        for value: Any in [1, "true", NSNull()] {
            XCTAssertThrowsError(try AXTreeOptions(body: ["include_offscreen": value], query: [:]))
        }
        XCTAssertThrowsError(try AXTreeOptions(body: [:], query: ["include_offscreen": "maybe"]))
        let action = try XCTUnwrap(MCPToolRequest.action(named: "get_ax_tree",
            arguments: ["device_id": "phone", "include_offscreen": true], longEdge: 1000))
        XCTAssertEqual(action.path, "/ax_tree")
        XCTAssertEqual(action.body["device"] as? String, "phone")
        XCTAssertEqual(action.body["include_offscreen"] as? Bool, true)
        for language: AppLanguage in [.en, .zh] {
            let tool = try XCTUnwrap(MCPToolCatalog.tools(for: language).first { $0["name"] as? String == "get_ax_tree" })
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, false)
        }
    }

    func testRemoteDiscoveryRequiresExactUDIDAndNeverFallsBack() throws {
        let list = "11111111-1111-1111-1111-111111111111 coredevice-1 iPhone\n22222222-2222-2222-2222-222222222222 ncm-2 iPhone\n33333333-3333-3333-3333-333333333333 coredevice-3 iPhone"
        XCTAssertEqual(try AXRemoteTransport.resolve(device: "target", list: list) {
            $0 == "coredevice-3" ? "target\n" : "other"
        }, "coredevice-3")
        XCTAssertThrowsError(try AXRemoteTransport.resolve(device: "missing", list: list) { _ in "other" })
        XCTAssertThrowsError(try AXRemoteTransport.resolve(device: "target", list: list) { _ in "target" })
    }

    func testFoundationArchiveDecodesAsInertValues() throws {
        let object: [String: Any] = ["label": "发送", "children": [1, 2], "data": Data([1, 2])]
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
        let decoded = try XCTUnwrap(try AXArchive(bytes).decode() as? [String: Any])
        XCTAssertEqual(decoded["label"] as? String, "发送")
        XCTAssertEqual(decoded["children"] as? [Int], [1, 2])
        XCTAssertEqual(decoded["data"] as? Data, Data([1, 2]))
        XCTAssertThrowsError(try AXArchive(Data("bad".utf8)))
    }

    func testArchiveRejectsUIDCycleAndBadIndex() throws {
        let source = try NSKeyedArchiver.archivedData(withRootObject: ["key": "value"], requiringSecureCoding: false)
        var plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: source, format: nil) as? [String: Any])
        let top = try XCTUnwrap(plist["$top"] as? [String: Any])
        var objects = try XCTUnwrap(plist["$objects"] as? [Any])
        objects[1] = top["root"]!
        plist["$objects"] = objects
        let cycle = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertThrowsError(try AXArchive(cycle).decode())
        plist["$objects"] = ["$null"]
        let invalid = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertThrowsError(try AXArchive(invalid).decode())
    }

    private func fixture() -> [String: Any] {
        ["associatedRequestType": 11, "resultData": ["treeDump": [
            ["associatedRequestType": 4, "resultData": ["objectID": 1, "pid": 42]],
            ["associatedRequestType": 2, "attribute": 129, "resultData": 1],
            ["associatedRequestType": 5, "associatedTranslationObject": ["objectID": 1],
             "resultData": ["3": "Example", "6": "example.app", "8": [2, 3], "9": [2]]],
            ["associatedRequestType": 5, "associatedTranslationObject": ["objectID": 2],
             "resultData": ["33": "发送", "77": 1, "21": "{{10, 20}, {100, 40}}", "1": "{60, 40}", "27": 1, "8": [1]]],
            ["associatedRequestType": 5, "associatedTranslationObject": ["objectID": 3],
             "resultData": ["3": "offscreen", "45": 15, "53": "draft"]],
        ]]]
    }

    func testHierarchyFieldsVisibilityAndCycleGuard() throws {
        var tree = AXTree(includeOffscreen: false)
        try tree.update(fixture())
        XCTAssertTrue(tree.ready)
        let json = tree.json(device: "phone")
        let elements = try XCTUnwrap(json["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[1]["parent"] as? Int, 0)
        XCTAssertEqual(elements[1]["role"] as? String, "Button")
        XCTAssertEqual(elements[1]["label"] as? String, "发送")
        XCTAssertEqual(elements[1]["frame"] as? [String: Double], ["x": 10, "y": 20, "width": 100, "height": 40])
        XCTAssertEqual(elements[1]["enabled"] as? Bool, true)
        XCTAssertEqual(json["coordinate_space"] as? String, "ax_native")
        XCTAssertEqual(json["snapshot_complete"] as? Bool, false)
        var all = AXTree(includeOffscreen: true)
        try all.update(fixture())
        XCTAssertEqual((all.json(device: "phone")["elements"] as? [[String: Any]])?.count, 3)
    }

    func testDTXRoundtripAndNestedAXSubscriptionReturnsTree() throws {
        let inner = try NSKeyedArchiver.archivedData(withRootObject: fixture(), requiringSecureCoding: false)
        let packet = try AXDTX.call(id: 9, selector: "update", argument: inner)
        var offset = 0
        var writes: [Data] = []
        var readPacket = false
        let json = try NativeAXTree.collect(device: "phone", includeOffscreen: false, send: { writes.append($0) }, next: { _ in
            guard !readPacket else { return nil }
            readPacket = true
            return try AXDTX.receive { size in
                guard size <= packet.count - offset else { throw AXDTX.Failure("fixture EOF") }
                defer { offset += size }
                return packet.subdata(in: offset..<offset + size)
            }
        })
        XCTAssertEqual((json["elements"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(writes.count, 3) // capabilities, subscribe, unsubscribe
        XCTAssertEqual(json["device"] as? String, "phone")
    }

    func testDTXAuxiliaryDictionaryAcceptsDeviceFlagsAndValidatesLengths() throws {
        let packet = try AXDTX.call(id: 1, selector: "update", argument: "fixture")
        let payload = Data(packet.dropFirst(32))
        let expected = try AXDTX.auxiliaryArchives(payload)
        XCTAssertEqual(expected.count, 1)
        for flags: UInt64 in [0xf0, 0x1f0, 0x79f0, 0xfffffff0] {
            var flagged = payload
            flagged.replaceSubrange(16..<20, with: AXDTX.number(flags))
            XCTAssertEqual(try AXDTX.auxiliaryArchives(flagged), expected)
        }
        for (range, value): (Range<Int>, UInt64) in [
            (16..<20, 0x79f1), // not a dictionary
            (20..<24, 1),      // reserved word
            (24..<32, 0),      // inconsistent body length
        ] {
            var invalid = payload
            invalid.replaceSubrange(range, with: AXDTX.number(value, bytes: range.count))
            XCTAssertThrowsError(try AXDTX.auxiliaryArchives(invalid))
        }
    }

    func testDTXRejectsMalformedAndOversizedMessages() throws {
        XCTAssertThrowsError(try AXDTX.receive { _ in Data(repeating: 0, count: 32) })
        var header = AXDTX.packet(id: 1, payload: Data())
        header.replaceSubrange(12..<16, with: AXDTX.number(UInt64(AXDTX.limit + 1)))
        XCTAssertThrowsError(try AXDTX.receive { _ in header })
        XCTAssertThrowsError(try AXDTX.auxiliaryArchives(Data()))
        XCTAssertThrowsError(try AXDTX.auxiliaryArchives(AXDTX.number(0) + AXDTX.number(99) + AXDTX.number(0, bytes: 8)))
    }

    func testEndpointReturnsNativeTreeAndUnavailableAs503() throws {
        let request = HTTPRequest(method: "POST", path: "/ax_tree", query: ["device": "wrong"],
                                  body: ["device": "target", "include_offscreen": true])
        let response = AXTreeEndpoint.response(request, resolve: { selector in
            XCTAssertEqual(selector, "target"); return "udid"
        }, capture: { id, offscreen in
            XCTAssertEqual(id, "udid"); XCTAssertTrue(offscreen)
            return ["source": "accessibility", "device": id, "elements": []]
        })
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["source"] as? String,
                       "accessibility")
        let failure = AXTreeEndpoint.response(request, resolve: { _ in "udid" }, capture: { _, _ in
            throw AXDTX.Failure("service unavailable")
        })
        XCTAssertEqual(failure.status, 503)
        XCTAssertTrue(String(decoding: failure.body, as: UTF8.self).contains("service unavailable"))
    }

    func testHTTPInvalidOptionsReachAXRouteInsteadOf404() {
        let response = ControlAPI.handle(HTTPRequest(method: "POST", path: "/ax_tree", query: [:],
            body: ["include_offscreen": "bad"]), ocrCapture: { _, _ in
                XCTFail("AX must never substitute OCR"); return ("", Data())
            }, axCapture: { _, _ in XCTFail("invalid options must not reach transport"); return [:] })
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("include_offscreen"))
    }


    private func projectionUpdate(_ id: Int, _ values: [String: Any]) -> [String: Any] {
        ["associatedRequestType": 11, "resultData": ["treeDump": [
            ["associatedRequestType": 5, "associatedTranslationObject": ["objectID": id], "resultData": values]
        ]]]
    }

    private func projectionTree(includeOffscreen: Bool = false) throws -> AXTree {
        var tree = AXTree(includeOffscreen: includeOffscreen)
        try tree.update(fixture())
        return tree
    }

    private func projectionIDs(_ result: [String: Any], field: String = "elements") throws -> [String] {
        try XCTUnwrap(result[field] as? [[String: Any]]).compactMap { $0["object_id"] as? String }
    }

    private func projectedLabel(_ tree: AXTree, id: String = "o3") throws -> String? {
        let elements = try XCTUnwrap(tree.json(device: "phone")["elements"] as? [[String: Any]])
        return try XCTUnwrap(elements.first { $0["object_id"] as? String == id })["label"] as? String
    }

    func testExplicitEmptyVisibilityExcludesKnownChildren() throws {
        var tree = try projectionTree()
        try tree.update(projectionUpdate(1, ["9": [Int]()]))
        let result = tree.json(device: "phone")
        XCTAssertEqual(try projectionIDs(result), ["o1"])
        XCTAssertEqual(try projectionIDs(result, field: "unreturned_elements"), ["o2", "o3"])
        XCTAssertEqual((result["coverage"] as? [String: Any])?["nodes_returned"] as? Int, 1)
        // An unrelated update must not erase the explicitly empty visible set.
        try tree.update(projectionUpdate(1, ["3": "Renamed"]))
        XCTAssertEqual(try projectionIDs(tree.json(device: "phone")), ["o1"])
        try tree.update(projectionUpdate(1, ["9": [3]]))
        XCTAssertEqual(try projectionIDs(tree.json(device: "phone")), ["o1", "o3"])
    }

    func testMissingVisibilityStillFallsBackToKnownChildren() throws {
        var tree = AXTree(includeOffscreen: false)
        try tree.update(["associatedRequestType": 11, "resultData": ["treeDump": [
            ["associatedRequestType": 4, "resultData": ["objectID": 1]],
            ["associatedRequestType": 5, "associatedTranslationObject": ["objectID": 1],
             "resultData": ["8": [2]]],
            ["associatedRequestType": 5, "associatedTranslationObject": ["objectID": 2],
             "resultData": ["3": "Child"]]
        ]]])
        XCTAssertEqual(try projectionIDs(tree.json(device: "phone")), ["o1", "o2"])
    }

    func testIncludeOffscreenIgnoresExplicitEmptyVisibility() throws {
        var tree = try projectionTree(includeOffscreen: true)
        try tree.update(projectionUpdate(1, ["9": [Int]()]))
        XCTAssertEqual(try projectionIDs(tree.json(device: "phone")), ["o1", "o2", "o3"])
    }

    func testAttribute3RefreshesPublicLabelAcrossIncrementalUpdates() throws {
        var tree = try projectionTree(includeOffscreen: true)
        for label in ["Before", "After", ""] {
            try tree.update(projectionUpdate(3, ["3": label]))
            XCTAssertEqual(try projectedLabel(tree), label)
            let elements = try XCTUnwrap(tree.json(device: "phone")["elements"] as? [[String: Any]])
            let child = try XCTUnwrap(elements.first { $0["object_id"] as? String == "o3" })
            XCTAssertEqual((child["raw_attributes"] as? [String: Any])?["3"] as? String, label)
        }
        // Application names use the same projection and must refresh as well.
        try tree.update(projectionUpdate(1, ["3": "Application After"]))
        let app = tree.json(device: "phone")["foreground_app"] as? [String: Any]
        XCTAssertEqual(app?["name"] as? String, "Application After")
    }

    func testAttribute33KeepsPriorityWhileBothSourcesKeepUpdating() throws {
        var tree = try projectionTree(includeOffscreen: true)
        try tree.update(projectionUpdate(3, ["33": "Preferred Before"]))
        try tree.update(projectionUpdate(3, ["3": "Fallback After"]))
        XCTAssertEqual(try projectedLabel(tree), "Preferred Before")
        try tree.update(projectionUpdate(3, ["33": "Preferred After"]))
        XCTAssertEqual(try projectedLabel(tree), "Preferred After")
        try tree.update(projectionUpdate(3, ["3": "Fallback Latest", "33": "Preferred Latest"]))
        XCTAssertEqual(try projectedLabel(tree), "Preferred Latest")
        try tree.update(projectionUpdate(3, ["33": ""]))
        try tree.update(projectionUpdate(3, ["3": "Must not replace an empty preferred label"]))
        XCTAssertEqual(try projectedLabel(tree), "")
    }

    func testNullOrInvalidPreferredLabelFallsBackToLatestStringSource() throws {
        var tree = try projectionTree(includeOffscreen: true)
        try tree.update(projectionUpdate(3, ["3": "Fallback Latest", "33": "Preferred"]))
        for invalid: Any in [NSNull(), 7, ["unexpected": "object"]] {
            try tree.update(projectionUpdate(3, ["33": invalid]))
            XCTAssertEqual(try projectedLabel(tree), "Fallback Latest")
        }
        try tree.update(projectionUpdate(3, ["3": "Fallback After"]))
        XCTAssertEqual(try projectedLabel(tree), "Fallback After")
        try tree.update(projectionUpdate(3, ["33": "Preferred Again"]))
        try tree.update(projectionUpdate(3, ["3": NSNull()]))
        XCTAssertEqual(try projectedLabel(tree), "Preferred Again")
        try tree.update(projectionUpdate(3, ["33": NSNull()]))
        XCTAssertNil(try projectedLabel(tree))
        try tree.update(projectionUpdate(3, ["3": "Recovered"]))
        XCTAssertEqual(try projectedLabel(tree), "Recovered")
    }
}
