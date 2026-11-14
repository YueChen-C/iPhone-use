import Foundation

/// A phone: its USB screen, and the Bluetooth host that drives it once matched and connected.
struct Device {
    let screen: ScreenCaptureSession
    let host: UUID?
    let bluetoothState: DeviceBluetoothState

    var id: String { screen.id }
    var lockState: DeviceLockState { DeviceLockMonitor.shared.state(for: screen) }

    var json: [String: Any] {
        var info: [String: Any] = [
            "id": id, "name": screen.name, "bluetooth": host != nil, "lockState": lockState.rawValue,
        ]
        info["bluetoothState"] = bluetoothState.rawValue
        info["input"] = USBInputController.shared.status(self)
        if let size = screen.size {
            info["width"] = Int(size.width)
            info["height"] = Int(size.height)
        }
        return info
    }
}

struct DeviceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Matches each phone's Bluetooth connection to its USB screen. Bluetooth does not say which
/// phone is which, so matching moves the pointer through one connection and looks for the
/// screen where it moved. Matches are saved, so a phone is matched once.
final class DeviceRegistry {
    static let shared = DeviceRegistry()

    private let lock = NSLock()
    // DeviceInput creation may wait for the Bluetooth queue. Keep it separate from
    // matching state, which Bluetooth callbacks access on that queue.
    private let inputLock = NSLock()
    private var pairings: [String: UUID] = [:]
    /// Cache identity includes both the BLE session and USB device. Keeping the
    /// entry together prevents an DeviceInput from being reused for another screen.
    private struct CachedInput {
        let input: DeviceInput
        let screenID: String?
        let screenObject: ObjectIdentifier?
        let routeGeneration: UUID?
    }
    private enum ReplacementRecovery {
        case notApplicable
        case blocked
        case recovered([String: UUID])
    }
    private var inputs: [UUID: CachedInput] = [:]
    private var retiringInputs: [String: [DeviceInput]] = [:]
    private var matchPending = false
    private var usableScreenRetries: Set<String> = []
    private let matchQueue = DispatchQueue(label: "iphone-use.match")
    /// Accessed only by matchQueue (and its synchronous probe callbacks).
    private var probeSchedule = DevicePairingProbeSchedule()
    private var identityRetrySchedule = CaptureIdentityRetrySchedule()
    private var probeActivities: [ObjectIdentifier: (input: DeviceInput, sequence: UInt64)]?
    private struct ProbeEvidence {
        let session: UUID?
        var scores: [ObjectIdentifier: Int] = [:]
        var absoluteScreens: Set<ObjectIdentifier> = []
        var results: [ObjectIdentifier: DevicePairingRecovery.ProbeResult] = [:]
        var orientations: [ObjectIdentifier: RelativePointerScreenMatcher.Orientation] = [:]
        var pointerOrigins: [ObjectIdentifier: (point: CGPoint, activity: UInt64)] = [:]
        var preparedScreens: Set<ObjectIdentifier> = []
    }
    /// Recovery and generic discovery share one motion proof per host/round.
    /// Failed observations cannot immediately start the same trajectory again.
    private var probeEvidence: [UUID: ProbeEvidence] = [:]
    private var probingCancelled = false
    private var backgroundMotionGeneration: UInt64 = 0
    private var probingGeneration: UInt64 = 0
    private var calibrationJobs = PointerCalibrationJobs()
    private var calibrationRetryTimer: DispatchSourceTimer?
    /// Persisted identities are candidates until motion confirms the physical
    /// phone and Bluetooth session. A continuously present phone retains that
    /// proof across capture remaps; separate capture verification gates input.
    struct Association: Hashable {
        let screen: UUID
        let host: UUID
        let session: UUID
    }
    private var verifiedAssociations: Set<Association> = []
    /// Never persist or carry an HID-to-capture rotation into another session.
    private var pointerOrientations: [Association: RelativePointerScreenMatcher.Orientation] = [:]

    private let pairingStore = DevicePairingStore()

    func start() {
        load()
        ScreenCaptureManager.shared.onScreensChanged = { [weak self] in
            USBInputController.shared.captureDidChange()
            self?.matchQueue.async {
                self?.syncBluetoothForCurrentScreens(resetExhausted: true)
            }
            self?.scheduleMatch()
        }
        HIDPeripheral.shared.onHostsChanged = { [weak self] in
            // Dispatch off HIDPeripheral.queue before querying queue-synchronized readers.
            self?.matchQueue.async {
                guard let self else { return }
                let screens = ScreenCaptureManager.shared.all
                let sessions = self.currentHostSessions()
                self.lock.withLock {
                    self.promoteVerifiedAssociationsLocked(screens: screens, sessions: sessions)
                }
                self.reconnectSavedBluetoothHosts(for: screens, resetExhausted: false)
            }
            self?.scheduleMatch()
        }
        DeviceLockMonitor.shared.onUsableFrameRestored = { [weak self] screenID in
            self?.scheduleMatch(usableScreenID: screenID)
            self?.matchQueue.async {
                guard let self, let device = self.all().first(where: { $0.id == screenID }),
                    device.host != nil, !self.isAutomaticallyCalibrating(screenID: screenID),
                    let state = self.lock.withLock({ self.calibrationJobs.status(screenID: screenID) }),
                    state["state"] as? String == "unavailable"
                else { return }
                self.automaticallyCalibrate(device, retry: true)
            }
        }
        DeviceLockMonitor.shared.start()
        let timer = DispatchSource.makeTimerSource(queue: matchQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.scheduleAutomaticCalibrations() }
        calibrationRetryTimer = timer
        timer.resume()
        matchQueue.async { [weak self] in
            self?.syncBluetoothForCurrentScreens(resetExhausted: true)
        }
    }

    private func syncBluetoothForCurrentScreens(resetExhausted: Bool) {
        dispatchPrecondition(condition: .onQueue(matchQueue))
        let snapshot = ScreenCaptureManager.shared.sampleScreensWithRevision()
        let sessions = currentHostSessions()
        lock.withLock {
            promoteVerifiedAssociationsLocked(screens: snapshot.screens, sessions: sessions)
        }
        HIDPeripheral.shared.setUSBScreenDemand(snapshot.retainsUSBDemand, revision: snapshot.revision)
        reconnectSavedBluetoothHosts(for: snapshot.screens, resetExhausted: resetExhausted)
    }

    /// Public trigger to force immediate BLE reconnect attempt for saved paired hosts.
    func reconnectBluetooth(resetExhausted: Bool = true) {
        matchQueue.async { [weak self] in
            guard let self else { return }
            let screens = ScreenCaptureManager.shared.all
            self.reconnectSavedBluetoothHosts(for: screens, resetExhausted: resetExhausted)
        }
    }

    /// Reconnects hosts that unexpectedly disconnected during idle, in parallel with USB resume.
    /// Normally the retained USB demand keeps the existing Bluetooth session alive.
    func prewakeBluetoothForIdleResume(
        observeUSBTopology: @escaping () -> USBValeriaConfigurator.IOSUSBTopologyObservation =
            USBValeriaConfigurator.currentIOSUSBTopology
    ) {
        matchQueue.async { [weak self] in
            guard let self else { return }
            guard observeUSBTopology().hasAttachedDevices else { return }
            let pairings = self.lock.withLock { self.pairings }
            guard !pairings.isEmpty else { return }
            let revision = ScreenCaptureManager.shared.mintUSBDemandRevision()
            HIDPeripheral.shared.setUSBScreenDemand(true, revision: revision)
            let connected = Set(HIDPeripheral.shared.connectedHosts)
            let targets = Set(pairings.values).subtracting(connected)
            HIDPeripheral.shared.reconnectKnownHosts(targets, resetExhausted: true)
        }
    }

    func all() -> [Device] {
        buildDevices(from: ScreenCaptureManager.shared.all)
    }

