import XCTest

@testable import iPhoneUse

final class LockScreenRecognitionTests: XCTestCase {
    private let clock = LockScreenText(text: "3:40", bounds: CGRect(x: 0.31, y: 0.13, width: 0.37, height: 0.08))
    private func label(_ text: String, y: Double = 0.24) -> LockScreenText {
        LockScreenText(text: text, bounds: CGRect(x: 0.25, y: y, width: 0.5, height: 0.03))
    }

    func testLargeCenteredClockWithChargingOrDateMatches() {
        for text in ["目前电量100%", "80% Charged", "Friday, October 30", "10月30日 星期五"] {
            XCTAssertTrue(LockScreenRecognition.resemblesLockScreen([clock, label(text)]), text)
        }
    }

    func testUnlockPromptAndClockMatches() {
        for text in ["按下主屏幕按钮以打开", "Press home to open", "Swipe up to unlock", "Swipe up to open"] {
            XCTAssertTrue(LockScreenRecognition.resemblesLockScreen([clock, label(text, y: 0.9)]))
        }
    }

    func testDateAboveClockMatchesNewerLockScreenLayout() {
        for text in ["Friday, October 30", "10月30日 星期五"] {
            XCTAssertTrue(LockScreenRecognition.resemblesLockScreen([clock, label(text, y: 0.08)]))
        }
        XCTAssertFalse(LockScreenRecognition.resemblesLockScreen([clock, label("目前电量100%", y: 0.08)]))
    }

    func testStatusBarClockHomeWidgetsAndOrdinaryContentDoNotMatch() {
        let smallClock = LockScreenText(text: "9:41", bounds: CGRect(x: 0.43, y: 0.01, width: 0.14, height: 0.02))
        XCTAssertFalse(LockScreenRecognition.resemblesLockScreen([smallClock, label("目前电量100%")]))
        XCTAssertFalse(LockScreenRecognition.resemblesLockScreen([clock]))
        XCTAssertFalse(LockScreenRecognition.resemblesLockScreen([clock, label("天气 25°")]))
        XCTAssertFalse(LockScreenRecognition.resemblesLockScreen([clock, label("目前电量100%", y: 0.8)]))
        XCTAssertFalse(LockScreenRecognition.resemblesLockScreen([label("Swipe up to unlock", y: 0.9)]))
        XCTAssertFalse(LockScreenRecognition.resemblesLockScreen([]))
    }

    func testWidgetClockOutsideLockScreenGeometryIsRejected() {
        let widget = LockScreenText(text: "3:40", bounds: CGRect(x: 0.05, y: 0.13, width: 0.22, height: 0.06))
        XCTAssertFalse(LockScreenRecognition.resemblesLockScreen([widget, label("Friday, October 30")]))
    }
}
