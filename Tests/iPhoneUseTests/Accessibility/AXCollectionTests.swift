import Foundation
import XCTest
@testable import iPhoneUse

final class AXCollectionTests: XCTestCase {
    private func message(_ responses: [[String: Any]]) throws -> AXDTX.Message {
        let data = try NSKeyedArchiver.archivedData(withRootObject:
            ["associatedRequestType": 11, "resultData": ["treeDump": responses]], requiringSecureCoding: false)
        let packet = try AXDTX.call(id: 9, selector: "update", argument: data)
        var offset = 0
        return try AXDTX.receive { count in
            defer { offset += count }
            return packet.subdata(in: offset..<offset + count)
        }
    }
    private func attributes(_ id: Int, _ fields: [String: Any]) -> [String: Any] {
        ["associatedRequestType": 5, "associatedTranslationObject": ["objectID": id], "resultData": fields]
    }
    func testCollectMergesLaterGeometryUnknownAttributesAndMissingChildren() throws {
        let first = try message([
            ["associatedRequestType": 4, "resultData": ["objectID": 1, "pid": 42]],
            attributes(1, ["8": [2, 3], "3": "Example"]), attributes(2, ["33": "Send"])
        ])
        let second = try message([attributes(2, ["21": "{{10, 20}, {30, 40}}", "7777": Data([1, 2, 3]), "53": Data([4, 5])]),
                                  attributes(4, ["33": "unlinked"]), attributes(3, ["8": [5]])])
        var packets = [first, second], reads = 0
        let result = try NativeAXTree.collect(device: "phone", includeOffscreen: true, send: { _ in }, next: { _ in
            reads += 1
            return packets.isEmpty ? nil : packets.removeFirst()
        })
        let elements = try XCTUnwrap(result["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual((elements[1]["frame"] as? [String: Double])?["x"], 10)
        let raw = try XCTUnwrap(elements[1]["raw_attributes"] as? [String: Any])
        XCTAssertEqual((raw["7777"] as? [String: String])?["value"], "AQID")
        let coverage = try XCTUnwrap(result["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["nodes_received"] as? Int, 4)
        XCTAssertEqual(coverage["nodes_with_frame"] as? Int, 1)
        XCTAssertEqual((coverage["unresolved_children"] as? [[String: String]])?.first?["child_id"], "o5")
        XCTAssertEqual((result["unreturned_elements"] as? [[String: Any]])?.first?["object_id"] as? String, "o4")
        XCTAssertEqual((result["capture"] as? [String: Any])?["messages_received"] as? Int, 2)
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
        XCTAssertEqual(result["snapshot_complete"] as? Bool, false)
    }
    func testDeadlineReturnsObservedPartialAndUnsubscribes() throws {
        let packet = try message([["associatedRequestType": 4, "resultData": ["objectID": 1]],
                                  attributes(1, ["8": [2]]), attributes(2, ["33": "Send"])])
        var now: TimeInterval = 0, count = 0, sent: [String] = []
        let result = try NativeAXTree.collect(device: "phone", includeOffscreen: false, send: {
            if let selector = try AXDTX.object(Data($0.dropFirst(32))) as? String { sent.append(selector) }
        }, next: { _ in count += 1; now = 10; return packet }, clock: { now }, maximumDuration: 1)
        XCTAssertEqual(count, 1)
        XCTAssertEqual((result["capture"] as? [String: Any])?["termination_reason"] as? String, "capture-deadline")
        XCTAssertEqual(sent.last, "clientNeedsAccessibility:")
        XCTAssertEqual(sent.count, 3)
    }
    func testReceiveTimeoutAtBudgetIsNotMislabelledQuiet() throws {
        let packet = try message([["associatedRequestType": 4, "resultData": ["objectID": 1]],
                                  attributes(1, ["8": [2]]), attributes(2, ["33": "Send"])])
        var now: TimeInterval = 0, count = 0
        let result = try NativeAXTree.collect(device: "phone", includeOffscreen: false, send: { _ in }, next: { _ in
            count += 1
            if count == 1 { now = 0.9; return packet }
            now = 1; return nil
        }, clock: { now }, maximumDuration: 1)
        XCTAssertEqual((result["capture"] as? [String: Any])?["termination_reason"] as? String, "capture-deadline")
    }
    func testDuplicateUpdatesDoNotResetQuietWindow() throws {
        let p = try message([["associatedRequestType": 4, "resultData": ["objectID": 1]],
                             attributes(1, ["8": [2]]), attributes(2, ["33": "Send"])])
        var now: TimeInterval = 0, count = 0
        let result = try NativeAXTree.collect(device: "phone", includeOffscreen: false, send: { _ in }, next: { _ in
            count += 1; now += 0.4; return p
        }, clock: { now })
        XCTAssertEqual(count, 3)
        XCTAssertEqual((result["capture"] as? [String: Any])?["termination_reason"] as? String, "quiet-window")
    }
    func testErrorAfterFirstUsableTreeIsNotSilentlyReportedAsComplete() throws {
        let p = try message([["associatedRequestType": 4, "resultData": ["objectID": 1]],
                             attributes(1, ["8": [2]]), attributes(2, ["33": "Send"])])
        var count = 0, sends = 0
        XCTAssertThrowsError(try NativeAXTree.collect(device: "phone", includeOffscreen: false, send: { _ in sends += 1 }, next: { _ in
            count += 1
            if count == 1 { return p }
            throw AXDTX.Failure("broken wire")
        }))
        XCTAssertEqual(sends, 3)
    }
    func testMessageReaderTimeoutPreservesExactlyOnePendingRead() throws {
        let gate = DispatchSemaphore(value: 0)
        let count = NSLock()
        var reads = 0
        let reader = AXMessageReader {
            count.lock(); reads += 1; count.unlock()
            _ = gate.wait(timeout: .now() + 2)
            return AXDTX.Message(identifier: 5, conversation: 0, channel: 0, expectsReply: false, payload: Data())
        }
        XCTAssertNil(try reader.next(timeout: 0.01))
        XCTAssertNil(try reader.next(timeout: 0.01))
        count.lock(); let actual = reads; count.unlock()
        XCTAssertEqual(actual, 1)
        gate.signal()
        XCTAssertEqual(try reader.next(timeout: 1)?.identifier, 5)
    }
    func testJSONSafeValuesAndStrictGeometry() throws {
        let value = try AXValues.json(["bytes": Data([1]), "unknown": [NSNull(), 3]]) as? [String: Any]
        XCTAssertNotNil(value)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(value!))
        XCTAssertNil(AXValues.frame("caption 1, 2, 3, 4"))
        XCTAssertNil(AXValues.frame("{{0, 0}, {-1, 5}}"))
        XCTAssertNil(AXValues.frame(["x": true, "y": 0, "width": 2, "height": 3]))
        XCTAssertEqual(AXValues.frame("{{-2.5, 4}, {30, 20}}")?["x"], -2.5)
        XCTAssertThrowsError(try AXValues.json(Double.infinity))
    }
}
