import AppKit
import Foundation
import XCTest

@testable import iPhoneUse

/// Replays one relative-report byte through the built-in drag curve.
private func curveStep(_ byte: UInt8) -> Double {
    let count = Int(Int8(bitPattern: byte))
    return Double(count.signum()) * DeviceInput.estimatedDragCurve[abs(count)]
}

final class HTTPMessageTests: XCTestCase {
    func testFragmentedRequestWaitsForTheDeclaredUTF8Body() throws {
        let body = Data(#"{"text":"你好"}"#.utf8)
        let header = Data("POST /type HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        XCTAssertNil(HTTPRequest.parse(Data(header.dropLast())))
        XCTAssertNil(HTTPRequest.parse(header + body.dropLast()))

        let request = try XCTUnwrap(HTTPRequest.parse(header + body))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/type")
        XCTAssertEqual(request.body["text"] as? String, "你好")
    }

    func testRequestTargetDecodesQueriesAndKeepsTheLastDuplicateValue() throws {
        let request = try XCTUnwrap(
            HTTPRequest.parse(
                Data(
                    "GET /screenshot?device=first&device=My%20iPhone&flag&format=png HTTP/1.1\r\n\r\n".utf8)))

        XCTAssertEqual(request.path, "/screenshot")
        XCTAssertEqual(request.query, ["device": "My iPhone", "flag": "", "format": "png"])
        XCTAssertTrue(request.body.isEmpty)
    }

    func testContentLengthIsCaseInsensitiveAndLastHeaderWins() throws {
        let data = Data("POST /type HTTP/1.1\r\nContent-Length: 900\r\ncOnTeNt-LeNgTh: 2\r\n\r\n{}ignored".utf8)
        let request = try XCTUnwrap(HTTPRequest.parse(data))
        XCTAssertTrue(request.body.isEmpty)
    }

    func testInvalidLengthsAndNonObjectJSONKeepTheExistingEmptyBodyFallback() throws {
        let invalidLength = Data("POST /type HTTP/1.1\r\nContent-Length: invalid\r\n\r\n".utf8)
        XCTAssertTrue(try XCTUnwrap(HTTPRequest.parse(invalidLength)).body.isEmpty)

        for body in ["[1,2]", "broken"] {
            let data = Data("POST /type HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
            XCTAssertTrue(try XCTUnwrap(HTTPRequest.parse(data)).body.isEmpty)
        }
    }

    func testResponseUsesByteLengthAndPreservesBinaryBody() {
        let body = Data([0, 127, 128, 255])
        let response = HTTPResponse(status: 503, contentType: "image/png", headers: ["X-Device": "phone"], body: body)
        let expectedHeader =
            "HTTP/1.1 503 Service Unavailable\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\nX-Device: phone\r\n\r\n"
        XCTAssertEqual(response.serialized, Data(expectedHeader.utf8) + body)
    }

    func testJSONResponseRetainsSortedKeysAndErrorStatus() {
        XCTAssertEqual(String(decoding: HTTPResponse.json(["z": 1, "a": 2]).body, as: UTF8.self), #"{"a":2,"z":1}"#)
        let response = HTTPResponse.error("pointer busy", status: 409)
        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"error":"pointer busy"}"#)
        XCTAssertTrue(String(decoding: response.serialized, as: UTF8.self).hasPrefix("HTTP/1.1 409 Conflict\r\n"))
    }
}

final class RequestCoordinatesTests: XCTestCase {
    private var previousLanguage: AppLanguage = .en

    override func setUp() {
        super.setUp()
        // Error text reads the app's live language; pin English so the exact-string
        // assertions below pass regardless of the host Mac's system language.
        previousLanguage = AppLanguageStore.shared.language
        AppLanguageStore.shared.set(.en)
    }

    override func tearDown() {
        AppLanguageStore.shared.set(previousLanguage)
        super.tearDown()
    }

    func testScreenshotDimensionsRoundAndNeverUpscale() {
        let mcpPortrait = RequestCoordinates.imageSize(
            CGSize(width: 1179, height: 2556), maxWidth: nil, maxEdge: MCPServer.longEdge)
        XCTAssertEqual(mcpPortrait.0, 461)
        XCTAssertEqual(mcpPortrait.1, 1000)
        let portrait = RequestCoordinates.imageSize(CGSize(width: 750, height: 1334), maxWidth: nil, maxEdge: 1200)
        XCTAssertEqual(portrait.0, 675)
        XCTAssertEqual(portrait.1, 1200)

        let constrained = RequestCoordinates.imageSize(CGSize(width: 800, height: 400), maxWidth: 300, maxEdge: 500)
        XCTAssertEqual(constrained.0, 300)
        XCTAssertEqual(constrained.1, 150)

        let original = RequestCoordinates.imageSize(CGSize(width: 100, height: 200), maxWidth: 1000, maxEdge: 1200)
        XCTAssertEqual(original.0, 100)
        XCTAssertEqual(original.1, 200)
    }

    func testCoordinatesUseRoundedScreenshotPixels() throws {
        let point = try RequestCoordinates.point(
            ["x": 337.5, "y": 600, "maxEdge": 1200.9], "x", "y",
            screenSize: CGSize(width: 750, height: 1334), screenName: "phone")
        XCTAssertEqual(point.0, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(point.1, 0.5, accuracy: 0.000_001)
    }

    func testExplicitDimensionsOverrideScaledDimensionsIndependently() throws {
        let point = try RequestCoordinates.point(
            ["x": 100, "y": 600, "width": 200, "maxEdge": 1200], "x", "y",
            screenSize: CGSize(width: 750, height: 1334), screenName: "phone")
        XCTAssertEqual(point.0, 0.5)
        XCTAssertEqual(point.1, 0.5)
    }

    func testFractionsAvoidFrameAccessAndDoNotClampAtTheAPIBoundary() throws {
        var frameReads = 0
        func readFrame() -> CGSize? {
            frameReads += 1
            return nil
        }
        let point = try RequestCoordinates.point(
            ["x": -0.25, "y": 1.5, "fraction": true], "x", "y",
            screenSize: readFrame(), screenName: "phone")
        XCTAssertEqual(point.0, -0.25)
        XCTAssertEqual(point.1, 1.5)
        XCTAssertEqual(frameReads, 0)
    }

    func testMissingCoordinatesTakePrecedenceOverMissingFrame() {
        XCTAssertThrowsError(
            try RequestCoordinates.point(
                ["x": 12], "x", "y", screenSize: nil, screenName: "phone")
        ) { error in
            XCTAssertEqual(String(describing: error), "x and y are required")
        }
        XCTAssertThrowsError(
            try RequestCoordinates.point(
                ["x": 1, "y": 2, "width": 100, "height": 200], "x", "y",
                screenSize: nil, screenName: "phone")
        ) { error in
            XCTAssertEqual(String(describing: error), "no frame yet from phone")
        }
    }

    func testNumericBridgingAndZeroDimensionsRemainPermissive() throws {
        let point = try RequestCoordinates.point(
            ["x": true, "y": 2, "width": 2, "height": 0], "x", "y",
            screenSize: CGSize(width: 100, height: 200), screenName: "phone")
        XCTAssertEqual(point.0, 0.5)
        XCTAssertTrue(point.1.isInfinite)
    }
}

final class SwipeRequestTests: XCTestCase {
    private var previousLanguage: AppLanguage = .en

    override func setUp() {
        super.setUp()
        previousLanguage = AppLanguageStore.shared.language
        AppLanguageStore.shared.set(.en)
    }

    override func tearDown() {
        AppLanguageStore.shared.set(previousLanguage)
        super.tearDown()
    }

    func testMCPPathSurvivesHTTPEncodingAndEmitsOneContinuousDrag() throws {
        let action = try XCTUnwrap(
            MCPToolRequest.action(
                named: "swipe",
                arguments: [
                    "points": [["x": 0, "y": 1000], ["x": 500, "y": 500], ["x": 0, "y": 0]],
                    "duration": 0.12, "device": "phone",
                ], longEdge: MCPServer.longEdge))
        let json = try JSONSerialization.data(withJSONObject: action.body)
        let header = Data("POST \(action.path) HTTP/1.1\r\nContent-Length: \(json.count)\r\n\r\n".utf8)
        let request = try XCTUnwrap(HTTPRequest.parse(header + json))
        XCTAssertEqual(request.path, "/swipe")
        XCTAssertEqual(request.body["device"] as? String, "phone")

        let size = CGSize(width: 750, height: 1500)
        let swipe = try SwipeRequest(request.body, screenSize: size, screenName: "phone")
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { size }, sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        try input.swipe(points: swipe.points, duration: swipe.duration)

        // One absolute hover carries the start position; the whole drag —
        // press, movement and release — stays on the relative collection.
        XCTAssertEqual(reports.first?.1, [0, 0, 0, 255, 127])
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.count, 1)
        XCTAssertEqual(reports.first { $0.0 == .relativeMouse }?.1, [1, 0, 0, 0])
        XCTAssertEqual(reports.last?.1, [0, 0, 0, 0])
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        var position = CGPoint(x: swipe.points[0].0 * size.width, y: swipe.points[0].1 * size.height)
        for (_, bytes) in movement {
            position.x += curveStep(bytes[1])
            position.y += curveStep(bytes[2])
        }
        XCTAssertEqual(position.x, 0, accuracy: 0.5)
        XCTAssertEqual(position.y, 0, accuracy: 0.5)
    }

    func testJSONPathUsesOriginalScreenPixelsAndPreservesPointOrder() throws {
        let json = #"{"points":[{"x":0,"y":200},{"x":100,"y":100},{"x":50,"y":0}],"duration":0.6}"#
        let wire = Data("POST /swipe HTTP/1.1\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)".utf8)
        let request = try XCTUnwrap(HTTPRequest.parse(wire))
        let swipe = try SwipeRequest(request.body, screenSize: CGSize(width: 100, height: 200), screenName: "phone")

        XCTAssertEqual(swipe.points.map { $0.0 }, [0, 1, 0.5])
        XCTAssertEqual(swipe.points.map { $0.1 }, [1, 0.5, 0])
        XCTAssertEqual(swipe.duration, 0.6)
    }

    func testScreenshotScalingAppliesToEveryPointAndExplicitDimensionsOverrideIt() throws {
        let body: [String: Any] = [
            "points": [["x": 337.5, "y": 600], ["x": 675, "y": 1200]], "maxEdge": 1200,
        ]
        let scaled = try SwipeRequest(body, screenSize: CGSize(width: 750, height: 1334), screenName: "phone")
        XCTAssertEqual(scaled.points.map { $0.0 }, [0.5, 1])
        XCTAssertEqual(scaled.points.map { $0.1 }, [0.5, 1])

        var resizedBody = body
        resizedBody["width"] = 1350
        let resized = try SwipeRequest(resizedBody, screenSize: CGSize(width: 750, height: 1334), screenName: "phone")
        XCTAssertEqual(resized.points.map { $0.0 }, [0.25, 0.5])
        XCTAssertEqual(resized.points.map { $0.1 }, [0.5, 1])
    }

    func testFractionPathNeedsNoFrameAndUsesDefaultDuration() throws {
        let swipe = try SwipeRequest(
            ["points": [["x": 0.2, "y": 0.8], ["x": 0.7, "y": 0.3]], "fraction": true],
            screenSize: nil, screenName: "phone")
        XCTAssertEqual(swipe.points.map { $0.0 }, [0.2, 0.7])
        XCTAssertEqual(swipe.points.map { $0.1 }, [0.8, 0.3])
        XCTAssertEqual(swipe.duration, 0.3)
    }

    func testNormalizedMCPToolsSurviveJSONAndUseScreenFractionsWithoutAFrame() throws {
        for name in ["move_pointer", "tap", "long_press", "swipe"] {
            let action = try XCTUnwrap(
                MCPToolRequest.action(
                    named: name,
                    arguments: [
                        "normalized": true, "x": 500, "y": 1000,
                        "points": [["x": 0, "y": 1000], ["x": 500, "y": 0]],
                    ],
                    longEdge: MCPServer.longEdge))
            let json = try JSONSerialization.data(withJSONObject: action.body)
            let header = Data("POST \(action.path) HTTP/1.1\r\nContent-Length: \(json.count)\r\n\r\n".utf8)
            let request = try XCTUnwrap(HTTPRequest.parse(header + json))
            if name == "swipe" {
                let swipe = try SwipeRequest(request.body, screenSize: nil, screenName: "phone")
                XCTAssertEqual(swipe.points.map { $0.0 }, [0, 0.5])
                XCTAssertEqual(swipe.points.map { $0.1 }, [1, 0])
            } else {
                let point = try RequestCoordinates.point(request.body, "x", "y", screenSize: nil, screenName: "phone")
                XCTAssertEqual(point.0, 0.5)
                XCTAssertEqual(point.1, 1)
            }
        }
    }

    func testPointLocalFieldsCannotOverridePathCoordinateSpace() throws {
        let swipe = try SwipeRequest(
            [
                "points": [["x": 25, "y": 50, "width": 25, "fraction": true], ["x": 50, "y": 100]],
                "width": 100, "height": 200,
            ], screenSize: CGSize(width: 500, height: 1000), screenName: "phone")
        XCTAssertEqual(swipe.points.map { $0.0 }, [0.25, 0.5])
        XCTAssertEqual(swipe.points.map { $0.1 }, [0.25, 0.5])
    }

    func testMissingPointsAndOldEndpointParametersAreRejected() {
        for body: [String: Any] in [[:], ["x1": 0, "y1": 0, "x2": 100, "y2": 200]] {
            XCTAssertThrowsError(try SwipeRequest(body, screenSize: nil, screenName: "phone")) { error in
                XCTAssertEqual(
                    String(describing: error), "points must contain at least two objects with numeric x and y")
            }
        }
    }

    func testInvalidArrayShapesAreRejected() {
        let invalidPoints: [Any] = [
            NSNull(), "0,0,1,1", [], [["x": 0, "y": 0]], [[0, 0], [1, 1]],
            [["x": 0, "y": 0], NSNull()],
        ]
        for points in invalidPoints {
            XCTAssertThrowsError(
                try SwipeRequest(["points": points, "fraction": true], screenSize: nil, screenName: "phone"))
        }
    }

    func testEveryPointMustHaveFiniteNumericCoordinates() {
        let invalidCoordinates: [Any] = [true, "0.5", NSNull(), Double.nan, Double.infinity]
        for invalid in invalidCoordinates {
            for axis in ["x", "y"] {
                var last: [String: Any] = ["x": 1, "y": 1]
                last[axis] = invalid
                XCTAssertThrowsError(
                    try SwipeRequest(
                        ["points": [["x": 0, "y": 0], last], "fraction": true],
                        screenSize: nil, screenName: "phone"))
            }
        }
        XCTAssertThrowsError(
            try SwipeRequest(
                ["points": [["x": 0, "y": 0], ["x": 1]], "fraction": true],
                screenSize: nil, screenName: "phone"))
    }

    func testExplicitDurationMustBePositiveAndNumeric() {
        let invalidDurations: [Any] = [0, -0.1, true, "0.3", NSNull(), Double.nan, Double.infinity]
        for duration in invalidDurations {
            XCTAssertThrowsError(
                try SwipeRequest(
                    ["points": [["x": 0, "y": 0], ["x": 1, "y": 1]], "fraction": true, "duration": duration],
                    screenSize: nil, screenName: "phone"))
        }
    }

    func testInvalidImageDimensionsCannotReachPointerInterpolation() {
        let body: [String: Any] = ["points": [["x": 0, "y": 0], ["x": 1, "y": 1]]]
        for key in ["width", "height", "maxEdge"] {
            for invalid: Any in [0, -1, true, "100", NSNull(), Double.infinity] {
                var invalidBody = body
                invalidBody[key] = invalid
                XCTAssertThrowsError(
                    try SwipeRequest(invalidBody, screenSize: CGSize(width: 100, height: 200), screenName: "phone"))
            }
        }
        for maxEdge in [0.5, Double(Int.max), Double.greatestFiniteMagnitude] {
            var invalidBody = body
            invalidBody["maxEdge"] = maxEdge
            XCTAssertThrowsError(
                try SwipeRequest(invalidBody, screenSize: CGSize(width: 100, height: 200), screenName: "phone"))
        }
        XCTAssertThrowsError(try SwipeRequest(body, screenSize: nil, screenName: "phone"))
        XCTAssertThrowsError(try SwipeRequest(body, screenSize: .zero, screenName: "phone"))
    }
}

/// Synthetic pixels exercise native Vision without capture, Bluetooth, or a display.
final class ScreenOCRTests: XCTestCase {
    private func image(withText: Bool = true) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        if withText {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black,
            ]
            NSAttributedString(string: "Hello OCR", attributes: attributes).draw(at: CGPoint(x: 80, y: 450))
            NSAttributedString(string: "Confirm", attributes: attributes).draw(at: CGPoint(x: 420, y: 100))
            NSGraphicsContext.restoreGraphicsState()
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any] = [:]) throws -> HTTPRequest {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try XCTUnwrap(
            HTTPRequest.parse(
                Data("\(method) \(path) HTTP/1.1\r\nContent-Length: \(data.count)\r\n\r\n".utf8) + data))
    }

    func testNativeRecognitionReportsTopLeftPixelsInReadingOrder() throws {
        let result = ScreenOCR.recognize(try image())
        XCTAssertEqual(result.width, 800)
        XCTAssertEqual(result.height, 600)
        XCTAssertEqual(result.items.map(\.text), ["Hello OCR", "Confirm"])
        let hello = try XCTUnwrap(result.items.first)
        XCTAssertEqual(hello.x, 195, accuracy: 35)
        XCTAssertEqual(hello.y, 120, accuracy: 25)
        let confirm = try XCTUnwrap(result.items.last)
        XCTAssertEqual(confirm.x, 510, accuracy: 35)
        XCTAssertEqual(confirm.y, 470, accuracy: 25)
    }

    func testBoundingBoxesFlipYAndSortTwelvePixelRowsLeftToRight() {
        let upperRight = ScreenOCR.Item(
            text: "right", box: CGRect(x: 0.7, y: 0.8, width: 0.2, height: 0.1), width: 1000, height: 1000)
        let upperLeft = ScreenOCR.Item(
            text: "left", box: CGRect(x: 0.1, y: 0.795, width: 0.2, height: 0.1), width: 1000, height: 1000)
        let bottom = ScreenOCR.Item(
            text: "bottom", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), width: 1000, height: 1000)
        XCTAssertEqual(upperRight.x, 800)
        XCTAssertEqual(upperRight.y, 150)
        XCTAssertEqual(ScreenOCR.sorted([bottom, upperRight, upperLeft]).map(\.text), ["left", "right", "bottom"])
    }

