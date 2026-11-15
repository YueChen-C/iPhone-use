import XCTest
@testable import iPhoneUse

final class USBRequestCoordinatesTests: XCTestCase {
    private let size = CGSize(width: 750, height: 1334)

    func testValidScreenshotConversionPreservesRoundingAndIndependentDimensions() throws {
        let point = try USBRequestCoordinates.point(
            ["x": 337.5, "y": 600, "maxEdge": 1200.9], "x", "y", screenSize: size, screenName: "fixture")
        XCTAssertEqual(point.0, 0.5); XCTAssertEqual(point.1, 0.5)
        let explicit = try USBRequestCoordinates.point(
            ["x": 100, "y": 600, "width": 200, "maxEdge": 1200], "x", "y", screenSize: size, screenName: "fixture")
        XCTAssertEqual(explicit.0, 0.5); XCTAssertEqual(explicit.1, 0.5)
    }

    func testFractionsDoNotReadCaptureButAreBoundedWithoutClamping() throws {
        var reads = 0
        func capture() -> CGSize? { reads += 1; return nil }
        let p = try USBRequestCoordinates.point(["x": 0.25, "y": 0.75, "fraction": true], "x", "y",
                                               screenSize: capture(), screenName: "fixture")
        XCTAssertEqual(p.0, 0.25); XCTAssertEqual(p.1, 0.75); XCTAssertEqual(reads, 0)
        for x in [-0.01, 1.01, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try USBRequestCoordinates.point(["x": x, "y": 0.5, "fraction": true], "x", "y",
                                                                screenSize: capture(), screenName: "fixture"))
        }
        XCTAssertEqual(reads, 0)
    }

    func testBooleanAndMalformedCoordinateMetadataRejectBeforeConversion() {
        let valid: [String: Any] = ["x": 20, "y": 30]
        for key in ["x", "y", "width", "height", "maxEdge"] {
            for value: Any in [true, false, "100", NSNull(), Double.nan, Double.infinity, -Double.infinity] {
                var body = valid; body[key] = value
                XCTAssertThrowsError(try USBRequestCoordinates.point(body, "x", "y", screenSize: size, screenName: "fixture"),
                                     "\(key)=\(value)")
            }
        }
        for value: Any in ["true", 1, 0, NSNull()] {
            var body = valid; body["fraction"] = value
            XCTAssertThrowsError(try USBRequestCoordinates.point(body, "x", "y", screenSize: size, screenName: "fixture"))
        }
        for key in ["width", "height", "maxEdge"] {
            for value in [0.0, -1] {
                var body = valid; body[key] = value
                XCTAssertThrowsError(try USBRequestCoordinates.point(body, "x", "y", screenSize: size, screenName: "fixture"))
            }
        }
        for value in [0.5, Double(Int.max), Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try USBRequestCoordinates.point(["x": 20, "y": 30, "maxEdge": value], "x", "y",
                                                                screenSize: size, screenName: "fixture"))
        }
    }

    func testInvalidCaptureAndRoundedZeroImageCannotReachIntegerConversion() {
        for size: CGSize? in [nil, .zero, .init(width: CGFloat.infinity, height: 10),
                              .init(width: Double(Int.max), height: 10), .init(width: 1, height: 1000)] {
            XCTAssertThrowsError(try USBRequestCoordinates.point(["x": 1, "y": 1, "maxEdge": 1], "x", "y",
                                                                screenSize: size, screenName: "fixture"))
        }
    }

    func testUSBHoldRejectsInvalidTypesAndPreservesDefaultAndBounds() throws {
        XCTAssertEqual(try USBRequestCoordinates.hold([:]), 0.08)
        for value in [0.0, 0.08, 60] { XCTAssertEqual(try USBRequestCoordinates.hold(["hold": value]), value) }
        for value: Any in [true, "0.1", NSNull(), -1, 60.01, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try USBRequestCoordinates.hold(["hold": value]))
        }
    }

    func testUSBSwipeChecksEveryPointAndDoesNotChangeLegacyBLEContract() throws {
        let valid: [String: Any] = ["points": [["x": 0.1, "y": 0.2], ["x": 0.8, "y": 0.9]], "fraction": true]
        XCTAssertEqual(try SwipeRequest(valid, screenSize: nil, screenName: "fixture", strictUSB: true).points.count, 2)
        var invalid = valid; invalid["points"] = [["x": 0.1, "y": 0.2], ["x": 1.01, "y": 0.9]]
        XCTAssertThrowsError(try SwipeRequest(invalid, screenSize: nil, screenName: "fixture", strictUSB: true))
        XCTAssertNoThrow(try SwipeRequest(invalid, screenSize: nil, screenName: "fixture"))
        invalid = valid; invalid["fraction"] = "true"
        XCTAssertThrowsError(try SwipeRequest(invalid, screenSize: size, screenName: "fixture", strictUSB: true))
        let legacy = try RequestCoordinates.point(["x": true, "y": 2, "width": 2, "height": 0], "x", "y",
                                                  screenSize: size, screenName: "fixture")
        XCTAssertEqual(legacy.0, 0.5); XCTAssertTrue(legacy.1.isInfinite)
    }
}
