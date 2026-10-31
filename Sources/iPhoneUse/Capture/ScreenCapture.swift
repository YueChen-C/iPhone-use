import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenCaptureStopResult: Equatable {
    let initiated: Bool
    let captureDrained: Bool
    let usbRestored: Bool

    var isClean: Bool { initiated && captureDrained && usbRestored }
}

protocol StoppableCaptureSource: AnyObject {
    func stop(completion: (() -> Void)?)
}

/// Enforces a single monotonic deadline across asynchronous capture session
/// shutdown and post-drain USB configuration restoration.
enum CaptureShutdownCoordinator {
    static func stop(
        waitTimeout: TimeInterval,
        activeSources: [StoppableCaptureSource],
        notifyQueue: DispatchQueue,
        restoreAllUSB: @escaping (_ deadlineUptime: TimeInterval) -> Bool
    ) -> ScreenCaptureStopResult {
        let boundedWait = (waitTimeout.isFinite && waitTimeout > 0) ? waitTimeout : 0
        let deadline = ProcessInfo.processInfo.systemUptime + boundedWait

        let group = DispatchGroup()
        for source in activeSources {
            group.enter()
            source.stop { group.leave() }
        }

        let usbDone = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var usbClean = false
        group.notify(queue: notifyQueue) {
            let restored = restoreAllUSB(deadline)
            resultLock.withLock { usbClean = restored }
            usbDone.signal()
        }

        guard boundedWait > 0 else {
            let drained = activeSources.isEmpty
            let restoredNow =
                drained
                && (usbDone.wait(timeout: .now()) == .success)
                && resultLock.withLock({ usbClean })
            return ScreenCaptureStopResult(
                initiated: true,
                captureDrained: drained,
                usbRestored: restoredNow)
        }

        let captureDrained: Bool
        if activeSources.isEmpty {
            captureDrained = true
        } else {
            let remainingForCapture = deadline - ProcessInfo.processInfo.systemUptime
            if remainingForCapture > 0 {
                captureDrained = group.wait(timeout: .now() + remainingForCapture) == .success
            } else {
                captureDrained = group.wait(timeout: .now()) == .success
            }
        }

        guard captureDrained else {
            return ScreenCaptureStopResult(
                initiated: true,
                captureDrained: false,
                usbRestored: false)
        }

        let remainingForUSB = deadline - ProcessInfo.processInfo.systemUptime
        let waitedOK: Bool
        if remainingForUSB > 0 {
            waitedOK = usbDone.wait(timeout: .now() + remainingForUSB) == .success
        } else {
            waitedOK = usbDone.wait(timeout: .now()) == .success
        }
        let usbRestored = waitedOK && resultLock.withLock({ usbClean })
        return ScreenCaptureStopResult(
            initiated: true,
            captureDrained: true,
            usbRestored: usbRestored)
    }
}

/// Resolves single-device USB physical pinning outside manager locks so
/// `manager.lock -> USBValeriaConfigurator.queue` lock-order edges never exist.
enum CaptureDiscoveryPinResolver {
    static func prequerySingleDevicePin(
        discoveredIDs: [String],
        needsNewSourceForID: (String) -> Bool,
        querySingleIOSDevice: () -> USBValeriaConfigurator.PinnedUSBDevice?
    ) -> (deviceID: String, pin: USBValeriaConfigurator.PinnedUSBDevice?)? {
        guard discoveredIDs.count == 1,
            let onlyID = discoveredIDs.first,
            needsNewSourceForID(onlyID)
        else { return nil }
        guard let queried = querySingleIOSDevice() else {
            return (onlyID, nil)
        }
        if !USBValeriaConfigurator.isOpaqueCaptureUUID(onlyID) {
            guard let discoveredSerial = USBValeriaConfigurator.normalizedSerial(onlyID),
                let usbSerial = USBValeriaConfigurator.normalizedSerial(queried.serial),
                discoveredSerial == usbSerial
            else {
                return (onlyID, nil)
            }
        }
        return (onlyID, queried)
    }

    static func prequerySingleOpaqueDevicePin(
        discoveredIDs: [String],
        needsNewSourceForID: (String) -> Bool,
        querySingleIOSDevice: () -> USBValeriaConfigurator.PinnedUSBDevice?
    ) -> (deviceID: String, pin: USBValeriaConfigurator.PinnedUSBDevice?)? {
        guard discoveredIDs.count == 1,
            let onlyID = discoveredIDs.first,
            USBValeriaConfigurator.isOpaqueCaptureUUID(onlyID)
        else { return nil }
        return prequerySingleDevicePin(
            discoveredIDs: discoveredIDs,
            needsNewSourceForID: needsNewSourceForID,
            querySingleIOSDevice: querySingleIOSDevice)
    }
}

