import XCTest
@testable import iPhoneUse

final class USBTouchTests: XCTestCase {
    private func displayAnswer(size: [NSNumber] = [NSNumber(value: UInt64(1170)), NSNumber(value: UInt64(2532))],
                               orientation: String = "rot0", backlight: String = "activeOn") -> [String: Any] {
        ["CoreDevice.output": ["backlightState": backlight, "displays": [
            ["primary": true, "external": false, "currentOrientation": orientation,
             "nativeOrientation": "rot0", "currentMode": ["size": size]]]]]
    }
    func testUnsignedXPCDisplayDimensionsAreAccepted() throws {
        let dimensions = try USBTouchSession.displayDimensions(displayAnswer())
        XCTAssertEqual(dimensions.0, 1170); XCTAssertEqual(dimensions.1, 2532)
    }
    func testDisplayDimensionsRejectInvalidNumbersAndUnsafeDisplayState() {
        for size: [NSNumber] in [[0, 2532], [1170, 1170], [2532, 1170], [1170, 9000],
                                 [NSNumber(value: UInt64.max), 2532], [1170.5, 2532],
                                 [NSNumber(value: Double.nan), 2532], [1170]] {
            XCTAssertThrowsError(try USBTouchSession.displayDimensions(displayAnswer(size: size)))
        }
        XCTAssertThrowsError(try USBTouchSession.displayDimensions(displayAnswer(orientation: "rot90")))
        XCTAssertThrowsError(try USBTouchSession.displayDimensions(displayAnswer(backlight: "off")))
    }
    func testSelectionDeniesBothTransportsUntilReleaseAndInvalidatesOldBLELease() {
        var selection = InputBackendSelection()
        let oldBLE = selection.generation
        XCTAssertTrue(selection.permits(.ble, generation: oldBLE))
        let usb = selection.begin(.usb)
        XCTAssertFalse(selection.permits(.ble)); XCTAssertFalse(selection.permits(.usb))
        selection.finish(usb, released: true)
        XCTAssertTrue(selection.permits(.usb, generation: usb))
        let ble = selection.begin(.ble)
        selection.finish(usb, released: true)
        XCTAssertFalse(selection.permits(.ble)); XCTAssertTrue(selection.transitioning)
        selection.finish(ble, released: true)
        XCTAssertTrue(selection.permits(.ble, generation: ble))
        XCTAssertFalse(selection.permits(.ble, generation: oldBLE))
    }
    func testUnconfirmedReleaseFailsClosedAndRequiresAnotherExplicitSelection() {
        var selection = InputBackendSelection()
        let token = selection.begin(.usb)
        selection.finish(token, released: false)
        XCTAssertFalse(selection.permits(.usb)); XCTAssertFalse(selection.permits(.ble))
        XCTAssertNotNil(selection.failure)
        let retry = selection.begin(.usb)
        XCTAssertFalse(selection.permits(.usb))
        selection.finish(retry, released: true)
        XCTAssertTrue(selection.permits(.usb))
    }
    func testWheelBackpressureDropsBacklogAndOldCompletionCannotClearNewGesture() throws {
        let gate = USBWheelGate()
        let first = try XCTUnwrap(gate.begin())
        for _ in 0..<1000 { XCTAssertNil(gate.begin()) }
        gate.cancel(); XCTAssertFalse(gate.isCurrent(first))
        let second = try XCTUnwrap(gate.begin())
        gate.finish(first); XCTAssertNil(gate.begin())
        gate.finish(second); XCTAssertNotNil(gate.begin())
    }
    func testFailedReleaseIsNotReportedAsConfirmed() throws {
        let contact = USBTouchContact { _, down in if !down { throw AXDTX.Failure("synthetic release failure") } }
        try contact.down(.init(x: 0.5, y: 0.5))
        contact.cancel(); XCTAssertFalse(contact.releaseConfirmed)
        contact.cancel(); XCTAssertFalse(contact.releaseConfirmed)
    }
    func testBLEBackendRetirementReleasesAndRejectsStaleInput() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), sleep: { _ in },
                                reportSender: { reports.append(($0, $1)) })
        input.press(x: 0.5, y: 0.5)
        XCTAssertTrue(input.releaseForBackendSwitch())
        XCTAssertTrue(input.isRetired)
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.map { $0.1[0] }, [0, 1, 0])
        let count = reports.count
        input.press(x: 0.2, y: 0.3)
        XCTAssertThrowsError(try input.tap(x: 0.2, y: 0.3))
        XCTAssertEqual(reports.count, count)
    }
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
