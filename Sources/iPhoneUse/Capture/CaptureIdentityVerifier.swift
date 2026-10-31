import Foundation

enum ScreenCaptureIdentityState: String {
    case singleDevice
    case pending
    case verified
    case partiallyVerified
    /// The system device framework or the phones' screenshot services are unavailable.
    case unavailable
    /// Independent screenshots did not prove a reliable mapping.
    case failed

    func permitsAssociation(identityVerified: Bool) -> Bool {
        switch self {
        case .singleDevice, .verified, .unavailable: true
        case .partiallyVerified: identityVerified
        case .pending, .failed: false
        }
    }
}

/// Subscription callbacks arrive separately for each HID report. Retry a
/// blocked capture identity once per new BLE session, never once per callback
/// or status poll. Disconnecting another phone does not restart verification.
struct CaptureIdentityRetrySchedule {
    private var sessions: [UUID: UUID] = [:]

    mutating func update(_ current: [UUID: UUID]) -> Bool {
        let hasNewSession = current.contains { sessions[$0.key] != $0.value }
        sessions = current
        return hasNewSession
    }
}

/// A newly attached AVFoundation stream can remain empty after startRunning.
/// Recover only empty streams, once per source instance, without a timer loop.
struct CaptureSourceRecovery {
    private var attempted: Set<UUID> = []

    mutating func take(empty: Set<UUID>) -> Set<UUID> {
        let fresh = empty.subtracting(attempted)
        attempted.formUnion(fresh)
        return fresh
    }

    mutating func retain(sources: Set<UUID>) {
        attempted.formIntersection(sources)
    }
}

/// Captures the exact manager and topology snapshot under which a USB Valeria
/// recovery plan was authorized, allowing execution-time revalidation before any
/// USB device configuration is mutated or capture session restarted.
struct CaptureValeriaRecoverySnapshot: Equatable {
    let isStopped: Bool
    let lifecycleGeneration: UInt64
    let sourceID: String
    let sourceInstanceID: UUID
    let sourceDeviceConnected: Bool
    let sourceHasFrame: Bool
    let activeSourceInstances: [String: UUID]
    let identityGeneration: UInt64
    let verificationState: ScreenCaptureIdentityState

    var isMultiDevice: Bool { activeSourceInstances.count > 1 }

    func matchesTopologyAndGeneration(current: Self) -> Bool {
        guard !current.isStopped,
            current.lifecycleGeneration == lifecycleGeneration,
            current.activeSourceInstances[sourceID] == sourceInstanceID,
            current.sourceDeviceConnected,
            current.activeSourceInstances == activeSourceInstances
        else { return false }
        if isMultiDevice {
            guard current.identityGeneration == identityGeneration,
                current.verificationState == .pending
            else { return false }
        }
        return true
    }

    func remainsValidForExecution(current: Self) -> Bool {
        matchesTopologyAndGeneration(current: current) && !current.sourceHasFrame
    }
}

/// Separates bounded USB Valeria configuration activation attempts from bounded
/// AVCaptureSession runtime-error restarts so an early no-op check never swallows
/// a subsequent runtime-error restart, while preventing endless recovery loops.
struct CaptureValeriaRecoveryTracker {
    static let maxUSBProbeAttempts = 2
    static let maxRuntimeRestarts = 1
    static let maxPassiveMultiDeviceRestoreChecks = 2

    struct Entry: Equatable {
        var inFlight = false
        var pendingRestartRequested = false
        var usbAttemptsUsed = 0
        var usbSwitched = false
        var activeSwitchEntryID: UInt64?
        var runtimeRestartsUsed = 0
        var postSwitchRestoreToken: UInt64 = 0
        var postSwitchRestoreInFlight = false
        var multiDevicePostSwitchCheckConsumed = false
        var passiveMultiDeviceChecksUsed = 0
    }

    enum BeginDecision: Equatable {
        case start(tryUSBActivation: Bool)
        case mergedIntoInFlight
        case denied
    }

    struct FinishDecision: Equatable {
        let shouldRestart: Bool
        let activeSwitchEntryID: UInt64?
    }

    struct PendingEmptyDiscoverySwitch: Equatable {
        let registryEntryID: UInt64
        let serial: String?
    }

    struct RefreshSourceState: Equatable {
        let id: String
        let instanceID: UUID
        let hasFrame: Bool
    }

    struct ScheduledPostSwitchCheck: Equatable {
        let sourceID: String
        let sourceInstanceID: UUID
        let entryID: UInt64
        let supersedeExisting: Bool
    }

    struct RefreshReconciliation: Equatable {
        let removedUSBEntries: [UInt64]
        let shouldRecoverEmptyDiscovery: Bool
        let shouldReconcilePendingSwitch: Bool
        let postSwitchChecks: [ScheduledPostSwitchCheck]
    }

    private(set) var entries: [UUID: Entry] = [:]
    private(set) var emptyDiscoveryInFlight = false
    private(set) var emptyDiscoveryAttemptedEntries: Set<UInt64> = []
    private(set) var pendingEmptyDiscoverySwitch: PendingEmptyDiscoverySwitch?
    private(set) var pendingSwitchReconciliationInFlight = false
    private(set) var ambiguousPendingRollbackScheduledForEntryID: UInt64?

    var hasPendingEmptyDiscoverySwitch: Bool {
        pendingEmptyDiscoverySwitch != nil
    }

    func activeSwitchEntryID(for sourceInstanceID: UUID) -> UInt64? {
        entries[sourceInstanceID]?.activeSwitchEntryID
    }

    mutating func begin(sourceInstanceID: UUID, restartRequested: Bool) -> BeginDecision {
        var entry = entries[sourceInstanceID] ?? Entry()
        if entry.inFlight {
            if restartRequested, entry.runtimeRestartsUsed < Self.maxRuntimeRestarts {
                entry.pendingRestartRequested = true
                entries[sourceInstanceID] = entry
                return .mergedIntoInFlight
            }
            return .denied
        }

        let canTryUSB = !entry.usbSwitched && entry.usbAttemptsUsed < Self.maxUSBProbeAttempts
        let canRestartOnError = restartRequested && entry.runtimeRestartsUsed < Self.maxRuntimeRestarts
        guard canTryUSB || canRestartOnError else { return .denied }

        entry.inFlight = true
        entry.pendingRestartRequested = canRestartOnError
        if canTryUSB {
            entry.usbAttemptsUsed += 1
        }
        entries[sourceInstanceID] = entry
        return .start(tryUSBActivation: canTryUSB)
    }

