import XCTest

@testable import iPhoneUse

final class DeviceBluetoothStateTests: XCTestCase {
    func testUSBOnlyReplacementIsDisconnectedWhileSEAndRemovedPhoneStayOnBluetooth() {
        let se = UUID()
        let removed = UUID()
        let replacement = UUID()
        let pairings = ["SE": se, "removed": removed, "new": replacement]
        let connected: Set<UUID> = [se, removed]
        XCTAssertEqual(
            DeviceBluetoothState.resolve(
                screenID: "SE", matchedHost: se, pairings: pairings, connectedHosts: connected), .connected)
        let state = DeviceBluetoothState.resolve(
            screenID: "new", matchedHost: nil, pairings: pairings, connectedHosts: connected)
        XCTAssertEqual(state, .disconnected)
        XCTAssertEqual(
            ControlConnectionStatus.resolve(
                hasScreen: true, hasMatchedHost: false, bluetoothState: state,
                inputIsCurrent: false, inputIsReady: false, screenPermitsInput: true), .disconnected)
    }

    func testOnlineSavedHostWaitsForIdentityProof() {
        let se = UUID()
        XCTAssertEqual(
            DeviceBluetoothState.resolve(
                screenID: "SE", matchedHost: nil, pairings: ["SE": se], connectedHosts: [se]), .unmatched)
    }

    func testFreshBluetoothPairingCanBeMatchedDespiteOfflineHistoricalHost() {
        XCTAssertEqual(
            DeviceBluetoothState.resolve(
                screenID: "new", matchedHost: nil, pairings: ["new": UUID()], connectedHosts: [UUID()]), .unmatched)
    }

    func testNewUSBOnlyPhoneDoesNotInheritAnotherPhonesConnection() {
        let other = UUID()
        XCTAssertEqual(
            DeviceBluetoothState.resolve(
                screenID: "new", matchedHost: nil, pairings: ["other": other], connectedHosts: [other]), .disconnected)
        XCTAssertEqual(
            DeviceBluetoothState.resolve(
                screenID: "new", matchedHost: nil, pairings: [:], connectedHosts: []), .disconnected)
    }
}
