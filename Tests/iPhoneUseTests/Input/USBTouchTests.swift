import XCTest
@testable import iPhoneUse

final class USBTouchTests: XCTestCase {
    func testRequestValidationRejectsInvalidDurationPathAndOperation() throws {
        let a = USBTouchPoint(x: 0.2, y: 0.4), b = USBTouchPoint(x: 0.2, y: 0.6)
        for duration in [-1, 60.01, Double.nan, .infinity] {
            XCTAssertThrowsError(try USBTouchRequest.validate("tap", points: [a], duration: duration))
        }
        for count in [0, 1, 2049] {
            XCTAssertThrowsError(try USBTouchRequest.validate("swipe", points: Array(repeating: a, count: count), duration: 0.3))
        }
        XCTAssertThrowsError(try USBTouchRequest.validate("swipe", points: [a, b], duration: 0))
        for operation in ["tap", "down", "move", "up"] {
            XCTAssertThrowsError(try USBTouchRequest.validate(operation, points: [], duration: 0))
            XCTAssertThrowsError(try USBTouchRequest.validate(operation, points: [a, b], duration: 0))
        }
        XCTAssertThrowsError(try USBTouchRequest.validate("hover", points: [a], duration: 0))
        XCTAssertThrowsError(try USBTouchRequest.validate("cancel", points: [a], duration: 0))
        XCTAssertThrowsError(try USBTouchRequest.validate("swipe", points: [a, .init(x: 2, y: 0.5)], duration: 0.3))
        try USBTouchRequest.validate("tap", points: [a], duration: 0)
        try USBTouchRequest.validate("tap", points: [a], duration: 60)
        try USBTouchRequest.validate("swipe", points: Array(repeating: b, count: 2048), duration: 60)
        try USBTouchRequest.validate("cancel", points: [], duration: 0)
    }