    mutating func finish(
        sourceInstanceID: UUID,
        switchedEntryID: UInt64?
    ) -> FinishDecision {
        guard var entry = entries[sourceInstanceID], entry.inFlight else {
            return FinishDecision(shouldRestart: false, activeSwitchEntryID: nil)
        }
        entry.inFlight = false
        let didSwitch = switchedEntryID != nil
        if let switchedEntryID {
            let changedSwitch = entry.activeSwitchEntryID != switchedEntryID
            entry.usbSwitched = true
            entry.activeSwitchEntryID = switchedEntryID
            if changedSwitch {
                entry.multiDevicePostSwitchCheckConsumed = false
                entry.passiveMultiDeviceChecksUsed = 0
            }
        }
        let consumeRuntimeRestart =
            !didSwitch
            && entry.pendingRestartRequested
            && entry.runtimeRestartsUsed < Self.maxRuntimeRestarts
        if consumeRuntimeRestart {
            entry.runtimeRestartsUsed += 1
        }
        entry.pendingRestartRequested = false
        entries[sourceInstanceID] = entry
        return FinishDecision(
            shouldRestart: didSwitch || consumeRuntimeRestart,
            activeSwitchEntryID: entry.activeSwitchEntryID)
    }

    mutating func cancelInFlight(sourceInstanceID: UUID) {
        guard var entry = entries[sourceInstanceID] else { return }
        entry.inFlight = false
        entry.pendingRestartRequested = false
        entries[sourceInstanceID] = entry
    }

    mutating func clearActiveSwitch(sourceInstanceID: UUID, matching entryID: UInt64) {
        guard var entry = entries[sourceInstanceID],
            entry.activeSwitchEntryID == entryID
        else { return }
        entry.activeSwitchEntryID = nil
        entry.postSwitchRestoreInFlight = false
        entry.postSwitchRestoreToken &+= 1
        entry.multiDevicePostSwitchCheckConsumed = false
        entry.passiveMultiDeviceChecksUsed = 0
        entries[sourceInstanceID] = entry
    }

    mutating func beginPostSwitchRestoreTimer(
        for sourceInstanceID: UUID,
        matching entryID: UInt64,
        supersedeExisting: Bool
    ) -> UInt64? {
        guard var entry = entries[sourceInstanceID],
            entry.activeSwitchEntryID == entryID
        else { return nil }
        if entry.postSwitchRestoreInFlight, !supersedeExisting {
            return nil
        }
        entry.postSwitchRestoreToken &+= 1
        entry.postSwitchRestoreInFlight = true
        entries[sourceInstanceID] = entry
        return entry.postSwitchRestoreToken
    }

    mutating func completePostSwitchRestoreTimer(
        for sourceInstanceID: UUID,
        matching entryID: UInt64,
        token: UInt64,
        observedMultiDevice: Bool = false
    ) -> Bool {
        guard var entry = entries[sourceInstanceID],
            entry.activeSwitchEntryID == entryID,
            entry.postSwitchRestoreToken == token
        else { return false }
        entry.postSwitchRestoreInFlight = false
        if observedMultiDevice {
            entry.multiDevicePostSwitchCheckConsumed = true
        }
        entries[sourceInstanceID] = entry
        return true
    }

    mutating func beginEmptyDiscovery() -> Bool {
        guard !emptyDiscoveryInFlight else { return false }
        emptyDiscoveryInFlight = true
        return true
    }

    mutating func evaluateEmptyDiscoveryTopology(
        _ observation: USBValeriaConfigurator.IOSUSBTopologyObservation
    ) -> (detachedSwitchEntryID: UInt64?, candidateToActivate: USBValeriaConfigurator.PinnedUSBDevice?) {
        guard case .observed(let topology) = observation else {
            return (nil, nil)
        }
        let attachedIOSEntryIDs = topology.attachedEntryIDs
        let singleDevice = topology.singleDevice
        emptyDiscoveryAttemptedEntries.formIntersection(attachedIOSEntryIDs)
        var detachedSwitchEntryID: UInt64?
        if let pending = pendingEmptyDiscoverySwitch,
            !attachedIOSEntryIDs.contains(pending.registryEntryID)
        {
            detachedSwitchEntryID = pending.registryEntryID
            pendingEmptyDiscoverySwitch = nil
            if ambiguousPendingRollbackScheduledForEntryID == pending.registryEntryID {
                ambiguousPendingRollbackScheduledForEntryID = nil
            }
        }

        guard emptyDiscoveryInFlight,
            pendingEmptyDiscoverySwitch == nil,
            attachedIOSEntryIDs.count == 1,
            let singleDevice,
            singleDevice.registryEntryID != 0,
            attachedIOSEntryIDs.contains(singleDevice.registryEntryID),
            !emptyDiscoveryAttemptedEntries.contains(singleDevice.registryEntryID)
        else {
            return (detachedSwitchEntryID, nil)
        }
        emptyDiscoveryAttemptedEntries.insert(singleDevice.registryEntryID)
        return (detachedSwitchEntryID, singleDevice)
    }

    mutating func finishEmptyDiscovery(switchedDevice: PendingEmptyDiscoverySwitch?) {
        guard emptyDiscoveryInFlight else { return }
        emptyDiscoveryInFlight = false
        if let switchedDevice {
            emptyDiscoveryAttemptedEntries.insert(switchedDevice.registryEntryID)
            pendingEmptyDiscoverySwitch = switchedDevice
            if ambiguousPendingRollbackScheduledForEntryID != switchedDevice.registryEntryID {
                ambiguousPendingRollbackScheduledForEntryID = nil
            }
        }
    }

    mutating func cancelEmptyDiscoveryInFlight() {
        emptyDiscoveryInFlight = false
    }

    mutating func beginPendingSwitchReconciliation() -> Bool {
        guard !pendingSwitchReconciliationInFlight,
            pendingEmptyDiscoverySwitch != nil
        else { return false }
        pendingSwitchReconciliationInFlight = true
        return true
    }

    mutating func finishPendingSwitchReconciliation() {
        pendingSwitchReconciliationInFlight = false
    }

    mutating func markAmbiguousPendingRollbackScheduledIfNeeded(for entryID: UInt64) -> Bool {
        guard pendingEmptyDiscoverySwitch?.registryEntryID == entryID,
            ambiguousPendingRollbackScheduledForEntryID != entryID
        else { return false }
        ambiguousPendingRollbackScheduledForEntryID = entryID
        return true
    }

    mutating func clearAmbiguousPendingRollbackSchedule(matching entryID: UInt64) {
        if ambiguousPendingRollbackScheduledForEntryID == entryID {
            ambiguousPendingRollbackScheduledForEntryID = nil
        }
    }

