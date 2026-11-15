import XCTest
@testable import iPhoneUse

final class USBDisplayReadinessTests: XCTestCase {
    private func screen(primary: Any = true, external: Any = false,
                        size: [NSNumber] = [1170, 2532]) -> [String: Any] {
        ["primary": primary, "external": external, "currentOrientation": "rot0",
         "nativeOrientation": "rot0", "currentMode": ["size": size]]
    }

    private func reply(_ screens: [[String: Any]]) -> [String: Any] {
        ["CoreDevice.output": ["backlightState": "activeOn", "displays": screens]]
    }

    private func reject(_ screens: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try USBTouchSession.displayDimensions(reply(screens)), file: file, line: line) {
            XCTAssertEqual(($0 as? USBPreparationFailure)?.reason, .displayUnavailable, file: file, line: line)
        }
    }

    func testExactlyOneTypedPrimaryWithSecondaryDisplaysRemainsSupported() throws {
        for screens in [[screen()], [screen(primary: false, external: true), screen()],
                        [screen(), screen(primary: false, external: true)]] {
            let size = try USBTouchSession.displayDimensions(reply(screens))
            XCTAssertEqual(size.0, 1170); XCTAssertEqual(size.1, 2532)
        }
    }

    func testDuplicatePrimaryIsRejectedRegardlessOfOrderOrDimensions() {
        let landscape = screen(size: [2532, 1170])
        reject([screen(), landscape]); reject([landscape, screen()])
        reject([screen(), screen()]); reject([]); reject([screen(primary: false)])
    }

    func testPrimaryAndExternalFlagsRejectNumericStringOrAbsentValues() {
        for value: Any in [NSNumber(value: 1), NSNumber(value: 0), "true", NSNull()] {
            reject([screen(primary: value)]); reject([screen(external: value)])
            reject([screen(), screen(primary: value, external: true)])
        }
        var missingPrimary = screen(); missingPrimary.removeValue(forKey: "primary")
        var missingExternal = screen(); missingExternal.removeValue(forKey: "external")
        reject([missingPrimary]); reject([missingExternal]); reject([screen(), missingPrimary])
    }

    func testBooleanDimensionsAreRejectedRatherThanCoercedToOne() {
        reject([screen(size: [NSNumber(value: true), 2532])])
        reject([screen(size: [1170, NSNumber(value: true)])])
    }

    func testNativeWireScalarTypesSurviveXPCDecode() throws {
        let answer = USBXPCValue.dictionary(["CoreDevice.output": .dictionary([
            "backlightState": .text("activeOn"), "displays": .array([.dictionary([
                "primary": .bool(true), "external": .bool(false),
                "currentOrientation": .text("rot0"), "nativeOrientation": .text("rot0"),
                "currentMode": .dictionary(["size": .array([.uint(1170), .uint(2532)])])])])])])
        var decoder = AXRSDDecoder(data: answer.encode())
        let decoded = try XCTUnwrap(try decoder.object() as? [String: Any])
        let size = try USBTouchSession.displayDimensions(decoded)
        XCTAssertEqual(size.0, 1170); XCTAssertEqual(size.1, 2532)
    }
}