    func testBadDataAndBlankScreenSafelyReturnEmptyItems() throws {
        let invalid = ScreenOCR.recognize(Data("invalid".utf8))
        XCTAssertTrue(invalid.items.isEmpty)
        XCTAssertEqual(invalid.width, 0)
        let blank = ScreenOCR.recognize(try image(withText: false))
        XCTAssertTrue(blank.items.isEmpty)
        XCTAssertEqual(blank.width, 800)
        XCTAssertEqual(blank.height, 600)
    }

    func testGETAndPOSTOCRUseSelectorsAndReturnDecodedImageDimensions() throws {
        let data = try image()
        for (method, path, body) in [
            ("GET", "/ocr?device=query&maxEdge=900", [:]),
            ("POST", "/ocr?device=query", ["device": "body", "maxEdge": 900]),
            ("GET", "/ocr?device_id=query&maxEdge=900", [:]),
            ("POST", "/ocr?device=query", ["device_id": "body", "maxEdge": 900]),
        ] as [(String, String, [String: Any])] {
            var captures = 0
            let response = ControlAPI.handle(
                try request(method, path, body),
                ocrCapture: { selector, edge in
                    captures += 1
                    XCTAssertEqual(selector, method == "GET" ? "query" : "body")
                    XCTAssertEqual(edge, 900)
                    return ("resolved", data)
                }, ocrTap: { _, _, _, _ in XCTFail("OCR must not tap") })
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(captures, 1)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            XCTAssertEqual(result["device"] as? String, "resolved")
            XCTAssertEqual(result["width"] as? Int, 800)
            XCTAssertEqual(result["height"] as? Int, 600)
            let items = try XCTUnwrap(result["items"] as? [[String: Any]])
            XCTAssertEqual(items.map { $0["text"] as? String }, ["Hello OCR", "Confirm"])
        }
    }

