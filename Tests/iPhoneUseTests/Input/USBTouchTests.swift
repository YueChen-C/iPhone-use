import Darwin
import XCTest
@testable import iPhoneUse

final class USBTouchTests: XCTestCase {
    func testDiscoveryAndReportsShareTheUniversalHIDEnvelope() throws {
        let bytes = Data([1, 2, 3])
        let payload: [String: USBXPCValue] = ["send": .dictionary(["_0": .data(bytes), "_1": .uint(42)])]
        let request = USBTouchSession.hidRequest(payload)
        XCTAssertEqual(Set(request.keys), ["featureIdentifier", "messageType", "payload"])
        guard case .text(let feature)? = request["featureIdentifier"],
              case .text(let message)? = request["messageType"],
              case .dictionary(let body)? = request["payload"] else { return XCTFail("Invalid HID envelope") }
        XCTAssertEqual(feature, "com.apple.coredevice.feature.remote.universalhidservice")
        XCTAssertEqual(message, "Request")
        XCTAssertEqual(USBXPCValue.dictionary(body).encode(), USBXPCValue.dictionary(payload).encode())
    }

    func testWindowPressCannotQueueBehindAdmittedOperations() throws {
        var admission = USBWindowInputAdmission()
        let first = try XCTUnwrap(admission.beginOperation())
        let queued = try XCTUnwrap(admission.beginOperation())
        XCTAssertFalse(admission.beginWindow())
        admission.finishOperation(first)
        XCTAssertFalse(admission.beginWindow())
        admission.finishOperation(queued)
        XCTAssertTrue(admission.beginWindow())
        XCTAssertNil(admission.beginOperation())
        XCTAssertFalse(admission.beginWindow())
    }

    func testWindowUpKeepsAdmissionClosedUntilItsReleaseCompletes() throws {
        var admission = USBWindowInputAdmission()
        XCTAssertTrue(admission.beginWindow())
        let release = try XCTUnwrap(admission.endWindow())
        XCTAssertFalse(admission.held)
        XCTAssertTrue(admission.releasing)
        XCTAssertFalse(admission.beginWindow())
        XCTAssertNil(admission.beginOperation())
        XCTAssertNil(admission.endWindow())
        admission.finishRelease(UUID())
        XCTAssertTrue(admission.releasing)
        admission.finishRelease(release)
        XCTAssertTrue(admission.beginWindow())
    }

    func testCancelReleaseCannotBeClearedByOldUpOrOldOperation() throws {
        var admission = USBWindowInputAdmission()
        XCTAssertTrue(admission.beginWindow())
        let old = try XCTUnwrap(admission.endWindow())
        let cancel = admission.cancelWindow()
        admission.finishRelease(old)
        admission.finishOperation(UUID())
        XCTAssertFalse(admission.beginWindow())
        XCTAssertNil(admission.beginOperation())
        admission.finishRelease(cancel)
        XCTAssertNotNil(admission.beginOperation())
    }

    func testRejectedWindowPressHasNoMatchingUpAndDoesNotCancelOperation() throws {
        var admission = USBWindowInputAdmission()
        let operation = try XCTUnwrap(admission.beginOperation())
        XCTAssertFalse(admission.beginWindow())
        XCTAssertNil(admission.endWindow())
        XCTAssertFalse(admission.releasing)
        XCTAssertFalse(admission.beginWindow())
        admission.finishOperation(operation)
        XCTAssertTrue(admission.beginWindow())
    }

