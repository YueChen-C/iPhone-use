import XCTest
@testable import iPhoneUse

final class USBInputShutdownTests: XCTestCase {
    func testDefaultBLESelectionAndExplicitUSBRemainIsolatedPerDevice() throws {
        let controller = USBInputController(requireUSB: { _ in })
        XCTAssertEqual(controller.selected("target"), .ble)
        let oldGeneration = controller.generation("target")
        XCTAssertTrue(controller.permitsBLE("target", generation: oldGeneration))
        try controller.selectAtLaunch(physicalID: "target")
        XCTAssertEqual(controller.selected("target"), .usb)
        XCTAssertFalse(controller.permitsBLE("target", generation: nil))
        XCTAssertFalse(controller.permitsBLE("target", generation: oldGeneration))
        XCTAssertEqual(controller.selected("peer"), .ble)
        XCTAssertTrue(controller.permitsBLE("peer", generation: nil))
        XCTAssertTrue(controller.stop(waitTimeout: 1))
    }

    func testCaptureChangeDoesNotPrepareAnUnboundLaunchSelectionOrSwitchBackend() throws {
        let controller = USBInputController(requireUSB: { _ in })
        try controller.selectAtLaunch(physicalID: "fixture")
        let generation = controller.generation("fixture")
        controller.captureDidChange()
        XCTAssertEqual(controller.selected("fixture"), .usb)
        XCTAssertEqual(controller.generation("fixture"), generation)
        XCTAssertFalse(controller.permitsBLE("fixture", generation: nil))
        XCTAssertTrue(controller.stop(waitTimeout: 1))
    }

    func testCaptureChangeCannotReopenStoppedAdmission() throws {
        let controller = USBInputController(requireUSB: { _ in })
        try controller.selectAtLaunch(physicalID: "fixture")
        XCTAssertTrue(controller.stop(waitTimeout: 1))
        let generation = controller.generation("fixture")
        controller.captureDidChange()
        XCTAssertEqual(controller.generation("fixture"), generation)
        XCTAssertFalse(controller.permitsBLE("fixture", generation: nil))
        XCTAssertFalse(controller.permitsBLE("other", generation: nil))
        XCTAssertTrue(controller.stop(waitTimeout: 0))
    }

    func testStopWithoutWorkersClosesAdmissionAndIsIdempotent() throws {
        let controller = USBInputController(requireUSB: { _ in })
        XCTAssertTrue(controller.permitsBLE("fixture", generation: nil))
        XCTAssertTrue(controller.stop(waitTimeout: 1))
        XCTAssertFalse(controller.permitsBLE("fixture", generation: nil))
        XCTAssertThrowsError(try controller.selectAtLaunch(physicalID: "fixture"))
        XCTAssertEqual(controller.selected("fixture"), .ble)
        XCTAssertTrue(controller.stop(waitTimeout: 0))
    }

    func testStopInvalidatesPreviouslySelectedRouteAndUnknownBLEInputs() throws {
        let controller = USBInputController(requireUSB: { _ in })
        try controller.selectAtLaunch(physicalID: "fixture")
        let generation = controller.generation("fixture")
        XCTAssertTrue(controller.stop(waitTimeout: 1))
        XCTAssertNotEqual(controller.generation("fixture"), generation)
        XCTAssertFalse(controller.permitsBLE("fixture", generation: generation))
        XCTAssertFalse(controller.permitsBLE("other-fixture", generation: nil))
    }

    func testUnconfirmedInputReleaseCannotProduceSuccessfulSignalExit() throws {
        let cleanCapture = ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: true)
        XCTAssertEqual(Application.terminationExitCode(for: cleanCapture, usbInputReleased: true), 0)
        XCTAssertEqual(Application.terminationExitCode(for: cleanCapture, usbInputReleased: false), 1)
    }

    func testInvalidTimeoutCannotReopenAdmission() throws {
        for timeout in [Double.nan, .infinity, -1] {
            let controller = USBInputController(requireUSB: { _ in })
            _ = controller.stop(waitTimeout: timeout)
            XCTAssertFalse(controller.permitsBLE("fixture", generation: nil))
            XCTAssertTrue(controller.stop(waitTimeout: 1))
        }
    }
}
