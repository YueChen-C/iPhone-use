import XCTest
@testable import iPhoneUse

final class USBHIDDiscoveryTests: XCTestCase {
    private func touchscreen(_ id: Any) -> [String: Any] {
        ["PrimaryUsagePage": 13, "PrimaryUsage": 4, "UniversalControlBuiltIn": true, "_ServiceID": id]
    }
    private func keyboard(_ id: Any, page: Any = 1, usage: Any = 6, virtual: Any = true) -> [String: Any] {
        ["DeviceTypeHint": "Keyboard", "_ServiceID": id, "_CoreDevice_codablePropertyStorage": [
            "UniversalControlVirtualService": ["bool": virtual], "_CoreDevice_originalUsages": ["array": [
                ["dictionary": ["DeviceUsagePage": ["int": page], "DeviceUsage": ["int": usage]]]]]]]
    }

    func testInvalidServiceIDsCannotWrapTruncateOrBecomeBooleanOne() {
        let invalid: [Any] = [0, -1, 7.5, NSNumber(value: 7.0), true, false,
                              Double.nan, Double.infinity, "918", NSNull()]
        for id in invalid {
            XCTAssertThrowsError(try USBTouchSession.touchscreen(["connectedServices": [touchscreen(id)]]), "\(id)")
            XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": [keyboard(id)]]), "\(id)")
        }
    }

    func testValidSignedAndUnsignedIDsPreserveTheirFullIntegerRange() throws {
        let values: [NSNumber] = [NSNumber(value: 918), NSNumber(value: Int64.max), NSNumber(value: UInt64.max)]
        for id in values {
            XCTAssertEqual(try USBTouchSession.touchscreen(["connectedServices": [touchscreen(id)]]), id.uint64Value)
            XCTAssertEqual(USBTouchSession.keyboardSurface(["connectedServices": [keyboard(id)]]), id.uint64Value)
        }
    }

    func testUsageSelectorsRequireIntegersRatherThanCoercedValues() {
        for page: Any in [13.75, NSNumber(value: 13.0), "13", true] {
            var touch = touchscreen(918); touch["PrimaryUsagePage"] = page
            XCTAssertThrowsError(try USBTouchSession.touchscreen(["connectedServices": [touch]]))
        }
        var touch = touchscreen(918); touch["PrimaryUsage"] = 4.75
        XCTAssertThrowsError(try USBTouchSession.touchscreen(["connectedServices": [touch]]))
        for page: Any in [1.75, NSNumber(value: 1.0), "1", true] {
            XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": [keyboard(919, page: page)]]))
        }
        for usage: Any in [6.75, NSNumber(value: 6.0), "6", true] {
            XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": [keyboard(919, usage: usage)]]))
        }
    }

    func testVirtualFlagsRequireAnActualBoolean() {
        for flag: Any in [1, NSNumber(value: 1), "true", false, NSNull()] {
            var touch = touchscreen(918); touch["UniversalControlBuiltIn"] = flag
            XCTAssertThrowsError(try USBTouchSession.touchscreen(["connectedServices": [touch]]))
            XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": [keyboard(919, virtual: flag)]]))
        }
    }

    func testServiceIDMustBeUniqueAcrossAllKindsNotOnlyMatchingCapabilities() {
        let services = [touchscreen(918), keyboard(918)]
        XCTAssertThrowsError(try USBTouchSession.touchscreen(["connectedServices": services]))
        XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": services]))
        XCTAssertThrowsError(try USBTouchSession.touchscreen([
            "connectedServices": [touchscreen(918), ["_ServiceID": UInt64(918)]]]))
        XCTAssertNil(USBTouchSession.keyboardSurface([
            "connectedServices": [keyboard(919), ["_ServiceID": UInt64(919)]]]))
    }

    func testUnavailableKeyboardDoesNotInventCapabilityOrRemoveValidTouch() throws {
        let services = [touchscreen(918), keyboard(-1)]
        XCTAssertEqual(try USBTouchSession.touchscreen(["connectedServices": services]), 918)
        XCTAssertNil(USBTouchSession.keyboardSurface(["connectedServices": services]))
    }

    func testNativeWireDecodedScalarsUseTheSameStrictDiscoveryPath() throws {
        func decode(_ services: [USBXPCValue]) throws -> [String: Any] {
            var decoder = AXRSDDecoder(data: USBXPCValue.dictionary(["connectedServices": .array(services)]).encode())
            return try XCTUnwrap(try decoder.object() as? [String: Any])
        }
        func touch(_ id: USBXPCValue) -> USBXPCValue {
            .dictionary(["_ServiceID": id, "PrimaryUsagePage": .int(13), "PrimaryUsage": .uint(4),
                         "UniversalControlBuiltIn": .bool(true)])
        }
        XCTAssertEqual(try USBTouchSession.touchscreen(decode([touch(.uint(UInt64.max))])), UInt64.max)
        XCTAssertThrowsError(try USBTouchSession.touchscreen(decode([touch(.int(-1))])))
        XCTAssertThrowsError(try USBTouchSession.touchscreen(decode([touch(.bool(true))])))
        XCTAssertThrowsError(try USBTouchSession.touchscreen(decode([touch(.uint(918)), touch(.int(918))])))
    }
}
