import XCTest

@testable import iPhoneUse

final class ControlWindowStateTests: XCTestCase {
    func testStartupWaitsWithoutADeviceAndOpensEachConnectedPhoneOnce() {
        var state = ControlWindowState()
        XCTAssertEqual(state.update(connectedIDs: []), [])
        XCTAssertTrue(state.needsWaitingWindow)

        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"]), ["phone-a", "phone-b"])
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertEqual(state.update(connectedIDs: ["phone-b", "phone-a"]), [])
        XCTAssertEqual(state.deviceIDs, ["phone-a", "phone-b"])
    }

    func testDisconnectAndReconnectKeepTheSameWindowsWithoutRetargeting() {
        var state = ControlWindowState()
        _ = state.update(connectedIDs: ["phone-a", "phone-b"])

        XCTAssertEqual(state.update(connectedIDs: ["phone-b", "phone-c"]), ["phone-c"])
        XCTAssertEqual(state.deviceIDs, ["phone-a", "phone-b", "phone-c"])
        XCTAssertEqual(state.update(connectedIDs: []), [])
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertEqual(state.update(connectedIDs: ["phone-a"]), [])
    }

    func testClosingOneWindowKeepsOtherWindowsAndDoesNotReopenOnEveryRefresh() {
        var state = ControlWindowState()
        _ = state.update(connectedIDs: ["phone-a", "phone-b"])

        XCTAssertFalse(state.close(deviceID: "phone-a"))
        for _ in 0..<3 {
            XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"]), [])
        }
        XCTAssertEqual(state.deviceIDs, ["phone-b"])
        XCTAssertTrue(state.close(deviceID: "phone-b"))
    }

    func testShowAllReopensClosedWindowsWithoutDuplicatingExistingOnes() {
        var state = ControlWindowState()
        _ = state.update(connectedIDs: ["phone-a", "phone-b"])
        _ = state.close(deviceID: "phone-a")

        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"], reopenClosed: true), ["phone-a"])
        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"], reopenClosed: true), [])
        XCTAssertEqual(state.deviceIDs, ["phone-a", "phone-b"])
    }

    func testReconnectingAManuallyClosedDeviceOpensANewWindow() {
        var state = ControlWindowState()
        _ = state.update(connectedIDs: ["phone-a", "phone-b"])
        _ = state.close(deviceID: "phone-a")

        XCTAssertEqual(state.update(connectedIDs: ["phone-b"]), [])
        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"]), ["phone-a"])
    }

    func testClosingTheOnlyDisconnectedWindowOrStartupPlaceholderExits() {
        var state = ControlWindowState()
        XCTAssertTrue(state.close(deviceID: nil))
        _ = state.update(connectedIDs: ["phone-a"])
        _ = state.update(connectedIDs: [])
        XCTAssertTrue(state.close(deviceID: "phone-a"))
    }

    func testResidentQuietSuppressesStartupPlaceholderAndHotplugWindows() {
        var state = ControlWindowState(mode: .residentQuiet)
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertEqual(state.update(connectedIDs: []), [])
        XCTAssertFalse(state.needsWaitingWindow)

        XCTAssertEqual(state.update(connectedIDs: ["phone-a"]), [])
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertEqual(state.deviceIDs, [])

        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"]), [])
        XCTAssertEqual(state.deviceIDs, [])
    }

    func testResidentQuietOpensOnExplicitRequestAndKeepsRunningWhenLastWindowCloses() {
        var state = ControlWindowState(mode: .residentQuiet)
        _ = state.update(connectedIDs: ["phone-a"])

        // Dock reopen or Window -> Show All Devices explicitly presents connected phones.
        XCTAssertEqual(state.update(connectedIDs: ["phone-a"], reason: .userRequest), ["phone-a"])
        XCTAssertFalse(state.needsWaitingWindow)

        // Plugging in a second phone while one window is open stays silent until requested.
        XCTAssertEqual(state.update(connectedIDs: ["phone-a", "phone-b"], reason: .discovery), [])
        XCTAssertEqual(state.deviceIDs, ["phone-a"])

        // Closing the last window neither terminates the process nor spawns a waiting window.
        XCTAssertFalse(state.close(deviceID: "phone-a"))
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertEqual(state.deviceIDs, [])

        // Unplugging and reconnecting the phone in quiet mode does not pop a new window.
        XCTAssertEqual(state.update(connectedIDs: []), [])
        XCTAssertEqual(state.update(connectedIDs: ["phone-a"]), [])
        XCTAssertFalse(state.needsWaitingWindow)
    }

