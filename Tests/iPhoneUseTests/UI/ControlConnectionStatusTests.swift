import XCTest

@testable import iPhoneUse

final class ControlConnectionStatusTests: XCTestCase {
    func testSurvivingBluetoothAssociationPausesForCaptureWithoutShowingPairingOverlay() {
        let status = ControlConnectionStatus.resolve(
            hasScreen: true, hasMatchedHost: true, bluetoothState: .connected,
            inputIsCurrent: true, inputIsReady: true, screenPermitsInput: false)
        XCTAssertEqual(status, .verifyingScreen)
        XCTAssertFalse(status.showsOverlay)
        XCTAssertEqual(
            ControlConnectionStatus.resolve(
                hasScreen: true, hasMatchedHost: true, bluetoothState: .connected,
                inputIsCurrent: true, inputIsReady: true, screenPermitsInput: true), .connected)
    }

    func testCaptureVerificationCannotHideARealDisconnectOrUnmatchedNewPhone() {
        for (bluetooth, expected) in [
            (DeviceBluetoothState.disconnected, ControlConnectionStatus.disconnected),
            (.unmatched, .unmatched),
        ] {
            let status = ControlConnectionStatus.resolve(
                hasScreen: true, hasMatchedHost: false, bluetoothState: bluetooth,
                inputIsCurrent: false, inputIsReady: false, screenPermitsInput: false)
            XCTAssertEqual(status, expected)
            XCTAssertTrue(status.showsOverlay)
        }
        XCTAssertEqual(
            ControlConnectionStatus.resolve(
                hasScreen: false, hasMatchedHost: false, bluetoothState: .connected,
                inputIsCurrent: false, inputIsReady: false, screenPermitsInput: false), .waitingForDevice)
    }

    func testOverlayViewOnlyDismissalAllowsClearScreenViewingAndHitTestPassThrough() {
        let overlay = ControlConnectionOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        overlay.update(.disconnected)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(overlay.isDismissed)

        // While guidance card is showing, clicking outside the card returns self (eats clicks)
        let hitBefore = overlay.hitTest(NSPoint(x: 10, y: 10))
        XCTAssertNotNil(hitBefore)
        XCTAssertEqual(hitBefore, overlay)

        // Dismiss guidance into view-only mode
        overlay.setDismissed(true)
        XCTAssertTrue(overlay.isDismissed)
        XCTAssertFalse(overlay.isHidden)

        // In view-only mode, clicking on empty area returns nil so clicks pass through to phoneView
        let hitAfter = overlay.hitTest(NSPoint(x: 10, y: 10))
        XCTAssertNil(hitAfter)

        // When device disconnects, dismissal resets
        overlay.update(.waitingForDevice)
        XCTAssertFalse(overlay.isDismissed)

        // When connected, overlay hides and dismissal resets
        overlay.setDismissed(true)
        overlay.update(.connected)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertFalse(overlay.isDismissed)
    }
}
