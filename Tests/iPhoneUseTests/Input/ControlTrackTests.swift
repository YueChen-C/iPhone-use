import XCTest
@testable import iPhoneUse

final class ControlTrackTests: XCTestCase {
    func testTrackModeParsing() {
        XCTAssertEqual(ControlTrackMode.parse("standard"), .standard)
        XCTAssertEqual(ControlTrackMode.parse("retail"), .standard)
        XCTAssertEqual(ControlTrackMode.parse("std"), .standard)
        XCTAssertEqual(ControlTrackMode.parse("enhanced"), .enhanced)
        XCTAssertEqual(ControlTrackMode.parse("developer"), .enhanced)
        XCTAssertEqual(ControlTrackMode.parse("dev"), .enhanced)
        XCTAssertEqual(ControlTrackMode.parse("poki"), .enhanced)
        XCTAssertEqual(ControlTrackMode.parse("auto"), .auto)
        XCTAssertEqual(ControlTrackMode.parse("dual"), .auto)
        XCTAssertEqual(ControlTrackMode.parse("automatic"), .auto)
        XCTAssertNil(ControlTrackMode.parse("unknown"))
        XCTAssertNil(ControlTrackMode.parse(""))
        XCTAssertNil(ControlTrackMode.parse(nil))
    }

    func testCoordinatorInitialStateAndSwitchMode() {
        let dummyInput = DeviceInput(
            host: UUID(),
            session: UUID(),
            sleep: { _ in },
            reportSender: { _, _ in },
            reportReadiness: { _, _, _ in true }
        )
        let coordinator = DualTrackInputCoordinator(
            udid: "test-device-001",
            mode: .auto,
            standardInputResolver: { dummyInput }
        )

        XCTAssertEqual(coordinator.mode, .auto)
        XCTAssertEqual(coordinator.state, .enhancedActive)
        XCTAssertNil(coordinator.degradationReason)

        coordinator.switchMode(.standard)
        XCTAssertEqual(coordinator.mode, .standard)
        XCTAssertEqual(coordinator.state, .standardActive)

        coordinator.switchMode(.enhanced)
        XCTAssertEqual(coordinator.mode, .enhanced)
        XCTAssertEqual(coordinator.state, .enhancedActive)
    }

    func testStandardModeAlwaysUsesStandardTrack() throws {
        var reportsSent: [(ReportID, [UInt8])] = []
        let dummyInput = DeviceInput(
            host: UUID(),
            session: UUID(),
            sleep: { _ in },
            reportSender: { reportID, bytes in
                reportsSent.append((reportID, bytes))
            },
            reportReadiness: { _, _, _ in true }
        )
        let coordinator = DualTrackInputCoordinator(
            udid: "test-device-002",
            mode: .standard,
            standardInputResolver: { dummyInput }
        )

        try coordinator.button(name: "home")
        XCTAssertEqual(coordinator.state, .standardActive)
        XCTAssertFalse(reportsSent.isEmpty)
    }

    func testAutoModeFallbackToStandardWhenEnhancedFails() throws {
        var standardTapCalled = false
        let dummyInput = DeviceInput(
            host: UUID(),
            session: UUID(),
            sleep: { _ in },
            reportSender: { reportID, bytes in
                standardTapCalled = true
            },
            reportReadiness: { _, _, _ in true }
        )
        let coordinator = DualTrackInputCoordinator(
            udid: "non-existent-device-udid",
            mode: .auto,
            standardInputResolver: { dummyInput }
        )

        // Calling tap on auto mode with a non-existent device will cause enhanced driver to fail
        // and trigger automatic graceful fallback to standard input!
        try coordinator.tap(x: 100, y: 100, screenWidth: 390, screenHeight: 844)

        XCTAssertEqual(coordinator.state, .degradedToStandard)
        XCTAssertNotNil(coordinator.degradationReason)
        XCTAssertTrue(coordinator.degradationReason?.contains("Enhanced track failed on tap") == true)
        XCTAssertTrue(standardTapCalled)
    }

    func testControlAPITrackRoutes() throws {
        let reqStatus = HTTPRequest(method: "GET", path: "/track", query: [:], body: [:])
        let respStatus = ControlAPI.handle(reqStatus)
        // With no device connected, expect 400 or error json
        XCTAssertTrue(respStatus.status == 400 || respStatus.status == 200)

        let reqSwitchInvalid = HTTPRequest(
            method: "POST",
            path: "/track/switch",
            query: [:],
            body: ["mode": "invalid"]
        )
        let respSwitchInvalid = ControlAPI.handle(reqSwitchInvalid)
        XCTAssertEqual(respSwitchInvalid.status, 400)
    }

    func testJevTrackRouterDecisionAndAPI() throws {
        let router = JevTrackRouter.shared

        // Banking/sensitive intent routes to standard track
        let bankDecision = router.evaluateHeuristically(prompt: "帮我打开招商银行查下账户余额", appName: "cmb")
        XCTAssertEqual(bankDecision.mode, .standard)
        XCTAssertTrue(bankDecision.confidence > 0.8)

        // Deep extraction / AX tree intent routes to enhanced track
        let axDecision = router.evaluateHeuristically(prompt: "抓取当前页面的无障碍元素树和层级结构", appName: nil)
        XCTAssertEqual(axDecision.mode, .enhanced)
        XCTAssertTrue(axDecision.confidence > 0.8)

        // General navigation routes to auto
        let generalDecision = router.evaluateHeuristically(prompt: "向上滑动查看更多内容", appName: "photos")
        XCTAssertEqual(generalDecision.mode, .auto)

        // Test /track/decide HTTP endpoint
        let decideReq = HTTPRequest(
            method: "POST",
            path: "/track/decide",
            query: [:],
            body: ["prompt": "打开工商银行转账"]
        )
        let resp = ControlAPI.handle(decideReq)
        XCTAssertEqual(resp.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true)
        let decJson = try XCTUnwrap(json["decision"] as? [String: Any])
        XCTAssertEqual(decJson["mode"] as? String, "standard")
    }

    func testStandardModeBlocksAXTreeInspection() throws {
        let coordinator = DualTrackInputCoordinator(
            udid: "test-device-standard",
            mode: .standard,
            standardInputResolver: { throw DeviceError("Device disconnected") }
        )
        XCTAssertThrowsError(try coordinator.getAXTree()) { error in
            XCTAssertTrue("\(error)".contains("disabled in standard mode"))
        }
    }

    func testNormalizedCoordinatesPreserveFractionsOnFallback() throws {
        var pointerReports: [[UInt8]] = []
        let dummyInput = DeviceInput(
            host: UUID(),
            session: UUID(),
            sleep: { _ in },
            reportSender: { reportID, bytes in
                if reportID == .absolutePointer {
                    pointerReports.append(bytes)
                }
            },
            reportReadiness: { _, _, _ in true }
        )
        let coordinator = DualTrackInputCoordinator(
            udid: "non-existent-device-udid",
            mode: .auto,
            standardInputResolver: { dummyInput }
        )

        try coordinator.tap(x: 0.5, y: 0.5, screenWidth: 1179, screenHeight: 2556)
        XCTAssertFalse(pointerReports.isEmpty)
        let firstReport = try XCTUnwrap(pointerReports.first)
        let rawX = UInt16(firstReport[1]) | (UInt16(firstReport[2]) << 8)
        let rawY = UInt16(firstReport[3]) | (UInt16(firstReport[4]) << 8)
        XCTAssertEqual(rawX, 16384, accuracy: 2)
        XCTAssertEqual(rawY, 16384, accuracy: 2)
    }
}
