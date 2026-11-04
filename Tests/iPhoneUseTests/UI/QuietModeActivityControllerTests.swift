import XCTest

@testable import iPhoneUse

final class QuietModeActivityControllerTests: XCTestCase {
    func testSixtySecondIdleRetainsBluetoothUntilPhysicalUSBUnplug() {
        var clock = 0.0
        var attached = true
        var restores = 0
        let manager = ScreenCaptureManager(restoreAllUSB: { _ in
            restores += 1
            return true
        })
        var policy = HIDLifecyclePolicy()
        policy.start(initialDisplayState: .allAsleep)
        var demands: [Bool] = []
        let syncDemand = {
            let snapshot = manager.sampleScreensWithRevision()
            XCTAssertTrue(snapshot.screens.isEmpty)
            XCTAssertTrue(policy.setUSBScreenDemand(snapshot.retainsUSBDemand, revision: snapshot.revision))
            demands.append(snapshot.retainsUSBDemand)
        }
        let controller = QuietModeActivityController(
            environment: [:], mode: { .residentQuiet }, now: { clock },
            suspendCapture: {
                let result = manager.suspendForIdle(waitTimeout: 1, hasAttachedIOSDevice: { attached })
                syncDemand()
                return result
            },
            checkIdleUnplug: {
                if manager.clearIdleUSBDemandIfUnplugged(hasAttachedIOSDevice: { attached }) { syncDemand() }
            }, resumeCapture: { XCTFail("No request should wake capture") })
        controller.start()
        defer { controller.stop() }
        clock = 59.99
        controller.checkIdle()
        XCTAssertFalse(controller.isSuspended)
        clock = 60
        controller.checkIdle()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(restores, 1)
        XCTAssertEqual(demands, [true])
        XCTAssertTrue(
            policy.shouldRunCoreBluetooth, "Idle video suspension must keep Bluetooth alive even with displays asleep")
        let retained = manager.sampleScreensWithRevision()
        controller.checkIdle()
        XCTAssertEqual(demands, [true], "An attached phone must retain demand on later idle checks")
        attached = false
        controller.checkIdle()
        XCTAssertEqual(demands, [true, false])
        XCTAssertFalse(policy.shouldRunCoreBluetooth)
        XCTAssertEqual(policy.inactiveReason, .idleNoDemand)
        XCTAssertFalse(policy.setUSBScreenDemand(retained.retainsUSBDemand, revision: retained.revision))
        XCTAssertFalse(policy.shouldRunCoreBluetooth, "Stale retained snapshots cannot undo unplug")
        controller.checkIdle()
        XCTAssertEqual(demands, [true, false], "Unplug notification must only be emitted once")
        XCTAssertEqual(restores, 1, "Unplug checks must not repeat capture shutdown")
    }

    func testIdleWithoutUSBAndOrdinaryStopDoNotRetainDemand() {
        let manager = ScreenCaptureManager(restoreAllUSB: { _ in true })
        XCTAssertTrue(manager.suspendForIdle(waitTimeout: 1, hasAttachedIOSDevice: { false }).isClean)
        XCTAssertFalse(manager.sampleScreensWithRevision().retainsUSBDemand)
        XCTAssertFalse(manager.clearIdleUSBDemandIfUnplugged(hasAttachedIOSDevice: { false }))
        XCTAssertTrue(manager.suspendForIdle(waitTimeout: 1, hasAttachedIOSDevice: { true }).isClean)
        XCTAssertTrue(manager.sampleScreensWithRevision().retainsUSBDemand)
        XCTAssertTrue(manager.stop(waitTimeout: 1).isClean)
        XCTAssertFalse(manager.sampleScreensWithRevision().retainsUSBDemand)
        XCTAssertFalse(manager.clearIdleUSBDemandIfUnplugged(hasAttachedIOSDevice: { false }))
    }

    func testIdleCaptureGapPreservesVerifiedBluetoothSessionAssociation() {
        let identity = UUID()
        let host = UUID()
        let session = UUID()
        let association = DeviceRegistry.Association(screen: identity, host: host, session: session)
        var verified: Set<DeviceRegistry.Association> = [association]
        DeviceRegistry.promoteVerifiedAssociations(
            &verified, screenIdentities: [:], pairings: ["phone": host], sessions: [host: session])
        XCTAssertEqual(verified, [association])
        DeviceRegistry.promoteVerifiedAssociations(
            &verified, screenIdentities: ["phone": identity], pairings: ["phone": host], sessions: [host: session])
        XCTAssertEqual(verified, [association])
    }

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
