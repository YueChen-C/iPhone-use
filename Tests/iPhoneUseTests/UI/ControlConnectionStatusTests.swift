import XCTest

@testable import iPhoneUse

final class ControlConnectionStatusTests: XCTestCase {
    func testDisabledWindowEventsPreservePendingDiscoveryRetry() {
        let capture = NSObject()
        let host = UUID()
        for state in [
            ControlConnectionStatus.waitingForDevice, .disconnected, .unmatched, .connecting,
            .verifyingScreen, .connected,
        ] {
            var schedule = DevicePairingProbeSchedule()
            _ = schedule.update(
                .init(screens: ["phone": ObjectIdentifier(capture)], sessions: [host: UUID()]), restart: true)
            guard let token = schedule.scheduleRetry() else { return XCTFail("expected discovery retry") }
            if state.permitsBackgroundMotionPreemption { schedule.cancel() }
            XCTAssertEqual(state.permitsBackgroundMotionPreemption, state == .connected)
            XCTAssertEqual(schedule.beginRetry(token), state != .connected)
        }
    }

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
