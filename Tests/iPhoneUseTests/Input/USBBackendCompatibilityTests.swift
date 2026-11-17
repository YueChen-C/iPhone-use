import XCTest
@testable import iPhoneUse

final class USBBackendCompatibilityTests: XCTestCase {
    func testRejectsVersionsBefore17WithoutImplyingAnImageOrHostFailure() {
        for version in ["1", "14.8.1", "15.4", "16", "16.7.12"] {
            XCTAssertThrowsError(try USBBackendCompatibility.validate(version: version)) {
                guard case USBBackendCompatibility.Failure.unsupported(let reported) = $0 else {
                    return XCTFail("Expected an exact unsupported-version reason, got \($0)")
                }
                XCTAssertEqual(reported, version)
            }
        }
    }
    func test17AndLaterAreEligibleNotProofOfUSBReadiness() {
        for version in ["17", "17.0", "17.7.1", "18.2", "26.5"] {
            XCTAssertNoThrow(try USBBackendCompatibility.validate(version: version))
        }
    }
    func testUnknownOrMalformedVersionFailsClosed() {
        for version in ["", "unknown", " 17.0", "17.0 ", "17.", ".17", "17..1", "17-beta", "-17", "17.0.1.2",
                        "１７.0", String(repeating: "9", count: 80)] {
            XCTAssertThrowsError(try USBBackendCompatibility.validate(version: version)) {
                guard case USBBackendCompatibility.Failure.unavailable = $0 else {
                    return XCTFail("Malformed metadata must not be admitted: \($0)")
                }
            }
        }
    }
    func testLocalizedPromptNamesMinimumActualVersionAndBluetooth() {
        for texts in [StringsUSBControl.en, .zh] {
            let value = texts.requiresiOS17("15.4")
            XCTAssertTrue(value.contains("17")); XCTAssertTrue(value.contains("15.4"))
            XCTAssertFalse(texts.versionUnavailable.isEmpty)
        }
        XCTAssertTrue(StringsUSBControl.en.requiresiOS17("16.7").contains("Bluetooth"))
        XCTAssertTrue(StringsUSBControl.zh.requiresiOS17("16.7").contains("蓝牙"))
    }
    func testWindowRequestCancellationIsIdempotentAndThreadSafe() {
        let request = USBBackendSelectionRequest()
        XCTAssertFalse(request.isCancelled)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in request.cancel() }
        XCTAssertTrue(request.isCancelled)
        request.cancel(); XCTAssertTrue(request.isCancelled)
    }
    func testRejectedSelectionPreservesBLERouteAndGeneration() {
        for version in ["15.4", "16.7.12", "unknown"] {
            var inspected: [String] = []
            let controller = USBInputController(requireUSB: { id in
                inspected.append(id)
                try USBBackendCompatibility.validate(version: version)
            })
            let generation = controller.generation("exact-device")
            XCTAssertThrowsError(try controller.selectAtLaunch(physicalID: "exact-device")) {
                guard let failure = $0 as? USBInputFailure else { return XCTFail("Expected typed API failure") }
                XCTAssertEqual(failure.httpStatus, version == "unknown" ? 503 : 400)
            }
            XCTAssertEqual(inspected, ["exact-device"])
            XCTAssertEqual(controller.selected("exact-device"), .ble)
            XCTAssertEqual(controller.generation("exact-device"), generation)
            XCTAssertTrue(controller.permitsBLE("exact-device", generation: generation))
            XCTAssertEqual(controller.selected("peer"), .ble)
            XCTAssertTrue(controller.stop(waitTimeout: 1))
        }
    }
    func test17PassesSelectionGateButDoesNotPrepareWithoutCapture() throws {
        let controller = USBInputController(requireUSB: { _ in try USBBackendCompatibility.validate(version: "17.0") })
        try controller.selectAtLaunch(physicalID: "exact-device")
        XCTAssertEqual(controller.selected("exact-device"), .usb)
        XCTAssertTrue(controller.stop(waitTimeout: 1))
    }
}
