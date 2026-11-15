import XCTest
@testable import iPhoneUse

final class ControlUSBShortcutTests: XCTestCase {
    func testKeyboardAndPhoneButtonsHaveIndependentUSBCapabilities() throws {
        let supported: Set<ControlShortcut> = [.search, .paste, .enter]
        for shortcut in ControlShortcut.allCases {
            XCTAssertEqual(shortcut.isAvailableUSB(keyboardReady: true), supported.contains(shortcut))
            XCTAssertFalse(shortcut.isAvailableUSB(keyboardReady: false))
            XCTAssertEqual(shortcut.isAvailableUSB(keyboardReady: false, buttonsReady: true), !supported.contains(shortcut))
            XCTAssertTrue(shortcut.isAvailableUSB(keyboardReady: true, buttonsReady: true))
        }
        let search = try XCTUnwrap(ControlShortcut.search.usbKey)
        XCTAssertEqual(search.name, "space"); XCTAssertEqual(search.modifiers, ["cmd"])
        let paste = try XCTUnwrap(ControlShortcut.paste.usbKey)
        XCTAssertEqual(paste.name, "v"); XCTAssertEqual(paste.modifiers, ["cmd"])
        let enter = try XCTUnwrap(ControlShortcut.enter.usbKey)
        XCTAssertEqual(enter.name, "enter"); XCTAssertTrue(enter.modifiers.isEmpty)
        for shortcut in [ControlShortcut.home, .power, .volumeUp, .volumeDown] {
            XCTAssertNil(shortcut.usbKey)
            XCTAssertNotNil(shortcut.usbButton)
        }
    }

    func testUSBShortcutsUseSameNativeStrokeEncodingAsPublicKeys() throws {
        for shortcut in [ControlShortcut.search, .paste, .enter] {
            let key = try XCTUnwrap(shortcut.usbKey)
            let stroke = try USBKeyboardRequest.key(key.name, modifiers: key.modifiers)
            XCTAssertEqual(stroke.code, KeyboardMap.code(for: key.name))
            XCTAssertEqual(stroke.modifiers, shortcut == .enter ? 0 : 8)
            XCTAssertEqual(try USBKeyboardReport.encode(code: stroke.code, modifiers: stroke.modifiers).count, 31)
        }
    }

    func testUSBFeedbackOnlyClaimsAcknowledgementNotVisibleUIEffect() {
        let zh = StringsUSBControl.zh.shortcutAcknowledged("回车")
        let en = StringsUSBControl.en.shortcutAcknowledged("Enter")
        XCTAssertTrue(zh.contains("检查画面"))
        XCTAssertTrue(en.contains("inspect screen"))
        XCTAssertTrue(StringsUSBControl.zh.shortcutFailed.contains("勿重放"))
        XCTAssertTrue(StringsUSBControl.en.shortcutFailed.contains("do not replay"))
    }
}