    func testResidentQuietExplicitRequestWithoutDevicesShowsDismissiblePlaceholder() {
        var state = ControlWindowState(mode: .residentQuiet)
        XCTAssertEqual(state.update(connectedIDs: [], reason: .userRequest), [])
        XCTAssertTrue(state.needsWaitingWindow)

        // While the waiting placeholder is minimized, hotplug must not pop an unminimized window.
        XCTAssertEqual(
            state.update(
                connectedIDs: ["phone-a"], reason: .discovery, canReplaceWaitingWindow: false),
            [])
        XCTAssertTrue(state.needsWaitingWindow)

        // Once visible (e.g. unminimized), the open placeholder transitions to the connected phone.
        XCTAssertEqual(
            state.update(
                connectedIDs: ["phone-a"], reason: .discovery, canReplaceWaitingWindow: true),
            ["phone-a"])
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertFalse(state.close(deviceID: "phone-a"))

        // Opening and closing the waiting placeholder itself also keeps the service alive.
        XCTAssertEqual(state.update(connectedIDs: [], reason: .userRequest), [])
        XCTAssertTrue(state.needsWaitingWindow)
        XCTAssertFalse(state.close(deviceID: nil))
        XCTAssertFalse(state.needsWaitingWindow)
    }

    func testTogglingBetweenDesktopAndResidentQuietRestoresZeroWindowSurfaceSafely() {
        var state = ControlWindowState(mode: .desktop)
        XCTAssertEqual(state.update(connectedIDs: []), [])
        XCTAssertTrue(state.needsWaitingWindow)

        // Enabling quiet mode at runtime keeps an already-visible placeholder until closed.
        state.setMode(.residentQuiet)
        XCTAssertTrue(state.needsWaitingWindow)
        XCTAssertFalse(state.close(deviceID: nil))
        XCTAssertFalse(state.needsWaitingWindow)

        // Returning to desktop mode with zero windows and no phone restores the waiting placeholder.
        state.setMode(.desktop)
        XCTAssertEqual(state.update(connectedIDs: [], reason: .resumeDesktopMode), [])
        XCTAssertTrue(state.needsWaitingWindow)

        // Returning to desktop mode with zero windows while a phone is connected opens that phone.
        state.setMode(.residentQuiet)
        _ = state.close(deviceID: nil)
        _ = state.update(connectedIDs: ["phone-a"], reason: .userRequest)
        XCTAssertFalse(state.close(deviceID: "phone-a"))
        state.setMode(.desktop)
        XCTAssertEqual(state.update(connectedIDs: ["phone-a"], reason: .resumeDesktopMode), ["phone-a"])
        XCTAssertFalse(state.needsWaitingWindow)
        XCTAssertTrue(state.close(deviceID: "phone-a"))
    }
}

final class AppRunModeStoreTests: XCTestCase {
    func testPrecedenceAndPersistenceWithoutMutatingDefaultsOnStartupOverrides() throws {
        let suite = "run-mode-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppRunModeStore(defaults: defaults, arguments: ["iphone-use"], environment: [:]).mode, .desktop)

        defaults.set("bogus", forKey: AppRunModeStore.defaultsKey)
        XCTAssertEqual(AppRunModeStore(defaults: defaults, arguments: ["iphone-use"], environment: [:]).mode, .desktop)

        // Explicit menu changes persist and notify only on actual transitions.
        let store = AppRunModeStore(defaults: defaults, arguments: ["iphone-use"], environment: [:])
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: AppRunModeStore.didChangeNotification, object: store, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.set(.desktop)
        XCTAssertEqual(defaults.string(forKey: AppRunModeStore.defaultsKey), "desktop")
        XCTAssertEqual(notifications, 0)

        store.set(.residentQuiet)
        XCTAssertEqual(store.mode, .residentQuiet)
        XCTAssertEqual(defaults.string(forKey: AppRunModeStore.defaultsKey), "residentQuiet")
        XCTAssertEqual(notifications, 1)

        store.set(.residentQuiet)
        XCTAssertEqual(notifications, 1)

        // Environment overrides persisted defaults without rewriting UserDefaults; invalid env falls through.
        XCTAssertEqual(
            AppRunModeStore(
                defaults: defaults,
                arguments: ["iphone-use"],
                environment: [AppRunModeStore.environmentKey: "desktop"]
            ).mode,
            .desktop)
        XCTAssertEqual(defaults.string(forKey: AppRunModeStore.defaultsKey), "residentQuiet")
        XCTAssertEqual(
            AppRunModeStore(
                defaults: defaults,
                arguments: ["iphone-use"],
                environment: [AppRunModeStore.environmentKey: "invalid"]
            ).mode,
            .residentQuiet)

        // CLI flags override both environment and persisted defaults; last explicit flag wins.
        XCTAssertEqual(
            AppRunModeStore(
                defaults: defaults,
                arguments: ["iphone-use", "--desktop", "--resident-quiet"],
                environment: [AppRunModeStore.environmentKey: "desktop"]
            ).mode,
            .residentQuiet)
        XCTAssertEqual(
            AppRunModeStore(
                defaults: defaults,
                arguments: ["iphone-use", "--resident-quiet", "--desktop"],
                environment: [AppRunModeStore.environmentKey: "resident-quiet"]
            ).mode,
            .desktop)

        XCTAssertFalse(StringsUI.zh.quietBackgroundMode.isEmpty)
        XCTAssertFalse(StringsUI.en.quietBackgroundMode.isEmpty)
        XCTAssertNotEqual(StringsUI.zh.quietBackgroundMode, StringsUI.en.quietBackgroundMode)
    }