/// Every iPhone plugged in over USB. A trusted iPhone shows up as a muxed capture
/// device once screen-capture devices are allowed (the same switch QuickTime flips).
final class ScreenCaptureManager: CaptureValeriaRecoveryHost {
    static let shared = ScreenCaptureManager()

    // The lock serializes discovery callbacks, timer refreshes and API reads.
    private let lock = NSLock()
    /// AVFoundation's nominal UIDs can be attached to the other iPhone's pixels
    /// when multiple muxed devices are present. Keep acquisition keyed by its
    /// source UID separately from the verified physical screen identity.
    private var sources: [String: ScreenCaptureSource] = [:]
    private var screens: [String: ScreenCaptureSession] = [:]
    private var verifiedScreenIDs: Set<String> = []
    private var refreshTimer: Timer?
    private var loggedNoScreens = false
    private var emptyRefreshCount = 0
    private var deviceObservers: [NSObjectProtocol] = []
    private let identityQueue = DispatchQueue(label: "iphone-use.capture-identity", qos: .utility)
    private let shutdownQueue = DispatchQueue(label: "iphone-use.capture-shutdown", qos: .userInitiated)
    private var identityGeneration: UInt64 = 0
    private var verificationState: ScreenCaptureIdentityState = .singleDevice
    private var associationIdentities = CaptureAssociationIdentity()
    private var sourceRecovery = CaptureSourceRecovery()
    private var valeriaRecovery = CaptureValeriaRecoveryTracker()
    private var lifecycleGeneration: UInt64 = 0
    private var isStopped = false

    /// Called when a phone's screen appears or goes away.
    var onScreensChanged: (() -> Void)?

