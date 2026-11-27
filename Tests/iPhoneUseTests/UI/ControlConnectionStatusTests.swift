import AppKit
import XCTest

@testable import iPhoneUse

final class ControlConnectionStatusTests: XCTestCase {
    func testUnmatchedStillAllowsManualRecheckButDisconnectedDoesNot() {
        XCTAssertTrue(DeviceBluetoothState.connected.canRecheckPointer)
        XCTAssertTrue(DeviceBluetoothState.unmatched.canRecheckPointer)
        XCTAssertFalse(DeviceBluetoothState.disconnected.canRecheckPointer)
    }

    func testUnmatchedOverlayDispatchesMatchingAndRestoresButtonWithFailure() throws {
        let overlay = ControlConnectionOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        var completion: ((Result<Void, Error>) -> Void)?
        overlay.onRetryBluetoothMatch = { completion = $0 }
        overlay.update(.unmatched)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(overlay)
        let strings = StringsWorkbench.current
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == strings.bluetoothMatchRetry })
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == strings.bluetoothMatching })

        try XCTUnwrap(completion)(.failure(BluetoothMatchRetryError.notObserved))
        let delivered = expectation(description: "matching completion rendered")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == strings.bluetoothMatchNotObserved })
        overlay.update(.disconnected)
        XCTAssertEqual(button.title, StringsUI.current.overlayButtonReconnect)
        XCTAssertTrue(button.isEnabled)
    }
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
            if state.permitsBackgroundMotionPreemption(backend: .ble) { schedule.cancel() }
            XCTAssertEqual(state.permitsBackgroundMotionPreemption(backend: .ble), state == .connected)
            XCTAssertEqual(schedule.beginRetry(token), state != .connected)
            XCTAssertFalse(state.permitsBackgroundMotionPreemption(backend: .usb),
                           "USB foreground input must not interrupt Bluetooth discovery")
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