    mutating func takeMatchingPendingSwitch(entryID: UInt64) -> Bool {
        guard pendingEmptyDiscoverySwitch?.registryEntryID == entryID else { return false }
        pendingEmptyDiscoverySwitch = nil
        if ambiguousPendingRollbackScheduledForEntryID == entryID {
            ambiguousPendingRollbackScheduledForEntryID = nil
        }
        return true
    }

    mutating func claimPendingEmptyDiscoverySwitch(
        for sourceInstanceID: UUID,
        sourceID: String,
        pinnedDevice: USBValeriaConfigurator.PinnedUSBDevice?
    ) -> UInt64? {
        guard let pending = pendingEmptyDiscoverySwitch,
            let pinnedDevice,
            pinnedDevice.registryEntryID == pending.registryEntryID
        else { return nil }
        if !USBValeriaConfigurator.isOpaqueCaptureUUID(sourceID) {
            guard let sourceSerial = USBValeriaConfigurator.normalizedSerial(sourceID),
                let pendingSerial = USBValeriaConfigurator.normalizedSerial(
                    pending.serial ?? pinnedDevice.serial),
                sourceSerial == pendingSerial
            else { return nil }
        }
        pendingEmptyDiscoverySwitch = nil
        if ambiguousPendingRollbackScheduledForEntryID == pending.registryEntryID {
            ambiguousPendingRollbackScheduledForEntryID = nil
        }
        var entry = entries[sourceInstanceID] ?? Entry()
        entry.usbSwitched = true
        entry.activeSwitchEntryID = pending.registryEntryID
        entry.multiDevicePostSwitchCheckConsumed = false
        entry.passiveMultiDeviceChecksUsed = 0
        entries[sourceInstanceID] = entry
        return pending.registryEntryID
    }

    mutating func takeOrphanedPendingSwitchWhenSourcesEmpty() -> UInt64? {
        guard let pending = pendingEmptyDiscoverySwitch else { return nil }
        pendingEmptyDiscoverySwitch = nil
        if ambiguousPendingRollbackScheduledForEntryID == pending.registryEntryID {
            ambiguousPendingRollbackScheduledForEntryID = nil
        }
        return pending.registryEntryID
    }

    mutating func reconcileAfterRefresh(
        changed: Bool,
        newlyClaimedSwitches: [ScheduledPostSwitchCheck] = [],
        activeSources: [RefreshSourceState],
        discoveredDeviceCount: Int
    ) -> RefreshReconciliation {
        let activeSourceInstances = Set(activeSources.map(\.instanceID))
        var removed: [UInt64] = []
        if changed {
            removed = retain(sources: activeSourceInstances)
            if activeSourceInstances.isEmpty,
                let orphanSwitch = takeOrphanedPendingSwitchWhenSourcesEmpty(),
                !removed.contains(orphanSwitch)
            {
                removed.append(orphanSwitch)
            }
        }
        var checks: [ScheduledPostSwitchCheck] = []
        for claimed in newlyClaimedSwitches {
            if activeSources.contains(where: {
                $0.instanceID == claimed.sourceInstanceID && !$0.hasFrame
            }) {
                checks.append(claimed)
            }
        }
        if activeSources.count <= 1 {
            for source in activeSources {
                if var entry = entries[source.instanceID],
                    entry.multiDevicePostSwitchCheckConsumed
                {
                    entry.multiDevicePostSwitchCheckConsumed = false
                    entries[source.instanceID] = entry
                }
            }
        } else if changed {
            for source in activeSources where !source.hasFrame {
                guard var entry = entries[source.instanceID],
                    let entryID = entry.activeSwitchEntryID,
                    !entry.postSwitchRestoreInFlight,
                    !entry.multiDevicePostSwitchCheckConsumed,
                    entry.passiveMultiDeviceChecksUsed < Self.maxPassiveMultiDeviceRestoreChecks,
                    !checks.contains(where: { $0.sourceInstanceID == source.instanceID })
                else { continue }
                entry.multiDevicePostSwitchCheckConsumed = true
                entry.passiveMultiDeviceChecksUsed += 1
                entries[source.instanceID] = entry
                checks.append(
                    ScheduledPostSwitchCheck(
                        sourceID: source.id,
                        sourceInstanceID: source.instanceID,
                        entryID: entryID,
                        supersedeExisting: false))
            }
        }
        let isEmpty = activeSourceInstances.isEmpty
        return RefreshReconciliation(
            removedUSBEntries: removed,
            shouldRecoverEmptyDiscovery: isEmpty && discoveredDeviceCount == 0,
            shouldReconcilePendingSwitch: !isEmpty && pendingEmptyDiscoverySwitch != nil,
            postSwitchChecks: checks)
    }

    mutating func retain(sources active: Set<UUID>) -> [UInt64] {
        var removedSwitches: [UInt64] = []
        for (id, entry) in entries where !active.contains(id) {
            if let switchID = entry.activeSwitchEntryID {
                removedSwitches.append(switchID)
            }
            entries[id] = nil
        }
        return removedSwitches
    }

    mutating func reset() -> [UInt64] {
        var switches = entries.values.compactMap(\.activeSwitchEntryID)
        if let pending = pendingEmptyDiscoverySwitch,
            !switches.contains(pending.registryEntryID)
        {
            switches.append(pending.registryEntryID)
        }
        entries.removeAll()
        emptyDiscoveryInFlight = false
        emptyDiscoveryAttemptedEntries.removeAll()
        pendingEmptyDiscoverySwitch = nil
        pendingSwitchReconciliationInFlight = false
        ambiguousPendingRollbackScheduledForEntryID = nil
        return switches
    }
}

protocol CaptureValeriaRecoverySource: AnyObject {
    var id: String { get }
    var instanceID: UUID { get }
    var pinnedUSBDevice: USBValeriaConfigurator.PinnedUSBDevice? { get }
    var isDeviceConnected: Bool { get }
    var hasFrame: Bool { get }
    var hasCaptureError: Bool { get }
    func restart()
    func recordRecoveryError(_ message: String)
}

protocol CaptureValeriaRecoveryHost: AnyObject {
    associatedtype Source: CaptureValeriaRecoverySource
    var recoveryLock: NSLock { get }
    var recoveryQueue: DispatchQueue { get }
    var isRecoveryStoppedLocked: Bool { get }
    var recoveryLifecycleGenerationLocked: UInt64 { get }
    var recoverySourcesLocked: [String: Source] { get }
    var recoveryIdentityGenerationLocked: UInt64 { get }
    var recoveryVerificationStateLocked: ScreenCaptureIdentityState { get }
    func withValeriaTrackerLocked<T>(_ body: (inout CaptureValeriaRecoveryTracker) -> T) -> T
    func enterMultiDevicePendingForValeriaLocked()
    func notifyScreensChangedAfterValeriaGate()
    func scheduleValeriaIdentityVerification(generation: UInt64, sources: [String: Source])
}

