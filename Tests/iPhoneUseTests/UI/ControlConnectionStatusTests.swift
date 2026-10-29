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
}
