import AppKit
import XCTest
@testable import iPhoneUse

final class ControlUSBPresentationTests: XCTestCase {
    private func presentation(_ state: InputBackendReadiness, reason: USBPreparationFailure.Reason? = nil,
                              capabilities: [String] = [], ready: Bool = false, hasScreen: Bool = true,
                              detail: String = "") -> ControlUSBPresentation {
        var snapshot: [String: Any] = ["state": state.rawValue, "capabilities": capabilities, "detail": detail]
        snapshot["reason"] = reason?.rawValue
        return .init(snapshot: snapshot, inputReady: ready, hasScreen: hasScreen)
    }

    func testReadyPresentationRequiresLiveInputAndSeparatesKeyboardCapability() {
        let touch = presentation(.ready, capabilities: ["tap"], ready: true)
        let keyboard = presentation(.ready, capabilities: ["tap", "text", "key"], ready: true)
        XCTAssertFalse(touch.showsOverlay)
        XCTAssertFalse(touch.keyboardReady)
        XCTAssertTrue(keyboard.keyboardReady)
        XCTAssertNotEqual(StringsUSBControl.en.status(touch), StringsUSBControl.en.status(keyboard))
        for capabilities in [["text"], ["key"], []] {
            XCTAssertFalse(presentation(.ready, capabilities: capabilities, ready: true).keyboardReady)
        }
        let stale = presentation(.ready, capabilities: ["text", "key"], ready: false)
        XCTAssertEqual(stale.state, .failed)
        XCTAssertTrue(stale.showsOverlay)
        XCTAssertFalse(stale.keyboardReady)
        let absent = presentation(.ready, capabilities: ["text", "key"], ready: true, hasScreen: false)
        XCTAssertEqual(absent.state, .disconnected)
        XCTAssertEqual(absent.recovery, .connect)
        XCTAssertFalse(absent.keyboardReady)
    }

    func testButtonCapabilityRequiresCompleteCurrentSnapshotNotKeyboard() {
        let buttons = USBHardwareButton.allCases.map(\.rawValue)
        let ready = presentation(.ready, capabilities: buttons, ready: true)
        XCTAssertTrue(ready.buttonsReady); XCTAssertFalse(ready.keyboardReady)
        XCTAssertEqual(StringsUSBControl.en.status(ready), "USB · Mouse and buttons ready")
        XCTAssertEqual(StringsUSBControl.zh.status(ready), "USB · 鼠标与按键已就绪")
        XCTAssertEqual(StringsUSBControl.en.status(presentation(.ready, capabilities: buttons + ["text", "key"], ready: true)),
                       "USB · Mouse, keyboard and buttons ready")
        XCTAssertFalse(presentation(.ready, capabilities: buttons, ready: false).buttonsReady)
        XCTAssertFalse(presentation(.ready, capabilities: buttons, ready: true, hasScreen: false).buttonsReady)
        XCTAssertFalse(presentation(.failed, capabilities: buttons, ready: true).buttonsReady)
        XCTAssertFalse(presentation(.ready, capabilities: ["home"], ready: true).buttonsReady)
    }

    func testRecoveryUsesTypedEvidenceAndDoesNotReadDiagnosticProse() {
        XCTAssertEqual(presentation(.failed, reason: .displayUnavailable).recovery, .display)
        for reason in [USBPreparationFailure.Reason.serviceUnavailable, .touchscreenUnavailable] {
            XCTAssertEqual(presentation(.failed, reason: reason).recovery, .services)
        }
        XCTAssertEqual(presentation(.identityUnverified, reason: .identityMismatch).recovery, .identity)
        XCTAssertEqual(presentation(.unsupportedHost, reason: .hostUnsupported).recovery, .host)
        for text in ["requiresDDI", "trust", "developer mode", "host_unsupported"] {
            XCTAssertEqual(presentation(.failed, detail: text).recovery, .select)
        }
        let conflicting = presentation(.unsupportedHost, reason: .displayUnavailable)
        XCTAssertNil(conflicting.reason)
        XCTAssertEqual(conflicting.recovery, .host)
    }

    func testEveryStateAndReasonHasLocalizedBoundedReadOnlyGuidance() {
        for state in InputBackendReadiness.allCases {
            let value = presentation(state, ready: state == .ready)
            XCTAssertFalse(StringsUSBControl.en.status(value).isEmpty)
            XCTAssertFalse(StringsUSBControl.zh.status(value).isEmpty)
            XCTAssertNotEqual(StringsUSBControl.en.status(value), StringsUSBControl.zh.status(value))
            XCTAssertFalse(StringsUSBControl.en.guidance(value.recovery).isEmpty)
            XCTAssertFalse(StringsUSBControl.zh.guidance(value.recovery).isEmpty)
        }
        let detail = String(repeating: "diagnostic", count: 1000)
        XCTAssertEqual(presentation(.failed, detail: detail).detail.count, 4096)
        XCTAssertEqual(ControlUSBPresentation(snapshot: ["state": "future"], inputReady: true, hasScreen: true).state, .failed)
        XCTAssertNotEqual(StringsUSBControl.en.guidance(.services), StringsUSBControl.en.guidance(.ddi))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testUSBFaultShowsExistingOverlayWithoutBluetoothReconnectOrPairing() throws {
        let old = AppLanguageStore.shared.language
        defer { AppLanguageStore.shared.set(old) }
        AppLanguageStore.shared.set(.en)
        let overlay = ControlConnectionOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        overlay.update(.verifyingScreen) // USB gates input without invoking BLE status.
        overlay.updateUSB(presentation(.failed, reason: .displayUnavailable))
        XCTAssertFalse(overlay.isHidden)
        let fields = descendants(overlay).compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue == StringsUSBControl.en.guidance(.display) && !$0.isHidden })
        let visibleTexts = Set(fields.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue))
        XCTAssertEqual(visibleTexts, [StringsUSBControl.en.title, "USB · Display unavailable",
                                    StringsUSBControl.en.guidance(.display)])
        let buttons = descendants(overlay).compactMap { $0 as? NSButton }
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == StringsUI.en.overlayButtonReconnect }).isHidden)
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == StringsUSBControl.en.viewOnly }).isEnabled)
        overlay.setDismissed(true)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 10, y: 10))) // View-only does not grant input.
        overlay.updateUSB(presentation(.ready, capabilities: ["tap"], ready: true))
        XCTAssertTrue(overlay.isHidden)
        XCTAssertFalse(overlay.isDismissed)
    }

    func testLocalizationAndBackendSwitchRestoreCorrectOverlayWithoutChangingInput() {
        let old = AppLanguageStore.shared.language
        defer { AppLanguageStore.shared.set(old) }
        AppLanguageStore.shared.set(.en)
        let overlay = ControlConnectionOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        overlay.update(.disconnected)
        overlay.updateUSB(presentation(.failed, reason: .serviceUnavailable))
        overlay.setDismissed(true)
        AppLanguageStore.shared.set(.zh)
        overlay.refreshLocalization()
        XCTAssertTrue(overlay.isDismissed)
        let fields = descendants(overlay).compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue == StringsUSBControl.zh.guidance(.services) })
        overlay.updateUSB(nil)
        XCTAssertFalse(overlay.isDismissed)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(fields.contains { $0.stringValue == StringsUI.zh.overlayHelp && !$0.isHidden })
        XCTAssertTrue(descendants(overlay).compactMap { $0 as? NSButton }.contains {
            $0.title == StringsUI.zh.overlayButtonReconnect && !$0.isHidden
        })
    }
}