/// Executes bounded USB Valeria activation, capture session restarts, and live USB
/// configuration rollbacks inside re-validated transactions across `recoveryLock`
/// and `recoveryQueue`.
enum CaptureValeriaRecoveryCoordinator {
    typealias USBActivator = (
        _ preferredSerial: String?,
        _ allowSingleIOSFallback: Bool,
        _ pinnedSingleDevice: USBValeriaConfigurator.PinnedUSBDevice?,
        _ shouldProceed: () -> Bool
    ) -> USBValeriaConfigurator.ActivationOutcome

    typealias USBTopologyProvider = () -> USBValeriaConfigurator.IOSUSBTopologyObservation
    typealias USBRestorer = (UInt64) -> USBValeriaConfigurator.RestoreOutcome

    static let usbResourceShortageMessage =
        "IOCreatePlugInInterfaceForService returned kIOReturnNoResources (0xE00002BE); specific cause is undetermined from this status code alone (replugging USB is one possible recovery step)"

    private enum AmbiguousPendingTimerDecision {
        case noop
        case restoreNow
        case retrySingleSourceReconciliation
    }

    private enum PendingReconcileInitialPlan<Source> {
        case noop
        case claimedFrameless(source: Source, entryID: UInt64, lifecycle: UInt64)
        case scheduleAmbiguousRollback(entryID: UInt64, lifecycle: UInt64)
        case queryUSBForSingleSource(expectedPendingEntryID: UInt64, lifecycle: UInt64)
    }

    private enum PendingReconcilePostTopologyAction<Source> {
        case noop
        case claimedFrameless(source: Source, entryID: UInt64)
        case restoreNow(entryID: UInt64)
        case scheduleAmbiguousRollback(entryID: UInt64)
    }

    private enum EmptyDiscoveryCompletion<Source> {
        case none
        case rollback(entryID: UInt64, managerStopped: Bool)
        case claimedFrameless(source: Source, entryID: UInt64)
        case needsPendingReconciliation
    }

    static func schedulePostSwitchRestoreIfNeeded<Host: CaptureValeriaRecoveryHost>(
        host: Host,
        source: Host.Source,
        trackedSwitchID: UInt64,
        expectedLifecycle: UInt64,
        delay: TimeInterval = 4.0,
        supersedeExisting: Bool = true,
        restoreUSB: @escaping USBRestorer = USBValeriaConfigurator.restorePreviousConfiguration
    ) {
        guard delay.isFinite, delay >= 0 else { return }
        let token: UInt64? = host.recoveryLock.withLock {
            guard !host.isRecoveryStoppedLocked,
                host.recoveryLifecycleGenerationLocked == expectedLifecycle,
                host.recoverySourcesLocked[source.id] === source,
                !source.hasFrame
            else { return nil }
            return host.withValeriaTrackerLocked {
                $0.beginPostSwitchRestoreTimer(
                    for: source.instanceID,
                    matching: trackedSwitchID,
                    supersedeExisting: supersedeExisting)
            }
        }
        guard let token else { return }
        host.recoveryQueue.asyncAfter(deadline: .now() + delay) { [weak host] in
            guard let host else { return }
            // Keep Valeria active on a single healthy locked iPhone waiting for
            // screen unlock (`hasCaptureError == false`), while rolling back if
            // multi-device verification remains degraded or capture errored.
            let shouldRestore = host.recoveryLock.withLock { () -> Bool in
                guard !host.isRecoveryStoppedLocked,
                    host.recoveryLifecycleGenerationLocked == expectedLifecycle
                else { return false }
                let sourceStillActiveFrameless =
                    host.recoverySourcesLocked[source.id] === source && !source.hasFrame
                let isMultiDevice = host.recoverySourcesLocked.count > 1
                let tokenCurrent = host.withValeriaTrackerLocked {
                    $0.completePostSwitchRestoreTimer(
                        for: source.instanceID,
                        matching: trackedSwitchID,
                        token: token,
                        observedMultiDevice: sourceStillActiveFrameless && isMultiDevice)
                }
                guard tokenCurrent, sourceStillActiveFrameless else { return false }
                return isMultiDevice || source.hasCaptureError
            }
            guard shouldRestore else { return }
            let restoreOutcome = performGatedLiveRestore(
                host: host, entryID: trackedSwitchID, restoreUSB: restoreUSB)
            if restoreOutcome.isTerminal {
                host.recoveryLock.withLock {
                    host.withValeriaTrackerLocked {
                        $0.clearActiveSwitch(
                            sourceInstanceID: source.instanceID,
                            matching: trackedSwitchID)
                    }
                }
            }
        }
    }

    static func applyRefreshPostSwitchChecks<Host: CaptureValeriaRecoveryHost>(
        host: Host,
        checks: [CaptureValeriaRecoveryTracker.ScheduledPostSwitchCheck],
        sourcesByID: [String: Host.Source],
        expectedLifecycle: UInt64,
        delay: TimeInterval = 4.0,
        restoreUSB: @escaping USBRestorer = USBValeriaConfigurator.restorePreviousConfiguration
    ) {
        for check in checks {
            guard let source = sourcesByID[check.sourceID],
                source.instanceID == check.sourceInstanceID
            else { continue }
            schedulePostSwitchRestoreIfNeeded(
                host: host,
                source: source,
                trackedSwitchID: check.entryID,
                expectedLifecycle: expectedLifecycle,
                delay: delay,
                supersedeExisting: check.supersedeExisting,
                restoreUSB: restoreUSB)
        }
    }

    private static func scheduleAmbiguousPendingRollbackIfNeeded<Host: CaptureValeriaRecoveryHost>(
        host: Host,
        pendingEntryID: UInt64,
        expectedLifecycle: UInt64,
        delay: TimeInterval,
        queryTopology: @escaping USBTopologyProvider,
        restoreUSB: @escaping USBRestorer
    ) {
        guard delay.isFinite, delay >= 0 else { return }
        host.recoveryQueue.asyncAfter(deadline: .now() + delay) { [weak host] in
            guard let host else { return }
            let decision: AmbiguousPendingTimerDecision = host.recoveryLock.withLock {
                guard !host.isRecoveryStoppedLocked,
                    host.recoveryLifecycleGenerationLocked == expectedLifecycle
                else { return .noop }
                return host.withValeriaTrackerLocked { tracker in
                    tracker.clearAmbiguousPendingRollbackSchedule(matching: pendingEntryID)
                    guard tracker.pendingEmptyDiscoverySwitch?.registryEntryID == pendingEntryID
                    else { return .noop }
                    if host.recoverySourcesLocked.count == 1 {
                        return .retrySingleSourceReconciliation
                    }
                    _ = tracker.takeMatchingPendingSwitch(entryID: pendingEntryID)
                    return .restoreNow
                }
            }
            switch decision {
            case .noop:
                break
            case .restoreNow:
                _ = performGatedLiveRestore(
                    host: host, entryID: pendingEntryID, restoreUSB: restoreUSB)
            case .retrySingleSourceReconciliation:
                reconcilePendingEmptyDiscoverySwitchIfNeeded(
                    host: host,
                    postSwitchRestoreDelay: delay,
                    queryTopology: queryTopology,
                    restoreUSB: restoreUSB,
                    allowDeferralOnAmbiguousUSB: false)
            }
        }
    }