    func start() {
        let generation = lock.withLock { () -> UInt64 in
            isStopped = false
            lifecycleGeneration &+= 1
            return lifecycleGeneration
        }
        allowScreenCaptureDevices()
        observeDeviceChanges()

        // CoreMediaIO can publish the iPhone capture device shortly after USB trust,
        // camera permission, or the screen-capture switch completes. A one-shot
        // refresh misses that transition, so keep a cheap watcher for reconnects too.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.lock.withLock({ !self.isStopped && self.lifecycleGeneration == generation }) else {
                return
            }
            self.refresh()
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            log("camera access \(granted ? "granted" : "denied")")
            guard let self, self.lock.withLock({ !self.isStopped && self.lifecycleGeneration == generation }) else {
                return
            }
            self.refresh()
        }
    }

    @discardableResult
    func stop(waitTimeout: TimeInterval = 0) -> ScreenCaptureStopResult {
        refreshTimer?.invalidate()
        refreshTimer = nil
        let (observers, activeSources) = lock.withLock {
            isStopped = true
            lifecycleGeneration &+= 1
            let currentObservers = deviceObservers
            deviceObservers.removeAll()
            let currentSources = Array(sources.values)
            sources.removeAll()
            screens.removeAll()
            verifiedScreenIDs.removeAll()
            _ = valeriaRecovery.reset()
            identityGeneration &+= 1
            return (currentObservers, currentSources)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        return CaptureShutdownCoordinator.stop(
            waitTimeout: waitTimeout,
            activeSources: activeSources,
            notifyQueue: shutdownQueue,
            restoreAllUSB: { deadline in
                USBValeriaConfigurator.restorePreviousConfigurations(deadlineUptime: deadline)
            })
    }

    private func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private func observeDeviceChanges() {
        let connected = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() }
        let disconnected = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() }
        lock.withLock {
            deviceObservers = [connected, disconnected]
        }
    }

    var all: [ScreenCaptureSession] {
        lock.withLock { screens.values.sorted { $0.name < $1.name } }
    }

    var identityState: ScreenCaptureIdentityState { lock.withLock { verificationState } }

    var permitsPointerAssociation: Bool {
        lock.withLock { verificationState.permitsAssociation(identityVerified: true) }
    }

    func permitsPointerAssociation(for screen: ScreenCaptureSession) -> Bool {
        lock.withLock {
            screens[screen.id] === screen
                && verificationState.permitsAssociation(identityVerified: verifiedScreenIDs.contains(screen.id))
        }
    }

    func isCurrent(_ screen: ScreenCaptureSession) -> Bool {
        lock.withLock { screens[screen.id] === screen }
    }

    func identityVerified(for screen: ScreenCaptureSession) -> Bool {
        lock.withLock { screens[screen.id] === screen && verifiedScreenIDs.contains(screen.id) }
    }

    var associationScreens: [ScreenCaptureSession] {
        lock.withLock {
            screens.values.filter {
                verificationState.permitsAssociation(identityVerified: verifiedScreenIDs.contains($0.id))
            }
            .sorted { $0.name < $1.name }
        }
    }

    /// Explicit matching can retry after identical/black/dynamic screens become
    /// distinguishable. Status polling never starts new screenshot work.
    func retryIdentityVerification() {
        let job: (UInt64, [String: ScreenCaptureSource])? = lock.withLock {
            guard !isStopped, sources.count > 1,
                verificationState == .failed || verificationState == .unavailable
                    || verificationState == .partiallyVerified
            else { return nil }
            identityGeneration &+= 1
            verificationState = .pending
            return (identityGeneration, sources)
        }
        guard let job else { return }
        onScreensChanged?()
        scheduleIdentityVerification(generation: job.0, sources: job.1)
    }

    private func refresh() {
        guard !lock.withLock({ isStopped }) else { return }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .muxed, position: .unspecified
        ).devices.filter { $0.modelID.contains("iOS") && $0.isConnected }
        let discoveredIDs = devices.map(\.uniqueID)
        let present = Set(discoveredIDs)
        // Query IOKit single-device USB identity strictly OUTSIDE `lock` so
        // `manager.lock -> USBValeriaConfigurator.queue` cycles are impossible.
        let prequeriedPin = CaptureDiscoveryPinResolver.prequerySingleDevicePin(
            discoveredIDs: discoveredIDs,
            needsNewSourceForID: { id in
                lock.withLock { !isStopped && sources[id] == nil }
            },
            querySingleIOSDevice: {
                USBValeriaConfigurator.currentSingleIOSDeviceIdentity()
            })

        var changed = false
        var shouldReallowCaptureDevices = false
        var shouldRecoverEmptyDiscovery = false
        var shouldReconcilePendingSwitch = false
        var removedUSBEntries: [UInt64] = []
        var postSwitchChecks: [CaptureValeriaRecoveryTracker.ScheduledPostSwitchCheck] = []
        var sourcesSnapshot: [String: ScreenCaptureSource] = [:]
        var refreshLifecycle: UInt64 = 0
        var job: (UInt64, [String: ScreenCaptureSource])?
        let didRun = lock.withLock { () -> Bool in
            guard !isStopped else { return false }
            refreshLifecycle = lifecycleGeneration
            var newlyClaimedSwitches: [CaptureValeriaRecoveryTracker.ScheduledPostSwitchCheck] = []
            for (id, source) in sources where !present.contains(id) {
                source.stop()
                sources[id] = nil
                changed = true
                log("screen gone: \(source.name)")
            }
            for device in devices where sources[device.uniqueID] == nil {
                let pinnedUSBDevice: USBValeriaConfigurator.PinnedUSBDevice? =
                    if present.count == 1,
                        let prequeriedPin,
                        prequeriedPin.deviceID == device.uniqueID
                    {
                        prequeriedPin.pin
                    } else {
                        nil
                    }
                do {
                    let newSource = try ScreenCaptureSource(
                        device: device,
                        pinnedUSBDevice: pinnedUSBDevice,
                        onFirstFrame: { [weak self] in self?.onScreensChanged?() },
                        onNeedsValeriaRecovery: { [weak self] source, restartAfter in
                            self?.recoverValeriaIfNeeded(for: source, restartSource: restartAfter)
                        })
                    sources[device.uniqueID] = newSource
                    if present.count == 1,
                        let claimedEntryID = valeriaRecovery.claimPendingEmptyDiscoverySwitch(
                            for: newSource.instanceID,
                            sourceID: device.uniqueID,
                            pinnedDevice: pinnedUSBDevice)
                    {
                        newlyClaimedSwitches.append(
                            .init(
                                sourceID: device.uniqueID,
                                sourceInstanceID: newSource.instanceID,
                                entryID: claimedEntryID,
                                supersedeExisting: true))
                    }
                    changed = true
                    log("capturing \(device.localizedName) (\(device.uniqueID))")
                } catch {
                    log("capture failed for \(device.localizedName): \(error)")
                }
            }
            sourcesSnapshot = sources
            let activeSourceStates = sources.values.map {
                CaptureValeriaRecoveryTracker.RefreshSourceState(
                    id: $0.id,
                    instanceID: $0.instanceID,
                    hasFrame: $0.hasFrame)
            }
            let activeInstances = Set(activeSourceStates.map(\.instanceID))
            let valeriaReconciliation = valeriaRecovery.reconcileAfterRefresh(
                changed: changed,
                newlyClaimedSwitches: newlyClaimedSwitches,
                activeSources: activeSourceStates,
                discoveredDeviceCount: devices.count)
            removedUSBEntries = valeriaReconciliation.removedUSBEntries
            shouldRecoverEmptyDiscovery = valeriaReconciliation.shouldRecoverEmptyDiscovery
            shouldReconcilePendingSwitch = valeriaReconciliation.shouldReconcilePendingSwitch
            postSwitchChecks = valeriaReconciliation.postSwitchChecks
            if changed {
                associationIdentities.retain(physicalIDs: Set(sources.keys))
                sourceRecovery.retain(sources: activeInstances)
                identityGeneration &+= 1
                if present.count > 1 {
                    // A failed capture must not turn two discovered phones into
                    // an assumed single-device identity.
                    verificationState = sources.count == present.count ? .pending : .failed
                } else {
                    verificationState = .singleDevice
                }
                rebuildScreens(mapping: [:], verified: false)
                if verificationState == .pending { job = (identityGeneration, sources) }
            }
            if sources.isEmpty {
                emptyRefreshCount &+= 1
                if emptyRefreshCount % 5 == 0 {
                    shouldReallowCaptureDevices = true
                }
                if !loggedNoScreens {
                    log("no iPhone screen yet (plug in over USB and trust this Mac)")
                    loggedNoScreens = true
                }
            } else {
                emptyRefreshCount = 0
                loggedNoScreens = false
            }
            return true
        }
        guard didRun else { return }
        if !removedUSBEntries.isEmpty {
            identityQueue.async { [weak self] in
                guard let self else { return }
                for entryID in removedUSBEntries {
                    _ = CaptureValeriaRecoveryCoordinator.performGatedLiveRestore(
                        host: self, entryID: entryID)
                }
            }
        }
        if !postSwitchChecks.isEmpty {
            CaptureValeriaRecoveryCoordinator.applyRefreshPostSwitchChecks(
                host: self,
                checks: postSwitchChecks,
                sourcesByID: sourcesSnapshot,
                expectedLifecycle: refreshLifecycle)
        }
        if shouldReallowCaptureDevices { allowScreenCaptureDevices() }
        if shouldRecoverEmptyDiscovery {
            CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(host: self)
        }
        if shouldReconcilePendingSwitch {
            CaptureValeriaRecoveryCoordinator.reconcilePendingEmptyDiscoverySwitchIfNeeded(
                host: self)
        }
        // Matching reads all again; notify only after releasing the discovery lock.
        if changed { onScreensChanged?() }
        if let job { scheduleIdentityVerification(generation: job.0, sources: job.1) }
    }

    var recoveryLock: NSLock { lock }
    var recoveryQueue: DispatchQueue { identityQueue }
    var isRecoveryStoppedLocked: Bool { isStopped }
    var recoveryLifecycleGenerationLocked: UInt64 { lifecycleGeneration }
    var recoverySourcesLocked: [String: ScreenCaptureSource] { sources }
    var recoveryIdentityGenerationLocked: UInt64 { identityGeneration }
    var recoveryVerificationStateLocked: ScreenCaptureIdentityState { verificationState }

    func withValeriaTrackerLocked<T>(_ body: (inout CaptureValeriaRecoveryTracker) -> T) -> T {
        body(&valeriaRecovery)
    }

    func enterMultiDevicePendingForValeriaLocked() {
        identityGeneration &+= 1
        verificationState = .pending
        rebuildScreens(mapping: [:], verified: false)
    }

    func notifyScreensChangedAfterValeriaGate() {
        onScreensChanged?()
    }

    func scheduleValeriaIdentityVerification(
        generation: UInt64,
        sources: [String: ScreenCaptureSource]
    ) {
        scheduleIdentityVerification(
            generation: generation, sources: sources, retryOnFailure: true, delay: 1.5)
    }

    /// Coordinates USB Valeria configuration activation through the manager's
    /// identity gate so multi-device pointer input is paused before any stream
    /// reconfiguration or restart, re-validated immediately before USB mutation,
    /// and re-verified afterward.
    private func recoverValeriaIfNeeded(for source: ScreenCaptureSource, restartSource: Bool) {
        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: self,
            for: source,
            restartSource: restartSource)
    }

    /// Called under lock. Retain surviving preview objects and Bluetooth proofs
    /// while input remains blocked by the separate capture verification state.
    private func rebuildScreens(mapping: [String: String], verified: Bool) {
        let displayMapping = CaptureScreenMapping.previews(
            confirmed: mapping,
            previous: screens.mapValues { .init(id: $0.sourceID, instance: $0.sourceInstanceID) },
            sources: sources.mapValues(\.instanceID))
        verifiedScreenIDs = verified ? Set(mapping.keys) : []
        screens = displayMapping.reduce(into: [:]) { result, entry in
            guard let physical = sources[entry.key], let source = sources[entry.value] else { return }
            let identity = associationIdentities.identity(
                physicalID: entry.key,
                isConfirmed: (verified && mapping[entry.key] != nil) || verificationState == .singleDevice)
            if let previous = screens[entry.key], previous.sourceInstanceID == source.instanceID,
                previous.associationIdentity == identity
            {
                result[entry.key] = previous
                return
            }
            result[entry.key] = ScreenCaptureSession(
                id: entry.key, name: physical.name, source: source,
                associationIdentity: identity)
        }
    }

    private func scheduleIdentityVerification(
        generation: UInt64, sources: [String: ScreenCaptureSource], retryOnFailure: Bool = true,
        delay: TimeInterval = 0.5
    ) {
        // Wait for newly started streams to deliver their first complete frames.
        identityQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let isCurrent = { self.lock.withLock { self.identityGeneration == generation } }
            guard isCurrent() else { return }
            let result = CaptureIdentityVerifier.verify(
                physicalIDs: sources.keys.sorted(),
                sourceImages: { sources.compactMapValues { $0.identityImage() } },
                isCurrent: isCurrent)
            var shouldRetry = false
            var shouldRecover = false
            let applied = self.lock.withLock { () -> Bool in
                guard self.identityGeneration == generation else { return false }
                switch result {
                case .verified(let mapping):
                    self.rebuildScreens(mapping: mapping, verified: true)
                    self.verificationState = .verified
                    log("capture identity verified: \(mapping)")
                case .partiallyVerified(let mapping):
                    self.rebuildScreens(mapping: mapping, verified: true)
                    self.verificationState = .partiallyVerified
                    log("capture identity partially verified: \(mapping)")
                    shouldRecover = true
                case .unavailable:
                    // Without an independent check, pointer discovery must
                    // prove this mapping again before reusing Bluetooth input.
                    self.associationIdentities = CaptureAssociationIdentity()
                    self.rebuildScreens(mapping: [:], verified: false)
                    self.verificationState = .unavailable
                    log("capture identity unverified: native USB screenshot service unavailable")
                case .failed:
                    self.verificationState = .failed
                    shouldRetry = retryOnFailure
                    shouldRecover = !retryOnFailure
                    log("capture identity verification failed: no unique complete USB-to-video mapping")
                }
                if shouldRecover {
                    let empty = sources.values.filter { $0.frame() == nil }
                    let selected = self.sourceRecovery.take(empty: Set(empty.map(\.instanceID)))
                    shouldRecover = !selected.isEmpty
                    if shouldRecover {
                        // Starting/stopping one muxed stream can reroute another
                        // stream's pixels. Keep Bluetooth proofs, but recheck
                        // the complete video mapping before accepting input.
                        self.verificationState = .pending
                        for source in empty where selected.contains(source.instanceID) {
                            log("restarting empty capture source: \(source.name) (\(source.id))")
                            source.restart()
                        }
                    }
                }
                return true
            }
            if applied { self.onScreensChanged?() }
            if applied, shouldRecover {
                self.scheduleIdentityVerification(
                    generation: generation, sources: sources, retryOnFailure: false, delay: 1.5)
            } else if applied, shouldRetry {
                // Capture and screenshotr can race during USB/service startup.
                // One delayed retry gives them time to settle without polling
                // indefinitely or ever moving a pointer for identity checks.
                self.scheduleIdentityVerification(
                    generation: generation, sources: sources, retryOnFailure: false, delay: 3)
            }
        }
    }
}