    func testTapTextResolvesFreshOCRAndNormalizesTheSelectedPixels() throws {
        let data = try image()
        var taps = 0
        let response = ControlAPI.handle(
            try request("POST", "/tap_text", ["text": "confirm", "hold": 0.2, "maxEdge": 1000, "device_id": "phone"]),
            ocrCapture: { selector, edge in
                XCTAssertEqual(selector, "phone")
                XCTAssertEqual(edge, 1000)
                return ("phone", data)
            },
            ocrTap: { id, x, y, hold in
                taps += 1
                XCTAssertEqual(id, "phone")
                XCTAssertEqual(x, 510.0 / 800, accuracy: 0.05)
                XCTAssertEqual(y, 470.0 / 600, accuracy: 0.05)
                XCTAssertEqual(hold, 0.2)
            })
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(response.status, 200)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["text"] as? String, "Confirm")
        XCTAssertNotNil(result["x"] as? Int)
        XCTAssertNotNil(result["y"] as? Int)
    }

    func testInvalidOCRParametersAndMissingMatchesNeverSendInput() throws {
        let invalid: [[String: Any]] = [
            [:], ["text": " "], ["text": "x", "exact": 1], ["text": "x", "index": -1],
            ["text": "x", "index": 0.5], ["text": "x", "index": true],
            ["text": "x", "hold": -1], ["text": "x", "hold": 61],
            ["text": "x", "maxEdge": 0], ["text": "x", "maxEdge": 0.5],
            ["text": "x", "maxEdge": true], ["text": "x", "maxEdge": "1200"],
        ]
        for body in invalid {
            let response = ControlAPI.handle(
                try request("POST", "/tap_text", body),
                ocrCapture: { _, _ in
                    XCTFail("invalid arguments must not capture")
                    return ("phone", Data())
                }, ocrTap: { _, _, _, _ in XCTFail("invalid arguments must not tap") })
            XCTAssertNotEqual(response.status, 200)
        }
        let response = ControlAPI.handle(
            try request("POST", "/tap_text", ["text": "missing"]),
            ocrCapture: { _, _ in
                ("phone", Data())
            }, ocrTap: { _, _, _, _ in XCTFail("failed OCR must not tap") })
        XCTAssertNotEqual(response.status, 200)
        for path in ["/ocr?maxEdge=0", "/ocr?maxEdge=oops"] {
            XCTAssertNotEqual(
                ControlAPI.handle(
                    try request("GET", path),
                    ocrCapture: { _, _ in
                        XCTFail("invalid dimensions must not capture")
                        return ("phone", Data())
                    }
                ).status, 200)
        }
    }

    func testMatchingSupportsExactSubstringAndZeroBasedDuplicateIndex() throws {
        let items = ["Settings", "Settings detail", "Settings"].map {
            ScreenOCR.Item(text: $0, box: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.1), width: 400, height: 800)
        }
        let result = ScreenOCR.Result(width: 400, height: 800, items: items)
        XCTAssertEqual(try TextTapRequest(["text": "settings", "index": 1]).match(result).text, "Settings detail")
        XCTAssertEqual(
            try TextTapRequest(["text": "Settings", "exact": true, "index": 1]).match(result).text, "Settings")
        XCTAssertThrowsError(try TextTapRequest(["text": "settings", "exact": true]).match(result))
        XCTAssertThrowsError(try TextTapRequest(["text": "Settings", "index": 3]).match(result))
    }
}