    /// Reconciles an unclaimed empty-discovery USB Valeria switch when capture sources are
    /// non-empty (for example, when two capture devices initially appeared together without
    /// pins and one subsequently disconnected, or when multi-device ambiguity persists).
    static func reconcilePendingEmptyDiscoverySwitchIfNeeded<Host: CaptureValeriaRecoveryHost>(
        host: Host,
        postSwitchRestoreDelay: TimeInterval = 4.0,
        queryTopology: @escaping USBTopologyProvider = USBValeriaConfigurator.currentIOSUSBTopology,
        restoreUSB: @escaping USBRestorer = USBValeriaConfigurator.restorePreviousConfiguration,
        allowDeferralOnAmbiguousUSB: Bool = true
    ) {
        let plan: PendingReconcileInitialPlan<Host.Source> = host.recoveryLock.withLock {
            guard !host.isRecoveryStoppedLocked,
                !host.recoverySourcesLocked.isEmpty,
                let pending = host.withValeriaTrackerLocked({ $0.pendingEmptyDiscoverySwitch })
            else { return .noop }
            let lifecycle = host.recoveryLifecycleGenerationLocked
            if host.recoverySourcesLocked.count == 1,
                let onlySource = host.recoverySourcesLocked.values.first
            {
                let claimedEntryID = host.withValeriaTrackerLocked {
                    $0.claimPendingEmptyDiscoverySwitch(
                        for: onlySource.instanceID,
                        sourceID: onlySource.id,
                        pinnedDevice: onlySource.pinnedUSBDevice)
                }
                if let claimedEntryID {
                    return onlySource.hasFrame
                        ? .noop
                        : .claimedFrameless(
                            source: onlySource,
                            entryID: claimedEntryID,
                            lifecycle: lifecycle)
                }
                let started = host.withValeriaTrackerLocked {
                    $0.beginPendingSwitchReconciliation()
                }
                guard started else { return .noop }
                return .queryUSBForSingleSource(
                    expectedPendingEntryID: pending.registryEntryID,
                    lifecycle: lifecycle)
            }
            let shouldSchedule = host.withValeriaTrackerLocked {
                $0.markAmbiguousPendingRollbackScheduledIfNeeded(for: pending.registryEntryID)
            }
            guard shouldSchedule else { return .noop }
            return .scheduleAmbiguousRollback(
                entryID: pending.registryEntryID,
                lifecycle: lifecycle)
        }

        switch plan {
        case .noop:
            return
        case .claimedFrameless(let source, let entryID, let lifecycle):
            schedulePostSwitchRestoreIfNeeded(
                host: host,
                source: source,
                trackedSwitchID: entryID,
                expectedLifecycle: lifecycle,
                delay: postSwitchRestoreDelay,
                restoreUSB: restoreUSB)
        case .scheduleAmbiguousRollback(let entryID, let lifecycle):
            if postSwitchRestoreDelay.isFinite, postSwitchRestoreDelay >= 0 {
                scheduleAmbiguousPendingRollbackIfNeeded(
                    host: host,
                    pendingEntryID: entryID,
                    expectedLifecycle: lifecycle,
                    delay: postSwitchRestoreDelay,
                    queryTopology: queryTopology,
                    restoreUSB: restoreUSB)
            } else {
                let took = host.recoveryLock.withLock {
                    !host.isRecoveryStoppedLocked
                        && host.recoveryLifecycleGenerationLocked == lifecycle
                        && host.withValeriaTrackerLocked({
                            $0.takeMatchingPendingSwitch(entryID: entryID)
                        })
                }
                if took {
                    _ = performGatedLiveRestore(
                        host: host, entryID: entryID, restoreUSB: restoreUSB)
                }
            }
        case .queryUSBForSingleSource(let expectedPendingEntryID, let lifecycle):
            host.recoveryQueue.async { [weak host] in
                guard let host else { return }
                let stillRelevant = host.recoveryLock.withLock {
                    guard !host.isRecoveryStoppedLocked,
                        host.recoveryLifecycleGenerationLocked == lifecycle
                    else { return false }
                    let hasMatchingPending = host.withValeriaTrackerLocked {
                        $0.pendingEmptyDiscoverySwitch?.registryEntryID == expectedPendingEntryID
                    }
                    guard hasMatchingPending, !host.recoverySourcesLocked.isEmpty else {
                        host.withValeriaTrackerLocked { $0.finishPendingSwitchReconciliation() }
                        return false
                    }
                    return true
                }
                guard stillRelevant else { return }

                let observation = queryTopology()

                let action: PendingReconcilePostTopologyAction<Host.Source> =
                    host.recoveryLock.withLock {
                        guard !host.isRecoveryStoppedLocked,
                            host.recoveryLifecycleGenerationLocked == lifecycle
                        else { return .noop }
                        defer {
                            host.withValeriaTrackerLocked { $0.finishPendingSwitchReconciliation() }
                        }
                        guard
                            let pending = host.withValeriaTrackerLocked({
                                $0.pendingEmptyDiscoverySwitch
                            }),
                            pending.registryEntryID == expectedPendingEntryID
                        else { return .noop }

                        if host.recoverySourcesLocked.isEmpty {
                            _ = host.withValeriaTrackerLocked {
                                $0.takeMatchingPendingSwitch(entryID: pending.registryEntryID)
                            }
                            return .restoreNow(entryID: pending.registryEntryID)
                        }

                        switch observation {
                        case .unavailable:
                            if !allowDeferralOnAmbiguousUSB {
                                _ = host.withValeriaTrackerLocked {
                                    $0.takeMatchingPendingSwitch(entryID: pending.registryEntryID)
                                }
                                return .restoreNow(entryID: pending.registryEntryID)
                            }
                            return .noop
                        case .observed(let topology):
                            guard topology.attachedEntryIDs.contains(pending.registryEntryID) else {
                                _ = host.withValeriaTrackerLocked {
                                    $0.takeMatchingPendingSwitch(entryID: pending.registryEntryID)
                                }
                                return .restoreNow(entryID: pending.registryEntryID)
                            }
                            if host.recoverySourcesLocked.count == 1,
                                let onlySource = host.recoverySourcesLocked.values.first,
                                topology.attachedEntryIDs.count == 1,
                                let singlePin = topology.singleDevice,
                                singlePin.registryEntryID == pending.registryEntryID
                            {
                                let claimedEntryID = host.withValeriaTrackerLocked {
                                    $0.claimPendingEmptyDiscoverySwitch(
                                        for: onlySource.instanceID,
                                        sourceID: onlySource.id,
                                        pinnedDevice: singlePin)
                                }
                                if let claimedEntryID {
                                    return onlySource.hasFrame
                                        ? .noop
                                        : .claimedFrameless(
                                            source: onlySource,
                                            entryID: claimedEntryID)
                                }
                                _ = host.withValeriaTrackerLocked {
                                    $0.takeMatchingPendingSwitch(entryID: pending.registryEntryID)
                                }
                                return .restoreNow(entryID: pending.registryEntryID)
                            }

                            if allowDeferralOnAmbiguousUSB,
                                postSwitchRestoreDelay.isFinite,
                                postSwitchRestoreDelay >= 0
                            {
                                let scheduled = host.withValeriaTrackerLocked {
                                    $0.markAmbiguousPendingRollbackScheduledIfNeeded(
                                        for: pending.registryEntryID)
                                }
                                return scheduled
                                    ? .scheduleAmbiguousRollback(entryID: pending.registryEntryID)
                                    : .noop
                            }
                            _ = host.withValeriaTrackerLocked {
                                $0.takeMatchingPendingSwitch(entryID: pending.registryEntryID)
                            }
                            return .restoreNow(entryID: pending.registryEntryID)
                        }
                    }

                switch action {
                case .noop:
                    break
                case .claimedFrameless(let source, let entryID):
                    schedulePostSwitchRestoreIfNeeded(
                        host: host,
                        source: source,
                        trackedSwitchID: entryID,
                        expectedLifecycle: lifecycle,
                        delay: postSwitchRestoreDelay,
                        restoreUSB: restoreUSB)
                case .restoreNow(let entryID):
                    _ = performGatedLiveRestore(
                        host: host, entryID: entryID, restoreUSB: restoreUSB)
                case .scheduleAmbiguousRollback(let entryID):
                    scheduleAmbiguousPendingRollbackIfNeeded(
                        host: host,
                        pendingEntryID: entryID,
                        expectedLifecycle: lifecycle,
                        delay: postSwitchRestoreDelay,
                        queryTopology: queryTopology,
                        restoreUSB: restoreUSB)
                }
            }
        }
    }