    func testConcurrentSetSerializesPersistenceAndInMemoryMode() throws {
        let suite = "run-mode-concurrency-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstEnteredPersist = DispatchSemaphore(value: 0)
        let secondReadyToEnterSet = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var pausedFirstQuietWrite = false

        let store = AppRunModeStore(
            defaults: defaults,
            arguments: ["iphone-use"],
            environment: [:],
            persistHook: { mode in
                let shouldPause = hookLock.withLock { () -> Bool in
                    guard mode == .residentQuiet, !pausedFirstQuietWrite else { return false }
                    pausedFirstQuietWrite = true
                    return true
                }
                guard shouldPause else { return }
                firstEnteredPersist.signal()
                _ = secondReadyToEnterSet.wait(timeout: .now() + 1.0)
                // Give the competing set(.desktop) call time to contend on store.lock
                // while this transaction is still mid-flight after defaults.set.
                Thread.sleep(forTimeInterval: 0.02)
            })

        let observer = NotificationCenter.default.addObserver(
            forName: AppRunModeStore.didChangeNotification, object: store, queue: nil
        ) { _ in
            // Reading store.mode synchronously inside the observer verifies post() runs unlocked.
            _ = store.mode
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            store.set(.residentQuiet)
            group.leave()
        }

        XCTAssertEqual(firstEnteredPersist.wait(timeout: .now() + 1.0), .success)

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            secondReadyToEnterSet.signal()
            store.set(.desktop)
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(store.mode, .desktop)
        XCTAssertEqual(defaults.string(forKey: AppRunModeStore.defaultsKey), store.mode.rawValue)
        XCTAssertEqual(
            AppRunModeStore(defaults: defaults, arguments: ["iphone-use"], environment: [:]).mode,
            store.mode)

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            store.set(index.isMultiple(of: 2) ? .residentQuiet : .desktop)
        }
        XCTAssertEqual(defaults.string(forKey: AppRunModeStore.defaultsKey), store.mode.rawValue)
    }
}

final class MultiDeviceWindowInputTests: XCTestCase {
    func testCancellingOneWindowDragLeavesTheOtherDevicePressedAndBusy() throws {
        var firstReports: [[UInt8]] = []
        var secondReports: [[UInt8]] = []
        let first = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { _, bytes in firstReports.append(bytes) })
        let second = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { _, bytes in secondReports.append(bytes) })

        first.press(x: 0.25, y: 0.25)
        second.press(x: 0.75, y: 0.75)
        // These synchronous API calls drain each device queue before observing
        // its window drag. Both must reject a competing coordinate operation.
        XCTAssertThrowsError(try first.nudge(dx: 0, dy: 0, click: false))
        XCTAssertThrowsError(try second.nudge(dx: 0, dy: 0, click: false))
        let secondBeforeCancel = secondReports

        // Losing focus or closing the first window releases only that phone.
        first.cancelPointer()
        try first.nudge(dx: 0, dy: 0, click: false)
        XCTAssertEqual(firstReports.last, [0, 0, 32, 0, 32])
        XCTAssertThrowsError(try second.nudge(dx: 0, dy: 0, click: false))
        XCTAssertEqual(secondReports, secondBeforeCancel)
        XCTAssertEqual(secondReports.last?.first, 1)

        // Its API can resume while the second phone's window is still dragging.
        try first.tap(x: 0.5, y: 0.5)
        XCTAssertThrowsError(try second.nudge(dx: 0, dy: 0, click: false))
        XCTAssertEqual(secondReports, secondBeforeCancel)
        second.cancelPointer()
        try second.nudge(dx: 0, dy: 0, click: false)
        XCTAssertEqual(secondReports.last, [0, 255, 95, 255, 95])
    }
}
