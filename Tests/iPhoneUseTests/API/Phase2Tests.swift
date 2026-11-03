import AppKit
import XCTest

@testable import iPhoneUse

final class Phase2Tests: XCTestCase {
    private func image(_ gray: CGFloat = 1, width: Int = 16) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testFrameCacheAvoidsRecognitionAndSeparatesDevicesDimensionsAndPixels() throws {
        let device = UUID().uuidString
        let data = try image()
        var calls = 0
        let recognize: (CGImage) throws -> [ScreenOCR.Item] = { _ in
            calls += 1
            return [ScreenOCR.Item(text: "cached", x: 1, y: 2)]
        }
        let first = ScreenOCR.recognize(data, device: device, recognition: recognize)
        let hit = ScreenOCR.recognize(data, device: device, recognition: recognize)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(first.screenHash, hit.screenHash)
        XCTAssertEqual(hit.items.map(\.text), ["cached"])
        _ = ScreenOCR.recognize(data, device: device + "other", recognition: recognize)
        _ = ScreenOCR.recognize(try image(width: 8), device: device, recognition: recognize)
        _ = ScreenOCR.recognize(try image(0), device: device, recognition: recognize)
        XCTAssertEqual(calls, 4)
        XCTAssertNotEqual(first.screenHash, ScreenOCR.screenHash(try image(0)))
        XCTAssertNotEqual(first.screenHash, ScreenOCR.screenHash(try image(width: 8)))
        for index in 0..<8 {
            _ = ScreenOCR.recognize(data, device: device + "\(index)", recognition: recognize)
        }
        _ = ScreenOCR.recognize(data, device: device, recognition: recognize)
        XCTAssertEqual(calls, 13, "The ninth distinct frame evicts the least recently used entry")
    }

