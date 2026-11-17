import XCTest
@testable import iPhoneUse

final class USBSetupPresentationTests: XCTestCase {
    private let states: [USBSetupPresentation] = [.inspecting, .downloading(5, 10), .retrying, .verifying,
                                                 .prepared, .cancelled, .failed]
    func testWorkingStatesAndClampedOrUnknownProgress() {
        XCTAssertEqual(states.map(\.isWorking), [true, true, true, true, false, false, false])
        XCTAssertEqual(USBSetupPresentation.downloading(5, 10).fraction, 0.5)
        XCTAssertEqual(USBSetupPresentation.downloading(-1, 10).fraction, 0)
        XCTAssertEqual(USBSetupPresentation.downloading(20, 10).fraction, 1)
        XCTAssertNil(USBSetupPresentation.downloading(0, -1).fraction)
        XCTAssertNil(USBSetupPresentation.verifying.fraction)
    }
    func testBothLanguagesHideSourceRoutingAndExplainInstallationBoundary() {
        for table in [StringsUSBSetup.zh, .en] {
            let values = [table.enable, table.consent, table.cancel, table.review]
                + states.map(table.progress)
            for text in values {
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.lowercased().contains("gitee"))
                XCTAssertFalse(text.lowercased().contains("github"))
                XCTAssertFalse(text.contains("优先")); XCTAssertFalse(text.contains("备用"))
            }
            XCTAssertTrue(table.consent.contains("18 MB")); XCTAssertTrue(table.consent.contains("60 MB"))
            XCTAssertTrue(table.progress(.downloading(5_000_000, 10_000_000)).contains("50%"))
        }
        XCTAssertTrue(StringsUSBSetup.zh.consent.contains("不会升级 iOS"))
        XCTAssertTrue(StringsUSBSetup.en.consent.contains("does not upgrade iOS"))
        XCTAssertTrue(StringsUSBSetup.zh.consent.contains("应用缓存"))
        XCTAssertTrue(StringsUSBSetup.en.consent.contains("app cache"))
        XCTAssertTrue(StringsUSBSetup.zh.progress(.prepared).contains("尚未安装"))
        XCTAssertTrue(StringsUSBSetup.en.progress(.prepared).contains("not installed"))
    }
}