    private func buildDevices(from screens: [ScreenCaptureSession]) -> [Device] {
        let sessions = currentHostSessions()
        let (pairings, verified, orientations) = lock.withLock {
            (self.pairings, self.verifiedAssociations, self.pointerOrientations)
        }
        return screens.map { screen in
            let host = pairings[screen.id].flatMap { host -> UUID? in
                guard ScreenCaptureManager.shared.isCurrent(screen), let session = sessions[host],
                    verified.contains(
                        Association(screen: screen.associationIdentity, host: host, session: session)),
                    orientations[Association(screen: screen.associationIdentity, host: host, session: session)] != nil
                else { return nil }
                return host
            }
            let state = DeviceBluetoothState.resolve(
                screenID: screen.id, matchedHost: host, pairings: pairings, connectedHosts: Set(sessions.keys))
            return Device(screen: screen, host: host, bluetoothState: state)
        }
    }

    private func currentHostSessions() -> [UUID: UUID] {
        Dictionary(
            uniqueKeysWithValues: HIDPeripheral.shared.hostDetails.compactMap { detail in
                detail.session.map { (detail.host, $0) }
            })
    }

    /// The caller holds `lock`; readers must never mint authorization as a side effect.
    private func promoteVerifiedAssociationsLocked(screens: [ScreenCaptureSession], sessions: [UUID: UUID]) {
        Self.promoteVerifiedAssociations(
            &verifiedAssociations,
            screenIdentities: Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.associationIdentity) }),
            pairings: pairings, sessions: sessions)
    }

    /// Value-only transitions keep authorization tests independent of USB and Bluetooth hardware.
    static func promoteVerifiedAssociations(
        _ verified: inout Set<Association>, screenIdentities: [String: UUID],
        pairings: [String: UUID], sessions: [UUID: UUID]
    ) {
        for (id, identity) in screenIdentities {
            guard let host = pairings[id], let session = sessions[host],
                verified.contains(where: { $0.screen == identity && $0.host == host })
            else { continue }
            verified.insert(Association(screen: identity, host: host, session: session))
        }
    }

    static func invalidateReplacedAssociations(
        _ verified: inout Set<Association>, screenID: String, host: UUID,
        screenIdentities: [String: UUID], pairings: [String: UUID]
    ) {
        let replacedHost = pairings[screenID].flatMap { $0 == host ? nil : $0 }
        let replacedScreens = Set(
            pairings.compactMap { id, existing in
                existing == host && id != screenID ? screenIdentities[id] : nil
            })
        let identity = screenIdentities[screenID]
        verified = verified.filter {
            $0.host != replacedHost && !replacedScreens.contains($0.screen)
                && ($0.host != host || $0.screen == identity)
                && ($0.screen != identity || $0.host == host)
        }
    }

    /// Device details plus the active pointer mode. Keeping this in the status
    /// endpoint makes it possible to verify which input path the running process
    /// actually loaded, instead of inferring it from a calibration file on disk.
    func status() -> [[String: Any]] {
        all().map { device in
            var info = device.json
            if let host = device.host {
                var pointer = input(for: host, screen: device.screen).pointerStatus
                if !ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen) {
                    pointer["ready"] = false
                    pointer["state"] = "screen-unverified"
                }
                pointer["host"] = host.uuidString
                if let adaptation = lock.withLock({ calibrationJobs.status(screenID: device.id) }) {
                    pointer["automaticCalibration"] = adaptation
                }
                info["pointer"] = pointer
            } else {
                info["pointer"] = ["state": "unpaired"]
            }
            return info
        }
    }

    /// Connected Bluetooth hosts that no present screen is matched to.
    func unmatchedHosts() -> [UUID] {
        let matched = Set(all().compactMap(\.host))
        return HIDPeripheral.shared.connectedHosts.filter { !matched.contains($0) }
    }

    /// A phone by id, name or id prefix. Without a query there must be exactly one phone.
    func find(_ query: String?) throws -> Device {
        let devices = all()
        if let query, !query.isEmpty {
            let q = query.lowercased()
            let hit =
                devices.first { $0.id.lowercased() == q } ?? devices.first { $0.screen.name.lowercased() == q }
                ?? devices.first { $0.id.lowercased().hasPrefix(q) }
            guard let hit else {
                throw DeviceError(StringsAPI.current.noPhoneMatches(query, Self.describe(devices)))
            }
            return hit
        }
        guard !devices.isEmpty else {
            throw DeviceError(StringsAPI.current.noScreen)
        }
        guard devices.count == 1 else {
            throw DeviceError(StringsAPI.current.multiplePhones(devices.count, Self.describe(devices)))
        }
        return devices[0]
    }

    /// Resolve only an already verified connection. A normal input request must
    /// never restart discovery after it has just cancelled background motion.
    func input(for device: Device) throws -> DeviceInput {
        let matched = try find(device.id)
        guard USBInputController.shared.permitsBLE(matched.id, generation: nil) else {
            throw DeviceError("Selected input backend is not ready for Bluetooth; no cross-backend fallback")
        }
        if let host = matched.host {
            guard ScreenCaptureManager.shared.permitsPointerAssociation(for: matched.screen) else {
                throw DeviceError(StringsAPI.current.screenIdentityUnverified(matched.screen.name))
            }
            return input(for: host, screen: matched.screen)
        }
        if matched.bluetoothState == .disconnected {
            throw DeviceError(
                StringsAPI.current.noBluetoothConnection(
                    device.screen.name, HIDPeripheral.shared.localName))
        }
        throw DeviceError(StringsAPI.current.ambiguousBluetooth(device.screen.name))
    }

    func input(for host: UUID, screen: ScreenCaptureSession? = nil) -> DeviceInput {
        return inputLock.withLock {
            // Serialize the session snapshot with cache access so a delayed old
            // session cannot replace a newer DeviceInput and split the input queues.
            let session = HIDPeripheral.shared.connectionSession(for: host)
            let screenID = screen?.id
            let routeGeneration = screenID.map { USBInputController.shared.generation($0) }
            let orientation: RelativePointerScreenMatcher.Orientation? = lock.withLock {
                guard let screen, let session else { return nil }
                return pointerOrientations[
                    Association(screen: screen.associationIdentity, host: host, session: session)]
            }
            if let cached = inputs[host], !cached.input.isRetired,
                cached.input.session == session, cached.screenID == screenID,
                cached.routeGeneration == routeGeneration,
                cached.screenObject == screen.map(ObjectIdentifier.init),
                orientation == nil || cached.input.pointerOrientation == orientation
            {
                return cached.input
            }
            if let old = inputs[host], let id = old.screenID,
               old.routeGeneration != routeGeneration {
                retiringInputs[id, default: []].append(old.input)
            }
            let input = makeInput(host: host, session: session, screen: screen)
            inputs[host] = CachedInput(
                input: input, screenID: screenID, screenObject: screen.map(ObjectIdentifier.init),
                routeGeneration: routeGeneration)
            return input
        }
    }

    /// Returns a cached input for a still-current Bluetooth session without
    /// changing the screen identity associated with the normal input cache.
    /// Recovery uses this only for its isolated probe: an absent USB screen
    /// must not cause an old input queue to be rebound to the newly discovered
    /// screen before the probe proves the replacement.
    private func cachedInput(for host: UUID, session: UUID) -> DeviceInput? {
        inputLock.withLock {
            guard let cached = inputs[host], cached.input.session == session else { return nil }
            return cached.input
        }
    }

    /// Called while inputLock is held. Resolve calibration and the live screen
    /// provider once for each cached session/screen pair.
    private func makeInput(
        host: UUID, session: UUID?, screen: ScreenCaptureSession?
    ) -> DeviceInput {
        let screenID = screen?.id
        let routeGeneration = screenID.map { USBInputController.shared.generation($0) }
        let calibration = loadCalibration(host: host, screen: screen)
        let rejected =
            screenID.flatMap { id in
                session.map { session in
                    lock.withLock {
                        calibrationJobs.hasRejectedCalibration(.init(screenID: id, host: host, session: session))
                    }
                }
            } ?? false
        let input = DeviceInput(
            host: host, session: session, calibration: calibration,
            calibrationRequired: RelativePointerCalibration.requiresCalibration(
                host: host, screenID: screenID),
            calibrationFilePresent: FileManager.default.fileExists(
                atPath: RelativePointerCalibration.fileURL(host: host).path),
            calibrationRejected: rejected,
            calibrationIsVerified: { [weak self] in
                guard calibration != nil else { return true }
                guard let self, let screenID, let session else { return false }
                return self.lock.withLock {
                    self.calibrationJobs.isVerified(.init(screenID: screenID, host: host, session: session))
                }
            },
            relativePointerOrientation: lock.withLock {
                guard let screen, let session else { return .identity }
                return pointerOrientations[
                    Association(screen: screen.associationIdentity, host: host, session: session)] ?? .identity
            },
            screenSize: screenID.map { id in
                // USB reconnect creates a new ScreenCaptureSession while the
                // Bluetooth session may remain unchanged.
                { ScreenCaptureManager.shared.all.first { $0.id == id }?.size }
            },
            inputIsAllowed: { [weak screen] in
                let manager = ScreenCaptureManager.shared
                guard let screen else { return screenID == nil && manager.permitsPointerAssociation }
                return USBInputController.shared.permitsBLE(screen.id, generation: routeGeneration)
                    && manager.permitsPointerAssociation(for: screen)
            })
        return input
    }

    private func loadCalibration(host: UUID, screen: ScreenCaptureSession?) -> RelativePointerCalibration? {
        guard let screen else { return nil }
        return RelativePointerCalibration.loadMatchingScreen(host: host, screenSize: screen.size, screenID: screen.id)
    }

    func pair(_ device: Device, host: UUID) {
        store([device.id: host], motionVerified: false)
        reconnectSavedBluetoothHostsIfNeeded(resetExhausted: true)
        scheduleMatch()
    }

    func isAutomaticallyCalibrating(screenID: String) -> Bool {
        lock.withLock { calibrationJobs.isRunning(screenID: screenID) }
    }

    /// Cancels measurement or discovery without waiting behind its input queue
    /// or trying to rematch the phone. The actual user action can then proceed.
    func cancelBackgroundMotion(for device: Device) {
        // A proven phone has its own input queue and cancellation sequence.
        // Its foreground activity must not cancel discovery of another phone.
        if device.host == nil {
            lock.withLock { backgroundMotionGeneration &+= 1 }
        }
        let input = inputLock.withLock {
            inputs.values.first { $0.screenID == device.id }?.input
        }
        input?.cancelBackgroundMotion()
    }

    func releaseForBackendSwitch(_ device: Device) -> Bool {
        let old = inputLock.withLock { () -> [DeviceInput] in
            var old = retiringInputs[device.id] ?? []
            for cached in inputs.values where cached.screenID == device.id {
                if !old.contains(where: { $0 === cached.input }) { old.append(cached.input) }
            }
            retiringInputs[device.id] = old
            return old
        }
        let unreleased = old.filter { !$0.releaseForBackendSwitch() }
        inputLock.withLock { retiringInputs[device.id] = unreleased }
        return unreleased.isEmpty
    }

    /// Verify saved curves per Bluetooth session with bounded retries. Only repeatable observed
    /// mismatches may trigger replacement; observation failure preserves files.
    func automaticallyCalibrate(_ device: Device, retry: Bool = false, verifyOnly: Bool = false) {
        guard USBInputController.shared.permitsBLE(device.id, generation: nil),
            device.lockState != .suspected, device.lockState != .paused,
            RelativePointerCalibration.isDeviceUDID(device.id),
            ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen),
            let host = device.host, let size = device.screen.size,
            size.width <= 4096, size.height <= 4096
        else { return }
        let input = input(for: host, screen: device.screen)
        let routeGeneration = USBInputController.shared.generation(device.id)
        guard
            verifyOnly || input.calibration?.matches(size) == true
                || (input.calibration == nil && input.needsCalibration),
            input.isCurrentSession,
            let session = input.session,
            HIDPeripheral.shared.isReady(report: .relativeMouse, host: host, session: session)
        else { return }
        let identityConfirmed = {
            let manager = ScreenCaptureManager.shared
            return manager.identityState == .singleDevice || manager.identityVerified(for: device.screen)
        }
        // Restricted fallback matching proves motion ownership, but cannot
        // justify rewriting a template under an unconfirmed physical USB ID.
        guard verifyOnly || identityConfirmed() else { return }
        let identity = PointerCalibrationJobs.Identity(screenID: device.id, host: host, session: session)
        let activity = input.inputActivitySequence
        guard
            lock.withLock({
                pairings[device.id] == host && calibrationJobs.begin(identity, retry: retry)
            })
        else { return }
        log("automatic pointer calibration started for \(device.screen.name)")
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            var verifiedProfile: RelativePointerCalibration?
            var saved = false
            var reused = false
            defer {
                self.lock.withLock {
                    self.calibrationJobs.finish(
                        identity, failure: failure, profile: verifiedProfile, saved: saved, reused: reused,
                        userInterrupted: failure != nil && input.inputActivitySequence != activity)
                }
            }
            let isReady = {
                USBInputController.shared.permitsBLE(device.id, generation: routeGeneration)
                    && ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen) && input.isCurrentSession
                    && HIDPeripheral.shared.isReady(report: .relativeMouse, host: host, session: session)
                    && self.lock.withLock { self.pairings[device.id] == host }
                    && ScreenCaptureManager.shared.all.contains { $0 === device.screen }
                    && device.screen.size == size
                    && (verifyOnly || identityConfirmed())
            }
            do {
                let originalFiles = try RelativePointerCalibration.storageSnapshot(host: host, screenID: device.id)
                guard
                    self.loadCalibration(host: host, screen: device.screen)
                        == input.calibration
                else { throw DeviceError("pointer calibration changed before measurement; reload it first") }
                let resolution = try input.measureRelativePointer(
                    screenID: device.id, size: size, activity: activity, reuseExisting: !verifyOnly, isReady: isReady,
                    capture: { device.screen.thumbnail(width: Int(size.width), height: Int(size.height)) },
                    onMismatch: {
                        self.lock.withLock { self.calibrationJobs.rejectExisting(identity) }
                        log("saved pointer curve no longer matches \(device.screen.name); measuring replacement")
                    },
                    progress: { count in
                        self.lock.withLock { self.calibrationJobs.progress(identity, count: count) }
                    })
                guard isReady() else { throw DeviceError("device changed during automatic pointer calibration") }
                guard try RelativePointerCalibration.storageSnapshot(host: host, screenID: device.id) == originalFiles
                else {
                    throw DeviceError("pointer calibration files changed during measurement; existing files preserved")
                }
                let profile = resolution.profile
                verifiedProfile = profile
                reused = resolution.reused
                if reused {
                    log("saved pointer calibration verified for \(device.screen.name); reused unchanged")
                    return
                }
                if verifyOnly {
                    log("automatic pointer measurement verified for \(device.screen.name); saved profile unchanged")
                    return
                }
                // A probe queued after measurement can call back into the
                // registry from this input queue. Retire before taking either
                // registry lock so waiting for that queue cannot block its
                // readiness callback; recheck identity before publishing.
                try input.retireForCalibrationReload(ifActivityUnchanged: activity)
                guard ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen),
                    HIDPeripheral.shared.connectionSession(for: host) == session,
                    HIDPeripheral.shared.isReady(report: .relativeMouse, host: host, session: session),
                    ScreenCaptureManager.shared.all.contains(where: { $0 === device.screen }),
                    device.screen.size == size
                else { throw DeviceError("device changed before saving pointer calibration") }
                // Cache construction can wait for Bluetooth callbacks that
                // need the registry lock, so acquire the cache lock first.
                try self.inputLock.withLock {
                    try self.lock.withLock {
                        guard ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen),
                            self.pairings[device.id] == host,
                            ScreenCaptureManager.shared.all.contains(where: { $0 === device.screen })
                        else {
                            throw DeviceError("device pairing changed during automatic pointer calibration")
                        }
                        guard self.inputs[host]?.input === input, input.isRetired else {
                            throw DeviceError("pointer input changed during automatic pointer calibration")
                        }
                        guard identityConfirmed(), profile.screenID == device.id else {
                            throw DeviceError("physical USB identity changed before saving pointer calibration")
                        }
                        try profile.saveVerified(ifUnchanged: originalFiles)
                        self.calibrationJobs.clearRejection(screenID: device.id)
                        self.inputs[host] = nil
                        saved = true
                    }
                }
                log("automatic pointer calibration verified for \(device.screen.name); saved=\(saved)")
            } catch {
                if self.lock.withLock({ self.calibrationJobs.hasRejectedCalibration(identity) }) {
                    input.rejectCalibration()
                }
                failure = String(describing: error)
                log("automatic pointer calibration stopped for \(device.screen.name): \(error)")
            }
        }
    }

    private func scheduleAutomaticCalibrations() {
        for device in all() { automaticallyCalibrate(device) }
    }

    /// Rebuild only this phone's input after calibration changes. Old window
    /// references retire and re-resolve on their next refresh; Bluetooth and
    /// every other phone's input remain intact.
    func reloadCalibration(for device: Device) throws {
        guard let host = device.host else { throw DeviceError("device has no matched Bluetooth connection") }
        guard !isAutomaticallyCalibrating(screenID: device.id) else { throw DeviceInput.InputError.pointerBusy }
        try inputLock.withLock {
            if let cached = inputs[host] { try cached.input.retireForCalibrationReload() }
            lock.withLock { calibrationJobs.invalidate(screenID: device.id) }
            inputs[host] = nil
        }
    }

    /// Matches unmatched hosts to unmatched screens and waits for the result.
    /// `force` rematches every screen present; a screen nothing is found for keeps its match.
    /// Every new match is probed, including single-phone connections. `probe`
    /// remains accepted for compatibility with existing clients.
    /// `allowProbing` is false for passive UI refreshes. Topology changes and
    /// explicit matching may move pointers, with at most one delayed retry.
    @discardableResult
    func match(force: Bool = false, probe: Bool = false, allowProbing: Bool = true) -> [String: UUID] {
        if allowProbing {
            reconnectSavedBluetoothHostsIfNeeded(resetExhausted: true)
            ScreenCaptureManager.shared.retryIdentityVerification()
        }
        return matchQueue.sync {
            runMatch(force: force, alwaysProbe: probe, allowProbing: allowProbing, restartProbing: allowProbing)
        }
    }

    private func reconnectSavedBluetoothHostsIfNeeded(resetExhausted: Bool) {
        reconnectSavedBluetoothHosts(for: ScreenCaptureManager.shared.all, resetExhausted: resetExhausted)
    }

    private func reconnectSavedBluetoothHosts(
        for screens: [ScreenCaptureSession], resetExhausted: Bool
    ) {
        let pairings = lock.withLock { self.pairings }
        guard !pairings.isEmpty else { return }
        let devices = buildDevices(from: screens)
        let presentIDs = Set(devices.map(\.id))
        let matchedIDs = Set(devices.filter { $0.host != nil }.map(\.id))
        let connected = Set(HIDPeripheral.shared.connectedHosts)
        let targets = HIDPeripheral.hostsToReconnect(
            pairings: pairings, presentScreenIDs: presentIDs,
            matchedScreenIDs: matchedIDs, connectedHosts: connected)
        HIDPeripheral.shared.reconnectKnownHosts(targets, resetExhausted: resetExhausted)
    }

    /// USB-selected captures cannot be targets of background BLE motion probes.
    private var bluetoothAssociationScreens: [ScreenCaptureSession] {
        ScreenCaptureManager.shared.associationScreens.filter { USBInputController.shared.permitsBLE($0.id, generation: nil) }
    }
    // MARK: Matching

    private func scheduleMatch(usableScreenID: String? = nil) {
        let alreadyPending = lock.withLock {
            if let usableScreenID { usableScreenRetries.insert(usableScreenID) }
            defer { matchPending = true }
            return matchPending
        }
        guard !alreadyPending else { return }
        matchQueue.asyncAfter(deadline: .now() + 1.5) {
            let usableScreenIDs = self.lock.withLock {
                self.matchPending = false
                defer { self.usableScreenRetries.removeAll() }
                return self.usableScreenRetries
            }
            let sessions = Dictionary(
                uniqueKeysWithValues: HIDPeripheral.shared.hostDetails.compactMap { detail in
                    detail.session.map { (detail.host, $0) }
                })
            if self.identityRetrySchedule.update(sessions) {
                ScreenCaptureManager.shared.retryIdentityVerification()
            }
            let retryUnmatched = self.all().contains { usableScreenIDs.contains($0.id) && $0.host == nil }
            if retryUnmatched { log("usable unlocked frame restored; retrying unmatched Bluetooth association") }
            self.runMatch(
                force: false, alwaysProbe: false, requireChangedTopology: !retryUnmatched)
        }
    }

    @discardableResult
    private func runMatch(
        force: Bool, alwaysProbe: Bool, allowProbing: Bool = true,
        restartProbing: Bool = false, requireChangedTopology: Bool = false
    ) -> [String: UUID] {
        guard ScreenCaptureManager.shared.permitsPointerAssociation else { return [:] }
        let screens = bluetoothAssociationScreens
        let hosts = HIDPeripheral.shared.connectedHosts
        let reconnectingHosts = restartProbing ? Set<UUID>() : HIDPeripheral.shared.reconnectingHosts
        if allowProbing {
            let pointerReports = Dictionary(
                uniqueKeysWithValues: hosts.map { host in
                    let session = HIDPeripheral.shared.connectionSession(for: host)
                    return (host, HIDPeripheral.shared.subscribedPointerReports(for: host, session: session))
                })
            if !restartProbing {
                let hasCapturedFrame = screens.contains { $0.frame() != nil }
                let hasReadyPointerHost = pointerReports.values.contains { !$0.isEmpty }
                guard
                    DevicePairingProbeSchedule.isReadyForAutomaticProbe(
                        hasCapturedFrame: hasCapturedFrame, hasReadyPointerHost: hasReadyPointerHost)
                else { return [:] }
            }
            let topology = DevicePairingProbeSchedule.Topology(
                screens: Dictionary(uniqueKeysWithValues: screens.map { ($0.id, ObjectIdentifier($0)) }),
                sessions: Dictionary(
                    uniqueKeysWithValues: hosts.compactMap { host in
                        HIDPeripheral.shared.connectionSession(for: host).map { (host, $0) }
                    }),
                pointerReports: pointerReports,
                reconnectingHosts: reconnectingHosts)
            let changed = probeSchedule.update(topology, restart: restartProbing)
            guard !requireChangedTopology || changed else { return [:] }
            probingCancelled = false
            probeEvidence = [:]
            probingGeneration = lock.withLock { backgroundMotionGeneration }
            // observeProbeActivity enrolls only inputs actually used in this
            // round; unrelated, already matched phones may remain in use.
            probeActivities = [:]
        }
        defer {
            if allowProbing {
                if probingMayContinue() { scheduleAutomaticCalibrations() }
                probeActivities = nil
            }
        }
        if allowProbing, !force { verifySavedAssociations(screens: screens, hosts: hosts) }
        guard !allowProbing || probingMayContinue() else { return [:] }
        let savedPairings = lock.withLock { self.pairings }
        var pairings = savedPairings
        if force { for screen in screens { pairings[screen.id] = nil } }
        var recoveryBlocked = false

        if !force, allowProbing {
            switch recoverReplacedUSBDevice(screens: screens, hosts: hosts, pairings: pairings) {
            case .recovered(let recovered):
                guard
                    store(
                        recovered, expectingPairings: pairings
                    )
                else { return [:] }
                for (id, host) in recovered {
                    log(
                        "recovered USB replacement \(screens.first { $0.id == id }?.name ?? id) with bluetooth host \(host)"
                    )
                }
                scheduleProbingRetryIfNeeded()
                return recovered
            case .blocked:
                // Do not let generic matching bypass recovery's evidence checks.
                // A probing round can fail innocently — a locked phone shows no
                // pointer, fresh captures may not have frames — so request the
                // single delayed retry instead of probing again immediately. A completely new
                // USB screen is different: stale records for disconnected
                // screens must not strand it behind an unrelated BLE host whose
                // probe is unavailable. Generic matching still requires a
                // movement proof before it stores a new binding.
                recoveryBlocked = true
                scheduleProbingRetryIfNeeded()
            case .notApplicable:
                break
            }

            if let reclaimed = reclaimVerifiedScreenOwner(screens: screens, hosts: hosts, pairings: pairings),
                store(reclaimed, expectingPairings: pairings)
            {
                for (id, host) in reclaimed {
                    log(
                        "reclaimed \(screens.first { $0.id == id }?.name ?? id) for its verified bluetooth host \(host)"
                    )
                }
                scheduleProbingRetryIfNeeded()
                return reclaimed
            }
        }

        let matchedHosts = Set(screens.compactMap { pairings[$0.id] }.filter(hosts.contains))
        let freeScreenIDs = Set(
            DevicePairingRecovery.matchingScreenIDs(
                screenIDs: screens.map(\.id), pairings: pairings, connectedHosts: hosts,
                reconnectingHosts: reconnectingHosts, recoveryBlocked: recoveryBlocked))
        var freeScreens = screens.filter { freeScreenIDs.contains($0.id) }
        let freeHosts = DevicePairingRecovery.orderedDiscoveryHosts(
            connectedHosts: hosts, matchedHosts: matchedHosts, pairings: pairings)
        guard !freeScreens.isEmpty, !freeHosts.isEmpty else { return [:] }

        var found: [String: UUID] = [:]
        // New bindings always need a movement proof. A single connected host
        // can belong to a different, USB-disconnected phone, and the probe also
        // discovers phones that need relative calibration.
        if allowProbing {
            for host in freeHosts where !freeScreens.isEmpty {
                guard probingMayContinue() else { break }
                guard let screen = probe(host, among: freeScreens) else { continue }
                found[screen.id] = host
                freeScreens.removeAll { $0.id == screen.id }
            }
            // Probing rounds that leave screens unpaired may have run against a
            // locked phone or not-yet-ready captures; request the bounded retry.
            scheduleProbingRetryIfNeeded()
        }
        guard Set(HIDPeripheral.shared.connectedHosts) == Set(hosts),
            store(found, expectingPairings: savedPairings)
        else { return [:] }
        for (id, host) in found {
            log("matched \(screens.first { $0.id == id }?.name ?? id) to bluetooth host \(host)")
        }
        return found
    }

    private func verifySavedAssociations(screens: [ScreenCaptureSession], hosts: [UUID]) {
        let sessions = Dictionary(
            uniqueKeysWithValues: hosts.compactMap { host in
                HIDPeripheral.shared.connectionSession(for: host).map { (host, $0) }
            })
        let saved = lock.withLock {
            promoteVerifiedAssociationsLocked(screens: screens, sessions: sessions)
            return pairings
        }
        var found: [String: UUID] = [:]
        for screen in screens {
            guard probingMayContinue() else { break }
            guard let host = saved[screen.id], let session = sessions[host] else { continue }
            let key = Association(screen: screen.associationIdentity, host: host, session: session)
            guard !lock.withLock({ verifiedAssociations.contains(key) && pointerOrientations[key] != nil }) else {
                continue
            }
            guard let actual = probe(host, among: screens), found[actual.id] == nil else { continue }
            found[actual.id] = host
        }
        guard sessions.allSatisfy({ HIDPeripheral.shared.connectionSession(for: $0.key) == $0.value }) else { return }
        if store(found, expectingPairings: saved) {
            for (id, host) in found { log("verified current capture association \(id) with \(host)") }
        }
        if all().contains(where: { $0.host == nil }) { scheduleProbingRetryIfNeeded() }
    }

    /// Wait progressively longer for slow subscriptions, first frames or unlock.
    /// The finite retry schedule never polls continuously with pointer motion.
    private func scheduleProbingRetryIfNeeded() {
        guard probingMayContinue() else { return }
        let screens = bluetoothAssociationScreens
        let hosts = HIDPeripheral.shared.connectedHosts
        let pairings = lock.withLock { self.pairings }
        let matchedHosts = Set(all().compactMap(\.host))
        let freeScreens = screens.filter { pairings[$0.id].map { !matchedHosts.contains($0) } ?? true }
        guard !freeScreens.isEmpty else { return }
        guard hosts.contains(where: { !matchedHosts.contains($0) }) else { return }

        guard let token = probeSchedule.scheduleRetry(), let delay = probeSchedule.pendingRetryDelay else { return }
        let activity = probeActivities?.map { $0.value } ?? []
        let generation = probingGeneration
        matchQueue.asyncAfter(deadline: .now() + delay) {
            guard self.probeSchedule.beginRetry(token) else { return }
            guard self.lock.withLock({ self.backgroundMotionGeneration == generation }),
                activity.allSatisfy({ $0.input.inputActivitySequence == $0.sequence })
            else {
                self.probeSchedule.cancel()
                return
            }
            self.runMatch(force: false, alwaysProbe: false, allowProbing: true)
        }
    }

    private func observeProbeActivity(_ input: DeviceInput) -> UInt64? {
        guard probingMayContinue() else { return nil }
        let key = ObjectIdentifier(input)
        if probeActivities?[key] == nil {
            probeActivities?[key] = (input, input.inputActivitySequence)
        }
        return input.inputActivitySequence
    }

    /// A cancelled per-host probe must not immediately restart as a relative
    /// fallback or move another host in the same matching round.
    private func probingMayContinue() -> Bool {
        guard !probingCancelled, ScreenCaptureManager.shared.permitsPointerAssociation else { return false }
        guard lock.withLock({ backgroundMotionGeneration == probingGeneration }),
            probeActivities?.values.allSatisfy({ $0.input.inputActivitySequence == $0.sequence }) ?? true
        else {
            probingCancelled = true
            probeSchedule.cancel()
            log("pointer discovery stopped for user input")
            return false
        }
        return true
    }

    /// USB reconnects can expose a new capture identity while CoreBluetooth
    /// keeps the old host online. A verified calibration profile is the only
    /// persisted evidence we use to identify that stale pairing. Probe both
    /// hosts before replacing it; uncertain or failed probes leave the saved
    /// pairing untouched for an explicit `/match` retry.
    private func recoverReplacedUSBDevice(
        screens: [ScreenCaptureSession], hosts: [UUID], pairings: [String: UUID]
    ) -> ReplacementRecovery {
        // Keep recovery intentionally narrow until multi-screen evidence can be
        // scored as a complete one-to-one matrix.
        guard screens.count == 1, let screen = screens.first else { return .notApplicable }
        let screenIDs = Set(screens.map(\.id))
        let matchedHosts = Set(screens.compactMap { pairings[$0.id] }.filter(hosts.contains))
        let freeHosts = hosts.filter { !matchedHosts.contains($0) }
        let mismatchedIDs = Set(
            screens.compactMap { screen -> String? in
                guard let host = pairings[screen.id], hosts.contains(host),
                    RelativePointerCalibration.isBoundToDifferentScreen(host: host, screenID: screen.id)
                else { return nil }
                return screen.id
            })
        let verifiedAbsentIDs = Set(
            pairings.compactMap { id, host -> String? in
                guard !screenIDs.contains(id), hosts.contains(host),
                    RelativePointerCalibration.isBoundToScreen(host: host, screenID: id)
                else { return nil }
                return id
            })

        // Older versions could save a replacement USB identity against the
        // still-connected old host before it had any calibration identity.
        // In that case, first test only truly unmapped hosts. Probe the current
        // mapping only after exactly one candidate clearly affects this screen.
        let isCurrentSessionVerified: Bool = {
            guard let mappedHost = pairings[screen.id],
                let session = HIDPeripheral.shared.connectionSession(for: mappedHost)
            else { return false }
            return lock.withLock {
                verifiedAssociations.contains(
                    Association(screen: screen.associationIdentity, host: mappedHost, session: session))
            }
        }()
        if mismatchedIDs.isEmpty,
            let mappedHost = pairings[screen.id], hosts.contains(mappedHost),
            DevicePairingRecovery.shouldVerifyUnidentifiedCurrentMapping(
                isCurrentSessionVerified: isCurrentSessionVerified,
                boundScreenID: RelativePointerCalibration.boundScreenID(host: mappedHost)),
            let candidate = DevicePairingRecovery.currentMappingCandidate(
                screenIDs: screens.map(\.id), pairings: pairings,
                connectedHosts: hosts, unmatchedHosts: freeHosts)
        {
            return verifyUnidentifiedCurrentMapping(
                candidate, screen: screen, screens: screens, hosts: hosts, pairings: pairings)
        }

        guard
            DevicePairingRecovery.shouldAttemptRecovery(
                screenID: screen.id, pairings: pairings,
                mismatchedCalibrationScreenIDs: mismatchedIDs,
                verifiedAbsentScreenPairingIDs: verifiedAbsentIDs)
        else { return .notApplicable }
        guard
            let candidate = DevicePairingRecovery.candidate(
                screenIDs: screens.map(\.id), pairings: pairings, connectedHosts: hosts,
                unmatchedHosts: freeHosts, mismatchedCalibrationScreenIDs: mismatchedIDs,
                verifiedAbsentScreenPairingIDs: verifiedAbsentIDs),
            candidate.screenID == screen.id
        else { return .blocked }

        guard
            RelativePointerCalibration.load(host: candidate.mappedHost, screenSize: nil) != nil,
            let mappedProfileScreenID = RelativePointerCalibration.boundScreenID(host: candidate.mappedHost),
            candidate.mappedScreenID == screen.id
                ? mappedProfileScreenID != screen.id
                : mappedProfileScreenID == candidate.mappedScreenID
        else { return .blocked }

        // probeAndReplace probes candidates first, so the mapped phone's
        // pointer only moves once a replacement is actually plausible.
        guard
            case .recovered(let replacement) = probeAndReplace(
                candidate, screen: screen, screens: screens, hosts: hosts, pairings: pairings)
        else { return .blocked }
        return .recovered(replacement)
    }

    /// Verifies an unidentified saved mapping with a candidate-first probe.
    /// This avoids moving the mapped phone's pointer when an unrelated BLE host
    /// appears, while still repairing stale USB-to-host pairs created by older
    /// releases once the current screen has a unique replacement candidate.
    private func verifyUnidentifiedCurrentMapping(
        _ candidate: DevicePairingRecovery.Candidate, screen: ScreenCaptureSession,
        screens: [ScreenCaptureSession], hosts: [UUID], pairings: [String: UUID]
    ) -> ReplacementRecovery {
        probeAndReplace(candidate, screen: screen, screens: screens, hosts: hosts, pairings: pairings)
    }

    /// Repairs a stored pairing that a device swap crossed onto the wrong
    /// host. The claimant — a connected host whose saved calibration was
    /// measured on the paired screen — is probed before the paired host, so
    /// an unverifiable claim never moves the currently paired phone.
    private func reclaimVerifiedScreenOwner(
        screens: [ScreenCaptureSession], hosts: [UUID], pairings: [String: UUID]
    ) -> [String: UUID]? {
        guard
            let candidate = DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: screens.map(\.id), pairings: pairings, connectedHosts: hosts,
                isVerifiedOwner: { RelativePointerCalibration.isBoundToScreen(host: $0, screenID: $1) }),
            let screen = screens.first(where: { $0.id == candidate.screenID })
        else { return nil }
        guard
            case .recovered(let replacement) = probeAndReplace(
                candidate, screen: screen, screens: screens, hosts: hosts, pairings: pairings)
        else { return nil }
        return replacement
    }

    /// Shared replacement proof: every candidate host is probed before the
    /// currently mapped one, a second hit aborts without touching the mapped
    /// phone, and the pairing is replaced only on a complete, unambiguous
    /// result set over an unchanged snapshot.
    private func probeAndReplace(
        _ candidate: DevicePairingRecovery.Candidate, screen: ScreenCaptureSession,
        screens: [ScreenCaptureSession], hosts: [UUID], pairings: [String: UUID]
    ) -> ReplacementRecovery {
        let probeHosts = [candidate.mappedHost] + candidate.unmatchedHosts
        let sessions = Dictionary(
            uniqueKeysWithValues: probeHosts.compactMap { host in
                HIDPeripheral.shared.connectionSession(for: host).map { (host, $0) }
            })
        guard sessions.count == probeHosts.count,
            recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions)
        else { return .blocked }

        var probeResults: [UUID: DevicePairingRecovery.ProbeResult] = [:]
        for host in candidate.unmatchedHosts {
            guard recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions),
                let expectedSession = sessions[host]
            else { return .blocked }

            let calibration = RelativePointerCalibration.pairingProbeCalibration(host: host, screenID: screen.id)
            let result = probeOutcome(
                host, on: screen, calibration: calibration, expectedSession: expectedSession,
                input: cachedInput(for: host, session: expectedSession))
            guard result != .unavailable else { return .blocked }
            probeResults[host] = result

            // A second hit already makes the candidate set ambiguous. Stop
            // here instead of moving more unrelated phones' pointers.
            if probeResults.values.filter({ $0 == .hit }).count > 1 { return .blocked }
        }
        guard DevicePairingRecovery.uniqueCandidateHit(for: candidate, probeResults: probeResults) != nil,
            recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions),
            let mappedSession = sessions[candidate.mappedHost]
        else { return .blocked }

        let mappedCalibration: PairingProbeCalibration
        if let calibration = RelativePointerCalibration.load(host: candidate.mappedHost, screenSize: nil) {
            mappedCalibration = .calibrated(calibration)
        } else if RelativePointerCalibration.requiresCalibration(host: candidate.mappedHost, screenID: nil) {
            // A malformed calibration opts this host into calibrated reports;
            // an absolute probe could falsely classify it as a miss.
            mappedCalibration = .unavailable
        } else {
            mappedCalibration = .absolute
        }
        let mappedResult = probeOutcome(
            candidate.mappedHost, on: screen, calibration: mappedCalibration, expectedSession: mappedSession,
            input: cachedInput(for: candidate.mappedHost, session: mappedSession))
        probeResults[candidate.mappedHost] = mappedResult

        guard recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions) else {
            return .blocked
        }
        guard let replacement = DevicePairingRecovery.replacement(for: candidate, probeResults: probeResults) else {
            return .blocked
        }
        return .recovered(replacement)
    }

    private func recoverySnapshotIsCurrent(
        screens: [ScreenCaptureSession], hosts: [UUID], pairings: [String: UUID], sessions: [UUID: UUID]
    ) -> Bool {
        let current = bluetoothAssociationScreens
        return ScreenCaptureManager.shared.permitsPointerAssociation && probingMayContinue()
            && current.count == screens.count && zip(current, screens).allSatisfy { $0 === $1 }
            && Set(HIDPeripheral.shared.connectedHosts) == Set(hosts)
            && lock.withLock({ self.pairings == pairings })
            && sessions.allSatisfy({ HIDPeripheral.shared.connectionSession(for: $0.key) == $0.value })
    }

    private func probeOutcome(
        _ host: UUID, on screen: ScreenCaptureSession,
        calibration: PairingProbeCalibration, expectedSession: UUID,
        input sharedInput: DeviceInput? = nil
    ) -> DevicePairingRecovery.ProbeResult {
        let routeGeneration = USBInputController.shared.generation(screen.id)
        let selectedCalibration: RelativePointerCalibration?
        let required: Bool
        switch calibration {
        case .calibrated(let profile):
            selectedCalibration = profile
            required = true
        case .absolute:
            selectedCalibration = nil
            required = false
        case .unavailable:
            selectedCalibration = nil
            required = true
        }
        let input =
            sharedInput
            ?? DeviceInput(
                host: host, session: expectedSession, calibration: selectedCalibration, calibrationRequired: required,
                inputIsAllowed: { [weak screen] in
                    guard let screen else { return false }
                    return USBInputController.shared.permitsBLE(screen.id, generation: routeGeneration)
                        && ScreenCaptureManager.shared.permitsPointerAssociation(for: screen)
                })
        guard input.host == host, input.session == expectedSession else { return .unavailable }
        let evidence = motionEvidence(input, verifyAbsolute: selectedCalibration == nil)
        let result = evidence.results[ObjectIdentifier(screen)] ?? .unavailable
        guard result == .hit else { return result }
        return finishProbe(input, on: screen, evidence: evidence) ? .hit : .unavailable
    }

    /// Scores only rank captures. A unique complete absolute trajectory or a
    /// relative rectangle must identify the screen before its binding is usable.
    private func probe(_ host: UUID, among screens: [ScreenCaptureSession]) -> ScreenCaptureSession? {
        let knownID = lock.withLock { pairings.first { $0.value == host }?.key }
        let input: DeviceInput
        if let screen = bluetoothAssociationScreens.first(where: { $0.id == knownID }) {
            input = self.input(for: host, screen: screen)
        } else {
            let captureSnapshot = bluetoothAssociationScreens
            let routes = captureSnapshot.map { ($0.id, USBInputController.shared.generation($0.id)) }
            let probeCalibration = RelativePointerCalibration.probeInputCalibration(
                host: host, screenID: screens.count == 1 ? screens[0].id : nil)
            input = DeviceInput(
                host: host, session: HIDPeripheral.shared.connectionSession(for: host),
                calibration: probeCalibration.calibration,
                calibrationRequired: probeCalibration.required,
                inputIsAllowed: {
                    let manager = ScreenCaptureManager.shared
                    return manager.permitsPointerAssociation
                        && routes.allSatisfy { USBInputController.shared.permitsBLE($0.0, generation: $0.1) }
                        && self.bluetoothAssociationScreens.count == captureSnapshot.count
                        && captureSnapshot.allSatisfy { manager.permitsPointerAssociation(for: $0) }
                })
        }
        let evidence = motionEvidence(input, verifyAbsolute: input.calibration == nil)
        let hits = screens.filter { evidence.results[ObjectIdentifier($0)] == .hit }
        guard hits.count == 1, let screen = hits.first,
            finishProbe(input, on: screen, evidence: evidence)
        else { return nil }
        return screen
    }

    /// All present screens are captured together. A unique absolute trajectory
    /// completes discovery directly; relative-only phones first try a local
    /// rectangle, then the edge-prepared path if that observation fails.
    private func motionEvidence(_ input: DeviceInput, verifyAbsolute: Bool) -> ProbeEvidence {
        let empty = ProbeEvidence(session: input.session)
        guard let sequence = observeProbeActivity(input), input.session != nil,
            HIDPeripheral.shared.connectionSession(for: input.host) == input.session
        else { return empty }
        if let cached = probeEvidence[input.host] {
            return cached.session == input.session ? cached : empty
        }
        guard input.isCurrentSession else { return empty }
        var evidence = empty
        // Even a failed or cancelled probe consumes this round's attempt.
        probeEvidence[input.host] = evidence
        let screens = bluetoothAssociationScreens
        guard !screens.isEmpty else { return evidence }
        let host = input.host
        let session = input.session
        func isReady(_ report: ReportID) -> Bool {
            ScreenCaptureManager.shared.permitsPointerAssociation && self.probingMayContinue()
                && input.inputActivitySequence == sequence && input.isCurrentSession
                && HIDPeripheral.shared.isReady(report: report, host: host, session: session)
        }
        if verifyAbsolute {
            func runAbsoluteTriangle(_ targets: [PointerScreenMatcher.ProbeTarget]) throws -> Bool {
                guard targets.count == 3 else { return false }
                let captures = try input.pairingProbe(
                    calibration: nil,
                    firstPoint: CGPoint(x: targets[0].x, y: targets[0].y),
                    secondPoint: CGPoint(x: targets[1].x, y: targets[1].y),
                    returnToStart: true,
                    thirdPoint: CGPoint(x: targets[2].x, y: targets[2].y),
                    isReady: { isReady(.absolutePointer) },
                    capture: {
                        let frames = screens.map {
                            $0.thumbnail(width: PointerScreenMatcher.width, height: PointerScreenMatcher.height)
                        }
                        guard frames.allSatisfy({ $0 != nil }) else { return nil }
                        return frames.flatMap { $0! }
                    })
                let pixels = PointerScreenMatcher.width * PointerScreenMatcher.height
                var sawPartialReversibleActivity = false
                if let intermediate = captures.intermediate, let returned = captures.returned {
                    for (i, screen) in screens.enumerated() {
                        let range = (i * pixels)..<((i + 1) * pixels)
                        let frames = [captures.before, captures.after, intermediate, returned].map { Array($0[range]) }
                        let key = ObjectIdentifier(screen)
                        let candidateScore = PointerScreenMatcher.score(
                            before: frames[0],
                            after: frames[1],
                            first: targets[0],
                            second: targets[1])
                        evidence.scores[key] = max(evidence.scores[key] ?? .min, candidateScore)
                        if PointerScreenMatcher.matchesAbsoluteRoundTrip(frames, targets: targets) {
                            if evidence.absoluteScreens.insert(key).inserted {
                                log("absolute pointer targets verified on \(screen.name) for \(host)")
                            }
                        } else if PointerScreenMatcher.hasReversibleTargetActivity(frames, targets: targets) {
                            sawPartialReversibleActivity = true
                        }
                    }
                }
                return sawPartialReversibleActivity
            }

            do {
                let sawPartialActivity = try runAbsoluteTriangle(PointerScreenMatcher.gutterProbeTargets)
                let matchedUniquely =
                    DevicePairingRecovery.absoluteProbeResults(
                        verified: screens.map { evidence.absoluteScreens.contains(ObjectIdentifier($0)) }) != nil
                if !matchedUniquely,
                    sawPartialActivity,
                    probingMayContinue(),
                    input.inputActivitySequence == sequence,
                    screens.allSatisfy({ screen in ScreenCaptureManager.shared.all.contains { $0 === screen } })
                {
                    _ = try runAbsoluteTriangle(PointerScreenMatcher.fallbackProbeTargets)
                }
            } catch {
                log("absolute probe \(host) unavailable: \(error)")
            }
        }
        guard probingMayContinue(), input.inputActivitySequence == sequence else { return empty }
        guard screens.allSatisfy({ screen in ScreenCaptureManager.shared.all.contains { $0 === screen } })
        else { return empty }
        if let results = DevicePairingRecovery.absoluteProbeResults(
            verified: screens.map { evidence.absoluteScreens.contains(ObjectIdentifier($0)) })
        {
            for (screen, result) in zip(screens, results) {
                evidence.results[ObjectIdentifier(screen)] = result
                if result == .hit { evidence.orientations[ObjectIdentifier(screen)] = .identity }
            }
            probeEvidence[host] = evidence
            log("absolute trajectory matched \(host); relative discovery skipped")
            return evidence
        }
        let order = PointerScreenMatcher.candidateOrder(
            scores: screens.map { evidence.scores[ObjectIdentifier($0)] ?? 0 })
        let rankedScreens = order.map { screens[$0] }
        do {
            for preparePosition in [false, true] {
                var originFrames: [PointerMotionObservation.Frame] = []
                let originScreen = rankedScreens.first { screen in
                    guard let calibration = input.calibration, let size = screen.size else { return false }
                    return calibration.screenID == screen.id && calibration.matches(size)
                }
                let captures = try input.relativePairingProbe(
                    preparePosition: preparePosition, isReady: { isReady(.relativeMouse) },
                    capture: {
                        if let originScreen, let size = originScreen.size,
                            let pixels = originScreen.thumbnail(width: Int(size.width), height: Int(size.height))
                        {
                            originFrames.append(.init(width: Int(size.width), height: Int(size.height), pixels: pixels))
                        }
                        return rankedScreens.map {
                            $0.thumbnail(
                                width: RelativePointerScreenMatcher.width, height: RelativePointerScreenMatcher.height)
                        }
                    })
                guard probingMayContinue(), input.inputActivitySequence == sequence,
                    screens.allSatisfy({ screen in ScreenCaptureManager.shared.all.contains { $0 === screen } })
                else { return empty }
                for (i, screen) in rankedScreens.enumerated() {
                    let frames = captures.map { $0[i] }
                    let orientation = RelativePointerScreenMatcher.orientation(frames)
                    let result =
                        orientation != nil
                        ? DevicePairingRecovery.ProbeResult.hit : DevicePairingRecovery.probeResult(for: frames)
                    evidence.orientations[ObjectIdentifier(screen)] = orientation
                    evidence.results[ObjectIdentifier(screen)] = result
                    log(
                        "relative probe \(host) on \(screen.name): \(result), prepared=\(preparePosition), orientation=\(orientation?.rawValue ?? "unknown")"
                    )
                }
                if evidence.results.values.filter({ $0 == .hit }).count == 1 {
                    if let originScreen, evidence.results[ObjectIdentifier(originScreen)] == .hit,
                        let orientation = evidence.orientations[ObjectIdentifier(originScreen)],
                        let origin = PointerMotionObservation.closedRectangleOrigin(
                            originFrames, orientation: orientation)
                    {
                        evidence.pointerOrigins[ObjectIdentifier(originScreen)] = (origin, sequence)
                    }
                    break
                }
            }
        } catch {
            log("relative probe \(host) unavailable: \(error)")
        }
        probeEvidence[host] = evidence
        return evidence
    }

    /// Identity verification must preserve an existing curve. Only a phone
    /// without any valid profile and without a proven absolute return path
    /// needs first-use measurement after the binding has been established.
    private func finishProbe(
        _ input: DeviceInput, on screen: ScreenCaptureSession, evidence: ProbeEvidence
    ) -> Bool {
        let key = ObjectIdentifier(screen)
        guard ScreenCaptureManager.shared.permitsPointerAssociation(for: screen), probingMayContinue(),
            input.session != nil,
            HIDPeripheral.shared.connectionSession(for: input.host) == input.session,
            evidence.session == input.session,
            evidence.results[key] == .hit,
            evidence.results.values.filter({ $0 == .hit }).count == 1,
            ScreenCaptureManager.shared.all.contains(where: { $0 === screen })
        else { return false }
        // A previous caller may have retired this input solely to reload the
        // mode established by this very proof. Its cached identity remains
        // valid within the round, without retiring or writing the marker twice.
        if probeEvidence[input.host]?.preparedScreens.contains(key) == true { return true }
        guard input.isCurrentSession else { return false }
        let hasProfile =
            RelativePointerCalibration.loadMatchingScreen(host: input.host, screenSize: nil, screenID: screen.id) != nil
        let absoluteVerified = evidence.absoluteScreens.contains(key)
        guard let orientation = evidence.orientations[key] else { return false }
        input.adoptRelativePointerOrientation(orientation)
        if let origin = evidence.pointerOrigins[key],
            input.adoptObservedPointerOrigin(origin.point, screenID: screen.id, activity: origin.activity)
        {
            log("observed pointer origin retained for \(screen.name); initial homing skipped")
        }
        if !hasProfile, absoluteVerified {
            do {
                try RelativePointerCalibration.clearRequirementAfterAbsoluteProof(screenID: screen.id)
                if input.needsCalibration {
                    let beforeRetirement = input.inputActivitySequence
                    try input.retireForCalibrationReload()
                    guard input.inputActivitySequence == beforeRetirement &+ 1 else { return false }
                    probeActivities?[ObjectIdentifier(input)] = (input, input.inputActivitySequence)
                }
                probeEvidence[input.host]?.preparedScreens.insert(key)
                return true
            } catch {
                log("absolute pointer mode recovery unavailable: \(error)")
                return false
            }
        }
        guard
            DevicePairingRecovery.shouldRequireCalibration(
                hasProfile: hasProfile, absoluteVerified: absoluteVerified)
        else {
            probeEvidence[input.host]?.preparedScreens.insert(key)
            return true
        }
        do {
            try RelativePointerCalibration.markRequired(screenID: screen.id)
            let beforeRetirement = input.inputActivitySequence
            try input.retireForCalibrationReload()
            guard input.inputActivitySequence == beforeRetirement &+ 1 else { return false }
            probeActivities?[ObjectIdentifier(input)] = (input, input.inputActivitySequence)
            probeEvidence[input.host]?.preparedScreens.insert(key)
            log("relative probe verified \(screen.name) for \(input.host); calibration required")
            return true
        } catch {
            log("relative probe calibration state unavailable: \(error)")
            return false
        }
    }

    // MARK: Saved matches

    /// One host drives one screen, so a new match replaces the host's old one.
    @discardableResult
    private func store(
        _ found: [String: UUID],
        expectingPairings expectedPairings: [String: UUID]? = nil, motionVerified: Bool = true
    ) -> Bool {
        guard !found.isEmpty else { return true }
        let screens = bluetoothAssociationScreens
        let sessions = Dictionary(
            uniqueKeysWithValues: HIDPeripheral.shared.hostDetails.compactMap { detail in
                detail.session.map { (detail.host, $0) }
            })
        if motionVerified {
            guard ScreenCaptureManager.shared.permitsPointerAssociation, probingMayContinue(),
                found.allSatisfy({ id, host in
                    guard let screen = screens.first(where: { $0.id == id }),
                        let session = sessions[host], let evidence = probeEvidence[host]
                    else { return false }
                    return evidence.session == session
                        && evidence.preparedScreens.contains(ObjectIdentifier(screen))
                })
            else { return false }
        }
        return lock.withLock {
            // Recovery is based on a snapshot taken before probing. Check it
            // again while holding the same lock used to publish pairings so a
            // concurrent explicit /pair cannot be overwritten by stale data.
            guard expectedPairings == nil || pairings == expectedPairings else { return false }
            for (id, host) in found {
                Self.invalidateReplacedAssociations(
                    &verifiedAssociations, screenID: id, host: host,
                    screenIdentities: Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.associationIdentity) }),
                    pairings: pairings)
                for (other, existing) in pairings where existing == host { pairings[other] = nil }
                pairings[id] = host
                if motionVerified, let screen = screens.first(where: { $0.id == id }), let session = sessions[host] {
                    let association = Association(screen: screen.associationIdentity, host: host, session: session)
                    verifiedAssociations.insert(association)
                    pointerOrientations[association] = probeEvidence[host]?.orientations[ObjectIdentifier(screen)]
                }
            }
            pointerOrientations = pointerOrientations.filter { association, _ in
                verifiedAssociations.contains(association) && sessions[association.host] == association.session
                    && screens.contains { $0.associationIdentity == association.screen }
            }
            pairingStore.save(pairings)
            return true
        }
    }

    private func load() {
        guard let saved = pairingStore.load() else { return }
        lock.withLock { pairings = saved }
    }

    private static func describe(_ devices: [Device]) -> String {
        let table = StringsAPI.current
        guard !devices.isEmpty else { return table.describeEmpty }
        return table.describePrefix + devices.map { "\($0.screen.name) (\($0.id))" }.joined(separator: ", ")
    }
}