    func testWindowAdmissionIsIndependentPerDeviceAndTracksOutstandingWork() throws {
        var first = USBWindowInputAdmission(), second = USBWindowInputAdmission()
        let operation = try XCTUnwrap(first.beginOperation())
        XCTAssertTrue(second.beginWindow())
        first.clearWindow() // Session failure must not erase an outstanding queue reservation.
        XCTAssertFalse(first.beginWindow())
        first.finishOperation(operation)
        XCTAssertTrue(first.beginWindow())
        XCTAssertTrue(second.held)
    }

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

final class USBTransportTests: XCTestCase {
    private final class Stream: AXByteStream {
        var incoming: Data
        var sent: [Data] = []
        var onSend: ((Data) -> Void)?
        init(_ frames: Data) { incoming = frames }
        func read(_ count: Int) throws -> Data {
            guard count <= incoming.count else { throw AXDTX.Failure("fixture EOF") }
            let bytes = Data(incoming.prefix(count)); incoming = Data(incoming.dropFirst(count)); return bytes
        }
        func send(_ data: Data) { sent.append(data); onSend?(data) }
    }
    func testWrapperBytesAndFragmentedMultiplexedReplies() throws {
        let answer = USBRemoteXPC.wrapper(.dictionary(["ok": .bool(true)]), id: 2)
        XCTAssertEqual(Array(answer.prefix(8)), [0x92, 0x0b, 0xb0, 0x29, 1, 0, 0, 0])
        XCTAssertEqual(try AXDTX.integer(answer, 16, 8), 2)
        let stream = Stream(AXRSD.frame(type: 4)
            + AXRSD.frame(type: 0, stream: 1, data: Data(answer.prefix(17)))
            + AXRSD.frame(type: 0, stream: 3, data: USBRemoteXPC.wrapper(nil))
            + AXRSD.frame(type: 0, stream: 1, data: Data(answer.dropFirst(17)) + answer))
        let client = try USBRemoteXPC(socket: stream)
        XCTAssertEqual(try client.request([:])["ok"] as? Bool, true)
        stream.incoming += AXRSD.frame(type: 0, stream: 1)
        XCTAssertEqual(try client.request([:])["ok"] as? Bool, true)
        let requests = stream.sent.filter { $0.count > 32 && $0[3] == 0 && (try? AXDTX.integer($0, 13)) == 0x10101 }
        XCTAssertEqual(try requests.map { try AXDTX.integer($0, 25, 8) }, [1, 3])
    }
    func testUSBHeaderOnlyKeepaliveIsNotAnObjectButRSDRemainsStrict() throws {
        let header = AXDTX.number(0x29b00b92) + AXDTX.number(1) + AXDTX.number(8, bytes: 8)
            + AXDTX.number(0, bytes: 8) + AXDTX.number(0x42133742) + AXDTX.number(5)
        let answer = USBRemoteXPC.wrapper(.dictionary(["ok": .bool(true)]))
        let stream = Stream(AXRSD.frame(type: 4) + AXRSD.frame(type: 0, stream: 1, data: header + answer))
        XCTAssertEqual(try USBRemoteXPC(socket: stream).request([:])["ok"] as? Bool, true)
        var buffer = header
        XCTAssertThrowsError(try AXRSD.decodeWrapper(&buffer))
    }
    func testPingAcknowledgesControlAndDataWithoutClaimingUIAcceptance() throws {
        let stream = Stream(AXRSD.frame(type: 4))
        let client = try USBRemoteXPC(socket: stream)
        stream.onSend = { packet in
            if packet.count == 17, packet[3] == 6, packet[4] == 0 {
                stream.incoming += AXRSD.frame(type: 4)
                    + AXRSD.frame(type: 6, data: Data(repeating: 7, count: 8))
                    + AXRSD.frame(type: 0, stream: 3, data: Data([1, 2]))
                    + AXRSD.frame(type: 6, flags: 1, data: Data(packet.dropFirst(9)))
            }
        }
        defer { stream.onSend = nil }
        try client.ping()
        XCTAssertTrue(stream.sent.contains(AXRSD.frame(type: 6, flags: 1, data: Data(repeating: 7, count: 8))))
        for id: UInt32 in [0, 3] {
            XCTAssertTrue(stream.sent.contains(AXRSD.frame(type: 8, stream: id, data: Data([0, 0, 0, 2]))))
        }
    }
    func testRSDDiscoveryUsesSameFragmentDecoderButKeepsServiceSelection() throws {
        let answer = USBRemoteXPC.wrapper(.dictionary(["Services": .dictionary([:])]))
        let stream = Stream(AXRSD.frame(type: 4) + AXRSD.frame(type: 6, data: Data(repeating: 1, count: 8))
            + AXRSD.frame(type: 0, stream: 1, data: Data(answer.prefix(20)))
            + AXRSD.frame(type: 0, stream: 3, data: USBRemoteXPC.wrapper(nil))
            + AXRSD.frame(type: 0, stream: 1, data: Data(answer.dropFirst(20))))
        XCTAssertNotNil(try AXRSD.discover(socket: stream)["Services"] as? [String: Any])
        XCTAssertTrue(stream.sent.contains(AXRSD.frame(type: 4, flags: 1)))
        XCTAssertTrue(stream.sent.contains(AXRSD.frame(type: 6, flags: 1, data: Data(repeating: 1, count: 8))))
    }
    func testMalformedWrapperAndClosedStreamFailWithoutRetry() throws {
        for frame in [AXRSD.frame(type: 0, stream: 1, data: Data(repeating: 0, count: 24)),
                      AXRSD.frame(type: 3, stream: 1), AXRSD.frame(type: 7)] {
            let stream = Stream(AXRSD.frame(type: 4) + frame)
            let client = try USBRemoteXPC(socket: stream)
            XCTAssertThrowsError(try client.request([:]))
            XCTAssertTrue(stream.incoming.isEmpty)
        }
    }
    func testOwnedSocketBoundsBidirectionalIOAndDescriptorCleanup() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        XCTAssertEqual(fcntl(pair[0], F_SETFL, O_NONBLOCK), 0)
        var stream: AXSocket? = try AXSocket(taking: pair[0])
        XCTAssertEqual(fcntl(pair[0], F_GETFL, 0) & O_NONBLOCK, 0)
        let bytes = Data([1, 2, 3, 4])
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.send(pair[1], $0.baseAddress, 4, 0) }, 4)
        XCTAssertEqual(try stream?.read(4), bytes)
        XCTAssertEqual(try stream?.read(0), Data())
        XCTAssertThrowsError(try stream?.read(-1)); XCTAssertThrowsError(try stream?.read(AXDTX.limit + 1))
        try stream?.send(bytes)
        var reply = Data(count: 4)
        XCTAssertEqual(reply.withUnsafeMutableBytes { Darwin.recv(pair[1], $0.baseAddress, 4, 0) }, 4)
        XCTAssertEqual(reply, bytes)
        stream = nil
        XCTAssertEqual(fcntl(pair[0], F_GETFL, 0), -1); XCTAssertEqual(errno, EBADF)
        let invalidFD = dup(STDOUT_FILENO)
        XCTAssertThrowsError(try AXSocket(taking: invalidFD))
        XCTAssertEqual(fcntl(invalidFD, F_GETFL, 0), -1); XCTAssertEqual(errno, EBADF)
    }
}