final class TypeTextRequestTests: XCTestCase {
    func testHTTPDeviceSelectorsPreserveBodyAndOriginalPrecedence() throws {
        let json = #"{"device_id":"body-alias"}"#
        let wire = Data(
            "POST /type?device=query&device_id=query-alias HTTP/1.1\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
                .utf8)
        let request = try XCTUnwrap(HTTPRequest.parse(wire))
        XCTAssertEqual(ControlAPI.deviceSelector(body: request.body, query: request.query), "body-alias")
        XCTAssertEqual(
            ControlAPI.deviceSelector(body: ["device": "body", "device_id": "alias"], query: request.query), "body")
        XCTAssertEqual(ControlAPI.deviceSelector(body: [:], query: request.query), "query")
        XCTAssertEqual(ControlAPI.deviceSelector(body: [:], query: ["device_id": "query-alias"]), "query-alias")
    }

    func testAllAtomicOptionCombinationsEmitOrderedKeyboardReports() throws {
        for mask in 0..<8 {
            var reports: [[UInt8]] = []
            let input = DeviceInput(
                host: UUID(), session: UUID(), screenSize: { nil }, sleep: { _ in },
                reportSender: { _, bytes in reports.append(bytes) })
            let body: [String: Any] = [
                "text": "a", "clear_before": mask & 1 != 0, "commit_ime": mask & 2 != 0, "press_enter": mask & 4 != 0,
            ]
            try TypeTextRequest(body).perform(on: input)
            // Modifier-only reports bracket cmd+a; inspect actual key-down usages separately.
            let pressed = reports.filter { $0.dropFirst(2).contains(where: { $0 != 0 }) }
            var expected: [UInt8] = []
            if mask & 1 != 0 { expected += [4, 42] }
            expected.append(4)
            if mask & 2 != 0 { expected.append(44) }
            if mask & 4 != 0 { expected.append(40) }
            XCTAssertEqual(pressed.map { $0[2] }, expected, "mask=\(mask)")
            if mask & 1 != 0 { XCTAssertEqual(pressed.first?[0], 8) }
            XCTAssertEqual(reports.count, expected.count * 2 + (mask & 1 != 0 ? 2 : 0))
            XCTAssertTrue(reports.last?.allSatisfy { $0 == 0 } == true)
        }
    }

