import XCTest

@testable import iPhoneUse

final class QuietModeActivityControllerTests: XCTestCase {
    func testIdleWindowAndRequests() {
        var clock = 0.0
        var mode = AppRunMode.residentQuiet
        var suspends = 0
        var resumes = 0
        let controller = QuietModeActivityController(
            environment: ["IPHONE_USE_IDLE_TIMEOUT": "0.08"], mode: { mode }, now: { clock },
            suspendCapture: {
                suspends += 1
                return ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: true)
            }, resumeCapture: { resumes += 1 })
        controller.start()
        defer { controller.stop() }
        clock = 0.09
        controller.checkIdle()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(suspends, 1)
        controller.setOpenWindows(true)
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(resumes, 1)
        clock = 2
        controller.checkIdle()
        XCTAssertEqual(suspends, 1)
        controller.setOpenWindows(false)
        clock = 2.09
        controller.checkIdle()
        XCTAssertTrue(controller.isSuspended)
        let passive = HTTPRequest(method: "GET", path: "/config", query: ["wake": "0"], body: [:])
        _ = ControlAPI.handle(passive, ocrCapture: { _, _ in fatalError() }, activity: controller)
        XCTAssertTrue(controller.isSuspended)
        let normal = HTTPRequest(method: "GET", path: "/config", query: [:], body: [:])
        _ = ControlAPI.handle(normal, ocrCapture: { _, _ in fatalError() }, activity: controller)
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(resumes, 2)
        clock = 2.18
        controller.checkIdle()
        XCTAssertTrue(controller.isSuspended)
        mode = .desktop
        controller.modeChanged()
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(resumes, 3)
        clock = 10
        controller.checkIdle()
        XCTAssertEqual(suspends, 3)
    }

    func testIncompleteShutdownStillResumesAndCanSuspendAgain() {
        var clock = 0.0
        var resumes = 0
        let controller = QuietModeActivityController(
            environment: ["IPHONE_USE_IDLE_TIMEOUT": "0.08"], mode: { .residentQuiet }, now: { clock },
            suspendCapture: {
                ScreenCaptureStopResult(initiated: true, captureDrained: false, usbRestored: false)
            }, resumeCapture: { resumes += 1 })
        controller.start()
        defer { controller.stop() }
        clock = 1
        controller.checkIdle()
        XCTAssertTrue(controller.requestStarted())
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(resumes, 1)
        controller.requestFinished()
        clock = 2
        controller.checkIdle()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertTrue(controller.requestStarted())
        XCTAssertEqual(resumes, 2)
        controller.requestFinished()
    }

    func testWakeGraceWindowSurvivesFollowUpRequestsWithoutExtending() {
        var clock = 0.0
        let controller = QuietModeActivityController(
            environment: ["IPHONE_USE_IDLE_TIMEOUT": "0.08"], mode: { .residentQuiet }, now: { clock },
            suspendCapture: {
                ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: true)
            }, resumeCapture: {})
        controller.start()
        defer { controller.stop() }
        XCTAssertFalse(controller.isWithinWakeGraceWindow)
        XCTAssertFalse(controller.requestStarted())
        controller.requestFinished()
        XCTAssertFalse(controller.isWithinWakeGraceWindow)
        clock = 1
        controller.checkIdle()
        XCTAssertFalse(controller.isWithinWakeGraceWindow)
        XCTAssertTrue(controller.requestStarted())
        controller.requestFinished()
        XCTAssertTrue(controller.isWithinWakeGraceWindow)
        clock = 6.99
        XCTAssertFalse(controller.requestStarted())
        controller.requestFinished()
        XCTAssertTrue(controller.isWithinWakeGraceWindow)
        clock = 7
        XCTAssertFalse(controller.isWithinWakeGraceWindow)
    }

    func testSuspendingClearsWakeGraceWindowAndNextWakeStartsANewWindow() {
        var clock = 0.0
        let controller = QuietModeActivityController(
            environment: ["IPHONE_USE_IDLE_TIMEOUT": "0.08"], mode: { .residentQuiet }, now: { clock },
            suspendCapture: {
                ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: true)
            }, resumeCapture: {})
        controller.start()
        defer { controller.stop() }
        clock = 1
        controller.checkIdle()
        XCTAssertTrue(controller.requestStarted())
        controller.requestFinished()
        XCTAssertTrue(controller.isWithinWakeGraceWindow)
        clock = 1.1
        controller.checkIdle()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertFalse(controller.isWithinWakeGraceWindow)
        clock = 2
        XCTAssertTrue(controller.requestStarted())
        controller.requestFinished()
        clock = 7.99
        XCTAssertTrue(controller.isWithinWakeGraceWindow)
        controller.stop()
        XCTAssertFalse(controller.isWithinWakeGraceWindow)
    }

}
