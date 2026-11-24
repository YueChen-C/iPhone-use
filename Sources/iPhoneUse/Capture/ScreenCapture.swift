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

/// Gates capture discovery until any persisted same-boot USB configuration switches
/// from an earlier abnormal exit have completed reconciliation on the serial USB
/// queue, preventing late or failed startup USB restores from interleaving with
/// newly opened capture sessions.
struct CaptureStartupReconciliationGate {
    enum Phase: Equatable {
        case idle
        case reconciling(generation: UInt64)
        case unresolved(generation: UInt64)
        case ready(generation: UInt64)
    }

    enum CompletionAction: Equatable {
        case becameReady
        case remainedUnresolved
        case ignoredStale
    }

    enum TickAction: Equatable {
        case runCaptureRefresh
        case retryReconciliation
        case wait
    }

    private(set) var phase: Phase = .idle

    /// Returns `true` when asynchronous USB reconciliation must run before capture
    /// discovery begins; returns `false` when immediately `.ready`.
    mutating func beginStart(generation: UInt64, hasPendingSwitches: Bool) -> Bool {
        if hasPendingSwitches {
            phase = .reconciling(generation: generation)
            return true
        }
        phase = .ready(generation: generation)
        return false
    }

    mutating func completeReconciliation(generation: UInt64, clean: Bool) -> CompletionAction {
        guard phase == .reconciling(generation: generation) else {
            return .ignoredStale
        }
        if clean {
            phase = .ready(generation: generation)
            return .becameReady
        }
        phase = .unresolved(generation: generation)
        return .remainedUnresolved
    }

    mutating func actionForPeriodicTick(generation: UInt64) -> TickAction {
        switch phase {
        case .ready(let g) where g == generation:
            return .runCaptureRefresh
        case .unresolved(let g) where g == generation:
            phase = .reconciling(generation: generation)
            return .retryReconciliation
        default:
            return .wait
        }
    }

    func permitsCaptureDiscovery(generation: UInt64) -> Bool {
        phase == .ready(generation: generation)
    }