    func testConcurrentSameFrameRunsRecognitionOnce() throws {
        let data = try image()
        let device = UUID().uuidString
        var calls = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = ScreenOCR.recognize(data, device: device) { _ in
                calls += 1
                return []
            }
        }
        XCTAssertEqual(calls, 1)
    }

    func testRecognitionFailureIsRetriedAndInvalidBytesHaveNoHash() throws {
        let device = UUID().uuidString
        let data = try image()
        let failed = ScreenOCR.recognize(data, device: device, recognition: { _ in throw DeviceError("test") })
        XCTAssertEqual(failed.screenHash, "")
        var retried = false
        let success = ScreenOCR.recognize(
            data, device: device,
            recognition: { _ in
                retried = true
                return []
            })
        XCTAssertTrue(retried)
        XCTAssertFalse(success.screenHash.isEmpty)
        XCTAssertEqual(ScreenOCR.screenHash(Data("invalid".utf8)), "")
    }

    func testDiffIsPerDeviceAndRoundTripsServerOCR() throws {
        let device = UUID().uuidString
        func result(_ texts: [String], hash: String) -> ScreenOCR.Result {
            ScreenOCR.Result(width: 16, height: 16, items: texts.map { .init(text: $0, x: 1, y: 2) }, screenHash: hash)
        }
        let first = result(["旧", "保留", "旧"], hash: "a")
        let initial = ScreenOCR.diff(device: device, current: first)
        XCTAssertEqual(Set(initial.added), ["旧", "保留"])
        XCTAssertFalse(initial.unchanged)
        let next = result(["新", "保留"], hash: "b")
        let delta = ScreenOCR.diff(device: device, current: next)
        XCTAssertEqual(delta.added, ["新"])
        XCTAssertEqual(delta.removed, ["旧"])
        XCTAssertEqual(delta.screenHash, "b")
        XCTAssertTrue(ScreenOCR.summaryDiff(for: next, device: device).contains("unchanged: true"))
        XCTAssertEqual(ScreenOCR.diff(device: device + "other", current: first).removed, [])
        let encoded = try JSONSerialization.data(withJSONObject: next.json(device: device))
        let decoded = try XCTUnwrap(ScreenOCR.decode(encoded))
        XCTAssertEqual(decoded.items.map(\.text), next.items.map(\.text))
        XCTAssertEqual(decoded.screenHash, "b")
        XCTAssertNil(ScreenOCR.decode(Data("{}".utf8)))
    }

    func testClipboardUsesCommandVWithoutIMEOrPinyin() throws {
        var reports: [[UInt8]] = []
        var copied: [String] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { _, bytes in
                reports.append(bytes)
            })
        input.step = 0
        let request = try TypeTextRequest(["text": "重庆🙂", "use_clipboard": true])
        XCTAssertFalse(request.ensureChineseIME)
        try request.perform(
            on: input,
            ocr: {
                XCTFail("Clipboard must skip IME OCR")
                return nil
            },
            clipboard: {
                copied.append($0)
            })
        XCTAssertEqual(copied, ["重庆🙂"])
        let pressed = reports.filter { $0.dropFirst(2).contains(where: { $0 != 0 }) }
        XCTAssertEqual(pressed.map { $0[2] }, [0x19])
        XCTAssertEqual(pressed.first?[0], 8)
        XCTAssertThrowsError(try TypeTextRequest(["text": "x", "use_clipboard": 1]))
        let sequence = try MCPKeyboardSequence.actions(arguments: ["steps": [["text": "🙂", "use_clipboard": true]]])
        guard case .request(let action) = sequence[0] else { return XCTFail("Expected request") }
        XCTAssertEqual(action.body["use_clipboard"] as? Bool, true)
    }

    func testClipboardFailureCannotClearFocusedField() throws {
        var reports = 0
        let input = DeviceInput(host: UUID(), session: UUID(), sleep: { _ in }, reportSender: { _, _ in reports += 1 })
        let request = try TypeTextRequest(["text": "中文", "use_clipboard": true, "clear_before": true])
        XCTAssertThrowsError(try request.perform(on: input, clipboard: { _ in throw DeviceError("clipboard failed") }))
        XCTAssertEqual(reports, 0)
    }

    func testActValidatesAllStepsBeforeExecutingAndStopsAtFirstFailure() throws {
        XCTAssertThrowsError(try ActRequest(["steps": [["type": "home"], ["type": "key", "key": "bad-key"]]]))
        XCTAssertThrowsError(try ActRequest(["steps": [["type": "home", "device": "other"]]]))
        XCTAssertThrowsError(try ActRequest(["steps": [["type": "delay", "seconds": true]]]))
        XCTAssertThrowsError(try ActRequest(["steps": [["type": "tap", "x": 1, "y": 2, "width": 0]]]))
        let request = try ActRequest([
            "steps": [
                ["type": "home"], ["type": "delay", "seconds": 0.2], ["type": "key", "key": "enter"], ["type": "home"],
            ]
        ])
        var paths: [String] = []
        var delays: [Double] = []
        let response = try request.perform(
            device: "target",
            capture: { _, _ in
                XCTFail("No OCR expected")
                return ("", Data())
            },
            sleep: {
                delays.append($0)
            },
            execute: { path, _, device in
                XCTAssertEqual(device, "target")
                paths.append(path)
                return path == "/key" ? .error("not ready", status: 503) : .json(["ok": true])
            })
        XCTAssertEqual(paths, ["/home", "/key"])
        XCTAssertEqual(delays, [0.2])
        XCTAssertEqual(response.status, 503)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["failed_step"] as? Int, 3)
        XCTAssertEqual(json["completed"] as? Int, 2)
    }

    func testWaitTextTimeoutStopsBatchWithDeterministicSleep() throws {
        let request = try ActRequest([
            "steps": [
                ["type": "wait_text", "text": "absent", "timeout": 0.25], ["type": "home"],
            ]
        ])
        var delay = 0.0
        let blank = try image()
        let response = try request.perform(
            device: "wait-test", capture: { _, _ in ("wait-test", blank) },
            sleep: {
                delay += $0
            },
            now: { 0 },
            execute: { _, _, _ in
                XCTFail("Timeout must stop execution")
                return .json([:])
            })
        XCTAssertEqual(delay, 0.25, accuracy: 0.00001)
        XCTAssertEqual(response.status, 400)
    }

    func testWaitTextSucceedsBeforeFollowingAction() throws {
        let device = UUID().uuidString
        let data = try image()
        _ = ScreenOCR.recognize(data, device: device, recognition: { _ in [.init(text: "完成", x: 1, y: 2)] })
        let request = try ActRequest(["steps": [["type": "wait_text", "text": "完成"], ["type": "home"]]])
        var paths: [String] = []
        let response = try request.perform(
            device: device, capture: { _, _ in (device, data) },
            sleep: { _ in
                XCTFail("Already visible text must not wait")
            },
            execute: { path, _, _ in
                paths.append(path)
                return .json(["ok": true])
            })
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(paths, ["/home"])
    }

    func testActTranslationPreservesMCPImageCoordinates() throws {
        let request = try XCTUnwrap(
            MCPToolRequest.action(
                named: "act",
                arguments: [
                    "device": "target",
                    "steps": [
                        ["type": "tap", "x": 250, "y": 750, "normalized": true],
                        ["type": "wait_text", "text": "完成"], ["type": "type", "text": "中文", "use_clipboard": true],
                    ],
                ], longEdge: 1000))
        XCTAssertEqual(request.path, "/act")
        let steps = try XCTUnwrap(request.body["steps"] as? [[String: Any]])
        XCTAssertEqual(steps[0]["x"] as? Double, 0.25)
        XCTAssertEqual(steps[0]["fraction"] as? Bool, true)
        XCTAssertEqual(steps[1]["maxEdge"] as? Int, 1000)
        XCTAssertEqual(steps[2]["use_clipboard"] as? Bool, true)
    }

    func testDynamicSettlingConvergesAndHonorsCeilingWithInjectedSleep() {
        var delays: [Double] = []
        var frames = ["a", "b", "b"]
        MCPServer.waitForStableFrame(sleep: { delays.append($0) }, now: { 0 }, frame: { _ in frames.removeFirst() })
        XCTAssertEqual(delays, [0.15, 0.08, 0.08])
        delays = []
        MCPServer.waitForStableFrame(sleep: { delays.append($0) }, now: { 0 }, frame: { _ in UUID().uuidString })
        XCTAssertEqual(delays.reduce(0, +), 0.6, accuracy: 0.00001)
        delays = []
        MCPServer.waitForStableFrame(sleep: { delays.append($0) }, now: { 0 }, frame: { _ in nil })
        XCTAssertEqual(delays, [0.15, 0.1])
    }

    func testDeviceCacheExpiresInvalidatesAndDoesNotCacheErrors() throws {
        var cache = MCPServer.DeviceListCache()
        var calls = 0
        func fetch() -> Data {
            calls += 1
            return Data("\(calls)".utf8)
        }
        let first = try cache.load(origin: "test", now: 0, fetch: fetch)
        XCTAssertEqual(try cache.load(origin: "test", now: 1.99, fetch: fetch), first)
        XCTAssertNotEqual(try cache.load(origin: "test", now: 2, fetch: fetch), first)
        cache.invalidate()
        XCTAssertThrowsError(try cache.load(origin: "test", now: 2.1, fetch: { throw DeviceError("offline") }))
        _ = try cache.load(origin: "test", now: 2.2, fetch: fetch)
        _ = try cache.load(origin: "other", now: 2.3, fetch: fetch)
        XCTAssertEqual(calls, 4)
    }

    func testWakeWindowSurvivesDiscoveryRequestAndReadinessHasNoMagicDelay() {
        let window = ControlAPI.WakeWindow()
        XCTAssertLessThan(window.deadline(wasSuspended: false, now: 10), 10)
        XCTAssertEqual(window.deadline(wasSuspended: true, now: 10), 16)
        XCTAssertEqual(window.deadline(wasSuspended: false, now: 10.1), 16)
        var polls = 0
        var delays: [Double] = []
        ControlAPI.waitUntilReady(
            deadline: 16, now: { 10.1 }, sleep: { delays.append($0) },
            ready: {
                polls += 1
                return polls == 3
            })
        XCTAssertEqual(delays, [0.05, 0.05])
        ControlAPI.waitUntilReady(
            deadline: 10, now: { 10.1 }, sleep: { _ in XCTFail("Expired window") },
            ready: {
                XCTFail("Expired window")
                return false
            })
    }
}
