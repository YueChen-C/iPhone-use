import Foundation
import XCTest
@testable import iPhoneUse

final class AXLegacyTreeTests: XCTestCase {
    func testVersionRoutesOnlySelectedPre17DevicesToLegacy() throws {
        for version in ["15", "15.4", "15.4.1", "16.7"] {
            XCTAssertTrue(try AXUSBProxy.usesLegacyService(version: version))
        }
        for version in ["17.0", "18.1", "26.5"] {
            XCTAssertFalse(try AXUSBProxy.usesLegacyService(version: version))
        }
        for version in ["", "abc", "14.8", "15.", "15..4", "١٥.٤", "15.4beta"] {
            XCTAssertThrowsError(try AXUSBProxy.usesLegacyService(version: version))
        }
    }

    func testDTXZeroMultipleArgumentsAndArchivedCallbackReply() throws {
        let zero = try AXDTX.call(id: 100, selector: "deviceCapabilities", reply: true)
        XCTAssertEqual(try AXDTX.integer(zero, 28), 1)
        let payload = Data(zero.dropFirst(32))
        XCTAssertTrue(try AXDTX.auxiliaryArchives(payload).isEmpty)
        XCTAssertEqual(try AXDTX.object(payload) as? String, "deviceCapabilities")
        let many = try AXDTX.call(id: 101, selector: "method::", arguments: ["one", 2])
        let args = try AXDTX.auxiliaryArchives(Data(many.dropFirst(32)))
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(try AXArchive(args[0]).decode() as? String, "one")
        let message = AXDTX.Message(identifier: 2, conversation: 0, channel: 0, expectsReply: true, payload: Data())
        let reply = try AXDTX.response(to: message, object: 6)
        XCTAssertEqual(try AXDTX.integer(reply, 20), 1)
        XCTAssertEqual(try AXDTX.object(Data(reply.dropFirst(32))) as? Int, 6)
    }

    func testWrapperDecodingAndUnsupportedOffscreenFailBeforeIO() throws {
        let wrapped = AXLegacyTree.wrap(["children": [AXLegacyTree.wrap(1)], "absent": NSNull()])
        let decoded = try XCTUnwrap(try AXLegacyTree.unwrap(wrapped) as? [String: Any])
        XCTAssertEqual(decoded["children"] as? [Int], [1])
        XCTAssertTrue(decoded["absent"] is NSNull)
        var deep: Any = 1
        for _ in 0..<70 { deep = AXLegacyTree.wrap(deep) }
        XCTAssertThrowsError(try AXLegacyTree.unwrap(deep))
        let reader = AXLegacyTree(send: { _ in XCTFail("must reject before sending") }, receive: { _ in
            XCTFail("must reject before receiving"); return Data()
        })
        XCTAssertThrowsError(try reader.read(device: "phone", includeOffscreen: true))
    }

    func testLegacyRejectsRemoteErrorReplyRatherThanReturningEmptyTree() throws {
        let payload = AXDTX.number(4) + AXDTX.number(0) + AXDTX.number(0, bytes: 8)
        let packet = AXDTX.packet(id: 101, conversation: 1, payload: payload)
        var offset = 0
        let reader = AXLegacyTree(send: { _ in }, receive: { count in
            guard count <= packet.count - offset else { throw AXDTX.Failure("fixture EOF") }
            defer { offset += count }
            return packet.subdata(in: offset..<offset + count)
        })
        XCTAssertThrowsError(try reader.read(device: "phone", includeOffscreen: false)) { error in
            XCTAssertTrue(String(describing: error).contains("Legacy AX request failed"))
        }
    }

    func testLegacySessionHandlesHostCallbackHierarchyDedupAndCleanup() throws {
        try assertLegacySession(wrapAtFirst: true)
    }

    func testLegacySessionReturnsObservedPartialTreeWhenFocusWrapsElsewhere() throws {
        try assertLegacySession(wrapAtFirst: false)
    }

    func testLegacyAdvertisedReadOnlyAttributesAndNativeGeometry() throws {
        try assertLegacySession(wrapAtFirst: true, extraAttributes: true)
    }

    func testAttributeDiscoveryNeverReadsActionAttributesOrGuessesGeometry() {
        let fields: [String: Any] = ["InspectorSectionsValue_v1": [["ElementAttributesValue_v1": [
            ["AttributeNameValue_v1": "Frame", "PerformsActionValue_v1": false],
            ["AttributeNameValue_v1": "Frame", "PerformsActionValue_v1": false],
            ["AttributeNameValue_v1": "AXAction-2010", "PerformsActionValue_v1": false],
            ["AttributeNameValue_v1": "perform", "PerformsActionValue_v1": true],
            ["AttributeNameValue_v1": "unknown-safety"]
        ]]]]
        XCTAssertEqual(AXLegacyTree.advertisedAttributes(fields), ["Frame"])
        XCTAssertNil(AXLegacyTree.geometry(["ElementRectValue_v1": "{{1, 2}, {3, 4}}"]))
        XCTAssertNil(AXLegacyTree.geometry(["Frame": "caption 1,2,3,4"]))
    }

