import AppKit
import XCTest

@testable import iPhoneUse

final class WorkbenchAppManagerTests: XCTestCase {
    private let device = "exact-device"
    private let first = "com.example.alpha"
    private let second = "com.example.beta"
    private let firstPath = "/Applications/A.app/A"
    private let secondPath = "/Applications/B.app/B"

    private func entries() -> [NativeAppInventory.Entry] {
        [
            .init(attributes: ["bundle_id": first, "name": "Alpha"], executablePath: firstPath),
            .init(attributes: ["bundle_id": second, "name": "备忘录"], executablePath: secondPath),
        ]
    }

    private func eventually(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }

    func testSearchesNameAndBundleIDCaseInsensitivelyAndRanksRunningFirst() {
        var apps = entries().compactMap(WorkbenchManagedApp.init)
        apps[1].state = .running
        XCTAssertEqual(WorkbenchManagedApp.visible(apps, query: "").map(\.bundleID), [second, first])
        XCTAssertEqual(WorkbenchManagedApp.visible(apps, query: "  ALpHa  ").map(\.bundleID), [first])
        XCTAssertEqual(WorkbenchManagedApp.visible(apps, query: "COM.EXAMPLE.BE").map(\.bundleID), [second])
        XCTAssertEqual(WorkbenchManagedApp.visible(apps, query: "备忘").map(\.bundleID), [second])
        XCTAssertTrue(WorkbenchManagedApp.visible(apps, query: "missing").isEmpty)
    }

    func testLaunchAndForceQuitUseBoundDeviceAndRefreshRatherThanGuessingState() throws {
        _ = NSApplication.shared
        let inventory = entries()
        var running = false  // Client calls are serialized by the sheet, including the refresh after a mutation.
        let client = WorkbenchAppManager.Client(
            inventory: { id in
                XCTAssertEqual(id, self.device)
                return inventory
            },
            processes: { id in
                XCTAssertEqual(id, self.device)
                return .init(paths: running ? [self.firstPath] : [], complete: true)
            },
            perform: { operation, id, bundleID in
                XCTAssertEqual(id, self.device)
                XCTAssertEqual(bundleID, self.first)
                XCTAssertNotEqual(running, operation == .launch, "no duplicate launch or force quit")
                running = operation == .launch
            })
        let view = WorkbenchAppManager(deviceID: device, deviceName: "Phone", language: .en, client: client)
        func state() -> NativeAppServices.RunningState? {
            view.visibleApps.first(where: { $0.bundleID == first })?.state
        }
        let table = try XCTUnwrap(
            view.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first)
        func button(_ operation: NativeAppManagement.Operation) throws -> NSButton {
            let row = try XCTUnwrap(view.visibleApps.firstIndex { $0.bundleID == first })
            let cell = view.tableView(table, viewFor: table.tableColumns.last, row: row)
            return try XCTUnwrap(
                cell?.subviews.compactMap { $0 as? NSButton }.first {
                    $0.accessibilityIdentifier() == "app-manager-\(operation.rawValue):\(first)"
                })
        }
        view.refresh()
        eventually { state() == .stopped }
        XCTAssertFalse(try button(.terminate).isEnabled)
        view.operate(.terminate, bundleID: first)  // stopped: no mutation
        view.operate(.launch, bundleID: "com.example.foreign")  // stale or invalid row: no mutation
        try button(.launch).performClick(nil)
        view.operate(.launch, bundleID: first)  // no duplicate send while busy
        eventually { state() == .running }
        XCTAssertTrue(try button(.terminate).isEnabled)
        try button(.terminate).performClick(nil)
        eventually { state() == .stopped }
    }

    func testProcessResultFromBeforeDisconnectIsDiscarded() {
        _ = NSApplication.shared
        let inventory = entries()
        let started = expectation(description: "Process query started")
        let release = DispatchSemaphore(value: 0)
        let client = WorkbenchAppManager.Client(
            inventory: { _ in inventory },
            processes: { _ in
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return .init(paths: [self.firstPath], complete: true)
            }, perform: { _, _, _ in XCTFail("Unexpected mutation") })
        let view = WorkbenchAppManager(deviceID: device, deviceName: "Phone", language: .zh, client: client)
        let refresh = view.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "app-manager-refresh"
        }
        view.refresh()
        wait(for: [started], timeout: 3)
        XCTAssertEqual(view.visibleApps.count, 2, "inventory is shown while process status is pending")
        view.setConnected(false)
        view.setConnected(true)
        release.signal()
        eventually { refresh?.isEnabled == true }
        XCTAssertTrue(view.visibleApps.isEmpty, "disconnect invalidates both old inventory and in-flight status")
    }

    func testFailedProcessReadKeepsAppsAndDisconnectClearsThem() {
        _ = NSApplication.shared
        let inventory = entries()
        let client = WorkbenchAppManager.Client(
            inventory: { _ in inventory },
            processes: { _ in throw DeviceError("Not available") },
            perform: { _, _, _ in XCTFail("Unexpected mutation") })
        let view = WorkbenchAppManager(deviceID: device, deviceName: "Phone", language: .en, client: client)
        let refresh = view.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "app-manager-refresh"
        }
        view.refresh()
        eventually { refresh?.isEnabled == true }
        XCTAssertEqual(view.visibleApps.count, 2)
        XCTAssertTrue(view.visibleApps.allSatisfy { $0.state == .unknown })
        view.setConnected(false)
        XCTAssertTrue(view.visibleApps.isEmpty)
        XCTAssertEqual(refresh?.isEnabled, false)
        view.operate(.launch, bundleID: first)
        view.setConnected(true)
        XCTAssertTrue(view.visibleApps.isEmpty, "do not restore an old snapshot")
        XCTAssertEqual(refresh?.isEnabled, true)
    }
}