    /// Activates dormant USB Valeria configuration when CoreMediaIO has not yet published any
    /// `AVCaptureDevice` (for example, an iPhone plugged in cold on configuration #6). Probes at
    /// most once per physical IOKit `registryEntryID` attach lifecycle and never mutates USB while
    /// holding `recoveryLock`.
    static func recoverEmptyDiscoveryIfNeeded<Host: CaptureValeriaRecoveryHost>(
        host: Host,
        postSwitchRestoreDelay: TimeInterval = 4.0,
        queryTopology: @escaping USBTopologyProvider = USBValeriaConfigurator.currentIOSUSBTopology,
        activateUSB: @escaping USBActivator = USBValeriaConfigurator.activateDormantValeriaConfiguration,
        restoreUSB: @escaping USBRestorer = USBValeriaConfigurator.restorePreviousConfiguration
    ) {
        let expectedLifecycle: UInt64? = host.recoveryLock.withLock {
            guard !host.isRecoveryStoppedLocked,
                host.recoverySourcesLocked.isEmpty,
                host.withValeriaTrackerLocked({ $0.beginEmptyDiscovery() })
            else { return nil }
            return host.recoveryLifecycleGenerationLocked
        }
        guard let expectedLifecycle else { return }

        host.recoveryQueue.async { [weak host] in
            guard let host else { return }
            let stillEmptyBeforeTopology = host.recoveryLock.withLock {
                guard !host.isRecoveryStoppedLocked,
                    host.recoveryLifecycleGenerationLocked == expectedLifecycle
                else { return false }
                guard host.recoverySourcesLocked.isEmpty else {
                    host.withValeriaTrackerLocked { $0.cancelEmptyDiscoveryInFlight() }
                    return false
                }
                return true
            }
            guard stillEmptyBeforeTopology else { return }

            let observation = queryTopology()

            let evaluation:
                (
                    detachedSwitchID: UInt64?,
                    candidate: USBValeriaConfigurator.PinnedUSBDevice?
                ) = host.recoveryLock.withLock {
                    guard !host.isRecoveryStoppedLocked,
                        host.recoveryLifecycleGenerationLocked == expectedLifecycle
                    else {
                        return (nil, nil)
                    }
                    guard host.recoverySourcesLocked.isEmpty else {
                        host.withValeriaTrackerLocked { $0.cancelEmptyDiscoveryInFlight() }
                        return (nil, nil)
                    }
                    let eval = host.withValeriaTrackerLocked {
                        $0.evaluateEmptyDiscoveryTopology(observation)
                    }
                    if eval.candidateToActivate == nil {
                        host.withValeriaTrackerLocked { $0.cancelEmptyDiscoveryInFlight() }
                    }
                    return (eval.detachedSwitchEntryID, eval.candidateToActivate)
                }

            if let detachedSwitchID = evaluation.detachedSwitchID {
                _ = performGatedLiveRestore(
                    host: host, entryID: detachedSwitchID, restoreUSB: restoreUSB)
            }
            guard let candidate = evaluation.candidate else { return }

            let isEligibleToMutateUSB: () -> Bool = { [weak host] in
                guard let host else { return false }
                return host.recoveryLock.withLock {
                    !host.isRecoveryStoppedLocked
                        && host.recoveryLifecycleGenerationLocked == expectedLifecycle
                        && host.recoverySourcesLocked.isEmpty
                }
            }

            let outcome = activateUSB(nil, true, candidate, isEligibleToMutateUSB)
            var switchedEntryID: UInt64?
            var unconfirmedEntryID: UInt64?
            switch outcome {
            case .switched(let record):
                switchedEntryID = record.registryEntryID
            case .unconfirmedSwitch(let record):
                unconfirmedEntryID = record.registryEntryID
            case .blockedByActiveUSBNetwork, .blockedByUSBResourceShortage, .notActivated:
                break
            }

            let completion: EmptyDiscoveryCompletion<Host.Source> = host.recoveryLock.withLock {
                let managerStopped = host.isRecoveryStoppedLocked
                let sameGeneration =
                    !managerStopped && host.recoveryLifecycleGenerationLocked == expectedLifecycle
                if let unconfirmedEntryID {
                    if sameGeneration {
                        host.withValeriaTrackerLocked { $0.cancelEmptyDiscoveryInFlight() }
                    }
                    return .rollback(entryID: unconfirmedEntryID, managerStopped: managerStopped)
                }
                guard sameGeneration else {
                    if let switchedEntryID {
                        return .rollback(entryID: switchedEntryID, managerStopped: managerStopped)
                    }
                    return .none
                }
                guard let switchedEntryID else {
                    host.withValeriaTrackerLocked { $0.cancelEmptyDiscoveryInFlight() }
                    return .none
                }
                guard switchedEntryID == candidate.registryEntryID else {
                    host.withValeriaTrackerLocked { $0.cancelEmptyDiscoveryInFlight() }
                    return .rollback(entryID: switchedEntryID, managerStopped: false)
                }
                let pending = CaptureValeriaRecoveryTracker.PendingEmptyDiscoverySwitch(
                    registryEntryID: switchedEntryID,
                    serial: candidate.serial)
                var claimedSource: Host.Source?
                host.withValeriaTrackerLocked { tracker in
                    tracker.finishEmptyDiscovery(switchedDevice: pending)
                    if host.recoverySourcesLocked.count == 1,
                        let onlySource = host.recoverySourcesLocked.values.first,
                        tracker.claimPendingEmptyDiscoverySwitch(
                            for: onlySource.instanceID,
                            sourceID: onlySource.id,
                            pinnedDevice: onlySource.pinnedUSBDevice) != nil
                    {
                        claimedSource = onlySource
                    }
                }
                if let claimedSource {
                    return claimedSource.hasFrame
                        ? .none
                        : .claimedFrameless(source: claimedSource, entryID: switchedEntryID)
                }
                if !host.recoverySourcesLocked.isEmpty {
                    return .needsPendingReconciliation
                }
                return .none
            }

            switch completion {
            case .none:
                break
            case .rollback(let entryID, let managerStopped):
                if managerStopped {
                    _ = restoreUSB(entryID)
                } else {
                    _ = performGatedLiveRestore(
                        host: host, entryID: entryID, restoreUSB: restoreUSB)
                }
            case .claimedFrameless(let source, let entryID):
                schedulePostSwitchRestoreIfNeeded(
                    host: host,
                    source: source,
                    trackedSwitchID: entryID,
                    expectedLifecycle: expectedLifecycle,
                    delay: postSwitchRestoreDelay,
                    restoreUSB: restoreUSB)
            case .needsPendingReconciliation:
                reconcilePendingEmptyDiscoverySwitchIfNeeded(
                    host: host,
                    postSwitchRestoreDelay: postSwitchRestoreDelay,
                    queryTopology: queryTopology,
                    restoreUSB: restoreUSB)
            }
        }
    }