    mutating func reset() {
        phase = .idle
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
    // Frame size can invalidate a route, never establish one.
    private var confirmedSizes: [String: CGSize] = [:]
    private var usbTopology: USBValeriaConfigurator.IOSUSBTopologyObservation?
    private var usbEntries: [String: UInt64] = [:]
    private var sourceUSBEntries: [String: UInt64] = [:]
    private var discoveryMissingSourceIDs: Set<String> = []
    private var provenRoutes: [String: CaptureScreenMapping.USBRoute] = [:]
    private var nextRefreshRevision: UInt64 = 0
    private var appliedRefreshRevision: UInt64 = 0
    private var refreshTimer: Timer?
    private var loggedNoScreens = false
    private var emptyRefreshCount = 0
    private var deviceObservers: [NSObjectProtocol] = []
    private let identityQueue = DispatchQueue(label: "iphone-use.capture-identity", qos: .utility)
    private let shutdownQueue = DispatchQueue(label: "iphone-use.capture-shutdown", qos: .userInitiated)
    private var identityGeneration: UInt64 = 0
    private var identityCheckSchedule = CaptureIdentityCheckSchedule()
    private var verificationState: ScreenCaptureIdentityState = .singleDevice
    // Once muxing has been observed, even the surviving single nominal source
    // may carry another phone's pixels during unplug/replug discovery.
    private var requiresDisplayVerification = false
    private var associationIdentities = CaptureAssociationIdentity()
    private var sourceRecovery = CaptureSourceRecovery()
    private var valeriaRecovery = CaptureValeriaRecoveryTracker()
    private var startupReconciliationGate = CaptureStartupReconciliationGate()
    private var captureDiscoveryEnabled = false
    private var lifecycleGeneration: UInt64 = 0
    private var usbDemandRevision: UInt64 = 0
    private var isStopped = false
    private var retainsIdleUSBDemand = false
    private let restoreAllUSB: (TimeInterval) -> Bool

    init(
        restoreAllUSB: @escaping (TimeInterval) -> Bool = {
            USBValeriaConfigurator.restorePreviousConfigurations(deadlineUptime: $0)
        }
    ) {
        self.restoreAllUSB = restoreAllUSB
    }

    /// Called when a phone's screen appears or goes away.
    var onScreensChanged: (() -> Void)?

    func start() {
        // Query persisted USB ledger strictly outside `lock`; fail closed if the ledger
        // either contains unrestored same-boot switches or could not be loaded cleanly.
        let hasPendingSwitches = USBValeriaConfigurator.requiresStartupReconciliation
        let (generation, needsAsyncReconcile) = lock.withLock { () -> (UInt64, Bool) in
            isStopped = false
            retainsIdleUSBDemand = false
            captureDiscoveryEnabled = false
            lifecycleGeneration &+= 1
            let gen = lifecycleGeneration
            let shouldReconcile = startupReconciliationGate.beginStart(
                generation: gen, hasPendingSwitches: hasPendingSwitches)
            return (gen, shouldReconcile)
        }

        if needsAsyncReconcile {
            runStartupReconciliationAttempt(generation: generation)
        } else {
            enableCaptureDiscoveryIfNeeded(generation: generation)
            refresh()
        }

        // CoreMediaIO can publish the iPhone capture device shortly after USB trust,
        // camera permission, or the screen-capture switch completes. When startup USB
        // reconciliation is unresolved, this timer retries reconciliation serially
        // before enabling any capture discovery.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let action = self.lock.withLock { () -> CaptureStartupReconciliationGate.TickAction in
                guard !self.isStopped, self.lifecycleGeneration == generation else { return .wait }
                return self.startupReconciliationGate.actionForPeriodicTick(generation: generation)
            }
            switch action {
            case .runCaptureRefresh:
                self.enableCaptureDiscoveryIfNeeded(generation: generation)
                self.refresh()
            case .retryReconciliation:
                self.runStartupReconciliationAttempt(generation: generation)
            case .wait:
                break
            }
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            log("camera access \(granted ? "granted" : "denied")")
            guard let self,
                self.lock.withLock({
                    !self.isStopped
                        && self.lifecycleGeneration == generation
                        && self.startupReconciliationGate.permitsCaptureDiscovery(generation: generation)
                })
            else {
                return
            }
            self.enableCaptureDiscoveryIfNeeded(generation: generation)
            self.refresh()
        }
    }

    private func runStartupReconciliationAttempt(generation: UInt64) {
        USBValeriaConfigurator.reconcilePersistedSwitchesAsync(budget: 1.0) { [weak self] clean in
            DispatchQueue.main.async {
                guard let self else { return }
                let outcome = self.lock.withLock { () -> CaptureStartupReconciliationGate.CompletionAction in
                    guard !self.isStopped, self.lifecycleGeneration == generation else {
                        return .ignoredStale
                    }
                    return self.startupReconciliationGate.completeReconciliation(
                        generation: generation, clean: clean)
                }
                switch outcome {
                case .becameReady:
                    self.enableCaptureDiscoveryIfNeeded(generation: generation)
                    self.refresh()
                case .remainedUnresolved:
                    log("startup USB configuration reconciliation incomplete; deferring capture discovery")
                case .ignoredStale:
                    break
                }
            }
        }
    }

    private func enableCaptureDiscoveryIfNeeded(generation: UInt64) {
        let shouldEnable = lock.withLock { () -> Bool in
            guard !isStopped,
                lifecycleGeneration == generation,
                startupReconciliationGate.permitsCaptureDiscovery(generation: generation),
                !captureDiscoveryEnabled
            else { return false }
            captureDiscoveryEnabled = true
            return true
        }
        guard shouldEnable else { return }
        allowScreenCaptureDevices()
        observeDeviceChanges()
    }

    @discardableResult
    func stop(waitTimeout: TimeInterval = 0) -> ScreenCaptureStopResult {
        stop(waitTimeout: waitTimeout, retainingIdleUSBDemand: { _ in false })
    }

    @discardableResult
    func suspendForIdle(
        waitTimeout: TimeInterval = 0,
        observeUSBTopology: () -> USBValeriaConfigurator.IOSUSBTopologyObservation =
            USBValeriaConfigurator.currentIOSUSBTopology
    ) -> ScreenCaptureStopResult {
        // USB topology queries must stay outside the manager lock (USB queue lock order).
        let observation = observeUSBTopology()
        return stop(
            waitTimeout: waitTimeout,
            retainingIdleUSBDemand: { hasActiveCapture in
                switch observation {
                case .observed(let topology):
                    return !topology.attachedEntryIDs.isEmpty
                case .unavailable:
                    return hasActiveCapture
                }
            })
    }

    @discardableResult
    func clearIdleUSBDemandIfUnplugged(
        observeUSBTopology: () -> USBValeriaConfigurator.IOSUSBTopologyObservation =
            USBValeriaConfigurator.currentIOSUSBTopology
    ) -> Bool {
        guard lock.withLock({ isStopped && retainsIdleUSBDemand }),
            observeUSBTopology().confirmsNoAttachedDevices
        else { return false }
        return lock.withLock {
            guard isStopped, retainsIdleUSBDemand else { return false }
            retainsIdleUSBDemand = false
            return true
        }
    }

    private func stop(
        waitTimeout: TimeInterval,
        retainingIdleUSBDemand: (_ hasActiveCapture: Bool) -> Bool = { _ in false }
    ) -> ScreenCaptureStopResult {
        refreshTimer?.invalidate()
        refreshTimer = nil
        let (observers, activeSources) = lock.withLock {
            let hadActiveCapture = !sources.isEmpty || !screens.isEmpty || retainsIdleUSBDemand
            isStopped = true
            retainsIdleUSBDemand = retainingIdleUSBDemand(hadActiveCapture)
            captureDiscoveryEnabled = false
            startupReconciliationGate.reset()
            lifecycleGeneration &+= 1
            let currentObservers = deviceObservers
            deviceObservers.removeAll()
            let currentSources = Array(sources.values)
            sources.removeAll()
            screens.values.forEach { $0.setDisplayIdentityConfirmed(false) }
            screens.removeAll()
            verifiedScreenIDs.removeAll()
            confirmedSizes.removeAll()
            usbTopology = nil
            usbEntries.removeAll()
            sourceUSBEntries.removeAll()
            discoveryMissingSourceIDs.removeAll()
            provenRoutes.removeAll()
            sourceRecovery = CaptureSourceRecovery()
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
            restoreAllUSB: restoreAllUSB)
    }

    private func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
        log("allow screen capture devices status=0x\(String(status, radix: 16))")
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

    /// Captures a linearizable snapshot of present USB screens together with a strictly
    /// monotonic revision minted under `lock`, preventing out-of-order demand updates.
    func sampleScreensWithRevision() -> (screens: [ScreenCaptureSession], retainsUSBDemand: Bool, revision: UInt64) {
        lock.withLock {
            usbDemandRevision &+= 1
            return (
                screens.values.sorted { $0.name < $1.name }, !screens.isEmpty || retainsIdleUSBDemand,
                usbDemandRevision
            )
        }
    }

    func mintUSBDemandRevision() -> UInt64 {
        lock.withLock {
            usbDemandRevision &+= 1
            return usbDemandRevision
        }
    }

    var identityState: ScreenCaptureIdentityState { lock.withLock { verificationState } }

    var observedUSBTopology: USBValeriaConfigurator.IOSUSBTopologyObservation {
        lock.withLock { usbTopology ?? .unavailable }
    }

    var permitsPointerAssociation: Bool {
        lock.withLock { screens.values.contains { $0.displayIdentityConfirmed } }
    }

    func permitsPointerAssociation(for screen: ScreenCaptureSession) -> Bool {
        lock.withLock {
            screens[screen.id] === screen
                && screen.displayIdentityConfirmed
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
                $0.displayIdentityConfirmed
            }
            .sorted { $0.name < $1.name }
        }
    }

    /// Explicit matching can retry after identical/black/dynamic screens become
    /// distinguishable. Status polling never starts new screenshot work.
    func retryIdentityVerification() {
        let job: (UInt64, [String: ScreenCaptureSource])? = lock.withLock {
            guard !isStopped, !sources.isEmpty,
                verificationState == .failed || verificationState == .unavailable
                    || verificationState == .partiallyVerified
            else { return nil }
            identityGeneration &+= 1
            verificationState = .pending
            rebuildScreens(mapping: [:])
            return (identityGeneration, sources)
        }
        guard let job else { return }
        onScreensChanged?()
        scheduleIdentityVerification(generation: job.0, sources: job.1)
    }

    private func refresh() {
        let request: (lifecycle: UInt64, revision: UInt64, confirmedEntries: [String: UInt64])? = lock.withLock {
            guard !isStopped else { return nil }
            nextRefreshRevision &+= 1
            // Keep the nominal-source USB binding in the refresh query too.
            // A stream can be unlisted by CoreMediaIO before identity has been
            // proven, so `provenRoutes` alone is empty exactly when we need to
            // verify that the physical USB device is still attached.
            let entries = provenRoutes.mapValues(\.entryID).merging(sourceUSBEntries) {
                _, retained in retained
            }
            return (lifecycleGeneration, nextRefreshRevision, entries)
        }
        guard let request else { return }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .muxed, position: .unspecified
        ).devices
            .filter { $0.modelID.contains("iOS") && $0.isConnected }
            .sorted { $0.uniqueID < $1.uniqueID }
        let discoveredIDs = devices.map(\.uniqueID)
        let present = Set(discoveredIDs)
        // Read the registry outside the manager lock and never open USB interfaces here.
        let topology = USBValeriaConfigurator.readIOSUSBTopology()
        let observed: USBValeriaConfigurator.ConnectedIOSUSBTopology?
        if case .observed(let current) = topology { observed = current } else { observed = nil }
        let currentEntries = CaptureScreenMapping.refreshUSBEntries(
            discoveredIDs: present, devices: observed?.devices, confirmedEntries: request.confirmedEntries,
            readEntry: USBValeriaConfigurator.readIOSUSBEntry)
        if present.isEmpty || present.count != request.confirmedEntries.count {
            log(
                "capture refresh discovery=\(discoveredIDs.sorted()) usbEntries=\(currentEntries) previousEntries=\(request.confirmedEntries)"
            )
        }
        let prequeriedPin = CaptureDiscoveryPinResolver.prequerySingleDevicePin(
            discoveredIDs: discoveredIDs,
            needsNewSourceForID: { id in
                lock.withLock {
                    guard !isStopped else { return false }
                    if sources[id] == nil { return true }
                    guard let previous = sourceUSBEntries[id], let current = currentEntries[id] else { return false }
                    return previous != current
                }
            },
            querySingleIOSDevice: { observed?.singleDevice })

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
            guard !isStopped, lifecycleGeneration == request.lifecycle,
                request.revision > appliedRefreshRevision
            else { return false }
            appliedRefreshRevision = request.revision
            refreshLifecycle = lifecycleGeneration
            let topologyChanged = usbTopology != topology || usbEntries != currentEntries
            usbTopology = topology
            let replacedAttachments = Set(sourceUSBEntries.compactMap { id, previous in
                currentEntries[id].flatMap { $0 == previous ? nil : id }
            })
            usbEntries = currentEntries
            // Registry attachment remains authoritative while CoreMediaIO's
            // discovery list is transiently empty. This lets the existing
            // source recover without treating the gap as a detach.
            for (id, source) in sources {
                source.setRegistryAttached(currentEntries[id] != nil)
            }
            let currentRoutes = currentUSBRoutes()
            let before = provenRoutes.count
            // AVFoundation's iOS capture UID carries the same serial that the
            // USB registry exposes for these devices. When the serial-to-entry
            // match is unique, USB itself is the identity proof: do not wait
            // for a screenshot comparison before publishing the native frame.
            // Opaque UIDs still fall through to the existing screenshot
            // verifier, and pointer association remains gated by the route.
            for (physicalID, route) in currentRoutes {
                guard currentEntries[physicalID] == route.entryID,
                    let size = sources[physicalID]?.size
                else { continue }
                provenRoutes[physicalID] = route
                confirmedSizes[physicalID] = size
            }
            provenRoutes = provenRoutes.filter {
                currentRoutes[$0.key] == $0.value && sources[$0.key]?.size == confirmedSizes[$0.key]
            }
            let stable = stableMappings()
            // CoreMediaIO can briefly return an empty AVFoundation discovery
            // snapshot while the assistant is restarting a stream. That is not
            // a USB detach: keep the existing source when its exact registry
            // entry is still present, so recovery can continue on the same
            // session instead of deleting the screen and reporting a false
            // "no iPhone" state.
            let transientlyMissingSourceIDs = sources.compactMap { id, _ -> String? in
                guard let previousEntry = sourceUSBEntries[id],
                    currentEntries[id] == previousEntry
                else { return nil }
                return id
            }
            for (id, _) in sources where !present.contains(id) && currentEntries[id] != nil {
                discoveryMissingSourceIDs.insert(id)
            }
            let reappearedFramelessSourceIDs: Set<String> = Set(sources.compactMap { id, source in
                guard present.contains(id), discoveryMissingSourceIDs.contains(id), !source.hasFrame else {
                    return nil
                }
                return id
            })
            discoveryMissingSourceIDs.subtract(present)
            let activeIDs = present.union(stable.keys).union(transientlyMissingSourceIDs)
            if activeIDs.count != sources.count || present.isEmpty {
                log(
                    "capture refresh active=\(activeIDs.sorted()) sources=\(sources.keys.sorted()) retainedMissing=\(transientlyMissingSourceIDs.sorted())"
                )
            }
            let multiDevice = activeIDs.count > 1 || (observed?.attachedEntryIDs.count ?? 0) > 1
            changed = topologyChanged || before != provenRoutes.count || (multiDevice && !requiresDisplayVerification)
            if changed || Set(sources.keys) != activeIDs {
                for screen in screens.values {
                    screen.setDisplayIdentityConfirmed(stable[screen.id] == screen.sourceID)
                }
            }
            var newlyClaimedSwitches: [CaptureValeriaRecoveryTracker.ScheduledPostSwitchCheck] = []
            for (id, source) in sources
            where !activeIDs.contains(id) || replacedAttachments.contains(id) || reappearedFramelessSourceIDs.contains(id)
            {
                source.stop()
                sources[id] = nil
                sourceUSBEntries[id] = nil
                discoveryMissingSourceIDs.remove(id)
                changed = true
                log("screen gone: \(source.name)")
            }
            // CoreMediaIO's iOS screen-capture assistant is process-wide. Do
            // not create two AVCaptureSession inputs in the same discovery
            // pass: let the first source settle (first frame or a concrete
            // runtime error) before admitting its peer on the next refresh.
            var mayCreateAnotherSource = sources.isEmpty || sources.values.allSatisfy(\.startupSettled)
            for device in devices where sources[device.uniqueID] == nil {
                guard mayCreateAnotherSource else { break }
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
                        onFirstFrame: { [weak self] source in self?.captureFirstFrame(from: source) },
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
                    mayCreateAnotherSource = false
                } catch {
                    log("capture failed for \(device.localizedName): \(error)")
                }
            }
            for id in sources.keys where sourceUSBEntries[id] == nil {
                sourceUSBEntries[id] = currentEntries[id]
            }
            for (id, source) in sources {
                source.setRegistryAttached(currentEntries[id] != nil)
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
                discoveredDeviceCount: activeIDs.count)
            removedUSBEntries = valeriaReconciliation.removedUSBEntries
            shouldRecoverEmptyDiscovery = valeriaReconciliation.shouldRecoverEmptyDiscovery
            shouldReconcilePendingSwitch = valeriaReconciliation.shouldReconcilePendingSwitch
            postSwitchChecks = valeriaReconciliation.postSwitchChecks
            if changed {
                associationIdentities.retain(physicalIDs: Set(sources.keys))
                sourceRecovery.retain(sources: activeInstances)
                identityGeneration &+= 1
                if multiDevice { requiresDisplayVerification = true }
                let canAssumeSingle = !requiresDisplayVerification && present.count == 1
                    && observed?.singleDevice.map { pin in
                        sources.values.contains {
                            usbEntries[$0.id] == pin.registryEntryID || $0.pinnedUSBDevice == pin
                        }
                    } == true
                if sources.isEmpty || canAssumeSingle {
                    verificationState = .singleDevice
                } else {
                    let retained = stableMappings()
                    verificationState = retained.count == sources.count ? .verified
                        : retained.isEmpty ? .pending : .partiallyVerified
                    if verificationState != .verified { job = (identityGeneration, sources) }
                }
                rebuildScreens(mapping: [:])
            }
            // A retained source with no current discovery entry is still tied to
            // an attached USB phone. Re-enabling CoreMediaIO is process-wide, so
            // only retry it while every retained source is still frameless; a
            // healthy peer must never be disturbed by this cold-start repair.
            let hasHealthyFrame = sources.values.contains(where: \.hasFrame)
            if sources.isEmpty || (present.isEmpty && !hasHealthyFrame) {
                emptyRefreshCount &+= 1
                if emptyRefreshCount % 5 == 0 {
                    shouldReallowCaptureDevices = true
                }
                if !loggedNoScreens {
                    log("no iPhone capture source currently visible (USB topology is checked separately)")
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
        if shouldReallowCaptureDevices {
            log("re-enabling CoreMediaIO screen capture discovery after retained frameless source")
            allowScreenCaptureDevices()
        }
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

    func enterMultiDevicePendingForValeriaLocked(target: CaptureValeriaIdentityTarget) {
        identityGeneration &+= 1
        verificationState = .pending
        requiresDisplayVerification = true
        switch target {
        case .source(let id): provenRoutes[id] = nil
        case .usbEntry(let entryID): provenRoutes = provenRoutes.filter { $0.value.entryID != entryID }
        }
        rebuildScreens(mapping: [:])
    }

    func notifyScreensChangedAfterValeriaGate() {
        onScreensChanged?()
    }

    func scheduleValeriaIdentityVerification(
        generation: UInt64,
        sources: [String: ScreenCaptureSource]
    ) {
        scheduleIdentityVerification(
            generation: generation, sources: sources, delay: 1.5)
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

    private func currentUSBRoutes() -> [String: CaptureScreenMapping.USBRoute] {
        sources.reduce(into: [:]) { result, pair in
            // The AVFoundation object can briefly report disconnected while
            // CoreMediaIO rebuilds its device list. The registry entry is the
            // authoritative attachment signal during that window.
            guard let entry = usbEntries[pair.key] else { return }
            result[pair.key] = .init(entryID: entry, sourceInstance: pair.value.instanceID, run: pair.value.captureRun)
        }
    }

    private func stableMappings() -> [String: String] {
        CaptureScreenMapping.continuing(
            proven: provenRoutes, current: currentUSBRoutes(), expectedSizes: confirmedSizes,
            sourceSizes: sources.compactMapValues(\.size))
    }

    /// Keep confirmed screen objects and their input workers while the route survives.
    private func rebuildScreens(mapping: [String: String]) {
        var proven = stableMappings()
        for (id, sourceID) in mapping {
            guard let size = sources[sourceID]?.size else { continue }
            confirmedSizes[id] = size
            proven[id] = sourceID
        }
        let displayMapping = CaptureScreenMapping.previews(
            confirmed: proven,
            previous: screens.mapValues { .init(id: $0.sourceID, instance: $0.sourceInstanceID) },
            sources: sources.mapValues(\.instanceID))
        verifiedScreenIDs = Set(proven.keys)
        let previousScreens = screens
        screens = displayMapping.reduce(into: [:]) { result, entry in
            guard let physical = sources[entry.key], let source = sources[entry.value] else { return }
            let displayConfirmed = proven[entry.key] == entry.value
                || (verificationState == .singleDevice && !requiresDisplayVerification)
            let expectedSize = proven[entry.key] == entry.value ? confirmedSizes[entry.key] : nil
            let previous = previousScreens[entry.key]
            if !displayConfirmed, let previous, !previous.displayIdentityConfirmed,
                previous.sourceInstanceID == source.instanceID, previous.expectedSize == expectedSize {
                result[entry.key] = previous
                return
            }
            let identity = associationIdentities.identity(physicalID: entry.key, isConfirmed: displayConfirmed)
            if let previous, previous.sourceInstanceID == source.instanceID,
                previous.associationIdentity == identity, previous.expectedSize == expectedSize {
                previous.setDisplayIdentityConfirmed(displayConfirmed)
                result[entry.key] = previous
                return
            }
            result[entry.key] = ScreenCaptureSession(
                id: entry.key, name: physical.name, source: source,
                associationIdentity: identity, displayIdentityConfirmed: displayConfirmed,
                expectedSize: expectedSize)
        }
        for (id, previous) in previousScreens where screens[id] !== previous {
            previous.setDisplayIdentityConfirmed(false)
        }
    }

    private func captureFirstFrame(from source: ScreenCaptureSource) {
        onScreensChanged?()
        let job: (UInt64, [String: ScreenCaptureSource])? = lock.withLock {
            guard !isStopped, sources[source.id] === source,
                verificationState != .singleDevice, verificationState != .verified
            else { return nil }
            return (identityGeneration, sources)
        }
        guard let job else { return }
        // Coalesce near-simultaneous first frames and supersede any long backoff.
        scheduleIdentityVerification(generation: job.0, sources: job.1, delay: 0.12)
    }

    private func scheduleIdentityVerification(
        generation: UInt64, sources: [String: ScreenCaptureSource],
        delay: TimeInterval = 0.5, recoveryAttempt: Int = 0
    ) {
        let deadline = DispatchTime.now() + delay
        let ticket = lock.withLock { () -> UInt64? in
            guard !isStopped, identityGeneration == generation else { return nil }
            return identityCheckSchedule.request(generation: generation, deadline: deadline)
        }
        guard let ticket else { return }
        identityQueue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.lock.withLock({
                !self.isStopped && self.identityGeneration == generation
                    && self.identityCheckSchedule.take(ticket: ticket)
            }) else { return }
            self.verifyIdentity(generation: generation, sources: sources, recoveryAttempt: recoveryAttempt)
        }
    }

    private func verifyIdentity(
        generation: UInt64, sources: [String: ScreenCaptureSource], recoveryAttempt: Int
    ) {
        let isCurrent = { self.lock.withLock { !self.isStopped && self.identityGeneration == generation } }
        let snapshot = lock.withLock { () -> ([String: String], USBValeriaConfigurator.IOSUSBTopologyObservation?)? in
            guard !isStopped, identityGeneration == generation else { return nil }
            return (stableMappings(), usbTopology)
        }
        guard let (retained, topology) = snapshot else { return }
        let runs = sources.mapValues(\.captureRun)
        let sizes = sources.compactMapValues(\.size)
        let reserved = Set(retained.values)
        var evidence = CaptureIdentityVerifier.Evidence()
        let result: CaptureIdentityVerifier.Result
        if sources.keys.allSatisfy({ retained[$0] != nil }) {
            result = .verified(retained)
        } else if sources.contains(where: { !reserved.contains($0.key) && $0.value.hasFrame }) {
            result = CaptureIdentityVerifier.verify(
                physicalIDs: sources.keys.sorted(),
                sourceImages: { sources.compactMapValues { $0.identityImage() } },
                isCurrent: isCurrent, retained: retained, reportEvidence: { evidence = $0 },
                screenshotTimeout: recoveryAttempt == 0 ? 3 : 10)
        } else {
            // A screenshot cannot prove a stream that hasn't produced a frame.
            result = retained.isEmpty ? .failed : .partiallyVerified(retained)
        }
        guard isCurrent() else { return }
        if topology != USBValeriaConfigurator.readIOSUSBTopology() {
            refresh()
            if isCurrent() {
                scheduleIdentityVerification(
                    generation: generation, sources: sources,
                    delay: CaptureIdentityRecovery.delay(attempt: recoveryAttempt),
                    recoveryAttempt: min(2, recoveryAttempt + 1))
            }
            return
        }
        var changed = false
        let retry: (delay: TimeInterval, attempt: Int)? = lock.withLock {
            guard !isStopped, identityGeneration == generation else { return nil }
            let previousState = verificationState
            let previousSessions = screens.mapValues(ObjectIdentifier.init)
            let previousVerified = verifiedScreenIDs
            defer {
                changed = previousState != verificationState || previousVerified != verifiedScreenIDs
                    || previousSessions != screens.mapValues(ObjectIdentifier.init)
            }
            guard sources.mapValues(\.captureRun) == runs, sources.compactMapValues(\.size) == sizes,
                stableMappings() == retained
            else {
                // Never commit screenshots across a capture restart or a change
                // in retained proof. No stale completion can reopen the gate.
                rebuildScreens(mapping: [:])
                verificationState = verifiedScreenIDs.isEmpty ? .pending : .partiallyVerified
                return (CaptureIdentityRecovery.delay(attempt: recoveryAttempt), min(2, recoveryAttempt + 1))
            }
            let routes = currentUSBRoutes()
            for id in evidence.contradicted { provenRoutes[id] = nil }
            for (id, sourceID) in evidence.independent where id == sourceID {
                provenRoutes[id] = routes[id]
            }
            let mapping: [String: String]
            switch result {
            case .verified(let found), .partiallyVerified(let found): mapping = found
            case .failed, .unavailable: mapping = [:]
            }
            rebuildScreens(mapping: mapping)
            if verifiedScreenIDs.count == sources.count {
                verificationState = .verified
            } else if !verifiedScreenIDs.isEmpty {
                verificationState = .partiallyVerified
            } else if case .unavailable = result {
                verificationState = .unavailable
            } else {
                verificationState = .failed
            }
            if !evidence.contradicted.isEmpty {
                log("capture identity contradicted on retained routes: \(evidence.contradicted.sorted())")
            }
            guard CaptureIdentityRecovery.permitsRetry(
                stopped: isStopped, expected: generation, current: identityGeneration,
                sourceCount: sources.count, state: verificationState)
            else { return nil }

            let active = Set(screens.values.filter(\.displayIdentityConfirmed).map(\.sourceInstanceID))
            let now = ProcessInfo.processInfo.systemUptime
            let empty = sources.values.filter {
                !active.contains($0.instanceID) && !$0.hasFrame && $0.isDeviceConnected
                    && $0.permitsInitialRecovery(now: now)
            }
            // The fallback replacement is scoped to this source's stopped
            // session and runs through CaptureSessionOperationQueue. Do not
            // defer it until this source is the only capture: one frameless
            // peer must be able to recover while another phone keeps
            // publishing frames.
            // CoreMediaIO's assistant is process-wide even though each phone has
            // its own AVCaptureSession. Restarting two empty sessions together
            // causes one restart to invalidate the other phone's stream. Recover
            // one source per pass and let the next identity check handle the rest.
            let candidate = empty.sorted {
                if $0.hasCaptureError != $1.hasCaptureError {
                    return $0.hasCaptureError
                }
                return $0.id < $1.id
            }.prefix(1)
            let selected = sourceRecovery.take(
                empty: Set(candidate.map(\.instanceID)),
                now: now,
                allowReopen: true)
            for source in candidate {
                guard let action = selected[source.instanceID] else { continue }
                if source.recoverEmptyCapture(action) {
                    log("\(action) for empty capture source: \(source.name) (\(source.id))")
                }
            }
            let pause = selected.isEmpty ? CaptureIdentityRecovery.delay(attempt: recoveryAttempt) : 1.5
            log("capture identity \(verificationState.rawValue); rechecking unresolved routes in \(pause)s")
            return (pause, selected.isEmpty ? min(2, recoveryAttempt + 1) : recoveryAttempt)
        }
        guard isCurrent() else { return }
        if changed { onScreensChanged?() }
        if let retry {
            scheduleIdentityVerification(
                generation: generation, sources: sources, delay: retry.delay, recoveryAttempt: retry.attempt)
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
    private let displayIdentity: CaptureDisplayIdentity
    let expectedSize: CGSize?

    var sourceID: String { source.id }
    var sourceInstanceID: UUID { source.instanceID }
    var size: CGSize? {
        frame().map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }
    var displayIdentityConfirmed: Bool {
        displayIdentity.isConfirmed && (expectedSize == nil || source.size == expectedSize)
    }
    var captureError: String? { source.lastError }

    fileprivate init(
        id: String, name: String, source: ScreenCaptureSource, associationIdentity: UUID,
        displayIdentityConfirmed: Bool, expectedSize: CGSize? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.associationIdentity = associationIdentity
        displayIdentity = CaptureDisplayIdentity(confirmed: displayIdentityConfirmed)
        self.expectedSize = expectedSize
    }

    fileprivate func setDisplayIdentityConfirmed(_ confirmed: Bool) { displayIdentity.setConfirmed(confirmed) }

    func frame() -> CVPixelBuffer? {
        let read: () -> CVPixelBuffer? = { [self] in
            guard let buffer = source.frame(), accepts(buffer) else { return nil }
            return buffer
        }
        // Keep the preview visible while a multi-device identity check is
        // pending. This is display-only; input admission still requires the
        // confirmed identity gate below.
        return displayIdentity.read(read) ?? read()
    }

    private func accepts(_ buffer: CVPixelBuffer) -> Bool {
        expectedSize == nil || expectedSize == CGSize(
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }

    func observationFrame() -> ScreenCaptureFrameStore.Snapshot? {
        let read: () -> ScreenCaptureFrameStore.Snapshot? = { [self] in
            guard let snapshot = source.observationFrame(), accepts(snapshot.buffer) else { return nil }
            return snapshot
        }
        return displayIdentity.read(read) ?? read()
    }

    func snapshot(png: Bool, maxWidth: Int? = nil, maxEdge: Int? = nil) -> Data? {
        let read = { [self] in
            source.snapshot(png: png, maxWidth: maxWidth, maxEdge: maxEdge, expectedSize: expectedSize)
        }
        return displayIdentity.read(read) ?? read()
    }

    func snapshotObservation(png: Bool, maxEdge: Int? = nil) -> (data: Data, receivedAt: TimeInterval)? {
        let read = { [self] in
            source.snapshotObservation(png: png, maxEdge: maxEdge, expectedSize: expectedSize)
        }
        return displayIdentity.read(read) ?? read()
    }

    func thumbnail(width: Int, height: Int) -> [UInt8]? {
        let read = { [self] in
            source.thumbnail(width: width, height: height, expectedSize: expectedSize)
        }
        return displayIdentity.read(read) ?? read()
    }
}

/// Keeps frame pixels and their freshness metadata under the same lock.
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

    private let lock = NSLock()
    private var latest: Snapshot?
    private var sequence: UInt64 = 0
    private var stopped = false

    func stop(discardLatest: Bool = false) {
        lock.withLock {
            stopped = true
            if discardLatest { latest = nil }
        }
    }

    /// Don't drop a first frame that arrived after discovery selected this source.
    func pauseIfEmpty() -> Bool {
        lock.withLock {
            guard !stopped, latest == nil else { return false }
            stopped = true
            return true
        }
    }

    func resume() {
        lock.withLock { stopped = false }
    }

    func publishOutcome(
        _ buffer: CVPixelBuffer,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> PublishOutcome {
        lock.withLock {
            guard !stopped, receivedAt.isFinite, receivedAt >= 0, sequence < .max else {
                return .rejected
            }
            let first = latest == nil
            sequence += 1
            latest = Snapshot(buffer: buffer, sequence: sequence, receivedAt: receivedAt)
            return first ? .firstFrame : .subsequentFrame
        }
    }

    @discardableResult
    func publish(_ buffer: CVPixelBuffer, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        publishOutcome(buffer, receivedAt: receivedAt) == .firstFrame
    }

    func snapshot() -> Snapshot? {
        lock.withLock { latest }
    }
}

protocol CaptureRunningSession: AnyObject {
    func startRunning()
    func stopRunning()
}

extension AVCaptureSession: CaptureRunningSession {}

/// CoreMediaIO's iOS screen-capture assistant is a process-wide resource. In
/// particular, overlapping start/stop calls from two independent AVCapture
/// sessions can tear down the assistant while the other session is still
/// being configured. Keep those calls ordered even though frame delivery stays
/// on one queue per phone.
private enum CaptureSessionOperationQueue {
    static let queue = DispatchQueue(
        label: "iphone-use.capture.session-operations", qos: .userInitiated)
    private static var nextStartUptime: TimeInterval = 0
    private static let minimumStartGap: TimeInterval = 1.0

    static func sync<T>(_ operation: () throws -> T) rethrows -> T {
        try queue.sync(execute: operation)
    }

    /// iOSScreenCaptureAssistant needs a short settle window between native
    /// session starts. Without it, the second phone can fail with `-308` while
    /// the first stream remains healthy.
    static func start(_ session: CaptureRunningSession) {
        queue.sync {
            let now = ProcessInfo.processInfo.systemUptime
            let wait = nextStartUptime - now
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            session.startRunning()
            nextStartUptime = ProcessInfo.processInfo.systemUptime + minimumStartGap
        }
    }
}

/// Coordinates asynchronous start, restart, and bounded-wait stop on a capture
/// source's serial queue without holding `stateLock` across potentially blocking
/// AVFoundation calls.
final class CaptureSourceLifecycle {
    private let session: CaptureRunningSession
    private let frames: ScreenCaptureFrameStore
    private let operationQueue: DispatchQueue
    private let shouldStartSession: () -> Bool
    private let stateLock = NSLock()
    private var stopped = false
    private var run: UInt64 = 0

    var captureRun: UInt64 { stateLock.withLock { run } }

    init(
        session: CaptureRunningSession,
        frames: ScreenCaptureFrameStore,
        queue: DispatchQueue,
        operationQueue: DispatchQueue? = nil,
        shouldStartSession: @escaping () -> Bool = { true }
    ) {
        self.session = session
        self.frames = frames
        self.operationQueue = operationQueue ?? queue
        self.shouldStartSession = shouldStartSession
    }

    var isStopped: Bool {
        stateLock.withLock { stopped }
    }

    func start() {
        operationQueue.async { [weak self] in
            guard let self,
                !self.stateLock.withLock({ self.stopped }),
                self.shouldStartSession()
            else { return }
            CaptureSessionOperationQueue.start(self.session)
            if self.stateLock.withLock({ self.stopped }) {
                self.frames.stop()
                CaptureSessionOperationQueue.sync { self.session.stopRunning() }
            }
        }
    }

    @discardableResult
    func restart(onlyIfEmpty: Bool = false, reconfigure: (() -> Void)? = nil) -> Bool {
        let canRestart = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            if onlyIfEmpty {
                guard frames.pauseIfEmpty() else { return false }
            } else {
                frames.stop(discardLatest: true)
            }
            run &+= 1
            return true
        }
        guard canRestart else { return false }
        operationQueue.async { [weak self] in
            guard let self else { return }
            CaptureSessionOperationQueue.sync { self.session.stopRunning() }
            guard !self.isStopped else { return }
            reconfigure?()
            let canResume = self.stateLock.withLock { () -> Bool in
                guard !self.stopped else { return false }
                self.frames.resume()
                return true
            }
            guard canResume else { return }
            CaptureSessionOperationQueue.start(self.session)
            if self.stateLock.withLock({ self.stopped }) {
                self.frames.stop()
                CaptureSessionOperationQueue.sync { self.session.stopRunning() }
            }
        }
        return true
    }

    func stop(onStopLocked: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        let session = self.session
        let frames = self.frames
        stateLock.withLock {
            stopped = true
            frames.stop()
            onStopLocked?()
        }
        operationQueue.async {
            frames.stop()
            // Always drain the native session, even after the virtual device
            // reports disconnected. Skipping this leaves an active CMIO graph
            // to be torn down by AVCaptureSession.dealloc, which is the path
            // that has been crashing iOSScreenCaptureAssistant.
            CaptureSessionOperationQueue.sync { session.stopRunning() }
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
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let queue: DispatchQueue
    private let sessionQueue: DispatchQueue
    // `AVCaptureSession.startRunning()` may block while CoreMediaIO waits for
    // the iOS screen-capture assistant. Keep the bounded Valeria recovery
    // trigger off the frame/session queue so a stalled start cannot suppress
    // the USB activation that is meant to unblock it.
    private let recoveryQueue: DispatchQueue
    private let frames = ScreenCaptureFrameStore()
    private let lifecycle: CaptureSourceLifecycle
    private let onFirstFrame: ((ScreenCaptureSource) -> Void)?
    private let onNeedsValeriaRecovery: ((ScreenCaptureSource, Bool) -> Void)?
    private let errorTracker = CaptureSourceErrorTracker()
    private let attachmentLock = NSLock()
    private var registryAttached = false
    private let observerLock = NSLock()
    private var runtimeErrorObserver: NSObjectProtocol?

    /// CoreMediaIO can temporarily remove a device from AVFoundation discovery
    /// while the USB registry still proves that the phone is attached. Keep
    /// recovery and session draining alive for that source during the gap.
    var isDeviceConnected: Bool {
        device.isConnected || attachmentLock.withLock { registryAttached }
    }
    var captureRun: UInt64 { lifecycle.captureRun }
    var hasFrame: Bool { frame() != nil }
    var hasCaptureError: Bool { errorTracker.hasError }
    var startupSettled: Bool {
        hasFrame || hasCaptureError
            || ProcessInfo.processInfo.systemUptime - startedAt >= CaptureSourceRecovery.initialGrace
    }

    var lastError: String? {
        errorTracker.lastError
    }

    func recordRecoveryError(_ message: String) {
        errorTracker.recordRecoveryError(message, isStopped: lifecycle.isStopped)
    }

    func setRegistryAttached(_ attached: Bool) {
        attachmentLock.withLock { registryAttached = attached }
    }

    init(
        device: AVCaptureDevice,
        pinnedUSBDevice: USBValeriaConfigurator.PinnedUSBDevice? = nil,
        onFirstFrame: ((ScreenCaptureSource) -> Void)? = nil,
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
        sessionQueue = DispatchQueue(label: "iphone-use.capture-session.\(device.uniqueID)", qos: .userInitiated)
        recoveryQueue = DispatchQueue(label: "iphone-use.capture-recovery.\(device.uniqueID)", qos: .utility)
        lifecycle = CaptureSourceLifecycle(
            session: session,
            frames: frames,
            queue: captureQueue,
            operationQueue: sessionQueue,
            shouldStartSession: { [weak device] in device?.isConnected ?? false })
        super.init()

        try CaptureSessionOperationQueue.sync { try configureSession() }
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

    func permitsInitialRecovery(now: TimeInterval) -> Bool {
        CaptureSourceRecovery.permitsInitialRecovery(startedAt: startedAt, now: now)
    }

    private func scheduleValeriaActivationCheck() {
        recoveryQueue.asyncAfter(deadline: .now() + CaptureSourceRecovery.initialGrace) { [weak self] in
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
            completion: { [self] in
                // The manager removes a source as soon as USB discovery says it
                // is gone. Retain the source until its session queue has drained
                // so the output delegate and native input cannot disappear while
                // CoreMediaIO is still unwinding the stream.
                withExtendedLifetime(self) {
                    completion?()
                }
            })
        if let observerToRemove {
            NotificationCenter.default.removeObserver(observerToRemove)
        }
    }

    func restart() {
        lifecycle.restart()
    }

    @discardableResult
    func recoverEmptyCapture(_ action: CaptureSourceRecovery.Action) -> Bool {
        guard isDeviceConnected else { return false }
        switch action {
        case .restart:
            return lifecycle.restart(onlyIfEmpty: true)
        case .reopenInput:
            return lifecycle.restart(onlyIfEmpty: true) { [weak self] in
                guard let self, self.isDeviceConnected else { return }
                do { try self.reopenNativeInput() }
                catch {
                    self.recordRecoveryError("could not reopen native capture input: \(error)")
                    log("could not reopen native capture input for \(self.name): \(error)")
                }
            }
        }
    }

    /// Replace only this session's input, on its serial queue while stopped.
    private func reopenNativeInput() throws {
        try CaptureSessionOperationQueue.sync {
            guard let previous = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first,
                previous.device.uniqueID == device.uniqueID
            else { throw CaptureError("native capture input no longer matches \(name)") }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.removeInput(previous)
            do {
                guard let refreshedDevice = AVCaptureDevice(uniqueID: device.uniqueID) else {
                    throw CaptureError("capture device disappeared while reopening \(name)")
                }
                let replacement = try AVCaptureDeviceInput(device: refreshedDevice)
                guard session.canAddInput(replacement) else { throw CaptureError("cannot reopen \(name)") }
                session.addInput(replacement)
            } catch {
                if session.canAddInput(previous) { session.addInput(previous) }
                throw error
            }
        }
    }

    var size: CGSize? {
        frame().map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }

    func frame() -> CVPixelBuffer? {
        frames.snapshot()?.buffer
    }

    func observationFrame() -> ScreenCaptureFrameStore.Snapshot? { frames.snapshot() }

    func identityImage() -> CaptureIdentityImage? {
        guard let buffer = frame() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = Self.context.createCGImage(image, from: image.extent) else { return nil }
        return CaptureIdentityImage(image: cgImage)
    }

    /// JPEG or PNG of the latest frame, scaled so neither edge exceeds the limits.
    func snapshot(png: Bool, maxWidth: Int? = nil, maxEdge: Int? = nil, expectedSize: CGSize? = nil) -> Data? {
        guard let frame = frames.snapshot(), Self.accepts(frame, expectedSize: expectedSize) else { return nil }
        return Self.snapshot(frame, png: png, maxWidth: maxWidth, maxEdge: maxEdge)?.data
    }

    func snapshotObservation(png: Bool, maxEdge: Int? = nil, expectedSize: CGSize? = nil) -> (data: Data, receivedAt: TimeInterval)? {
        guard let frame = frames.snapshot(), Self.accepts(frame, expectedSize: expectedSize) else { return nil }
        return Self.snapshot(frame, png: png, maxEdge: maxEdge)
    }

    static func accepts(_ frame: ScreenCaptureFrameStore.Snapshot, expectedSize: CGSize?) -> Bool {
        expectedSize == nil || expectedSize == CGSize(
            width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
    }

    /// Retain one frame for encoding; never attach a later frame's timestamp to
    /// older pixels. This runs only on snapshot requests, not frame publication.
    static func snapshot(_ frame: ScreenCaptureFrameStore.Snapshot, png: Bool,
                         maxWidth: Int? = nil, maxEdge: Int? = nil) -> (data: Data, receivedAt: TimeInterval)? {
        var image = CIImage(cvPixelBuffer: frame.buffer)
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
        return (data as Data, frame.receivedAt)
    }

    /// Grayscale pixels of the latest frame at a small size, first row at the top.
    func thumbnail(width: Int, height: Int, expectedSize: CGSize? = nil) -> [UInt8]? {
        guard let frame = frames.snapshot(), Self.accepts(frame, expectedSize: expectedSize) else { return nil }
        let buffer = frame.buffer
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
            onFirstFrame?(self)
        }
    }

    struct CaptureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
