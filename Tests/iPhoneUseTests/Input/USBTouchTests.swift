import XCTest
@testable import iPhoneUse

final class USBTouchTests: XCTestCase {
    func testWireReportMatchesVerifiedLayout() throws {
        let down = try USBTouchWire.report(x: 0.5, y: 1, touching: true, timestamp: 0x010203040506)
        let up = try USBTouchWire.report(x: 0.5, y: 1, touching: false, timestamp: 0x010203040506)
        XCTAssertEqual(down.count, 58)
        XCTAssertEqual(Array(down.prefix(8)), [9, 1, 5, 0xc2, 0, 128, 255, 255])
        XCTAssertEqual(Array(down[44..<50]), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(up[3], 2)
        XCTAssertEqual(up[4..<8], down[4..<8])
        for invalid in [Double.nan, .infinity, -0.1, 1.01] {
            XCTAssertThrowsError(try USBTouchWire.report(x: invalid, y: 0.5, touching: true, timestamp: 0))
        }
    }
    func testMouseContactDownDragUpAndHoverIsNeverSent() throws {
        var sent: [(USBTouchPoint, Bool)] = []
        let contact = USBTouchContact { sent.append(($0, $1)) }
        let a = USBTouchPoint(x: 0.2, y: 0.3), b = USBTouchPoint(x: 0.8, y: 0.7)
        XCTAssertThrowsError(try contact.move(a))
        XCTAssertTrue(sent.isEmpty)
        try contact.down(a); try contact.move(b); try contact.up(b)
        XCTAssertEqual(sent.map(\.0), [a, b, b])
        XCTAssertEqual(sent.map(\.1), [true, true, false])
        XCTAssertNil(contact.point)
        contact.cancel(); XCTAssertEqual(sent.count, 3)
    }
    func testCancelReleasesLastPointExactlyOnce() throws {
        var sent: [(USBTouchPoint, Bool)] = []
        let contact = USBTouchContact { sent.append(($0, $1)) }
        let a = USBTouchPoint(x: 0.2, y: 0.3), b = USBTouchPoint(x: 0.8, y: 0.7)
        try contact.down(a); try contact.move(b); contact.cancel(); contact.cancel()
        XCTAssertEqual(sent.map(\.0), [a, b, b])
        XCTAssertEqual(sent.map(\.1), [true, true, false])
    }
    func testPartialContactFailureOnlyAttemptsReleaseNeverReplaysContact() {
        var touching: [Bool] = []
        let contact = USBTouchContact { _, down in
            touching.append(down)
            if down { throw AXDTX.Failure("synthetic partial write") }
        }
        XCTAssertThrowsError(try contact.down(.init(x: 0.5, y: 0.5)))
        XCTAssertEqual(touching, [true, false])
        XCTAssertNil(contact.point)
    }
    func testInvalidDragPreservesLastKnownReleasePosition() throws {
        var sent: [(USBTouchPoint, Bool)] = []
        let contact = USBTouchContact { sent.append(($0, $1)) }
        let a = USBTouchPoint(x: 0.2, y: 0.3)
        try contact.down(a)
        XCTAssertThrowsError(try contact.move(.init(x: .nan, y: 0)))
        contact.cancel()
        XCTAssertEqual(sent.map(\.0), [a, a])
        XCTAssertEqual(sent.map(\.1), [true, false])
    }
    func testTouchscreenSelectedFromCapabilitiesNotHardcodedSurface() throws {
        let screen: [String: Any] = ["PrimaryUsagePage": 13, "PrimaryUsage": 4,
                                    "UniversalControlBuiltIn": true, "_ServiceID": 999]
        let keyboard: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "_ServiceID": 512]
        XCTAssertEqual(try USBTouchSession.touchscreen(["connectedServices": [screen, keyboard]]), 999)
        XCTAssertThrowsError(try USBTouchSession.touchscreen(["connectedServices": [screen, screen]]))
        XCTAssertThrowsError(try USBTouchSession.touchscreen(["connectedServices": [keyboard]]))
    }
    func testBackendMCPTranslationAndValidation() throws {
        let request = try XCTUnwrap(MCPToolRequest.action(named: "set_input_backend",
            arguments: ["backend": "usb", "device_id": "DEVICE"], longEdge: 1000))
        XCTAssertEqual(request.path, "/input/backend")
        XCTAssertEqual(request.body["backend"] as? String, "usb")
        XCTAssertEqual(request.body["device"] as? String, "DEVICE")
        XCTAssertThrowsError(try MCPToolRequest.action(named: "set_input_backend",
            arguments: ["backend": "auto"], longEdge: 1000))
    }
    func testBackendAPIRejectsInvalidModeBeforeDeviceDiscovery() {
        let response = ControlAPI.handle(.init(method: "POST", path: "/input/backend", query: [:], body: ["backend": "auto"]))
        XCTAssertEqual(response.status, 400)
    }
}