    func testInvalidRequestHasNoDisplayOrContactSideEffectsAndValidRequestStillWorks() throws {
        var checks = 0, pings = 0
        var reports: [(USBTouchPoint, Bool)] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 99,
            readDisplay: { checks += 1; return (1170, 2532) }, ping: { pings += 1 },
            send: { reports.append(($0, $1)) })
        let point = USBTouchPoint(x: 0.5, y: 0.3)
        XCTAssertThrowsError(try session.execute("tap", points: [point], duration: 61))
        XCTAssertThrowsError(try session.execute("swipe", points: Array(repeating: point, count: 2049), duration: 0.3))
        XCTAssertEqual(checks, 0); XCTAssertEqual(pings, 0); XCTAssertTrue(reports.isEmpty)
        try session.execute("down", points: [point], duration: 0)
        try session.execute("up", points: [point], duration: 0)
        XCTAssertEqual(checks, 1); XCTAssertEqual(pings, 1)
        XCTAssertEqual(reports.map(\.1), [true, false])
    }

    func testContinuousDragRechecksDisplayWithoutIdleTickAndReleasesLastSafePoint() throws {
        var time = 0.0, rotated = false, checks = 0
        var reports: [(USBTouchPoint, Bool)] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 99,
            readDisplay: { checks += 1; if rotated { throw AXDTX.Failure("fixture landscape") }; return (1170, 2532) },
            ping: {}, send: { reports.append(($0, $1)) }, now: { time })
        let first = USBTouchPoint(x: 0.2, y: 0.4), last = USBTouchPoint(x: 0.2, y: 0.5)
        try session.execute("down", points: [first], duration: 0)
        for index in 1...100 { time = Double(index) / 1000; try session.execute("move", points: [last], duration: 0) }
        XCTAssertEqual(checks, 1) // No per-move RPC while cached validation is fresh.
        rotated = true; time = 0.51
        XCTAssertThrowsError(try session.execute("move", points: [.init(x: 0.8, y: 0.8)], duration: 0))
        XCTAssertEqual(checks, 2); XCTAssertEqual(reports.last?.0, last); XCTAssertEqual(reports.last?.1, false)
        XCTAssertFalse(reports.contains { $0.0 == USBTouchPoint(x: 0.8, y: 0.8) })
        try session.finish()
    }
    func testContinuousDragEnforcesMonotonicHeldDeadlineWithoutIdleTick() throws {
        var time = 0.0, sent: [Bool] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 99,
            readDisplay: { (1170, 2532) }, ping: {}, send: { _, down in sent.append(down) }, now: { time })
        let point = USBTouchPoint(x: 0.3, y: 0.5)
        try session.execute("down", points: [point], duration: 0)
        time = 61
        XCTAssertThrowsError(try session.execute("move", points: [point], duration: 0))
        XCTAssertEqual(sent, [true, false]); try session.finish()
    }
    func testDisplaySizeChangeOnUpStillReleasesPreviousPoint() throws {
        var dimensions = (1170, 2532), time = 0.0
        var reports: [(USBTouchPoint, Bool)] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: dimensions, surface: 99,
            readDisplay: { dimensions }, ping: {}, send: { reports.append(($0, $1)) }, now: { time })
        let point = USBTouchPoint(x: 0.2, y: 0.3)
        try session.execute("down", points: [point], duration: 0)
        dimensions = (2532, 1170); time = 0.6
        XCTAssertThrowsError(try session.execute("up", points: [.init(x: 0.9, y: 0.9)], duration: 0))
        XCTAssertEqual(reports.map(\.0), [point, point]); XCTAssertEqual(reports.map(\.1), [true, false])
    }
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
    func testFailedCancelCannotBeAcknowledgedByPingOrOverwrittenByAnotherContact() throws {
        var allowRelease = false, pings = 0, sent: [Bool] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 99,
            readDisplay: { (1170, 2532) }, ping: { pings += 1 }, send: { _, down in
                sent.append(down)
                if !down && !allowRelease { throw AXDTX.Failure("fixture failed release") }
            })
        let point = USBTouchPoint(x: 0.5, y: 0.3)
        try session.execute("down", points: [point], duration: 0)
        XCTAssertThrowsError(try session.execute("cancel", points: [], duration: 0))
        XCTAssertEqual(pings, 0); XCTAssertEqual(sent, [true, false])
        allowRelease = true // Recovery of the transport is not proof of prior release.
        XCTAssertThrowsError(try session.execute("down", points: [point], duration: 0))
        XCTAssertThrowsError(try session.execute("tap", points: [point], duration: 0))
        XCTAssertThrowsError(try session.execute("cancel", points: [], duration: 0))
        XCTAssertThrowsError(try session.finish())
        XCTAssertEqual(sent, [true, false]); XCTAssertEqual(pings, 0)
    }
    func testSuccessfulAndIdleCancelConfirmReleaseAndPermitExplicitNextContact() throws {
        var pings = 0, sent: [Bool] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 99,
            readDisplay: { (1170, 2532) }, ping: { pings += 1 }, send: { _, down in sent.append(down) })
        let point = USBTouchPoint(x: 0.5, y: 0.3)
        try session.execute("cancel", points: [], duration: 0)
        XCTAssertTrue(sent.isEmpty); XCTAssertEqual(pings, 1)
        try session.execute("down", points: [point], duration: 0)
        try session.execute("cancel", points: [], duration: 0)
        try session.execute("down", points: [point], duration: 0)
        try session.execute("up", points: [point], duration: 0)
        XCTAssertEqual(sent, [true, false, true, false]); XCTAssertEqual(pings, 3)
    }
    func testCancelPingFailureDoesNotAcknowledgeAnOtherwiseSentRelease() throws {
        var sent: [Bool] = []
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 99,
            readDisplay: { (1170, 2532) }, ping: { throw AXDTX.Failure("fixture ping failure") },
            send: { _, down in sent.append(down) })
        let point = USBTouchPoint(x: 0.5, y: 0.3)
        try session.execute("down", points: [point], duration: 0)
        XCTAssertThrowsError(try session.execute("cancel", points: [], duration: 0))
        XCTAssertEqual(sent, [true, false])
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