    private func assertLegacySession(wrapAtFirst: Bool, extraAttributes: Bool = false) throws {
        var packets: [Data] = [], sent: [String] = [], attributeNames: [String] = []
        var offset = 0
        let token = Data([1, 2, 3]), child = Data([4, 5, 6])
        func envelope(_ type: String, _ value: Any) -> [String: Any] {
            ["ObjectType": type, "Value": AXLegacyTree.wrap(value)]
        }
        func element(_ token: Data) -> [String: Any] {
            envelope("AXAuditElement_v1", ["PlatformElementValue_v1": AXLegacyTree.wrap(token)])
        }
        func node(_ token: Data, children: [Any] = []) -> [String: Any] {
            envelope("AXAuditNode_v1", ["AuditElementValue_v1": element(token),
                "HumanReadableDescriptionValue_v1": AXLegacyTree.wrap("Native button"),
                "HumanReadableRoleDescriptionValue_v1": AXLegacyTree.wrap("Button"),
                "ChildrenValue_v1": AXLegacyTree.wrap(children)])
        }
        func focus(_ token: Data) throws -> Data {
            var fields: [String: Any] = ["ElementValue_v1": element(token), "CaptionTextValue_v1": AXLegacyTree.wrap("Native button")]
            if extraAttributes {
                let attrs: [[String: Any]] = [
                    ["AttributeNameValue_v1": "Frame", "PerformsActionValue_v1": false],
                    ["AttributeNameValue_v1": "VendorData", "PerformsActionValue_v1": false],
                    ["AttributeNameValue_v1": "Missing", "PerformsActionValue_v1": false],
                    ["AttributeNameValue_v1": "AXAction-2010", "PerformsActionValue_v1": true]
                ]
                fields["InspectorSectionsValue_v1"] = AXLegacyTree.wrap([["ElementAttributesValue_v1": attrs]])
            }
            return try AXDTX.call(id: 10, selector: "hostInspectorCurrentElementChanged:",
                argument: envelope("AXAuditInspectorFocus_v1", fields))
        }

        func reply(_ id: UInt32, _ value: Any?) throws -> Data {
            if let value {
                return try AXDTX.response(to: .init(identifier: id, conversation: 0, channel: 0,
                                                  expectsReply: false, payload: Data()), object: value)
            }
            return AXDTX.packet(id: id, conversation: 1,
                payload: AXDTX.number(0) + AXDTX.number(0) + AXDTX.number(0, bytes: 8))
        }
        let tree = try AXLegacyTree(send: { packet in
            let id = UInt32(try AXDTX.integer(packet, 16))
            let payload = Data(packet.dropFirst(32))
            guard let selector = try AXDTX.object(payload) as? String else { return }
            sent.append(selector)
            switch selector {
            case "_notifyOfPublishedCapabilities:":
                packets.append(try AXDTX.call(id: 2, selector: "hostApiVersion", reply: true))
            case "deviceInspectorShowVisuals:", "deviceSetAppMonitoringEnabled:",
                 "deviceInspectorSetMonitoredEventType:", "devicePerformFinalCleanup":
                if try AXDTX.integer(packet, 28) != 0 { packets.append(try reply(id, nil)) }
            case "deviceFetchSpecialElement:": packets.append(try reply(id, element(token)))
            case "deviceInspectorFocusOnElement:": packets.append(try focus(token))
            case "deviceInspectorMoveWithOptions:": packets.append(try focus(wrapAtFirst ? token : child))
            case "deviceElement:valueForAttribute:":
                let args = try AXDTX.auxiliaryArchives(payload)
                let attr = try XCTUnwrap(try AXLegacyTree.unwrap(AXArchive(args[1]).decode()) as? [String: Any])
                let name = try XCTUnwrap(attr["AttributeNameValue_v1"] as? String)
                attributeNames.append(name)
                if name == "_AXHierarchyElementsAttribute" {
                    packets.append(try reply(id, node(token, children: [node(child), node(child)])))
                } else {
                    let values: [String: Any] = ["Label": "Send", "Traits": 1, "Frame": "{{1, 2}, {3, 4}}", "VendorData": Data([7, 8])]
                    let value = values[name]
                    packets.append(try reply(id, value.map(AXLegacyTree.wrap)))
                }
            default: XCTFail("Unexpected selector: \(selector)")
            }
        }, receive: { count in
            guard let first = packets.first, count <= first.count - offset else { throw AXDTX.Failure("fixture EOF") }
            let result = first.subdata(in: offset..<offset + count); offset += count
            if offset == first.count { packets.removeFirst(); offset = 0 }
            return result
        }).read(device: "phone", includeOffscreen: false)
        let elements = try XCTUnwrap(tree["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0]["label"] as? String, "Send")
        XCTAssertEqual(elements[0]["role"] as? String, "Button")
        if wrapAtFirst { XCTAssertNil(elements[1]["label"]) }
        else { XCTAssertEqual(elements[1]["label"] as? String, "Send") }
        XCTAssertEqual(elements[1]["parent"] as? Int, 0)
        XCTAssertFalse(tree["hierarchy_complete"] as? Bool ?? true)
        XCTAssertEqual(tree["geometry_available"] as? Bool, extraAttributes)
        XCTAssertTrue(tree["cleanup_acknowledged"] as? Bool ?? false)
        XCTAssertEqual(tree["traversal_complete"] as? Bool, wrapAtFirst)
        XCTAssertEqual(tree["termination_reason"] as? String,
                       wrapAtFirst ? "returned-to-first" : "revisited-focus-node")
        XCTAssertTrue(tree["foreground_app"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(tree))
        if extraAttributes {
            XCTAssertEqual((elements[0]["frame"] as? [String: Double])?["width"], 3)
            let raw = try XCTUnwrap(elements[0]["raw_attributes"] as? [String: Any])
            XCTAssertEqual((raw["VendorData"] as? [String: String])?["value"], "Bwg=")
            XCTAssertTrue(raw["Missing"] is NSNull)
            XCTAssertFalse(attributeNames.contains("AXAction-2010"))
            XCTAssertEqual(tree["geometry_simultaneous"] as? Bool, false)
        }
        XCTAssertTrue(sent.contains("devicePerformFinalCleanup"))
        XCTAssertFalse(sent.contains { $0.contains("performAction") || $0.contains("setValue:") })
    }
}