/// One physical iPhone's public screen identity. Acquisition may come from a
/// different nominal AVFoundation UID after independent USB verification.
final class ScreenCaptureSession {
    let id: String
    let name: String
    let associationIdentity: UUID
    private let source: ScreenCaptureSource

    var sourceID: String { source.id }
    var sourceInstanceID: UUID { source.instanceID }
    var size: CGSize? { source.size }
    var captureError: String? { source.lastError }

    fileprivate init(
        id: String, name: String, source: ScreenCaptureSource, associationIdentity: UUID
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.associationIdentity = associationIdentity
    }

    func frame() -> CVPixelBuffer? { source.frame() }

    func observationFrame() -> ScreenCaptureFrameStore.Snapshot? { source.observationFrame() }

    func snapshot(png: Bool, maxWidth: Int? = nil, maxEdge: Int? = nil) -> Data? {
        source.snapshot(png: png, maxWidth: maxWidth, maxEdge: maxEdge)
    }

    func thumbnail(width: Int, height: Int) -> [UInt8]? { source.thumbnail(width: width, height: height) }

    /// Wait for an atomically identified USB frame received after the input
    /// deadline. Call from the phone's input queue, never the capture callback.
    func pointerFrame(
        after sequence: UInt64?, notBefore: TimeInterval, timeout: TimeInterval = 2
    ) throws -> VisualPointerFrame {
        try source.pointerFrame(after: sequence, notBefore: notBefore, timeout: timeout)
    }
}

