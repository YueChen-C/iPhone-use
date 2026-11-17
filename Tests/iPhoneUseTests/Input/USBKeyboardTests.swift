import AppKit
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
        let strokes = try request.usbStrokes()
        XCTAssertEqual(strokes.count, 7)
        XCTAssertEqual(strokes[0], .init(code: 4, modifiers: 8))
        XCTAssertEqual(strokes[1].code, 0x2A); XCTAssertEqual(strokes.last?.code, 0x28)
        XCTAssertThrowsError(try TypeTextRequest(["text": String(repeating: "a", count: 512), "clear_before": true]).usbStrokes())
        let clipboard = try TypeTextRequest(["text": "🙂", "use_clipboard": true])
        XCTAssertEqual(try clipboard.usbStrokes(), [.init(code: 0x19, modifiers: 8)])
        XCTAssertFalse(try USBKeyboardRequest.text("你好", convertHanzi: true).isEmpty)
    }
    func testCompactPinyinMarkerRequiresConfirmedASCIIBeforeEditing() throws {
        let request = try TypeTextRequest(["text": "native", "clear_before": true])
        var time: TimeInterval = 10, reads = 0
        var sent: [[USBKeyboardStroke]] = []
        try request.performUSB(ocr: {
            reads += 1
            let label = reads == 1 ? "拼" : "space"
            return self.observation(self.keyboardOCR(label), at: time)
        }, sleep: { time += $0 }, now: { time }, send: { sent.append($0) })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(sent, [[try USBKeyboardRequest.key("space", modifiers: ["control"])],
                              try request.usbStrokes()])
    }

    private func keyboardOCR(_ text: String) -> ScreenOCR.Result {
        .init(width: 100, height: 100, items: [.init(text: text, x: 50, y: 90)])
    }
    private func observation(_ result: ScreenOCR.Result, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> USBKeyboardObservation {
        .init(result: result, receivedAt: time)
    }
    func testUSBToggleMustConfirmBeforeClearTextAndSubmit() throws {
        let request = try TypeTextRequest(["text": "usb", "clear_before": true, "submit": true])
        let chinese = keyboardOCR("拼")
        var sent: [[USBKeyboardStroke]] = [], reads = 0, waits: [TimeInterval] = []
        XCTAssertThrowsError(try request.performUSB(ocr: { reads += 1; return observation(chinese) },
            sleep: { waits.append($0) }, send: { sent.append($0) })) { error in
                XCTAssertTrue(error is TypeTextRequest.USBInputModeUnconfirmed)
            }
        XCTAssertEqual(sent, [[try USBKeyboardRequest.key("space", modifiers: ["control"])]])
        XCTAssertEqual(reads, 9); XCTAssertEqual(waits.count, 8)
        XCTAssertEqual(waits.reduce(0, +), 0.95, accuracy: 0.0001)
    }
    func testUSBConfirmedModeSendsOneAtomicEditAfterToggle() throws {
        let request = try TypeTextRequest(["text": "usb", "clear_before": true, "submit": true])
        let chinese = keyboardOCR("拼"), english = keyboardOCR("space")
        var sent: [[USBKeyboardStroke]] = [], reads = 0
        try request.performUSB(ocr: { reads += 1; return observation(reads < 3 ? chinese : english) },
            sleep: { _ in }, send: { sent.append($0) })
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(sent, [[try USBKeyboardRequest.key("space", modifiers: ["control"])],
                              try request.usbStrokes()])
    }
    func testUSBUnknownPostToggleModeNeverTypesOrRetriesToggle() throws {
        let request = try TypeTextRequest(["text": "usb", "clear_before": true])
        let chinese = keyboardOCR("拼")
        var sent: [[USBKeyboardStroke]] = [], reads = 0
        XCTAssertThrowsError(try request.performUSB(ocr: { reads += 1; return reads == 1 ? observation(chinese) : nil },
            sleep: { _ in }, send: { sent.append($0) }))
        XCTAssertEqual(sent, [[try USBKeyboardRequest.key("space", modifiers: ["control"])]])
    }
    func testUSBModeWaitCancellationCannotDispatchEdit() throws {
        let request = try TypeTextRequest(["text": "usb", "clear_before": true])
        let chinese = keyboardOCR("拼")
        var cancelled = false, sent: [[USBKeyboardStroke]] = []
        XCTAssertThrowsError(try request.performUSB(ocr: { observation(chinese) }, sleep: { _ in cancelled = true },
            checkCurrent: { if cancelled { throw AXDTX.Failure("stale") } },
            send: { sent.append($0) }))
        XCTAssertEqual(sent, [[try USBKeyboardRequest.key("space", modifiers: ["control"])]])
    }
    func testUSBCompletePreflightPrecedesToggleOrClipboard() throws {
        let oversized = try TypeTextRequest(["text": String(repeating: "a", count: 511), "clear_before": true])
        XCTAssertThrowsError(try oversized.performUSB(ocr: { XCTFail("before OCR"); return nil },
            sleep: { _ in XCTFail("before wait") }, clipboard: { _ in XCTFail("before clipboard") },
            send: { _ in XCTFail("before input") }))
        let chinese = keyboardOCR("拼")
        let noRoomForToggle = try TypeTextRequest(["text": String(repeating: "a", count: 510), "clear_before": true])
        XCTAssertThrowsError(try noRoomForToggle.performUSB(ocr: { observation(chinese) },
            sleep: { _ in XCTFail("before wait") }, send: { _ in XCTFail("before input") }))
        let clipboard = try TypeTextRequest(["text": "🙂", "clear_before": true, "use_clipboard": true])
        XCTAssertThrowsError(try clipboard.performUSB(ocr: { XCTFail("clipboard needs no mode"); return nil },
            clipboard: { _ in throw AXDTX.Failure("clipboard failed") }, send: { _ in XCTFail("before input") }))
    }
    func testUSBChineseModeConfirmationAndAlreadySelectedMode() throws {
        let request = try TypeTextRequest(["text": "蓝牙"])
        let english = keyboardOCR("space"), chinese = keyboardOCR("拼")
        var sent: [[USBKeyboardStroke]] = [], reads = 0
        try request.performUSB(ocr: {
            reads += 1
            return .init(result: reads == 1 ? english : chinese, receivedAt: ProcessInfo.processInfo.systemUptime,
                         firstCandidate: reads > 2 ? "蓝牙" : nil)
        },
            sleep: { _ in }, send: { sent.append($0) })
        XCTAssertEqual(sent, [[try USBKeyboardRequest.key("space", modifiers: ["control"])],
                              Array(try request.usbStrokes().dropLast()),
                              [try USBKeyboardRequest.key("space", modifiers: [])]])
        sent.removeAll()
        try request.performUSB(ocr: {
            .init(result: chinese, receivedAt: ProcessInfo.processInfo.systemUptime, firstCandidate: "蓝牙")
        }, sleep: { _ in }, send: { sent.append($0) })
        XCTAssertEqual(sent.flatMap { $0 }, try request.usbStrokes())
    }
    func testUSBFailedToggleIsNotRetriedOrFollowedByEdit() throws {
        let request = try TypeTextRequest(["text": "usb", "clear_before": true])
        let chinese = keyboardOCR("拼")
        var sends = 0
        XCTAssertThrowsError(try request.performUSB(ocr: { observation(chinese) }, sleep: { _ in XCTFail("send failed") },
            send: { _ in sends += 1; throw AXDTX.Failure("uncertain") }))
        XCTAssertEqual(sends, 1)
    }
    func testUSBFreshnessUsesMonotonicFrameTimeNotRecognitionTime() {
        let result = keyboardOCR("space")
        XCTAssertTrue(observation(result, at: 10).isFresh(at: 12))
        XCTAssertFalse(observation(result, at: 10).isFresh(at: 12.001))
        XCTAssertFalse(observation(result, at: 11).isFresh(at: 10))
        for time in [TimeInterval.nan, .infinity, -.infinity, -1] {
            XCTAssertFalse(observation(result, at: time).isFresh(at: 10))
            XCTAssertFalse(observation(result, at: 10).isFresh(at: time))
        }
        XCTAssertFalse(observation(result, at: 10).isFresh(at: 10, after: 10))
        XCTAssertTrue(observation(result, at: 10.1).isFresh(at: 10.2, after: 10))
    }
    func testUSBStaleOrMissingInitialFrameCannotToggleClearTypeOrSubmit() throws {
        let request = try TypeTextRequest(["text": "usb", "clear_before": true, "submit": true])
        let cases: [(USBKeyboardObservation?, TypeTextRequest.USBInputModeUnconfirmed.Reason)] = [
            (nil, .observationUnavailable), (observation(keyboardOCR("space"), at: 7), .observationStale),
            (observation(keyboardOCR("拼"), at: 11), .observationStale)
        ]
        for (initial, reason) in cases {
            var sends = 0
            XCTAssertThrowsError(try request.performUSB(ocr: { initial }, now: { 10 },
                send: { _ in sends += 1 })) { error in
                XCTAssertEqual((error as? TypeTextRequest.USBInputModeUnconfirmed)?.reason, reason)
            }
            XCTAssertEqual(sends, 0)
        }
    }
    func testUSBPostToggleEvidenceMustPostdateToggleAcknowledgement() throws {
        let request = try TypeTextRequest(["text": "usb", "clear_before": true, "submit": true])
        var time: TimeInterval = 10, reads = 0, sent: [[USBKeyboardStroke]] = []
        XCTAssertThrowsError(try request.performUSB(ocr: {
            reads += 1
            return self.observation(self.keyboardOCR(reads == 1 ? "拼" : "space"), at: 10)
        }, sleep: { time += $0 }, now: { time }, send: { sent.append($0) }))
        XCTAssertEqual(reads, 9)
        XCTAssertEqual(sent, [[try USBKeyboardRequest.key("space", modifiers: ["control"])]])
    }
    func testUSBFreshPostToggleFrameCanConfirmIdenticalOCRContent() throws {
        let request = try TypeTextRequest(["text": "usb"])
        var time: TimeInterval = 10, reads = 0, sent: [[USBKeyboardStroke]] = []
        try request.performUSB(ocr: {
            reads += 1
            return self.observation(self.keyboardOCR(reads == 1 ? "拼" : "space"), at: time)
        }, sleep: { time += $0 }, now: { time }, send: { sent.append($0) })
        XCTAssertEqual(reads, 2); XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last, try request.usbStrokes())
    }
    func testUSBOCRThatExpiresBeforeDispatchCannotEdit() throws {
        let request = try TypeTextRequest(["text": "usb", "clear_before": true])
        var time: TimeInterval = 10, sends = 0
        XCTAssertThrowsError(try request.performUSB(ocr: {
            self.observation(self.keyboardOCR("space"), at: 10)
        }, now: { time }, checkCurrent: { time += 1.1 }, send: { _ in sends += 1 }))
        XCTAssertEqual(sends, 0)
    }
    func testUSBUnknownInitialModeCannotClearTypeOrSubmit() throws {
        for text in ["蓝牙", "usb"] {
            let request = try TypeTextRequest(["text": text, "clear_before": true, "submit": true])
            var sends = 0
            XCTAssertThrowsError(try request.performUSB(ocr: {
                self.observation(.init(width: 100, height: 100, items: []), at: 10)
            }, sleep: { _ in XCTFail("unknown mode must not toggle") }, now: { 10 },
                send: { _ in sends += 1 })) { error in
                XCTAssertEqual((error as? TypeTextRequest.USBInputModeUnconfirmed)?.reason, .modeUnconfirmed)
            }
            XCTAssertEqual(sends, 0)
        }
    }
    func testUSBQWERTYAloneCannotProveEnglishMode() {
        let result = ScreenOCR.Result(width: 100, height: 100, items: ["q", "w", "e", "a", "s", "d"].map {
            .init(text: $0, x: 50, y: 75)
        })
        XCTAssertTrue(ChineseIMEHeuristic.isEnglish(result)) // BLE's historical heuristic stays unchanged.
        XCTAssertEqual(USBKeyboardMode.infer(result), .unknown)
    }
    func testUSBExplicitRawTextOptOutRemainsAvailable() throws {
        let request = try TypeTextRequest(["text": "蓝牙", "ensure_chinese_ime": false])
        var sent: [[USBKeyboardStroke]] = []
        try request.performUSB(ocr: { XCTFail("explicit raw pinyin"); return nil }, send: { sent.append($0) })
        XCTAssertEqual(sent, [try request.usbStrokes()])
    }
    func testUSBDetailModeCanConfirmWithoutChangingFrameTimestamp() throws {
        let request = try TypeTextRequest(["text": "safe"])
        let empty = ScreenOCR.Result(width: 100, height: 100, items: [])
        var sent: [[USBKeyboardStroke]] = []
        try request.performUSB(ocr: { .init(result: empty, receivedAt: 10, mode: .ascii) }, now: { 10 },
            send: { sent.append($0) })
        XCTAssertEqual(sent.count, 1)
        XCTAssertThrowsError(try request.performUSB(ocr: { .init(result: empty, receivedAt: 7, mode: .ascii) },
            now: { 10 }, send: { _ in XCTFail("detail pass cannot refresh stale pixels") }))
    }
    private func qwertyOCR() -> ScreenOCR.Result {
        .init(width: 740, height: 1600, items: [
            .init(text: "qwertyuiop", x: 370, y: 1105), .init(text: "asdfghjkl", x: 370, y: 1207),
            .init(text: "zxcvbnm", x: 370, y: 1310),
        ])
    }
    func testUSBDetailLegendsRequireKeyboardRowsAndExactPosition() {
        let result = qwertyOCR()
        let a = ScreenOCR.Item(text: "A", x: 521, y: 1433)
        let pinyin = ScreenOCR.Item(text: "拼", x: 521, y: 1433)
        XCTAssertTrue(USBKeyboardModeOCR.hasKeyboardRows(result))
        XCTAssertEqual(USBKeyboardModeOCR.mode(result, markers: [a]), .ascii)
        XCTAssertEqual(USBKeyboardModeOCR.mode(result, markers: [pinyin]), .chinese)
        XCTAssertEqual(USBKeyboardModeOCR.mode(result, markers: [a, pinyin]), .unknown)
        XCTAssertEqual(USBKeyboardModeOCR.mode(result, markers: [.init(text: "ABC", x: 521, y: 1433)]), .unknown)
        XCTAssertEqual(USBKeyboardModeOCR.mode(result, markers: [.init(text: "A", x: 50, y: 1105)]), .unknown)
        XCTAssertEqual(USBKeyboardModeOCR.mode(.init(width: 740, height: 1600, items: []), markers: [a]), .unknown)
        let landscape = ScreenOCR.Result(width: 1600, height: 740, items: result.items)
        XCTAssertFalse(USBKeyboardModeOCR.hasKeyboardRows(landscape))
    }

    func testUSBKeyboardFullRowAllowsOneSubstitutionButStillRequiresModeLegend() {
        func result(_ row: String) -> ScreenOCR.Result {
            .init(width: 740, height: 1600, items: [
                .init(text: "QWERT", x: 199, y: 1106), .init(text: "YUIOP", x: 539, y: 1104),
                .init(text: row, x: 368, y: 1206),
                .init(text: "Z", x: 150, y: 1307), .init(text: "X CVBNM", x: 400, y: 1308),
            ])
        }
        let merged = result("ASDFGHUKL")
        let ascii = ScreenOCR.Item(text: "A", x: 529, y: 1432)
        let pinyin = ScreenOCR.Item(text: "拼", x: 521, y: 1433)
        XCTAssertTrue(USBKeyboardModeOCR.hasKeyboardRows(merged))
        XCTAssertEqual(USBKeyboardModeOCR.mode(merged, markers: [ascii]), .ascii)
        XCTAssertEqual(USBKeyboardModeOCR.mode(merged, markers: []), .unknown)
        XCTAssertEqual(USBKeyboardModeOCR.mode(merged, markers: [ascii, pinyin]), .unknown)
        XCTAssertEqual(USBKeyboardModeOCR.mode(merged, markers: [.init(text: "A", x: 200, y: 1200)]), .unknown)
        for invalid in ["ASDFGUUKL", "ASDFGHUK", "ASDFGHUUKL", "LKJHGFDSA", "QWERTYUIO", "ADGJLSFHK"] {
            XCTAssertFalse(USBKeyboardModeOCR.hasKeyboardRows(result(invalid)), invalid)
            XCTAssertEqual(USBKeyboardModeOCR.mode(result(invalid), markers: [ascii]), .unknown)
        }
        let missingRow = ScreenOCR.Result(width: 740, height: 1600, items: Array(merged.items.dropFirst(2)))
        XCTAssertFalse(USBKeyboardModeOCR.hasKeyboardRows(missingRow))
        let moved = ScreenOCR.Result(width: 740, height: 1600,
            items: merged.items.map { .init(text: $0.text, x: $0.x, y: 300) })
        XCTAssertFalse(USBKeyboardModeOCR.hasKeyboardRows(moved))
    }

    func testUSBASCIIObservationSkipsOnlyCandidatePassAndRetainsTimestamp() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 740, pixelsHigh: 1600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 740 * 4, bitsPerPixel: 32))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for includeCandidate in [false, true] {
            let device = UUID().uuidString
            _ = ScreenOCR.recognize(data, device: device, recognition: { _ in self.qwertyOCR().items })
            var passes: [String] = []
            let observation = USBKeyboardModeOCR.observe(data, device: device, receivedAt: 10,
                includeCandidate: includeCandidate, recognizeDetail: { _, origin in
                    if origin.y > 1200 {
                        passes.append("mode")
                        return [.init(text: "拼", x: 521, y: 1433)]
                    }
                    passes.append("candidate")
                    return [.init(text: "蓝牙", x: 58, y: 1016)]
                })
            XCTAssertEqual(passes, includeCandidate ? ["mode", "candidate"] : ["mode"])
            XCTAssertEqual(observation.mode, .chinese)
            XCTAssertEqual(observation.firstCandidate, includeCandidate ? "蓝牙" : nil)
            XCTAssertEqual(observation.receivedAt, 10)
            XCTAssertFalse(observation.isFresh(at: 12.001))
            XCTAssertFalse(observation.isFresh(at: 10, after: 10))
        }
        XCTAssertFalse(try TypeTextRequest(["text": "native"]).ensureChineseIME)
        XCTAssertTrue(try TypeTextRequest(["text": "蓝牙"]).ensureChineseIME)
    }

    func testUSBCandidateMustMatchBeforeOnePlannedSpaceAndSubmit() throws {
        let request = try TypeTextRequest(["text": "蓝牙", "clear_before": true, "submit": true])
        var time = 10.0, sent: [[USBKeyboardStroke]] = [], reads = 0
        try request.performUSB(ocr: {
            reads += 1
            return .init(result: self.keyboardOCR("拼"), receivedAt: time,
                         firstCandidate: reads > 2 ? "蓝牙" : nil)
        }, sleep: { time += $0 }, now: { time }, send: { sent.append($0) })
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(sent.map(\.count), [7, 1, 1])
        XCTAssertEqual(sent.flatMap { $0 }, try request.usbStrokes())
    }
    func testUSBWrongMissingOrStaleCandidateNeverCommitsOrSubmits() throws {
        let request = try TypeTextRequest(["text": "蓝牙", "clear_before": true, "submit": true])
        for (candidate, stale) in [("栏牙", false), ("蓝牙", true), ("", false)] {
            var time = 10.0, sent: [[USBKeyboardStroke]] = [], reads = 0
            XCTAssertThrowsError(try request.performUSB(ocr: {
                reads += 1
                return .init(result: self.keyboardOCR("拼"), receivedAt: stale ? 10 : time,
                             firstCandidate: candidate)
            }, sleep: { time += $0 }, now: { time }, send: { sent.append($0) })) { error in
                XCTAssertTrue(error is TypeTextRequest.USBCandidateUnconfirmed)
            }
            XCTAssertEqual(reads, 9)
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent[0], Array(try request.usbStrokes().dropLast(2)))
        }
    }
    func testUSBCandidateWaitCancellationCannotCommitOrReplay() throws {
        let request = try TypeTextRequest(["text": "蓝牙", "submit": true])
        var sent: [[USBKeyboardStroke]] = [], cancelled = false
        XCTAssertThrowsError(try request.performUSB(ocr: { self.observation(self.keyboardOCR("拼")) },
            sleep: { _ in cancelled = true }, checkCurrent: { if cancelled { throw AXDTX.Failure("stale lease") } },
            send: { sent.append($0) }))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].count, 5)
    }
    func testUSBFirstCandidateRequiresExactSeparatedLeftHanTokenAndRows() {
        let result = qwertyOCR()
        XCTAssertEqual(USBKeyboardModeOCR.firstCandidate(result, items: [.init(text: "蓝牙", x: 58, y: 1016)]), "蓝牙")
        for items: [ScreenOCR.Item] in [
            [.init(text: "蓝牙 蓝牙耳机", x: 90, y: 1016)], [.init(text: "蓝牙耳机", x: 300, y: 1016)],
            [.init(text: "蓝牙", x: 58, y: 800)], [.init(text: "lanya", x: 58, y: 1016)],
            [.init(text: "蓝牙", x: 58, y: 1016), .init(text: "栏牙", x: 70, y: 1016)],
        ] { XCTAssertNil(USBKeyboardModeOCR.firstCandidate(result, items: items)) }
        XCTAssertNil(USBKeyboardModeOCR.firstCandidate(.init(width: 740, height: 1600, items: []),
                                                      items: [.init(text: "蓝牙", x: 58, y: 1016)]))
    }
    func testUSBMixedHanRunsKeepOriginalStrokeOrderAndSingleSpaces() throws {
        let request = try TypeTextRequest(["text": "蓝牙 USB 蓝牙!", "clear_before": true, "submit": true])
        var time = 10.0, sent: [[USBKeyboardStroke]] = []
        try request.performUSB(ocr: {
            .init(result: self.keyboardOCR("拼"), receivedAt: time, firstCandidate: "蓝牙")
        }, sleep: { time += $0 }, now: { time }, send: { sent.append($0) })
        XCTAssertEqual(sent.flatMap { $0 }, try request.usbStrokes())
        XCTAssertEqual(sent.count, 5)
        XCTAssertEqual(sent[1], [try USBKeyboardRequest.key("space", modifiers: [])])
        XCTAssertEqual(sent[3], sent[1])
    }
    func testUSBCandidateErrorHTTPContractCannotClaimNoInput() throws {
        let response = ControlAPI.handle(
            HTTPRequest(method: "GET", path: "/ocr", query: ["wake": "0"], body: [:]),
            ocrCapture: { _, _ in throw TypeTextRequest.USBCandidateUnconfirmed() })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(body["code"] as? String, "input_candidate_unconfirmed")
        XCTAssertEqual(body["textDispatched"] as? Bool, true)
        XCTAssertEqual(body["mayHaveExecuted"] as? Bool, true)
        XCTAssertEqual(body["replayAllowed"] as? Bool, false)
    }
    func testUSBObservationBudgetIsSharedByAllHanRunsAndIncludesOCR() throws {
        let request = try TypeTextRequest(["text": "蓝牙 蓝牙 蓝牙", "clear_before": true, "submit": true])
        var time = 10.0, sent: [[USBKeyboardStroke]] = [], reads = 0
        XCTAssertThrowsError(try request.performUSB(ocr: {
            reads += 1; time += 1.5
            return .init(result: self.keyboardOCR("拼"), receivedAt: time, firstCandidate: "蓝牙")
        }, sleep: { time += $0 }, now: { time }, send: { sent.append($0) })) { error in
            let value = error as? TypeTextRequest.USBObservationBudgetExceeded
            XCTAssertEqual(value?.textDispatched, true)
            XCTAssertEqual(value?.inputDispatched, true)
        }
        XCTAssertEqual(reads, 3) // Not a fresh four-second budget for each run.
        XCTAssertEqual(sent.count, 3) // First run + Space + second run, no second commit/Enter.
        XCTAssertEqual(sent[1], [try USBKeyboardRequest.key("space", modifiers: [])])
        XCTAssertFalse(sent.flatMap { $0 }.contains { $0.code == 0x28 })
    }
    func testUSBSlowInitialOCRBudgetStopsBeforeAnyInput() throws {
        let request = try TypeTextRequest(["text": "蓝牙", "clear_before": true, "submit": true])
        var time = 10.0
        XCTAssertThrowsError(try request.performUSB(ocr: {
            time += 4
            return .init(result: self.keyboardOCR("拼"), receivedAt: time)
        }, now: { time }, send: { _ in XCTFail("no clear/toggle/text/submit") })) { error in
            let value = error as? TypeTextRequest.USBObservationBudgetExceeded
            XCTAssertEqual(value?.textDispatched, false)
            XCTAssertEqual(value?.inputDispatched, false)
        }
    }
    func testUSBModeToggleConsumesSameBudgetWithoutClaimingTextSent() throws {
        let request = try TypeTextRequest(["text": "蓝牙", "clear_before": true])
        var time = 10.0, reads = 0, sent: [[USBKeyboardStroke]] = []
        XCTAssertThrowsError(try request.performUSB(ocr: {
            reads += 1; time += 2
            return .init(result: self.keyboardOCR(reads == 1 ? "space" : "拼"), receivedAt: time)
        }, sleep: { time += $0 }, now: { time }, send: { sent.append($0) })) { error in
            let value = error as? TypeTextRequest.USBObservationBudgetExceeded
            XCTAssertEqual(value?.textDispatched, false)
            XCTAssertEqual(value?.inputDispatched, true) // The single toggle DID execute.
        }
        XCTAssertEqual(sent, [[try USBKeyboardRequest.key("space", modifiers: ["control"])]])
    }
    func testUSBCandidateExpiringDuringLeaseCheckCannotSendSpaceOrSubmit() throws {
        let request = try TypeTextRequest(["text": "蓝牙", "clear_before": true, "submit": true])
        var time = 10.0, reads = 0, candidateRead = false, sent: [[USBKeyboardStroke]] = []
        XCTAssertThrowsError(try request.performUSB(ocr: {
            reads += 1; candidateRead = reads > 1
            return .init(result: self.keyboardOCR("拼"), receivedAt: time, firstCandidate: "蓝牙")
        }, sleep: { time += $0 }, now: { time }, checkCurrent: {
            if candidateRead { time += 2.1; candidateRead = false }
        }, send: { sent.append($0) })) { error in
            XCTAssertTrue(error is TypeTextRequest.USBCandidateUnconfirmed)
        }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0], Array(try request.usbStrokes().dropLast(2)))
    }
    func testUSBKeyboardTransportTimeDoesNotResetOrConsumeObservationBudget() throws {
        let request = try TypeTextRequest(["text": "蓝牙", "submit": true])
        var time = 10.0, sent: [[USBKeyboardStroke]] = []
        try request.performUSB(ocr: {
            .init(result: self.keyboardOCR("拼"), receivedAt: time, firstCandidate: "蓝牙")
        }, sleep: { time += $0 }, now: { time }, send: { sent.append($0); time += 5 })
        XCTAssertEqual(sent.flatMap { $0 }, try request.usbStrokes())
    }
    func testUSBObservationTimeoutHTTPFlagsIncludeToggleOnlyCase() throws {
        for (textSent, inputSent) in [(false, false), (false, true), (true, true)] {
            let response = ControlAPI.handle(
                HTTPRequest(method: "GET", path: "/ocr", query: ["wake": "0"], body: [:]),
                ocrCapture: { _, _ in throw TypeTextRequest.USBObservationBudgetExceeded(
                    textDispatched: textSent, inputDispatched: inputSent) })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            XCTAssertEqual(response.status, 409)
            XCTAssertEqual(body["code"] as? String, "input_observation_timeout")
            XCTAssertEqual(body["textDispatched"] as? Bool, textSent)
            XCTAssertEqual(body["mayHaveExecuted"] as? Bool, inputSent)
            XCTAssertEqual(body["replayAllowed"] as? Bool, false)
        }
    }
    func testUSBExpiredObservationWaitCannotStartAnotherOCR() throws {
        let request = try TypeTextRequest(["text": "蓝牙"])
        var time = 10.0, reads = 0, sends = 0
        XCTAssertThrowsError(try request.performUSB(ocr: {
            reads += 1
            return .init(result: self.keyboardOCR("space"), receivedAt: time)
        }, sleep: { _ in time += 4.1 }, now: { time }, send: { _ in sends += 1 })) { error in
            XCTAssertTrue(error is TypeTextRequest.USBObservationBudgetExceeded)
        }
        XCTAssertEqual(reads, 1); XCTAssertEqual(sends, 1) // Toggle only, no new OCR/edit.
    }
}
