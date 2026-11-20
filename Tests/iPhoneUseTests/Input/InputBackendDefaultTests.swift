import XCTest
@testable import iPhoneUse

final class InputBackendDefaultTests: XCTestCase {
    func testVersionDefaultIsUSBFor173AndLaterOnly() {
        for version in ["17.3", "17.3.0", "17.3.1", "17.10", "18", "18.2", "25.9", "26", "26.0", "26.5", "26.1.2", "27.0"] {
            XCTAssertEqual(InputBackendKind.defaultForIOSVersion(version), .usb, version)
        }
        for version in ["15.4", "16.7", "17", "17.0", "17.2", "17.2.99", "17.3-beta", "17.3.", "17..3", "17.3.0.1", "17.３", "17.99999999999999999999999999999", "", "unknown", "26-beta", "26.", "２６.0", " 26.0"] {
            XCTAssertEqual(InputBackendKind.defaultForIOSVersion(version), .ble, version)
        }
    }

    func testDefaultInvalidatesOnlyThisPhonesBLELeaseWithoutClaimingReadiness() {
        let controller = USBInputController(requireUSB: { _ in XCTFail("Applying metadata must not prepare input") })
        let oldLease = controller.generation("exact-id")
        XCTAssertTrue(controller.applyDefault(physicalID: "exact-id", version: "17.3"))
        XCTAssertEqual(controller.selected("exact-id"), .usb)
        XCTAssertFalse(controller.permitsBLE("exact-id", generation: oldLease))
        XCTAssertEqual(controller.selected("peer"), .ble)
        let usbGeneration = controller.generation("exact-id")
        XCTAssertFalse(controller.applyDefault(physicalID: "exact-id", version: "17.3"))
        XCTAssertEqual(controller.generation("exact-id"), usbGeneration)
        XCTAssertFalse(controller.applyDefault(physicalID: "old", version: "17.2.9"))
        XCTAssertEqual(controller.selected("old"), .ble)
        XCTAssertTrue(controller.stop(waitTimeout: 1))
        XCTAssertFalse(controller.applyDefault(physicalID: "after-stop", version: "17.3"))
    }

    func testInFlightExplicitChoiceWinsOverLateDefaultMetadata() {
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let completed = expectation(description: "explicit selection completed")
        let controller = USBInputController(requireUSB: { _ in
            entered.signal()
            _ = finish.wait(timeout: .now() + 2)
            throw USBBackendCompatibility.Failure.unavailable
        })
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                try controller.selectAtLaunch(physicalID: "exact-id")
                XCTFail("explicit USB preflight should fail in this fixture")
            } catch { }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(controller.applyDefault(physicalID: "exact-id", version: "17.3"))
        finish.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(controller.selected("exact-id"), .ble)
        XCTAssertFalse(controller.applyDefault(physicalID: "exact-id", version: "17.3"))
        XCTAssertTrue(controller.stop(waitTimeout: 1))
    }

    func testPreparationFailureKeepsUSBSelectedAndRejectsBothRoutes() {
        var state = InputBackendSelection()
        let generation = state.begin(.usb)
        state.fail(generation, message: "Developer service unavailable")
        XCTAssertEqual(state.backend, .usb)
        XCTAssertFalse(state.permits(.usb))
        XCTAssertFalse(state.permits(.ble))
        let explicitBLE = state.begin(.ble)
        state.fail(generation, message: "late failure")
        state.finish(explicitBLE, released: true)
        XCTAssertTrue(state.permits(.ble))
        XCTAssertNil(state.failure)
    }
}