/// Keeps frame pixels and their freshness metadata under the same lock. Waiting
/// releases this lock so the capture callback can publish and wake consumers.
final class ScreenCaptureFrameStore {
    enum PublishOutcome: Equatable {
        case rejected
        case firstFrame
        case subsequentFrame

        var isAccepted: Bool { self != .rejected }
    }

    struct Snapshot {
        let buffer: CVPixelBuffer
        let sequence: UInt64
        let receivedAt: TimeInterval
    }

    private let condition = NSCondition()
    private var latest: Snapshot?
    private var sequence: UInt64 = 0
    private var stopped = false

    func publishOutcome(
        _ buffer: CVPixelBuffer,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> PublishOutcome {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, receivedAt.isFinite, receivedAt >= 0, sequence < .max else {
            return .rejected
        }
        sequence += 1
        latest = Snapshot(buffer: buffer, sequence: sequence, receivedAt: receivedAt)
        condition.broadcast()
        return sequence == 1 ? .firstFrame : .subsequentFrame
    }

    @discardableResult
    func publish(_ buffer: CVPixelBuffer, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        publishOutcome(buffer, receivedAt: receivedAt) == .firstFrame
    }

    func snapshot() -> Snapshot? {
        condition.lock()
        defer { condition.unlock() }
        return latest
    }

    func wait(after sequence: UInt64?, notBefore: TimeInterval, timeout: TimeInterval) throws -> Snapshot {
        guard notBefore.isFinite, notBefore >= 0, timeout.isFinite, timeout >= 0 else {
            throw DeviceError("invalid fresh pointer frame deadline")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard deadline.isFinite else { throw DeviceError("invalid fresh pointer frame timeout") }
        condition.lock()
        defer { condition.unlock() }
        while true {
            guard !stopped else { throw DeviceError("USB capture stopped while waiting for a pointer frame") }
            if let latest, sequence.map({ latest.sequence > $0 }) ?? true, latest.receivedAt >= notBefore {
                return latest
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DeviceError("timed out waiting for a fresh USB pointer frame") }
            // A notification may be spurious or contain an older frame. Recheck
            // both predicates against the original monotonic deadline.
            guard condition.wait(until: Date(timeIntervalSinceNow: remaining)) else {
                throw DeviceError("timed out waiting for a fresh USB pointer frame")
            }
        }
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    func resume() {
        condition.lock()
        stopped = false
        condition.unlock()
    }
}

protocol CaptureRunningSession: AnyObject {
    func startRunning()
    func stopRunning()
}

extension AVCaptureSession: CaptureRunningSession {}

/// Coordinates asynchronous start, restart, and bounded-wait stop on a capture
/// source's serial queue without holding `stateLock` across potentially blocking
/// AVFoundation calls.
final class CaptureSourceLifecycle {
    private let session: CaptureRunningSession
    private let frames: ScreenCaptureFrameStore
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var stopped = false

    init(session: CaptureRunningSession, frames: ScreenCaptureFrameStore, queue: DispatchQueue) {
        self.session = session
        self.frames = frames
        self.queue = queue
    }

    var isStopped: Bool {
        stateLock.withLock { stopped }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stateLock.withLock({ self.stopped }) else { return }
            self.session.startRunning()
            if self.stateLock.withLock({ self.stopped }) {
                self.frames.stop()
                self.session.stopRunning()
            }
        }
    }

    @discardableResult
    func restart(onBeforeStop: (() -> Void)? = nil) -> Bool {
        let canRestart = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            onBeforeStop?()
            frames.stop()
            return true
        }
        guard canRestart else { return false }
        queue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            let canResume = self.stateLock.withLock { () -> Bool in
                guard !self.stopped else { return false }
                self.frames.resume()
                return true
            }
            guard canResume else { return }
            self.session.startRunning()
            if self.stateLock.withLock({ self.stopped }) {
                self.frames.stop()
                self.session.stopRunning()
            }
        }
        return true
    }

