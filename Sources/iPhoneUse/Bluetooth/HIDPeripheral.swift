import CoreBluetooth
import Foundation

/// The Mac as a BLE keyboard + pointer (HID over GATT). Classic Bluetooth HID is out:
/// bluetoothd owns L2CAP PSM 17 and 19 on current macOS.
final class HIDPeripheral: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    static let shared = HIDPeripheral()

    let localName = "iPhone Use"

    /// Owns the GATT database, subscriptions, connection tokens and pending reports.
    /// Public readers synchronize here; all delegate callbacks already run here.
    private let queue = DispatchQueue(label: "iphone-use.bluetooth")
    private var manager: CBPeripheralManager!
    private var centralManager: CBCentralManager?
    private var reconnectTracker = HIDReconnectTracker()
    private var reconnectingPeripherals: [UUID: CBPeripheral] = [:]
    private let reconnectTimeout: TimeInterval = 12
    private var servicesToAdd: [CBMutableService] = []
    private var serviceBeingAdded: CBMutableService?
    private var published = false

    private var inputs: [ReportID: CBMutableCharacteristic] = [:]
    private var keyboardOutput: CBMutableCharacteristic!
    private var controlPoint: CBMutableCharacteristic!
    private var protocolMode: CBMutableCharacteristic!
    private var batteryLevel: CBMutableCharacteristic!
    private var serviceChanged: CBMutableCharacteristic!

    private var centrals: [UUID: CBCentral] = [:]
    private var connections = HIDConnectionState()
    private let drainBarriers = HIDDrainBarrier()
    private var serviceChangedSent = Set<UUID>()

    private var stateDescription = "starting"
    var state: String { queue.sync { stateDescription } }
    private let tracePointer = ProcessInfo.processInfo.environment["IPHONE_USE_TRACE_POINTER"] == "1"
    private var lastPointerTrace = Date.distantPast
    private var lastSentPointerTrace = Date.distantPast

    /// Called on the Bluetooth queue when a phone starts or stops listening for input.
    var onHostsChanged: (() -> Void)?

    func start() {
        queue.async {
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
            self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    func stop() {
        queue.sync {
            if manager?.isAdvertising == true {
                manager?.stopAdvertising()
            }
            cancelAllReconnections()
        }
    }

    /// Initiates a bounded BLE link to saved bonded iPhones whose USB screens are
    /// present, waking their HOGP client without requiring manual Settings > Bluetooth taps.
    func reconnectKnownHosts(_ hosts: Set<UUID>, resetExhausted: Bool = true) {
        queue.async {
            let activeSessions = Set(self.connections.sessions.keys)
            let toCancel = self.reconnectTracker.updateTargets(
                hosts, activeSessions: activeSessions, resetExhausted: resetExhausted)
            for host in toCancel {
                if let peripheral = self.reconnectingPeripherals[host] {
                    self.centralManager?.cancelPeripheralConnection(peripheral)
                } else {
                    _ = self.reconnectTracker.handleTermination(
                        host: host, hasActiveSession: activeSessions.contains(host))
                }
            }
            self.attemptReconnections()
        }
    }

    /// Selects saved BLE hosts that should be woken for currently present, unmatched USB screens.
    static func hostsToReconnect(
        pairings: [String: UUID],
        presentScreenIDs: Set<String>,
        matchedScreenIDs: Set<String>,
        connectedHosts: Set<UUID>
    ) -> Set<UUID> {
        let unmatchedScreens = presentScreenIDs.subtracting(matchedScreenIDs)
        guard !unmatchedScreens.isEmpty else { return [] }
        let matchedHosts = Set(matchedScreenIDs.compactMap { pairings[$0] })
        var candidates = Set(unmatchedScreens.compactMap { pairings[$0] })
        if unmatchedScreens.contains(where: { pairings[$0] == nil }) {
            candidates.formUnion(Set(pairings.values).subtracting(matchedHosts))
        }
        return candidates.subtracting(connectedHosts)
    }

    /// Phones subscribed to at least one input report.
    var connectedHosts: [UUID] {
        queue.sync { hostsWithInput }
    }

    /// Saved hosts with an active or queued bounded BLE link attempt that have
    /// not yet subscribed to any HID input report.
    var reconnectingHosts: Set<UUID> {
        queue.sync {
            reconnectTracker.reconnectingHosts(activeSessions: Set(connections.sessions.keys))
        }
    }

    /// Pointer report characteristics currently subscribed for the host's live session.
    func subscribedPointerReports(for host: UUID, session: UUID?) -> Set<ReportID> {
        queue.sync {
            guard manager?.state == .poweredOn, published else { return [] }
            var reports: Set<ReportID> = []
            for report in [ReportID.absolutePointer, .relativeMouse]
            where connections.isReady(report: report, host: host, session: session) {
                reports.insert(report)
            }
            return reports
        }
    }

    private var hostsWithInput: [UUID] {
        Array(connections.sessions.keys)
    }

    func connectionSession(for host: UUID) -> UUID? {
        queue.sync { connections.sessions[host] }
    }

    /// Per-host connection detail for the status endpoint: which channels
    /// each phone subscribed to, and the session token validating its input.
    var hostDetails: [(host: UUID, session: UUID?, channels: [String])] {
        queue.sync {
            centrals.keys.sorted { $0.uuidString < $1.uuidString }.map { host in
                let channels = (connections.subscriptions[host] ?? [])
                    .map(Self.describe)
                    .sorted()
                return (host, connections.sessions[host], channels)
            }
        }
    }

    private static func describe(_ channel: HIDConnectionState.Channel) -> String {
        switch channel {
        case .report(let id): return String(describing: id)
        case .serviceChanged: return "serviceChanged"
        case .battery: return "battery"
        }
    }

    /// Read on the Bluetooth queue so callers never reuse readiness from a
    /// previous connection or assume every report is ready with the keyboard.
    func isReady(report: ReportID, host: UUID, session: UUID?) -> Bool {
        queue.sync {
            guard manager?.state == .poweredOn, published else { return false }
            return connections.isReady(report: report, host: host, session: session)
        }
    }

    /// `isAllowed` runs on the Bluetooth queue at enqueue and notification;
    /// it must not call this object's queue-synchronized readers.
    func send(
        _ id: ReportID, _ bytes: [UInt8], to host: UUID, session: UUID?, isAllowed: (() -> Bool)? = nil
    ) {
        queue.async {
            if self.tracePointer, id == .absolutePointer || id == .relativeMouse,
                Date().timeIntervalSince(self.lastPointerTrace) > 0.5
            {
                self.lastPointerTrace = Date()
                log(
                    "pointer enqueue report=\(id) \(bytes) sessionCurrent=\(session != nil && self.connections.sessions[host] == session) subscribed=\(self.connections.subscriptions[host]?.contains(.report(id)) == true)"
                )
            }
            guard self.manager?.state == .poweredOn, self.published else { return }
            self.connections.enqueue(
                .report(id), data: Data(bytes), host: host, session: session, isAllowed: isAllowed)
            self.drain()
        }
    }

    /// Waits for this host's reports already queued before this call to be
    /// accepted by CoreBluetooth. This is not acknowledgement from the phone.
    /// Call from the serial input queue after send(), never from the BLE queue:
    /// FIFO dispatch puts registration after those asynchronous enqueue blocks.
    func waitUntilReportsDrained(host: UUID, session: UUID?, timeout: TimeInterval) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        guard let session, timeout.isFinite, timeout > 0 else { return false }
        let waiter = HIDDrainBarrier.Waiter(host: host, session: session, timeout: timeout)
        queue.async {
            guard self.manager?.state == .poweredOn, self.published,
                self.centrals[host] != nil, self.connections.sessions[host] == session
            else {
                waiter.finish(false)
                return
            }
            let pendingCount = self.connections.pending.filter {
                $0.host == host && $0.session == session && $0.channel.isInput
            }.count
            self.drainBarriers.register(waiter, pendingCount: pendingCount)
        }
        let drained = waiter.wait()
        if !drained {
            queue.async { self.drainBarriers.cancel(waiter) }
        }
        return drained
    }

    // MARK: GATT database

    private static func sig(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    private func buildServices() -> [CBMutableService] {
        // Service/characteristic order is part of the host's cached GATT layout.
        let gatt = makeGenericAttributeService()
        let hid = makeHIDService()
        let device = makeDeviceInformationService()
        let battery = makeBatteryService()
        return [gatt, hid, device, battery]
    }

    private func makeGenericAttributeService() -> CBMutableService {
        serviceChanged = CBMutableCharacteristic(
            type: CBUUID(string: "2A05"), properties: [.indicate], value: nil, permissions: [.readable])
        let gatt = CBMutableService(type: Self.sig("1801"), primary: true)
        gatt.characteristics = [serviceChanged]
        return gatt
    }

    private func makeHIDService() -> CBMutableService {
        let info = CBMutableCharacteristic(
            type: CBUUID(string: "2A4A"), properties: [.read],
            value: Data([0x11, 0x01, 0x00, 0x02]), permissions: [.readable])
        let reportMap = CBMutableCharacteristic(
            type: CBUUID(string: "2A4B"), properties: [.read],
            value: Data(HIDReportMap.descriptor), permissions: [.readEncryptionRequired])
        controlPoint = CBMutableCharacteristic(
            type: CBUUID(string: "2A4C"), properties: [.writeWithoutResponse],
            value: nil, permissions: [.writeEncryptionRequired])
        protocolMode = CBMutableCharacteristic(
            type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse],
            value: nil, permissions: [.readable, .writeable])

        var characteristics: [CBMutableCharacteristic] = [info, reportMap, controlPoint, protocolMode]
        for id in [ReportID.keyboard, .absolutePointer, .relativeMouse, .consumer] {
            let report = CBMutableCharacteristic(
                type: CBUUID(string: "2A4D"), properties: [.read, .notify],
                value: nil, permissions: [.readEncryptionRequired])
            report.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([id.rawValue, 1]))]
            inputs[id] = report
            characteristics.append(report)
        }
        keyboardOutput = CBMutableCharacteristic(
            type: CBUUID(string: "2A4D"), properties: [.read, .write, .writeWithoutResponse],
            value: nil, permissions: [.readEncryptionRequired, .writeEncryptionRequired])
        keyboardOutput.descriptors = [
            CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([ReportID.keyboard.rawValue, 2]))
        ]
        characteristics.append(keyboardOutput)

        let hid = CBMutableService(type: Self.sig("1812"), primary: true)
        hid.characteristics = characteristics
        return hid
    }

    private func makeDeviceInformationService() -> CBMutableService {
        let device = CBMutableService(type: Self.sig("180A"), primary: true)
        device.characteristics = [
            CBMutableCharacteristic(
                type: CBUUID(string: "2A29"), properties: [.read],
                value: Data("iPhone Use".utf8), permissions: [.readable]),
            CBMutableCharacteristic(
                type: CBUUID(string: "2A50"), properties: [.read],
                value: Data([0x02, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x01]), permissions: [.readable]),
        ]
        return device
    }

    private func makeBatteryService() -> CBMutableService {
        batteryLevel = CBMutableCharacteristic(
            type: CBUUID(string: "2A19"), properties: [.read, .notify], value: nil, permissions: [.readable])
        let battery = CBMutableService(type: Self.sig("180F"), primary: true)
        battery.characteristics = [batteryLevel]
        return battery
    }

    private func addNextService() {
        guard manager.state == .poweredOn else { return }
        guard !servicesToAdd.isEmpty else {
            published = true
            advertise()
            attemptReconnections()
            return
        }
        let service = servicesToAdd.removeFirst()
        serviceBeingAdded = service
        manager.add(service)
    }

    private func advertise() {
        guard manager.state == .poweredOn, published, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
        ])
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log("bluetooth state \(peripheral.state.rawValue) auth \(CBManager.authorization.rawValue)")
        resetConnectionState()
        switch peripheral.state {
        case .poweredOn:
            stateDescription = "powered on"
            peripheral.removeAllServices()
            servicesToAdd = buildServices()
            addNextService()
        case .unauthorized:
            stateDescription = "bluetooth not allowed (System Settings > Privacy & Security > Bluetooth)"
        case .poweredOff:
            stateDescription = "bluetooth off"
        default:
            stateDescription = "bluetooth unavailable (\(peripheral.state.rawValue))"
        }
        onHostsChanged?()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        // A callback from a database invalidated by a reset must not advance the
        // publication of its replacement database.
        guard peripheral.state == .poweredOn, service === serviceBeingAdded else { return }
        serviceBeingAdded = nil
        if let error {
            stateDescription = "failed to add \(service.uuid): \(error.localizedDescription)"
            log(stateDescription)
            return
        }
        log("added service \(service.uuid)")
        addNextService()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral.state == .poweredOn, published else { return }
        if let error, (error as? CBError)?.code != .alreadyAdvertising {
            stateDescription = "advertising failed: \(error.localizedDescription)"
        } else {
            updateHostDescription()
        }
        log(stateDescription)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let value: Data
        switch request.characteristic.uuid {
        case CBUUID(string: "2A4E"): value = Data([0x01])
        case CBUUID(string: "2A19"): value = Data([100])
        case CBUUID(string: "2A4D"): value = Data(count: reportLength(request.characteristic))
        default:
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral.state == .poweredOn, published else {
            if let first = requests.first { peripheral.respond(to: first, withResult: .unlikelyError) }
            return
        }
        for request in requests {
            remember(request.central)
            if request.characteristic.uuid == controlPoint.uuid {
                log("control point write \(request.value.map { [UInt8]($0) } ?? []) from \(request.central.identifier)")
                recoverStaleCacheIfNeeded(request.central)
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard published, peripheral.state == .poweredOn, let channel = channel(for: characteristic) else { return }
        remember(central)
        connections.subscribe(channel, host: central.identifier)
        log("subscribe \(characteristic.uuid) \(describe(characteristic)) from \(central.identifier)")
        if case .report(let id) = channel {
            reconnectTracker.noteSessionEstablished(central.identifier)
            connections.enqueue(
                channel, data: Data(count: Self.length(id)), host: central.identifier,
                session: connections.sessions[central.identifier])
            drain()
            hostsChanged()
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard peripheral.state == .poweredOn, published, let channel = channel(for: characteristic) else { return }
        if connections.pending.contains(where: { $0.host == central.identifier && $0.channel == channel }) {
            drainBarriers.invalidate(host: central.identifier, session: connections.sessions[central.identifier])
        }
        connections.unsubscribe(channel, host: central.identifier)
        if connections.subscriptions[central.identifier] == nil {
            centrals[central.identifier] = nil
        }
        log("unsubscribe \(characteristic.uuid) \(describe(characteristic)) from \(central.identifier)")
        hostsChanged()
        drain()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drain()
    }

    private func resetConnectionState() {
        // CoreBluetooth invalidates connections and the local GATT database on a
        // reset. Never keep notifications or DeviceInput sessions from the old database.
        drainBarriers.invalidateAll()
        connections.reset()
        centrals.removeAll()
        serviceChangedSent.removeAll()
        servicesToAdd.removeAll()
        serviceBeingAdded = nil
        inputs.removeAll()
        published = false
        for host in reconnectTracker.cancelEstablishedOnPeripheralReset() {
            if let peripheral = reconnectingPeripherals[host] {
                centralManager?.cancelPeripheralConnection(peripheral)
            } else {
                _ = reconnectTracker.handleTermination(host: host, hasActiveSession: false)
            }
        }
    }

    // MARK: Helpers

    /// Keeps advertising while phones are connected so more can pair.
    private func hostsChanged() {
        updateHostDescription()
        advertise()
        onHostsChanged?()
    }

    private func updateHostDescription() {
        let count = hostsWithInput.count
        stateDescription =
            count == 0 ? "advertising as \(localName)" : "\(count) connected, advertising as \(localName)"
    }

    /// Stop a host at its first rejected notification so per-host FIFO order is
    /// preserved, while continuing to drain other subscribed centrals so a
    /// stalled or suspended peer cannot head-of-line block active phones.
    private func drain() {
        guard manager?.state == .poweredOn, published else {
            drainBarriers.invalidateAll()
            return
        }
        var blockedHosts: Set<UUID> = []
        while true {
            // nextPendingReportIndex may discard stale identity/session reports.
            // Such removal must not satisfy a waiter as if updateValue accepted it.
            let next = connections.nextPendingReportIndex(
                excludingHosts: blockedHosts,
                onDrop: drainBarriers.count > 0
                    ? { [drainBarriers] dropped in
                        drainBarriers.invalidate(host: dropped.host, session: dropped.session)
                    }
                    : nil)
            guard let (index, report) = next else { return }
            guard let characteristic = characteristic(for: report.channel), let central = centrals[report.host] else {
                drainBarriers.invalidate(host: report.host, session: report.session)
                connections.removePending(at: index)
                continue
            }
            let sent = manager.updateValue(report.data, for: characteristic, onSubscribedCentrals: [central])
            if tracePointer, report.channel == .report(.absolutePointer) || report.channel == .report(.relativeMouse),
                Date().timeIntervalSince(lastSentPointerTrace) > 0.5
            {
                lastSentPointerTrace = Date()
                log(
                    "pointer notify channel=\(report.channel) \([UInt8](report.data)) accepted=\(sent) host=\(report.host)"
                )
            }
            guard sent else {
                blockedHosts.insert(report.host)
                continue
            }
            connections.removePending(at: index)
            drainBarriers.didAccept(host: report.host, session: report.session)
        }
    }

    private func channel(for characteristic: CBCharacteristic) -> HIDConnectionState.Channel? {
        if let id = inputs.first(where: { $0.value === characteristic })?.key { return .report(id) }
        if characteristic === serviceChanged { return .serviceChanged }
        if characteristic === batteryLevel { return .battery }
        return nil
    }

    private func characteristic(for channel: HIDConnectionState.Channel) -> CBMutableCharacteristic? {
        switch channel {
        case .report(let id): return inputs[id]
        case .serviceChanged: return serviceChanged
        case .battery: return batteryLevel
        }
    }

    private func remember(_ central: CBCentral) {
        centrals[central.identifier] = central
    }

    /// A bonded host that trusts a stale cache writes the Control Point but never subscribes.
    /// Service Changed makes it rediscover.
    private func recoverStaleCacheIfNeeded(_ central: CBCentral) {
        let subscribed = connections.subscriptions[central.identifier] ?? []
        guard !subscribed.contains(where: \.isInput), subscribed.contains(.serviceChanged),
            !serviceChangedSent.contains(central.identifier)
        else { return }
        serviceChangedSent.insert(central.identifier)
        log("stale cache on \(central.identifier), indicating Service Changed")
        connections.enqueue(.serviceChanged, data: Data([0x10, 0x00, 0xFF, 0xFF]), host: central.identifier)
        drain()
    }

    private func reportLength(_ characteristic: CBCharacteristic) -> Int {
        if characteristic === keyboardOutput { return 1 }
        if let id = inputs.first(where: { $0.value === characteristic })?.key { return Self.length(id) }
        return 0
    }

    private static func length(_ id: ReportID) -> Int {
        switch id {
        case .keyboard: 8
        case .absolutePointer: 5
        case .relativeMouse: 4
        case .consumer: 2
        }
    }

    private func describe(_ characteristic: CBCharacteristic) -> String {
        if let id = inputs.first(where: { $0.value === characteristic })?.key { return "(\(id))" }
        return ""
    }

    // MARK: Bonded host BLE link initiation

    private func redactedHost(_ host: UUID) -> String {
        tracePointer ? host.uuidString : "\(host.uuidString.prefix(8))…"
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            attemptReconnections()
        } else {
            reconnectTracker.resetForCentralPowerOff()
            reconnectingPeripherals.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("BLE link connected to saved host \(redactedHost(peripheral.identifier))")
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        handleCentralTermination(for: peripheral.identifier)
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        handleCentralTermination(for: peripheral.identifier)
    }

    private func handleCentralTermination(for host: UUID) {
        reconnectingPeripherals[host] = nil
        let hasSession = connections.sessions[host] != nil
        switch reconnectTracker.handleTermination(host: host, hasActiveSession: hasSession) {
        case .none:
            break
        case .retryNow:
            attemptReconnections()
        case .scheduleBackoff(let token, let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let active = self.connections.sessions[host] != nil
                if self.reconnectTracker.completeBackoff(
                    host: host, token: token, hasActiveSession: active)
                {
                    self.attemptReconnections()
                }
            }
        case .notifyChanged:
            onHostsChanged?()
        }
    }

    private func attemptReconnections() {
        guard manager?.state == .poweredOn, published,
            let centralManager, centralManager.state == .poweredOn
        else { return }
        let activeSessions = Set(connections.sessions.keys)
        let missing = reconnectTracker.connectableHosts(activeSessions: activeSessions)
        guard !missing.isEmpty else { return }
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: Array(missing))
        let retrievedIDs = Set(peripherals.map(\.identifier))
        var missingUnretrievable = false
        for unretrievable in missing.subtracting(retrievedIDs) {
            reconnectTracker.markUnretrievable(unretrievable)
            missingUnretrievable = true
        }
        for peripheral in peripherals {
            let host = peripheral.identifier
            reconnectingPeripherals[host] = peripheral
            let attempt = reconnectTracker.beginConnecting(host)
            log("initiating BLE link to saved host \(redactedHost(host))")
            centralManager.connect(peripheral, options: nil)
            queue.asyncAfter(deadline: .now() + reconnectTimeout) { [weak self] in
                guard let self else { return }
                let hasSession = self.connections.sessions[host] != nil
                guard
                    self.reconnectTracker.markTimedOut(
                        host: host, attempt: attempt, hasActiveSession: hasSession)
                else { return }
                if let active = self.reconnectingPeripherals[host] {
                    self.centralManager?.cancelPeripheralConnection(active)
                } else {
                    self.handleCentralTermination(for: host)
                }
                if (self.reconnectTracker.attemptsUsed[host] ?? 0) >= HIDReconnectTracker.maxAutomaticAttempts {
                    self.onHostsChanged?()
                }
            }
        }
        if missingUnretrievable {
            onHostsChanged?()
        }
    }

    private func cancelAllReconnections() {
        for host in reconnectTracker.cancelAllForStop() {
            if let peripheral = reconnectingPeripherals[host] {
                centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
        reconnectingPeripherals.removeAll()
    }
}