    private static func snapshotLocked<Host: CaptureValeriaRecoveryHost>(
        host: Host,
        source: Host.Source
    ) -> CaptureValeriaRecoverySnapshot {
        let sources = host.recoverySourcesLocked
        return CaptureValeriaRecoverySnapshot(
            isStopped: host.isRecoveryStoppedLocked,
            lifecycleGeneration: host.recoveryLifecycleGenerationLocked,
            sourceID: source.id,
            sourceInstanceID: source.instanceID,
            sourceDeviceConnected: source.isDeviceConnected,
            sourceHasFrame: source.hasFrame,
            activeSourceInstances: sources.mapValues(\.instanceID),
            identityGeneration: host.recoveryIdentityGenerationLocked,
            verificationState: host.recoveryVerificationStateLocked)
    }

    /// Closes the multi-device identity gate before restoring a previous USB
    /// configuration while the manager is live, and schedules fresh verification
    /// for the post-restore topology afterward.
    @discardableResult
    static func performGatedLiveRestore<Host: CaptureValeriaRecoveryHost>(
        host: Host,
        entryID: UInt64,
        restoreUSB: USBRestorer = USBValeriaConfigurator.restorePreviousConfiguration
    ) -> USBValeriaConfigurator.RestoreOutcome {
        let preState: (shouldProceed: Bool, closedGate: Bool) = host.recoveryLock.withLock {
            guard !host.isRecoveryStoppedLocked else { return (false, false) }
            if host.recoverySourcesLocked.count > 1 {
                host.enterMultiDevicePendingForValeriaLocked()
                return (true, true)
            }
            return (true, false)
        }
        guard preState.shouldProceed else { return .notTracked }
        if preState.closedGate {
            host.notifyScreensChangedAfterValeriaGate()
        }

        let outcome = restoreUSB(entryID)

        let postVerify: (closedGate: Bool, job: (UInt64, [String: Host.Source])?) =
            host.recoveryLock.withLock {
                guard !host.isRecoveryStoppedLocked,
                    host.recoverySourcesLocked.count > 1
                else { return (false, nil) }
                host.enterMultiDevicePendingForValeriaLocked()
                return (true, (host.recoveryIdentityGenerationLocked, host.recoverySourcesLocked))
            }
        if postVerify.closedGate {
            host.notifyScreensChangedAfterValeriaGate()
        }
        if let job = postVerify.job {
            host.scheduleValeriaIdentityVerification(generation: job.0, sources: job.1)
        }
        return outcome
    }