    func stop(onStopLocked: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        stateLock.withLock {
            stopped = true
            frames.stop()
            onStopLocked?()
        }
        let session = self.session
        let frames = self.frames
        queue.async {
            frames.stop()
            session.stopRunning()
            completion?()
        }
    }

    @discardableResult
    func stopAndWait(timeout: TimeInterval, onStopLocked: (() -> Void)? = nil) -> Bool {
        let done = DispatchSemaphore(value: 0)
        stop(onStopLocked: onStopLocked) {
            done.signal()
        }
        guard timeout.isFinite, timeout > 0 else { return false }
        return done.wait(timeout: .now() + timeout) == .success
    }
}

/// Preserves actionable capture runtime and USB recovery errors across bounded
/// `restart()` attempts until an actual video frame is accepted by `ScreenCaptureFrameStore`.
final class CaptureSourceErrorTracker {
    private let lock = NSLock()
    private var lastErrorDescription: String?
    private var revision: UInt64 = 0
    private var lastErrorRevision: UInt64 = 0
    private var stopped = false

    var lastError: String? {
        lock.withLock { lastErrorDescription }
    }

    var hasError: Bool {
        lock.withLock { lastErrorDescription != nil }
    }

    func currentRevision() -> UInt64 {
        lock.withLock { revision }
    }

