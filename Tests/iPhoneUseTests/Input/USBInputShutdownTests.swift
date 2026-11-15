import XCTest
@testable import iPhoneUse

final class USBInputShutdownTests: XCTestCase {
    func testDefaultBLESelectionAndExplicitUSBRemainIsolatedPerDevice() {
        let controller = USBInputController()
        XCTAssertEqual(controller.selected("target"), .ble)
        let oldGeneration = controller.generation("target")
        XCTAssertTrue(controller.permitsBLE("target", generation: oldGeneration))
        controller.selectAtLaunch(physicalID: "target")
        XCTAssertEqual(controller.selected("target"), .usb)
        XCTAssertFalse(controller.permitsBLE("target", generation: nil))
        XCTAssertFalse(controller.permitsBLE("target", generation: oldGeneration))
        XCTAssertEqual(controller.selected("peer"), .ble)
        XCTAssertTrue(controller.permitsBLE("peer", generation: nil))
        XCTAssertTrue(controller.stop(waitTimeout: 1))
    }

    func testCaptureChangeDoesNotPrepareAnUnboundLaunchSelectionOrSwitchBackend() {
        let controller = USBInputController()
        controller.selectAtLaunch(physicalID: "fixture")
        let generation = controller.generation("fixture")
        controller.captureDidChange()
        XCTAssertEqual(controller.selected("fixture"), .usb)
        XCTAssertEqual(controller.generation("fixture"), generation)
        XCTAssertFalse(controller.permitsBLE("fixture", generation: nil))
        XCTAssertTrue(controller.stop(waitTimeout: 1))
    }

    func testCaptureChangeCannotReopenStoppedAdmission() {
        let controller = USBInputController()
        controller.selectAtLaunch(physicalID: "fixture")
        XCTAssertTrue(controller.stop(waitTimeout: 1))
        let generation = controller.generation("fixture")
        controller.captureDidChange()
        XCTAssertEqual(controller.generation("fixture"), generation)
        XCTAssertFalse(controller.permitsBLE("fixture", generation: nil))
        XCTAssertFalse(controller.permitsBLE("other", generation: nil))
        XCTAssertTrue(controller.stop(waitTimeout: 0))
    }

    func testStopWithoutWorkersClosesAdmissionAndIsIdempotent() {
        let controller = USBInputController()
        XCTAssertTrue(controller.permitsBLE("fixture", generation: nil))
        XCTAssertTrue(controller.stop(waitTimeout: 1))
        XCTAssertFalse(controller.permitsBLE("fixture", generation: nil))
        controller.selectAtLaunch(physicalID: "fixture")
        XCTAssertEqual(controller.selected("fixture"), .ble)
        XCTAssertTrue(controller.stop(waitTimeout: 0))
    }

    func testStopInvalidatesPreviouslySelectedRouteAndUnknownBLEInputs() {
        let controller = USBInputController()
        controller.selectAtLaunch(physicalID: "fixture")
        let generation = controller.generation("fixture")
        XCTAssertTrue(controller.stop(waitTimeout: 1))
        XCTAssertNotEqual(controller.generation("fixture"), generation)
        XCTAssertFalse(controller.permitsBLE("fixture", generation: generation))
        XCTAssertFalse(controller.permitsBLE("other-fixture", generation: nil))
    }

    func testUnconfirmedInputReleaseCannotProduceSuccessfulSignalExit() {
        let cleanCapture = ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: true)
        XCTAssertEqual(Application.terminationExitCode(for: cleanCapture, usbInputReleased: true), 0)
        XCTAssertEqual(Application.terminationExitCode(for: cleanCapture, usbInputReleased: false), 1)
    }

    func testInvalidTimeoutCannotReopenAdmission() {
        for timeout in [Double.nan, .infinity, -1] {
            let controller = USBInputController()
            _ = controller.stop(waitTimeout: timeout)
            XCTAssertFalse(controller.permitsBLE("fixture", generation: nil))
            XCTAssertTrue(controller.stop(waitTimeout: 1))
        }
    }
}