    static func recoverIfNeeded<Host: CaptureValeriaRecoveryHost>(
        host: Host,
        for source: Host.Source,
        restartSource: Bool,
        postSwitchRestoreDelay: TimeInterval = 4.0,
        activateUSB: @escaping USBActivator = USBValeriaConfigurator.activateDormantValeriaConfiguration,
        restoreUSB: @escaping USBRestorer = USBValeriaConfigurator.restorePreviousConfiguration
    ) {
        let plan: (snapshot: CaptureValeriaRecoverySnapshot, tryUSB: Bool)? = host.recoveryLock.withLock {
            guard !host.isRecoveryStoppedLocked,
                host.recoverySourcesLocked[source.id] === source,
                source.isDeviceConnected,
                !source.hasFrame
            else { return nil }
            let decision = host.withValeriaTrackerLocked {
                $0.begin(sourceInstanceID: source.instanceID, restartRequested: restartSource)
            }
            switch decision {
            case .denied, .mergedIntoInFlight:
                return nil
            case .start(let tryUSB):
                if host.recoverySourcesLocked.count > 1 {
                    host.enterMultiDevicePendingForValeriaLocked()
                }
                return (snapshotLocked(host: host, source: source), tryUSB)
            }
        }
        guard let plan else { return }
        if plan.snapshot.isMultiDevice {
            host.notifyScreensChangedAfterValeriaGate()
        }

        host.recoveryQueue.async { [weak host] in
            guard let host else { return }
            let isEligibleToMutateUSB: () -> Bool = { [weak host] in
                guard let host else { return false }
                return host.recoveryLock.withLock {
                    guard host.recoverySourcesLocked[source.id] === source else { return false }
                    let current = snapshotLocked(host: host, source: source)
                    return plan.snapshot.remainsValidForExecution(current: current)
                }
            }

            var switchedEntryID: UInt64?
            var unconfirmedEntryID: UInt64?
            if plan.tryUSB, isEligibleToMutateUSB() {
                let outcome = activateUSB(
                    plan.snapshot.sourceID,
                    !plan.snapshot.isMultiDevice,
                    source.pinnedUSBDevice,
                    isEligibleToMutateUSB)
                switch outcome {
                case .switched(let record):
                    switchedEntryID = record.registryEntryID
                case .unconfirmedSwitch(let record):
                    unconfirmedEntryID = record.registryEntryID
                case .blockedByActiveUSBNetwork:
                    source.recordRecoveryError(
                        "USB Personal Hotspot is the active primary network connection")
                case .blockedByUSBResourceShortage:
                    source.recordRecoveryError(usbResourceShortageMessage)
                case .notActivated:
                    break
                }
            }

            let postAction = host.recoveryLock.withLock {
                () -> (
                    shouldRestart: Bool,
                    activeSwitchEntryID: UInt64?,
                    rollbackEntryID: UInt64?,
                    verifyJob: (UInt64, [String: Host.Source])?
                ) in
                if let unconfirmedEntryID {
                    let finish = host.withValeriaTrackerLocked {
                        $0.finish(sourceInstanceID: source.instanceID, switchedEntryID: nil)
                    }
                    let stillMatches =
                        host.recoverySourcesLocked[source.id] === source
                        && plan.snapshot.matchesTopologyAndGeneration(
                            current: snapshotLocked(host: host, source: source))
                    let shouldRestartAfterRollback =
                        stillMatches && !source.hasFrame && finish.shouldRestart
                    return (shouldRestartAfterRollback, nil, unconfirmedEntryID, nil)
                }
                guard host.recoverySourcesLocked[source.id] === source else {
                    host.withValeriaTrackerLocked {
                        $0.cancelInFlight(sourceInstanceID: source.instanceID)
                    }
                    return (false, nil, switchedEntryID, nil)
                }
                let current = snapshotLocked(host: host, source: source)
                guard plan.snapshot.matchesTopologyAndGeneration(current: current) else {
                    host.withValeriaTrackerLocked {
                        $0.cancelInFlight(sourceInstanceID: source.instanceID)
                    }
                    return (false, nil, switchedEntryID, nil)
                }
                let verifyJob =
                    plan.snapshot.isMultiDevice
                    ? (host.recoveryIdentityGenerationLocked, host.recoverySourcesLocked)
                    : nil
                if current.sourceHasFrame {
                    host.withValeriaTrackerLocked { tracker in
                        if switchedEntryID != nil {
                            _ = tracker.finish(
                                sourceInstanceID: source.instanceID,
                                switchedEntryID: switchedEntryID)
                        } else {
                            tracker.cancelInFlight(sourceInstanceID: source.instanceID)
                        }
                    }
                    return (false, nil, nil, verifyJob)
                }
                let finish = host.withValeriaTrackerLocked {
                    $0.finish(
                        sourceInstanceID: source.instanceID,
                        switchedEntryID: switchedEntryID)
                }
                return (finish.shouldRestart, finish.activeSwitchEntryID, nil, verifyJob)
            }

            if let rollbackEntryID = postAction.rollbackEntryID {
                _ = performGatedLiveRestore(
                    host: host, entryID: rollbackEntryID, restoreUSB: restoreUSB)
            }
            if postAction.shouldRestart {
                source.restart()
                if let trackedSwitchID = postAction.activeSwitchEntryID {
                    schedulePostSwitchRestoreIfNeeded(
                        host: host,
                        source: source,
                        trackedSwitchID: trackedSwitchID,
                        expectedLifecycle: plan.snapshot.lifecycleGeneration,
                        delay: postSwitchRestoreDelay,
                        restoreUSB: restoreUSB)
                }
            }
            if postAction.rollbackEntryID == nil, let verifyJob = postAction.verifyJob {
                host.scheduleValeriaIdentityVerification(
                    generation: verifyJob.0, sources: verifyJob.1)
            }
        }
    }
}

/// Runs only after capture topology changes or an explicit matching retry. No
/// subprocess, screenshot, or comparison is performed on the video hot path.
enum CaptureIdentityVerifier {
    enum Result {
        case verified([String: String])
        case partiallyVerified([String: String])
        case unavailable
        case failed
    }

    enum Screenshot {
        case image(CaptureIdentityImage)
        case unavailable
        case failed
    }

    /// Injectable screenshot collection keeps missing screenshotr services and
    /// mixed-device verification covered without requiring physical phones.
    static func verify(
        physicalIDs: [String], sourceImages: () -> [String: CaptureIdentityImage],
        isCurrent: () -> Bool, waitForRetry: () -> Void = {}, screenshot: (String) -> Screenshot
    ) -> Result {
        var previous: [String: String]?
        for attempt in 0..<3 {
            if attempt > 0 { waitForRetry() }
            guard isCurrent() else { return .failed }
            var physical: [String: CaptureIdentityImage] = [:]
            var unavailable: Set<String> = []
            for id in physicalIDs {
                guard isCurrent() else { return .failed }
                switch screenshot(id) {
                case .image(let image): physical[id] = image
                case .unavailable: unavailable.insert(id)
                case .failed: break
                }
            }
            guard isCurrent() else { return .failed }
            if unavailable.count == physicalIDs.count { return .unavailable }
            let mapping = CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: Set(physicalIDs), physical: physical,
                sources: sourceImages(), unavailable: unavailable)
            if !mapping.isEmpty, previous == mapping {
                return mapping.count == physicalIDs.count ? .verified(mapping) : .partiallyVerified(mapping)
            }
            previous = mapping
        }
        return .failed
    }

    static func verify(
        physicalIDs: [String], sourceImages: () -> [String: CaptureIdentityImage],
        isCurrent: () -> Bool
    ) -> Result {
        return verify(
            physicalIDs: physicalIDs, sourceImages: sourceImages, isCurrent: isCurrent,
            waitForRetry: { Thread.sleep(forTimeInterval: 0.5) },
            screenshot: { USBIdentityScreenshot.capture(physicalID: $0) })
    }
}