    func markStopped() {
        lock.withLock { stopped = true }
    }

    static func formatRuntimeError(_ error: NSError?) -> String {
        guard let error else { return "capture runtime error" }
        let base = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = base.isEmpty ? "capture runtime error" : base
        if let reason = error.localizedFailureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
            !reason.isEmpty,
            !message.contains(reason)
        {
            message += " (\(reason))"
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            let fourCC = (underlying.userInfo["AVErrorFourCharCode"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let fourCC, !fourCC.isEmpty, !message.contains(fourCC) {
                let codeText = String(underlying.code)
                if message.contains(codeText) {
                    message += " [\(fourCC)]"
                } else {
                    message += " (\(underlying.domain) \(codeText) [\(fourCC)])"
                }
            } else {
                let codeText = String(underlying.code)
                if !message.contains(codeText) {
                    message += " (\(underlying.domain) \(codeText))"
                }
            }
        }
        return message
    }

    @discardableResult
    func recordRuntimeError(_ error: NSError?, isStopped: Bool) -> String {
        let message = Self.formatRuntimeError(error)
        guard !isStopped else { return message }
        lock.withLock {
            guard !stopped else { return }
            if revision < .max {
                revision += 1
            }
            lastErrorRevision = revision
            lastErrorDescription = message
        }
        return message
    }

    func recordRecoveryError(_ message: String, isStopped: Bool) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStopped, !trimmed.isEmpty else { return }
        lock.withLock {
            guard !stopped else { return }
            if revision < .max {
                revision += 1
            }
            lastErrorRevision = revision
            if let existing = lastErrorDescription {
                if !existing.contains(trimmed) {
                    lastErrorDescription = "\(existing); \(trimmed)"
                }
            } else {
                lastErrorDescription = trimmed
            }
        }
    }

    func clearOnAcceptedFrame(
        _ outcome: ScreenCaptureFrameStore.PublishOutcome,
        observedErrorRevisionBeforePublish upperBound: UInt64
    ) {
        guard outcome.isAccepted else { return }
        lock.withLock {
            if lastErrorRevision <= upperBound {
                lastErrorDescription = nil
            }
        }
    }

    func publishFrameClearingPriorErrors(
        _ buffer: CVPixelBuffer,
        into frames: ScreenCaptureFrameStore,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        beforeClearHook: (() -> Void)? = nil
    ) -> ScreenCaptureFrameStore.PublishOutcome {
        let observedRevision = currentRevision()
        let outcome = frames.publishOutcome(buffer, receivedAt: receivedAt)
        beforeClearHook?()
        clearOnAcceptedFrame(outcome, observedErrorRevisionBeforePublish: observedRevision)
        return outcome
    }
}

/// A nominal AVFoundation acquisition source. Its UID is never rewritten by
/// screen identity verification, so ordinary device refreshes preserve remaps.
final class ScreenCaptureSource:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    CaptureValeriaRecoverySource,
    StoppableCaptureSource
{
    private static let context = CIContext()

    /// The nominal capture device UID, independent of the pixels' physical phone.
    let id: String
    let name: String
    let instanceID = UUID()
    let device: AVCaptureDevice
    let pinnedUSBDevice: USBValeriaConfigurator.PinnedUSBDevice?

    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let frames = ScreenCaptureFrameStore()
    private let lifecycle: CaptureSourceLifecycle
    private let onFirstFrame: (() -> Void)?
    private let onNeedsValeriaRecovery: ((ScreenCaptureSource, Bool) -> Void)?
    private let errorTracker = CaptureSourceErrorTracker()
    private let observerLock = NSLock()
    private var runtimeErrorObserver: NSObjectProtocol?

    var isDeviceConnected: Bool { device.isConnected }
    var hasFrame: Bool { frame() != nil }
    var hasCaptureError: Bool { errorTracker.hasError }

    var lastError: String? {
        errorTracker.lastError
    }

    func recordRecoveryError(_ message: String) {
        errorTracker.recordRecoveryError(message, isStopped: lifecycle.isStopped)
    }

    init(
        device: AVCaptureDevice,
        pinnedUSBDevice: USBValeriaConfigurator.PinnedUSBDevice? = nil,
        onFirstFrame: (() -> Void)? = nil,
        onNeedsValeriaRecovery: ((ScreenCaptureSource, Bool) -> Void)? = nil
    ) throws {
        self.device = device
        self.pinnedUSBDevice = pinnedUSBDevice
        self.onFirstFrame = onFirstFrame
        self.onNeedsValeriaRecovery = onNeedsValeriaRecovery
        id = device.uniqueID
        name = device.localizedName
        let captureQueue = DispatchQueue(label: "iphone-use.capture.\(device.uniqueID)")
        queue = captureQueue
        lifecycle = CaptureSourceLifecycle(session: session, frames: frames, queue: captureQueue)
        super.init()
        queue.setSpecific(key: queueKey, value: true)

        try configureSession()
        observeRuntimeErrors()
        lifecycle.start()
        scheduleValeriaActivationCheck()
    }

    private func configureSession() throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError("cannot capture \(name)") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError("cannot read frames from \(name)") }
        session.addOutput(output)
    }

    private func observeRuntimeErrors() {
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] note in
            guard let self, !self.lifecycle.isStopped else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = self.errorTracker.recordRuntimeError(
                error, isStopped: self.lifecycle.isStopped)
            let shouldNotify = !self.lifecycle.isStopped && self.frames.snapshot() == nil
            log("capture runtime error for \(self.name): \(error.map(String.init(describing:)) ?? message)")
            if shouldNotify {
                self.onNeedsValeriaRecovery?(self, true)
            }
        }
    }

    private func scheduleValeriaActivationCheck() {
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                !self.lifecycle.isStopped,
                self.frames.snapshot() == nil
            else { return }
            self.onNeedsValeriaRecovery?(self, false)
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        var observerToRemove: NSObjectProtocol?
        lifecycle.stop(
            onStopLocked: { [weak self] in
                guard let self else { return }
                self.errorTracker.markStopped()
                self.observerLock.withLock {
                    observerToRemove = self.runtimeErrorObserver
                    self.runtimeErrorObserver = nil
                }
            },
            completion: completion)
        if let observerToRemove {
            NotificationCenter.default.removeObserver(observerToRemove)
        }
    }

    func restart() {
        lifecycle.restart()
    }

    var size: CGSize? {
        frame().map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }

    func frame() -> CVPixelBuffer? {
        frames.snapshot()?.buffer
    }

    func observationFrame() -> ScreenCaptureFrameStore.Snapshot? { frames.snapshot() }

    func pointerFrame(
        after sequence: UInt64?, notBefore: TimeInterval, timeout: TimeInterval
    ) throws -> VisualPointerFrame {
        guard DispatchQueue.getSpecific(key: queueKey) != true else {
            throw DeviceError("cannot wait for a pointer frame on the USB capture queue")
        }
        let snapshot = try frames.wait(after: sequence, notBefore: notBefore, timeout: timeout)
        let width = CVPixelBufferGetWidth(snapshot.buffer)
        let height = CVPixelBufferGetHeight(snapshot.buffer)
        guard (1...4096).contains(width), (1...4096).contains(height),
            let pixels = Self.grayscale(snapshot.buffer, width: width, height: height)
        else { throw DeviceError("cannot convert a full-size USB pointer frame") }
        return VisualPointerFrame(
            frame: PointerMotionObservation.Frame(width: width, height: height, pixels: pixels),
            sequence: snapshot.sequence, receivedAt: snapshot.receivedAt)
    }

    func identityImage() -> CaptureIdentityImage? {
        guard let buffer = frame() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = Self.context.createCGImage(image, from: image.extent) else { return nil }
        return CaptureIdentityImage(image: cgImage)
    }

    /// JPEG or PNG of the latest frame, scaled so neither edge exceeds the limits.
    func snapshot(png: Bool, maxWidth: Int? = nil, maxEdge: Int? = nil) -> Data? {
        guard let buffer = frame() else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        var scale = 1.0
        if let maxWidth { scale = min(scale, Double(maxWidth) / image.extent.width) }
        if let maxEdge { scale = min(scale, Double(maxEdge) / max(image.extent.width, image.extent.height)) }
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cgImage = Self.context.createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Grayscale pixels of the latest frame at a small size, first row at the top.
    func thumbnail(width: Int, height: Int) -> [UInt8]? {
        guard let buffer = frame() else { return nil }
        return Self.grayscale(buffer, width: width, height: height)
    }

    /// Render outside the frame-state lock. Retaining the snapshot keeps this
    /// buffer alive even when capture publishes the next one during conversion.
    private static func grayscale(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, !width.multipliedReportingOverflow(by: height).overflow else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let small = image.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / image.extent.width, y: CGFloat(height) / image.extent.height))
        guard let cgImage = Self.context.createCGImage(small, from: small.extent) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let outcome = errorTracker.publishFrameClearingPriorErrors(buffer, into: frames)
        if outcome == .firstFrame {
            onFirstFrame?()
        }
    }

    struct CaptureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
