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

    func testExplicitPreparationRetryIsNotOfferedWhileReadyBusyUnsupportedOrAbsent() {
        for state in [InputBackendReadiness.failed, .identityUnverified, .disconnected, .requiresTrust,
                      .requiresDeveloperMode, .requiresDDI] {
            XCTAssertTrue(presentation(state).offersPreparationRetry, state.rawValue)
            XCTAssertFalse(presentation(state, hasScreen: false).offersPreparationRetry)
        }
        for state in [InputBackendReadiness.preparing, .ready, .unsupportedHost, .unsupportedDevice, .disabled] {
            XCTAssertFalse(presentation(state, ready: state == .ready).offersPreparationRetry)
        }
    }

    func testExplicitPreparationButtonDebouncesAndNeverCallsSetupOrBluetooth() throws {
        let old = AppLanguageStore.shared.language
        defer { AppLanguageStore.shared.set(old) }
        AppLanguageStore.shared.set(.en)
        let overlay = ControlConnectionOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 800), presentation: .inspector)
        overlay.updateUSB(presentation(.failed, detail: "native preflight diagnostic"))
        let buttons = descendants(overlay).compactMap { $0 as? NSButton }
        let retry = try XCTUnwrap(buttons.first { $0.title == StringsUSBControl.en.retryPreparation })
        let bluetooth = try XCTUnwrap(buttons.first { $0.title == StringsUI.en.overlayButtonReconnect })
        var retried = 0, setup = 0
        var finish: (() -> Void)?
        overlay.onRetryUSB = { completion in retried += 1; finish = completion }
        overlay.onEnableUSB = { setup += 1 }
        XCTAssertFalse(retry.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(bluetooth.isHiddenOrHasHiddenAncestor)
        retry.performClick(nil)
        XCTAssertEqual(retried, 1); XCTAssertFalse(retry.isEnabled)
        overlay.updateUSB(presentation(.failed)) // A polling update cannot enable a duplicate.
        retry.performClick(nil); XCTAssertEqual(retried, 1)
        finish?(); XCTAssertTrue(retry.isEnabled)
        XCTAssertEqual(setup, 0)
        AppLanguageStore.shared.set(.zh); overlay.refreshLocalization()
        XCTAssertEqual(retry.title, StringsUSBControl.zh.retryPreparation)
        overlay.updateUSB(presentation(.preparing)); XCTAssertTrue(retry.isHidden)
        overlay.updateUSB(presentation(.ready, capabilities: ["tap"], ready: true)); XCTAssertTrue(retry.isHidden)
        overlay.updateUSB(nil); XCTAssertTrue(retry.isHidden)
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

    func testVersionRefusalUsesExistingCardSurvivesPollingAndAcknowledgesWithoutUSBSetup() throws {
        let old = AppLanguageStore.shared.language
        defer { AppLanguageStore.shared.set(old) }
        AppLanguageStore.shared.set(.en)
        let overlay = ControlConnectionOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        overlay.update(.connected)
        XCTAssertTrue(overlay.isHidden)
        let message = StringsUSBControl.en.requiresiOS17("15.4")
        overlay.showBackendSelectionFailure(message)
        for _ in 0..<3 { overlay.update(.connected); overlay.updateUSB(nil) }
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(overlay.isDismissed)
        let views = descendants(overlay)
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == message && !$0.isHiddenOrHasHiddenAncestor
        })
        let buttons = views.compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(buttons.map(\.title), [StringsUSBControl.en.acknowledge])
        XCTAssertNotNil(overlay.hitTest(NSPoint(x: 10, y: 10)))
        var dismissed = false
        overlay.onNoticeDismissed = { dismissed = true }
        AppLanguageStore.shared.set(.zh); overlay.refreshLocalization()
        let acknowledge = try XCTUnwrap(buttons.first)
        XCTAssertEqual(acknowledge.title, StringsUSBControl.zh.acknowledge)
        let buttonRow = try XCTUnwrap(acknowledge.superview as? NSStackView)
        XCTAssertTrue(buttonRow.views(in: .center).contains(acknowledge))
        acknowledge.performClick(nil)
        XCTAssertTrue(dismissed)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertFalse(overlay.isDismissed)
    }

    func testRefusalDismissalRestoresConnectionGuidanceAndDisconnectClearsNotice() throws {
        let overlay = ControlConnectionOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        overlay.update(.disconnected)
        overlay.setDismissed(true)
        overlay.showBackendSelectionFailure("Unsupported iOS")
        XCTAssertFalse(overlay.isDismissed)
        overlay.showBackendSelectionFailure(nil)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(descendants(overlay).compactMap { $0 as? NSButton }.contains {
            $0.title == StringsUI.current.overlayButtonReconnect && !$0.isHiddenOrHasHiddenAncestor
        })
        overlay.showBackendSelectionFailure("Unsupported iOS")
        overlay.update(.waitingForDevice)
        overlay.update(.connected)
        XCTAssertTrue(overlay.isHidden)
    }

    func testSetupOfferRequiresMissingDDIOrTypedServiceEvidenceAndCurrentScreen() {
        XCTAssertTrue(presentation(.requiresDDI).offersUSBSetup)
        for reason in [USBPreparationFailure.Reason.serviceUnavailable, .touchscreenUnavailable] {
            XCTAssertTrue(presentation(.failed, reason: reason).offersUSBSetup)
            XCTAssertFalse(presentation(.failed, reason: reason, hasScreen: false).offersUSBSetup)
        }
        for state in InputBackendReadiness.allCases where state != .requiresDDI {
            XCTAssertFalse(presentation(state, ready: state == .ready, detail: "DDI service unavailable").offersUSBSetup)
        }
        XCTAssertFalse(presentation(.failed, reason: .displayUnavailable).offersUSBSetup)
        XCTAssertFalse(presentation(.unsupportedHost, reason: .serviceUnavailable).offersUSBSetup)
        XCTAssertFalse(presentation(.requiresDDI, hasScreen: false).offersUSBSetup)
    }

    func testOverlaySetupProgressCancellationAndCompletionNeverReconnectBluetooth() throws {
        let old = AppLanguageStore.shared.language
        defer { AppLanguageStore.shared.set(old) }
        AppLanguageStore.shared.set(.en)
        let overlay = ControlConnectionOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        overlay.updateUSB(presentation(.requiresDDI))
        let views = descendants(overlay)
        let buttons = views.compactMap { $0 as? NSButton }
        let setup = try XCTUnwrap(buttons.first { $0.title == StringsUSBSetup.en.enable })
        let viewOnly = try XCTUnwrap(buttons.first { $0.title == StringsUSBControl.en.viewOnly })
        let bar = try XCTUnwrap(views.compactMap { $0 as? NSProgressIndicator }.first)
        var enables = 0, cancels = 0
        overlay.onEnableUSB = { enables += 1 }
        overlay.onCancelUSBSetup = { cancels += 1 }
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == StringsUI.en.overlayButtonReconnect }).isHidden)
        XCTAssertFalse(setup.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains(StringsUSBSetup.en.consent) && !$0.isHiddenOrHasHiddenAncestor
        })
        setup.performClick(nil)
        XCTAssertEqual(enables, 1)
        overlay.updateSetup(.inspecting)
        XCTAssertFalse(bar.isHidden); XCTAssertTrue(bar.isIndeterminate)
        XCTAssertFalse(viewOnly.isEnabled)
        XCTAssertEqual(setup.title, StringsUSBSetup.en.cancel)
        setup.performClick(nil)
        XCTAssertEqual(cancels, 1)
        overlay.updateSetup(.downloading(5, 10))
        XCTAssertFalse(bar.isIndeterminate); XCTAssertEqual(bar.doubleValue, 0.5)
        overlay.updateSetup(.failed)
        XCTAssertTrue(bar.isHidden); XCTAssertTrue(viewOnly.isEnabled)
        XCTAssertEqual(setup.title, StringsUSBSetup.en.enable)
        overlay.updateSetup(.installing)
        XCTAssertTrue(setup.isHidden); XCTAssertFalse(bar.isHidden); XCTAssertTrue(bar.isIndeterminate)
        overlay.updateSetup(.connecting)
        overlay.updateUSB(presentation(.preparing))
        XCTAssertFalse(bar.isHidden); XCTAssertTrue(setup.isHidden)
        overlay.updateUSB(presentation(.ready, ready: true))
        overlay.updateSetup(.complete)
        XCTAssertFalse(overlay.isHidden); XCTAssertFalse(bar.isHidden)
        XCTAssertFalse(bar.isIndeterminate); XCTAssertEqual(bar.doubleValue, 1)
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == StringsUSBSetup.en.progress(.complete) && !$0.isHiddenOrHasHiddenAncestor
        })
        AppLanguageStore.shared.set(.zh); overlay.refreshLocalization()
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == StringsUSBSetup.zh.progress(.complete) && !$0.isHiddenOrHasHiddenAncestor
        })
        overlay.updateSetup(nil)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertEqual(enables, 1); XCTAssertEqual(cancels, 1)
        overlay.updateUSB(nil)
        XCTAssertTrue(setup.isHidden); XCTAssertTrue(bar.isHidden); XCTAssertTrue(viewOnly.isEnabled)
    }

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
        XCTAssertTrue(fields.contains { $0.stringValue.contains(StringsUSBControl.zh.guidance(.services)) })
        overlay.updateUSB(nil)
        XCTAssertFalse(overlay.isDismissed)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(fields.contains { $0.stringValue == StringsUI.zh.overlayHelp && !$0.isHidden })
        XCTAssertTrue(descendants(overlay).compactMap { $0 as? NSButton }.contains {
            $0.title == StringsUI.zh.overlayButtonReconnect && !$0.isHidden
        })
    }
}