    func testPinyinPreservesUmlautAsVBeforeStrippingTones() {
        let cases = [
            "女": "nv ", "吕": "lv ", "绿": "lv ", "绿色": "lvse ", "略": "lve ", "虐": "nve ",
            "女儿": "nver ", "居去需雨": "juquxuyu ", "学": "xue ", "你好": "nihao ", "a女b": "anv b",
        ]
        for (text, expected) in cases {
            XCTAssertEqual(KeyboardMap.keyboardText(for: text), expected, text)
        }
    }

    func testHanziReportsAndIMEHeuristic() throws {
        XCTAssertEqual(KeyboardMap.keyboardText(for: "蓝牙"), "lanya ")
        XCTAssertEqual(KeyboardMap.keyboardText(for: "快捷指令"), "kuaijiezhiling ")
        XCTAssertEqual(KeyboardMap.keyboardText(for: "A蓝牙!快捷指令"), "Alanya !kuaijiezhiling ")
        XCTAssertNil(KeyboardMap.keyboardText(for: "蓝牙🙂"))
        XCTAssertEqual(KeyboardMap.code(for: "capslock"), 0x39)
        XCTAssertEqual(KeyboardMap.code(for: "caps_lock"), 0x39)
        var reports: [[UInt8]] = []
        var delays: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { nil }, sleep: { _ in },
            reportSender: { _, bytes in reports.append(bytes) })
        func result(_ labels: [String]) -> ScreenOCR.Result {
            ScreenOCR.Result(
                width: 100, height: 100,
                items: labels.map {
                    ScreenOCR.Item(
                        text: $0, box: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), width: 100, height: 100)
                })
        }
        try TypeTextRequest(["text": "蓝牙"]).perform(
            on: input, ocr: { result(["return"]) }, sleep: { delays.append($0) })
        let pressed = reports.filter { $0.dropFirst(2).contains(where: { $0 != 0 }) }
        XCTAssertEqual(pressed.map { $0[2] }, [44, 15, 4, 17, 28, 4, 44])
        XCTAssertEqual(pressed.first?[0], 1)
        XCTAssertEqual(delays, [0.25])
        reports.removeAll()
        try TypeTextRequest(["text": "蓝牙", "ensure_chinese_ime": false]).perform(
            on: input,
            ocr: {
                XCTFail("OCR must be skipped")
                return nil
            })
        XCTAssertEqual(
            reports.filter { $0.dropFirst(2).contains(where: { $0 != 0 }) }.map { $0[2] },
            [15, 4, 17, 28, 4, 44])
        XCTAssertTrue(ChineseIMEHeuristic.isEnglish(result(["q", "w", "e"])))
        XCTAssertFalse(ChineseIMEHeuristic.isEnglish(result(["q", "w", "e", "完成"])))
        XCTAssertFalse(ChineseIMEHeuristic.isEnglish(result([])))
        XCTAssertTrue(try TypeTextRequest(["text": "abc", "ensure_chinese_ime": true]).ensureChineseIME)
        XCTAssertFalse(try TypeTextRequest(["text": "abc"]).ensureChineseIME)
    }

    func testInvalidTextAndOptionsCannotClearTheField() {
        var reports = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { nil }, sleep: { _ in },
            reportSender: { _, _ in reports += 1 })
        var invalid: [[String: Any]] = [["clear_before": true], ["text": "🙂", "clear_before": true]]
        for option in MCPKeyboardSequence.textOptions {
            for value: Any in [0, 1, "true", NSNull()] {
                var body: [String: Any] = ["text": "a", "clear_before": true]
                body[option] = value
                invalid.append(body)
            }
        }
        for body in invalid { XCTAssertThrowsError(try TypeTextRequest(body).perform(on: input)) }
        XCTAssertEqual(reports, 0)
    }
}
