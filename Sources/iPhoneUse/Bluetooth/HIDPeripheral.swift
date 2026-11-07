import CoreBluetooth
import CoreGraphics
import Foundation

/// The Mac as a BLE keyboard + pointer (HID over GATT). Classic Bluetooth HID is out:
/// bluetoothd owns L2CAP PSM 17 and 19 on current macOS.
final class HIDPeripheral: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    static let shared = HIDPeripheral()

    let localName = "iPhone Use"

    /// Owns the GATT database, subscriptions, connection tokens and pending reports.
    /// Public readers synchronize here; all delegate callbacks already run here.
    private let queue = DispatchQueue(label: "iphone-use.bluetooth")
    private var manager: CBPeripheralManager?
    private var centralManager: CBCentralManager?
    private var lifecyclePolicy = HIDLifecyclePolicy()
    private var reconnectTracker = HIDReconnectTracker()
    private var reconnectingPeripherals: [UUID: CBPeripheral] = [:]
    private let reconnectTimeout = HIDReconnectTracker.attemptTimeout
    private var servicesToAdd: [CBMutableService] = []
    private var serviceBeingAdded: CBMutableService?
    private var published = false

    private var inputs: [ReportID: CBMutableCharacteristic] = [:]
    private var reportMaps: [ObjectIdentifier: [UInt8]] = [:]
    private var keyboardOutput: CBMutableCharacteristic?
    private var batteryLevel: CBMutableCharacteristic?
    private var serviceChanged: CBMutableCharacteristic?

    private var centrals: [UUID: CBCentral] = [:]
    private var connections = HIDConnectionState()
    private var serviceChangedSent = Set<UUID>()

    private var stateDescription = "starting"
    var state: String { queue.sync { stateDescription } }
    private let tracePointer = ProcessInfo.processInfo.environment["IPHONE_USE_TRACE_POINTER"] == "1"
    private var lastPointerTrace = Date.distantPast
    private var lastSentPointerTrace = Date.distantPast

    /// Called on the Bluetooth queue when a phone starts or stops listening for input.
    var onHostsChanged: (() -> Void)?
    private let queryOnlineDisplayState: () -> HIDOnlineDisplayState = HIDPeripheral.onlineDisplayState

    /// Classifies online displays via CoreGraphics, explicitly separating query errors
    /// (`.unknown`) from confirmed zero-display headless Macs (`.noOnlineDisplays`),
    /// clamshell/DarkWake sleep (`.allAsleep`), and active displays (`.atLeastOneAwake`).
    static func onlineDisplayState() -> HIDOnlineDisplayState {
        var reportedCount: UInt32 = 0
        let countStatus = CGGetOnlineDisplayList(0, nil, &reportedCount)
        guard countStatus == .success, reportedCount > 0 else {
            return HIDOnlineDisplayState.classify(
                countQueryError: countStatus,
                reportedCount: reportedCount)
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(reportedCount))
        var resolvedCount = reportedCount
        let listStatus = CGGetOnlineDisplayList(reportedCount, &displays, &resolvedCount)
        guard listStatus == .success, resolvedCount > 0 else {
            return HIDOnlineDisplayState.classify(
                countQueryError: countStatus,
                reportedCount: reportedCount,
                listQueryError: listStatus,
                resolvedCount: resolvedCount)
        }
        let count = min(Int(resolvedCount), displays.count)
        let asleepFlags = displays.prefix(count).map { CGDisplayIsAsleep($0) != 0 }
        return HIDOnlineDisplayState.classify(
            countQueryError: countStatus,
            reportedCount: reportedCount,
            listQueryError: listStatus,
            resolvedCount: UInt32(count),
            asleepFlags: asleepFlags)
    }

    func start(initialDisplayState: HIDOnlineDisplayState = .atLeastOneAwake) {
        queue.async {
            self.lifecyclePolicy.start(initialDisplayState: initialDisplayState)
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
            self.scheduleUnknownDisplayRetryIfNeededOnQueue()
        }
    }

    func stop() {
        let callback: (() -> Void)? = queue.sync {
            self.lifecyclePolicy.stop()
            return self.applyCoreBluetoothLifecycleOnQueue(clearTargetsOnStop: true)
                ? self.onHostsChanged : nil
        }
        callback?()
    }

    /// Synchronously unregisters CoreBluetooth managers before AppKit acknowledges
    /// `NSWorkspace.willSleepNotification`, removing `ai.new-wave.iphone-use` from
    /// `bluetoothd`'s session map so bonded BLE traffic cannot wake the sleeping Mac.
    func systemWillSleep() {
        let callback: (() -> Void)? = queue.sync {
            self.lifecyclePolicy.systemWillSleep()
            return self.applyCoreBluetoothLifecycleOnQueue() ? self.onHostsChanged : nil
        }
        callback?()
    }

    func systemDidWake(displayState: HIDOnlineDisplayState) {
        queue.async {
            self.lifecyclePolicy.systemDidWake(displayState: displayState)
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
            self.scheduleUnknownDisplayRetryIfNeededOnQueue()
        }
    }

    func screensDidSleep() {
        queue.async {
            self.lifecyclePolicy.screensDidSleep()
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
        }
    }

    func screensDidWake() {
        queue.async {
            self.lifecyclePolicy.screensDidWake()
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
        }
    }

    func setUSBScreenDemand(_ hasScreens: Bool, revision: UInt64) {
        queue.async {
            guard self.lifecyclePolicy.setUSBScreenDemand(hasScreens, revision: revision) else {
                return
            }
            if hasScreens {
                self.refreshUnresolvedDisplayQueryIfNeededOnQueue()
            }
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
        }
    }

    func beginWindowDemand(_ token: UUID) {
        queue.async {
            self.lifecyclePolicy.beginWindowDemand(token)
            self.refreshUnresolvedDisplayQueryIfNeededOnQueue()
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
        }
    }

    func endWindowDemand(_ token: UUID) {
        queue.async {
            self.lifecyclePolicy.endWindowDemand(token)
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
        }
    }

    func setResidentQuietDemand(_ active: Bool) {
        queue.async {
            self.lifecyclePolicy.setResidentQuietDemand(active)
            self.refreshUnresolvedDisplayQueryIfNeededOnQueue()
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
        }
    }

    func refreshDisplayStateIfNeeded() {
        queue.async {
            guard self.lifecyclePolicy.hasUnresolvedDisplayQuery else { return }
            self.refreshUnresolvedDisplayQueryIfNeededOnQueue()
            if self.applyCoreBluetoothLifecycleOnQueue() {
                self.onHostsChanged?()
            }
        }
    }

    private func refreshUnresolvedDisplayQueryIfNeededOnQueue() {
        guard lifecyclePolicy.hasUnresolvedDisplayQuery else { return }
        let generation = lifecyclePolicy.displayQueryGeneration
        let state = queryOnlineDisplayState()
        if lifecyclePolicy.resolveUnknownDisplayQuery(state, generation: generation) {
            log("resolved deferred display state on demand (\(state))")
        }
    }

    private func scheduleUnknownDisplayRetryIfNeededOnQueue() {
        guard let retry = lifecyclePolicy.nextUnknownDisplayRetry() else { return }
        queue.asyncAfter(deadline: .now() + retry.delay) { [weak self] in
            guard let self else { return }
            guard self.lifecyclePolicy.hasUnresolvedDisplayQuery,
                self.lifecyclePolicy.displayQueryGeneration == retry.generation
            else {
                return
            }
            let state = self.queryOnlineDisplayState()
            if self.lifecyclePolicy.resolveUnknownDisplayQuery(state, generation: retry.generation) {
                log("resolved deferred display state (\(state))")
                if self.applyCoreBluetoothLifecycleOnQueue() {
                    self.onHostsChanged?()
                }
            } else {
                self.scheduleUnknownDisplayRetryIfNeededOnQueue()
            }
        }
    }

    /// Starts or unregisters `CBPeripheralManager` and `CBCentralManager` to match
    /// `lifecyclePolicy.shouldRunCoreBluetooth`. Returns `true` when live sessions
    /// or managers were torn down and observers should refresh host state.
    @discardableResult
    private func applyCoreBluetoothLifecycleOnQueue(clearTargetsOnStop: Bool = false) -> Bool {
        if lifecyclePolicy.shouldRunCoreBluetooth {
            guard manager == nil || centralManager == nil else { return false }
            reconnectTracker.resetForCentralPowerOff()
            reconnectingPeripherals.removeAll()
            stateDescription = "starting"
            log(
                "bluetooth session starting (usb=\(lifecyclePolicy.hasPresentUSBScreens), windows=\(lifecyclePolicy.hasOpenControlWindows))"
            )
            if manager == nil {
                manager = CBPeripheralManager(delegate: self, queue: queue)
            }
            if centralManager == nil {
                centralManager = CBCentralManager(delegate: self, queue: queue)
            }
            return false
        }

        let hadActiveManagers = manager != nil || centralManager != nil
        let hadSessions = !connections.sessions.isEmpty
        if manager?.isAdvertising == true {
            manager?.stopAdvertising()
        }
        let hostsToCancel =
            clearTargetsOnStop
            ? reconnectTracker.cancelAllForStop()
            : reconnectTracker.suspendForLifecycleTeardown()
        for host in hostsToCancel {
            if let peripheral = reconnectingPeripherals[host] {
                centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
        reconnectingPeripherals.removeAll()
        centralManager?.delegate = nil
        centralManager = nil
        manager?.delegate = nil
        manager = nil
        resetConnectionState()
        reportMaps.removeAll()
        keyboardOutput = nil
        batteryLevel = nil
        serviceChanged = nil
        let nextDescription = lifecyclePolicy.inactiveReason?.stateDescription ?? "stopped"
        if hadActiveManagers {
            log("bluetooth session unregistered (\(nextDescription))")
        }
        stateDescription = nextDescription
        return hadActiveManagers || hadSessions
    }

    /// Initiates a bounded BLE link to saved bonded iPhones whose USB screens are
    /// present, waking their HOGP client without requiring manual Settings > Bluetooth taps.
    func reconnectKnownHosts(_ hosts: Set<UUID>, resetExhausted: Bool = true) {
        queue.async {
            if !hosts.isEmpty {
                self.refreshUnresolvedDisplayQueryIfNeededOnQueue()
                if self.applyCoreBluetoothLifecycleOnQueue() {
                    self.onHostsChanged?()
                }
            }
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
            guard manager != nil else { return [] }
            return reconnectTracker.reconnectingHosts(activeSessions: Set(connections.sessions.keys))
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
        _ id: ReportID, _ bytes: [UInt8], to host: UUID, session: UUID?, isAllowed: (() -> Bool)? = nil,
        absoluteRelease: Bool = false
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
                .report(id), data: Data(bytes), host: host, session: session, isAllowed: isAllowed,
                absoluteRelease: absoluteRelease)
            self.drain()
        }
    }

    // MARK: GATT database

    private static func sig(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    private func buildServices() -> [CBMutableService] {
        reportMaps.removeAll()
        // Service/characteristic order is part of the host's cached GATT layout.
        let gatt = makeGenericAttributeService()
        let hid = makeHIDService(reports: HIDReportMap.primaryReports)
        let device = makeDeviceInformationService()
        let battery = makeBatteryService()
        return [gatt, hid, device, battery, makeHIDService(reports: HIDReportMap.absoluteReports)]
    }

    private func makeGenericAttributeService() -> CBMutableService {
        let characteristic = CBMutableCharacteristic(
            type: CBUUID(string: "2A05"), properties: [.indicate], value: nil, permissions: [.readable])
        serviceChanged = characteristic
        let gatt = CBMutableService(type: Self.sig("1801"), primary: true)
        gatt.characteristics = [characteristic]
        return gatt
    }

    private func makeHIDService(reports: [ReportID]) -> CBMutableService {
        let info = CBMutableCharacteristic(
            type: CBUUID(string: "2A4A"), properties: [.read],
            value: Data([0x11, 0x01, 0x00, 0x02]), permissions: [.readable])
        let reportMap = CBMutableCharacteristic(
            type: CBUUID(string: "2A4B"), properties: [.read],
            value: nil, permissions: [.readEncryptionRequired])
        reportMaps[ObjectIdentifier(reportMap)] = HIDReportMap.descriptor(for: reports)
        let control = CBMutableCharacteristic(
            type: CBUUID(string: "2A4C"), properties: [.writeWithoutResponse],
            value: nil, permissions: [.writeEncryptionRequired])
        let mode = CBMutableCharacteristic(
            type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse],
            value: nil, permissions: [.readable, .writeable])

        var characteristics: [CBMutableCharacteristic] = [info, reportMap, control, mode]
        for id in reports {
            let report = CBMutableCharacteristic(
                type: CBUUID(string: "2A4D"), properties: [.read, .notify],
                value: nil, permissions: [.readEncryptionRequired])
            report.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([id.rawValue, 1]))]
            inputs[id] = report
            characteristics.append(report)
        }
        if reports.contains(.keyboard) {
            let output = CBMutableCharacteristic(
                type: CBUUID(string: "2A4D"), properties: [.read, .write, .writeWithoutResponse],
                value: nil, permissions: [.readEncryptionRequired, .writeEncryptionRequired])
            output.descriptors = [
                CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([ReportID.keyboard.rawValue, 2]))
            ]
            keyboardOutput = output
            characteristics.append(output)
        }

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
        let level = CBMutableCharacteristic(
            type: CBUUID(string: "2A19"), properties: [.read, .notify], value: nil, permissions: [.readable])
        batteryLevel = level
        let battery = CBMutableService(type: Self.sig("180F"), primary: true)
        battery.characteristics = [level]
        return battery
    }

    private func addNextService() {
        guard let manager, manager.state == .poweredOn else { return }
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
        guard let manager, manager.state == .poweredOn, published, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
        ])
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
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
        guard peripheral === manager, peripheral.state == .poweredOn, service === serviceBeingAdded else { return }
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
        guard peripheral === manager, peripheral.state == .poweredOn, published else { return }
        if let error, (error as? CBError)?.code != .alreadyAdvertising {
            stateDescription = "advertising failed: \(error.localizedDescription)"
        } else {
            updateHostDescription()
        }
        log(stateDescription)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        let value: Data
        switch request.characteristic.uuid {
        case CBUUID(string: "2A4B"):
            guard let descriptor = reportMaps[ObjectIdentifier(request.characteristic)] else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                return
            }
            value = Data(descriptor)
            log("HID report map read: \(descriptor.count) bytes, offset=\(request.offset)")
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
        guard peripheral === manager, peripheral.state == .poweredOn, published else {
            if let first = requests.first { peripheral.respond(to: first, withResult: .unlikelyError) }
            return
        }
        for request in requests {
            remember(request.central)
            if request.characteristic.uuid == CBUUID(string: "2A4C") {
                log("control point write \(request.value.map { [UInt8]($0) } ?? []) from \(request.central.identifier)")
                recoverStaleCacheIfNeeded(request.central)
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    /// Records a GATT characteristic subscription without enqueuing unsolicited
    /// input notifications. Initial idle report values are served on demand via
    /// GATT Read (`didReceiveRead`); pushing zeroed pointer reports on CCCD
    /// subscription moves `absolutePointer` to `(0, 0)` and wakes AssistiveTouch's
    /// on-screen cursor whenever an unplugged iPhone reconnects over BLE.
    @discardableResult
    static func recordSubscription(
        _ channel: HIDConnectionState.Channel,
        host: UUID,
        connections: inout HIDConnectionState,
        reconnectTracker: inout HIDReconnectTracker
    ) -> Bool {
        connections.subscribe(channel, host: host)
        guard channel.isInput else { return false }
        reconnectTracker.noteSessionEstablished(host)
        return true
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, published, peripheral.state == .poweredOn,
            let channel = channel(for: characteristic)
        else { return }
        remember(central)
        let establishedInput = Self.recordSubscription(
            channel, host: central.identifier,
            connections: &connections, reconnectTracker: &reconnectTracker)
        log("subscribe \(characteristic.uuid) \(describe(characteristic)) from \(central.identifier)")
        if establishedInput {
            hostsChanged()
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, peripheral.state == .poweredOn, published,
            let channel = channel(for: characteristic)
        else { return }
        connections.unsubscribe(channel, host: central.identifier)
        if connections.subscriptions[central.identifier] == nil {
            centrals[central.identifier] = nil
        }
        log("unsubscribe \(characteristic.uuid) \(describe(characteristic)) from \(central.identifier)")
        hostsChanged()
        drain()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        drain()
    }

    private func resetConnectionState() {
        // CoreBluetooth invalidates connections and the local GATT database on a
        // reset. Never keep notifications or DeviceInput sessions from the old database.
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
        guard let manager, manager.state == .poweredOn, published else { return }
        var blockedHosts: Set<UUID> = []
        while let (index, report) = connections.nextPendingReportIndex(excludingHosts: blockedHosts) {
            guard let characteristic = characteristic(for: report.channel), let central = centrals[report.host] else {
                connections.removePending(at: index, accepted: false)
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
        }
    }

    private func channel(for characteristic: CBCharacteristic) -> HIDConnectionState.Channel? {
        if let id = inputs.first(where: { $0.value === characteristic })?.key { return .report(id) }
        if let serviceChanged, characteristic === serviceChanged { return .serviceChanged }
        if let batteryLevel, characteristic === batteryLevel { return .battery }
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
        if let keyboardOutput, characteristic === keyboardOutput { return 1 }
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
        guard central === centralManager else { return }
        if central.state == .poweredOn {
            attemptReconnections()
        } else {
            reconnectTracker.resetForCentralPowerOff()
            reconnectingPeripherals.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === centralManager else { return }
        log("BLE link connected to saved host \(redactedHost(peripheral.identifier))")
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        guard central === centralManager else { return }
        handleCentralTermination(for: peripheral.identifier)
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard central === centralManager else { return }
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
        guard let manager, manager.state == .poweredOn, published,
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
}
