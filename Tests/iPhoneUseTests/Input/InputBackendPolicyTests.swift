import XCTest

@testable import iPhoneUse

final class InputBackendPolicyTests: XCTestCase {
    private let device = "PHYSICAL_DEVICE"
    private let session = UUID()
    private let generation = UUID()

    private func snapshot(
        _ backend: InputBackendKind = .usb, id: String? = nil,
        session: UUID? = nil, readiness: InputBackendReadiness = .ready,
        capabilities: Set<InputCapability> = [.tap]
    ) -> InputBackendSnapshot {
        InputBackendSnapshot(
            backend: backend, physicalDeviceID: id ?? device, sessionID: session ?? self.session,
            readiness: readiness, capabilities: capabilities)
    }

    private func route(
        _ snapshots: [InputBackendSnapshot], selected: InputBackendKind = .usb,
        id: String? = nil, capability: InputCapability = .tap
    ) throws -> InputRouteLease {
        try InputBackendPolicy.resolve(
            selected: selected, physicalDeviceID: id ?? device, generation: generation,
            capability: capability, snapshots: snapshots)
    }

    private func fails(
        _ code: InputRoutingError.Code, backend: InputBackendKind = .usb,
        _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? InputRoutingError, InputRoutingError(code: code, backend: backend),
                file: file, line: line)
        }
    }

    func testDefaultRemainsBluetooth() {
        XCTAssertEqual(InputBackendPolicy.defaultBackend, .ble)
    }

    func testUSBReadyRequiresNoBluetoothHostOrCalibration() throws {
        let lease = try route([snapshot()])
        XCTAssertEqual(lease.backend, .usb)
        XCTAssertEqual(lease.physicalDeviceID, device)
        XCTAssertEqual(lease.sessionID, session)
        XCTAssertEqual(lease.generation, generation)
        XCTAssertEqual(lease.capability, .tap)
    }

    func testExplicitBackendSelectionDoesNotPreferAnotherReadyTransport() throws {
        let states = [snapshot(.ble), snapshot(.usb)]
        XCTAssertEqual(try route(states).backend, .usb)
        XCTAssertEqual(try route(states, selected: .ble).backend, .ble)
    }

    func testUnavailableUSBDoesNotFallBackToReadyBluetooth() {
        fails(.backendUnavailable) { _ = try self.route([self.snapshot(.ble)]) }
    }

    func testEveryNonReadyUSBStateRejectsEvenWithReadyBluetooth() {
        for state in InputBackendReadiness.allCases where state != .ready {
            fails(.inputNotReady) {
                _ = try self.route([self.snapshot(.ble), self.snapshot(readiness: state)])
            }
        }
    }

    func testUnsupportedKeyboardDoesNotSilentlyUseBluetooth() {
        fails(.unsupportedCapability) {
            _ = try self.route([self.snapshot(.usb), self.snapshot(.ble, capabilities: [.text])], capability: .text)
        }
    }

    func testExactIdentityCannotMatchOtherDeviceOrPrefix() {
        fails(.backendUnavailable) { _ = try self.route([self.snapshot(id: self.device + "_OTHER")]) }
        fails(.backendUnavailable) { _ = try self.route([self.snapshot()], id: "PHYSICAL") }
        fails(.invalidIdentity) { _ = try self.route([self.snapshot()], id: " \n") }
    }

    func testDuplicateBackendDeviceSnapshotsFailClosed() {
        fails(.ambiguousIdentity) { _ = try self.route([self.snapshot(), self.snapshot(session: UUID())]) }
    }

    func testReadyWithoutTransportSessionFailsClosed() {
        let state = InputBackendSnapshot(
            backend: .usb, physicalDeviceID: device, sessionID: nil, readiness: .ready, capabilities: [.tap])
        fails(.inputNotReady) { _ = try self.route([state]) }
    }

    func testUnchangedLeasePassesValidation() throws {
        let state = snapshot()
        try InputBackendPolicy.validate(try route([state]), generation: generation, snapshot: state)
    }

    func testReconnectOrSwitchInvalidatesOldLease() throws {
        let lease = try route([snapshot()])
        fails(.staleSession) {
            try InputBackendPolicy.validate(lease, generation: UUID(), snapshot: self.snapshot())
        }
        fails(.staleSession) {
            try InputBackendPolicy.validate(lease, generation: self.generation, snapshot: self.snapshot(session: UUID()))
        }
        fails(.staleSession) {
            try InputBackendPolicy.validate(lease, generation: self.generation, snapshot: self.snapshot(.ble))
        }
        fails(.staleSession) {
            try InputBackendPolicy.validate(lease, generation: self.generation, snapshot: self.snapshot(id: "OTHER"))
        }
    }

    func testDisconnectOrCapabilityLossStopsAlreadyResolvedAction() throws {
        let lease = try route([snapshot()])
        fails(.inputNotReady) {
            try InputBackendPolicy.validate(
                lease, generation: self.generation, snapshot: self.snapshot(readiness: .disconnected))
        }
        fails(.unsupportedCapability) {
            try InputBackendPolicy.validate(
                lease, generation: self.generation, snapshot: self.snapshot(capabilities: []))
        }
    }

    func testNoExecutionStagePermitsAutomaticReplay() {
        for state in [InputExecutionDisposition.notStarted, .mayHaveExecuted, .acknowledged] {
            XCTAssertFalse(state.permitsAutomaticReplay)
        }
    }
}
