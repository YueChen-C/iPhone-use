import XCTest
@testable import iPhoneUse

final class InputBackendPreferencesTests: XCTestCase {
    private let modern = "00008101-0018242C3400001E"
    private let older = "00008030-001A690E2EC3802E"

    func testEachExactDeviceRestoresSavedChoiceAcrossControllerRecreation() {
        let suite = "iPhoneUse.InputPreferenceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InputBackendPreferences(defaults: defaults)
        store.save(.ble, physicalID: modern)
        store.save(.usb, physicalID: older)
        let restartedStore = InputBackendPreferences(defaults: UserDefaults(suiteName: suite)!)
        let controller = USBInputController(requireUSB: { _ in XCTFail("Restore must not imply readiness") },
                                            preferences: restartedStore)
        XCTAssertEqual(controller.selected(modern), .ble)
        XCTAssertEqual(controller.selected(older), .usb)
        XCTAssertFalse(controller.applyDefault(physicalID: modern, version: "17.3"))
        XCTAssertEqual(controller.selected(modern), .ble, "Saved Bluetooth beats the iOS 17.3 default")
        XCTAssertEqual(controller.selected("unknown"), .ble)
        XCTAssertTrue(controller.stop(waitTimeout: 1))
    }

    func testDefaultsAndLaunchOverridesNeverOverwriteSavedUserChoice() throws {
        let suite = "iPhoneUse.InputPreferenceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InputBackendPreferences(defaults: defaults)
        let automatic = USBInputController(requireUSB: { _ in }, preferences: store)
        XCTAssertTrue(automatic.applyDefault(physicalID: modern, version: "17.3"))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(automatic.stop(waitTimeout: 1))
        store.save(.ble, physicalID: modern)
        let launch = USBInputController(requireUSB: { _ in }, preferences: store)
        try launch.selectAtLaunch(physicalID: modern)
        XCTAssertEqual(launch.selected(modern), .usb)
        XCTAssertEqual(store.load()[modern], .ble)
        XCTAssertTrue(launch.stop(waitTimeout: 1))
        let restarted = USBInputController(preferences: store)
        XCTAssertEqual(restarted.selected(modern), .ble)
        XCTAssertTrue(restarted.stop(waitTimeout: 1))
    }

    func testRejectedChoiceAndMalformedRecordsCannotReplacePreferenceOrMatchByPrefix() {
        let suite = "iPhoneUse.InputPreferenceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([modern: "ble", older: "invalid", "yue": "usb", "00008101": "usb"],
                     forKey: InputBackendPreferences.defaultsKey)
        let store = InputBackendPreferences(defaults: defaults)
        XCTAssertEqual(store.load(), [modern: .ble])
        store.save(.usb, physicalID: "00008101")
        XCTAssertEqual(store.load(), [modern: .ble])
        let controller = USBInputController(requireUSB: { _ in throw USBBackendCompatibility.Failure.unavailable },
                                            preferences: store)
        XCTAssertThrowsError(try controller.selectAtLaunch(physicalID: modern))
        XCTAssertEqual(store.load()[modern], .ble)
        XCTAssertEqual(controller.selected(modern), .ble)
        XCTAssertTrue(controller.stop(waitTimeout: 1))
    }
}
