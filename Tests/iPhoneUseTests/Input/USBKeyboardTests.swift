import XCTest
@testable import iPhoneUse

final class USBKeyboardTests: XCTestCase {
    func testWindowKeyboardBackpressureReservesWholeEventsAndBoundsRepeat() throws {
        let gate = USBKeyboardGate()
        XCTAssertNil(gate.begin(strokes: 0)); XCTAssertNil(gate.begin(strokes: -1))
        XCTAssertNil(gate.begin(strokes: 33))
        let first = try XCTUnwrap(gate.begin(strokes: 31))
        XCTAssertNil(gate.begin(strokes: 2)) // Not a partial two-stroke event.
        let last = try XCTUnwrap(gate.begin(strokes: 1))
        for _ in 0..<10_000 { XCTAssertNil(gate.begin(strokes: 1)) }
        gate.finish(first)
        XCTAssertNotNil(gate.begin(strokes: 31)); XCTAssertNil(gate.begin(strokes: 1))
        gate.finish(last); XCTAssertNotNil(gate.begin(strokes: 1))
    }
    func testWindowKeyboardExpiryUsesMonotonicClockBeforeDispatch() throws {
        var time = 7.0
        let gate = USBKeyboardGate(now: { time })
        let ticket = try XCTUnwrap(gate.begin(strokes: 1))
        time = 7.5; XCTAssertTrue(gate.isCurrent(ticket))
        time = 7.501; XCTAssertFalse(gate.isCurrent(ticket))
        gate.finish(ticket); XCTAssertNotNil(gate.begin(strokes: 32))
    }
    func testWindowKeyboardCancelInvalidatesOldTicketsWithoutFreeingNewOnes() throws {
        let gate = USBKeyboardGate()
        let old = try XCTUnwrap(gate.begin(strokes: 32))
        gate.cancel(); XCTAssertFalse(gate.isCurrent(old))
        let current = try XCTUnwrap(gate.begin(strokes: 32))
        gate.finish(old); XCTAssertTrue(gate.isCurrent(current)); XCTAssertNil(gate.begin(strokes: 1))
        gate.finish(current); gate.finish(current); XCTAssertNotNil(gate.begin(strokes: 32))
    }
    func testReportIsBitmapNotBootKeyboardAndIncludesModifierUsages() throws {
        let report = try USBKeyboardReport.encode(code: 4, modifiers: 0x8A)
        XCTAssertEqual(report.count, 31)
        XCTAssertEqual(report[0], 1); XCTAssertEqual(report[1], 0x10)
        XCTAssertEqual(report[29], 0x8A); XCTAssertEqual(report[30], 0)
        XCTAssertEqual(try USBKeyboardReport.encode(), Data([1] + Array(repeating: 0, count: 30)))
        for invalid: UInt8 in [0, 1, 2, 3, 0xE0, 0xFF] {
            XCTAssertThrowsError(try USBKeyboardReport.encode(code: invalid))
        }
    }
    func testDynamicKeyboardDiscoveryUsesOriginalUsageAndRejectsAmbiguity() throws {
        let keyboard: [String: Any] = ["_ServiceID": 918, "PrimaryUsage": 0, "PrimaryUsagePage": 0,
            "DeviceTypeHint": "Keyboard", "_CoreDevice_codablePropertyStorage": [
                "UniversalControlVirtualService": ["bool": true], "_CoreDevice_originalUsages": ["array": [
                    ["dictionary": ["DeviceUsagePage": ["int": 1], "DeviceUsage": ["int": 6]]]]]]]
        XCTAssertEqual(USBTouchSession.keyboardSurface(["connectedServices": [keyboard]]), 918)
        XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": [keyboard, keyboard]]))
        var wrong = keyboard; wrong["DeviceTypeHint"] = "Digitizer"
        XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": [wrong]]))
        wrong = keyboard; wrong["_CoreDevice_codablePropertyStorage"] = [:]
        XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": [wrong]]))
    }
    func testModifierReleaseOrderAndNoHeldKeysAfterSuccess() throws {
        var reports: [Data] = []
        let state = USBKeyboardState(send: { reports.append($0) }, sleep: { _ in })
        try state.press(.init(code: 4, modifiers: 0x0A), interrupted: { false })
        XCTAssertEqual(reports.map { $0[29] }, [0x0A, 0x0A, 0x0A, 0])
        XCTAssertEqual(reports.map { $0[1] }, [0, 0x10, 0, 0])
        XCTAssertTrue(state.releaseConfirmed)
        state.cancel(); XCTAssertEqual(reports.count, 4)
    }
    func testPartialDownOnlyAttemptsReleaseNeverReplaysKey() {
        var reports: [Data] = []
        let state = USBKeyboardState(send: { data in
            reports.append(data)
            if data[1] != 0 { throw AXDTX.Failure("partial down") }
        }, sleep: { _ in })
        XCTAssertThrowsError(try state.press(.init(code: 4), interrupted: { false }))
        XCTAssertEqual(reports.map { $0[1] }, [0x10, 0]); XCTAssertTrue(state.releaseConfirmed)
    }
    func testFailedReleaseCannotBeOverwrittenOrReportedAsConfirmed() {
        var count = 0
        let state = USBKeyboardState(send: { _ in count += 1; throw AXDTX.Failure("transport") }, sleep: { _ in })
        XCTAssertThrowsError(try state.press(.init(code: 4), interrupted: { false }))
        XCTAssertFalse(state.releaseConfirmed); XCTAssertEqual(count, 2)
        state.cancel()
        XCTAssertThrowsError(try state.press(.init(code: 5), interrupted: { false }))
        XCTAssertEqual(count, 2)
    }
    func testCancelAfterModifierBeforeKeyOnlyReleases() {
        var reports: [Data] = []
        let state = USBKeyboardState(send: { reports.append($0) }, sleep: { _ in })
        XCTAssertThrowsError(try state.press(.init(code: 4, modifiers: 8), interrupted: { !reports.isEmpty }))
        XCTAssertEqual(reports.map { $0[29] }, [8, 0]); XCTAssertTrue(reports.allSatisfy { $0[1] == 0 })
    }
    func testRequestPreflightsAllKeysAndBoundsBeforeAnyInput() throws {
        let valid = USBKeyboardStroke(code: 4)
        try USBTouchRequest.validate("keyboard", points: [], duration: 0, strokes: [valid])
        XCTAssertThrowsError(try USBTouchRequest.validate("keyboard", points: [], duration: 0))
        XCTAssertThrowsError(try USBTouchRequest.validate("keyboard", points: [], duration: 1, strokes: [valid]))
        XCTAssertThrowsError(try USBKeyboardRequest.validate(Array(repeating: valid, count: 513)))
        XCTAssertThrowsError(try USBKeyboardRequest.validate([valid, .init(code: 0xFF)]))
        XCTAssertThrowsError(try USBKeyboardRequest.text("abc🙂"))
        XCTAssertThrowsError(try USBKeyboardRequest.key("unknown-key", modifiers: []))
        XCTAssertNil(KeyboardMap.code(for: "")); XCTAssertNil(KeyboardMap.code(for: "unknown-key"))
        let report = try USBKeyboardRequest.text("Aa!")
        XCTAssertEqual(report.map(\.modifiers), [2, 0, 2])
    }
    func testSessionSerialKeyboardAcknowledgesAfterReleaseAndPing() throws {
        var keys: [Data] = [], touches = 0, pings = 0
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 7, keyboardSurface: 22,
            readDisplay: { (1170, 2532) }, ping: { pings += 1 }, send: { _, _ in touches += 1 },
            sendKeyboard: { keys.append($0) })
        try session.execute("keyboard", points: [], duration: 0, strokes: [.init(code: 4)])
        XCTAssertEqual(keys.map { $0[1] }, [0x10, 0]); XCTAssertEqual(touches, 0); XCTAssertEqual(pings, 1)
        try session.finish(); XCTAssertEqual(pings, 2)
    }
    func testTouchOnlySessionRemainsUsableAndRejectsKeyboardWithoutSending() throws {
        var touches = 0
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 7,
            readDisplay: { (1170, 2532) }, ping: {}, send: { _, _ in touches += 1 })
        XCTAssertThrowsError(try session.execute("keyboard", points: [], duration: 0, strokes: [.init(code: 4)]))
        XCTAssertEqual(touches, 0)
        try session.execute("down", points: [.init(x: 0.2, y: 0.3)], duration: 0)
        XCTAssertThrowsError(try session.execute("keyboard", points: [], duration: 0, strokes: [.init(code: 4)]))
        try session.finish(); XCTAssertEqual(touches, 2)
    }
    func testFailedKeyboardReleaseAlsoGatesTouchAndFinish() throws {
        var touches = 0, pings = 0
        let session = USBTouchSession(physicalID: "fixture", dimensions: (1170, 2532), surface: 7, keyboardSurface: 22,
            readDisplay: { (1170, 2532) }, ping: { pings += 1 }, send: { _, _ in touches += 1 },
            sendKeyboard: { _ in throw AXDTX.Failure("transport failed") })
        XCTAssertThrowsError(try session.execute("keyboard", points: [], duration: 0, strokes: [.init(code: 4)]))
        XCTAssertThrowsError(try session.execute("down", points: [.init(x: 0.2, y: 0.3)], duration: 0))
        XCTAssertThrowsError(try session.finish())
        XCTAssertEqual(touches, 0); XCTAssertEqual(pings, 0)
    }
    func testAtomicTypeOptionsReuseNativeKeyboardWithoutBLE() throws {
        let request = try TypeTextRequest(["text": "USB!", "clear_before": true, "press_enter": true])
        let strokes = try request.usbStrokes(ocr: nil)
        XCTAssertEqual(strokes.count, 7)
        XCTAssertEqual(strokes[0], .init(code: 4, modifiers: 8))
        XCTAssertEqual(strokes[1].code, 0x2A); XCTAssertEqual(strokes.last?.code, 0x28)
        XCTAssertThrowsError(try TypeTextRequest(["text": String(repeating: "a", count: 512), "clear_before": true]).usbStrokes(ocr: nil))
        let clipboard = try TypeTextRequest(["text": "🙂", "use_clipboard": true])
        XCTAssertEqual(try clipboard.usbStrokes(ocr: nil), [.init(code: 0x19, modifiers: 8)])
        XCTAssertFalse(try USBKeyboardRequest.text("你好", convertHanzi: true).isEmpty)
    }
    func testCompactPinyinMarkerTogglesBeforeAtomicASCIIEdit() throws {
        let marker = ScreenOCR.Item(text: "拼", x: 521, y: 1433)
        let ocr = ScreenOCR.Result(width: 740, height: 1600, items: [marker])
        let request = try TypeTextRequest(["text": "native", "clear_before": true])
        let expected = [try USBKeyboardRequest.key("space", modifiers: ["control"])]
            + (try request.usbStrokes(ocr: nil))
        XCTAssertEqual(try request.usbStrokes(ocr: ocr), expected)

        // App text and hidden/unknown keyboards are not input-mode evidence.
        let outside = ScreenOCR.Result(width: 740, height: 1600,
            items: [.init(text: "拼", x: 521, y: 100)])
        XCTAssertEqual(try request.usbStrokes(ocr: outside), try request.usbStrokes(ocr: nil))
        let clipboard = try TypeTextRequest(["text": "native", "use_clipboard": true])
        XCTAssertEqual(try clipboard.usbStrokes(ocr: ocr), try clipboard.usbStrokes(ocr: nil))
    }
}
