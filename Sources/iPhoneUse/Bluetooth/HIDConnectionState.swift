import Foundation

/// State owned exclusively by HIDPeripheral's Bluetooth queue. Keeping it separate
/// from CoreBluetooth lets disconnect and backpressure handling run without hardware.
struct HIDConnectionState {
    enum Channel: Hashable {
        case report(ReportID)
        case serviceChanged
        case battery

        var isInput: Bool {
            if case .report = self { return true }
            return false
        }
    }

    struct PendingReport {
        let host: UUID
        let channel: Channel
        let data: Data
        let session: UUID?
        let isAllowed: (() -> Bool)?

        var permissionIsCurrent: Bool {
            // Releases cannot move a pointer and must survive invalidation so
            // a key or mouse button pressed earlier does not remain held.
            switch channel {
            case .report(.relativeMouse), .report(.keyboard), .report(.consumer):
                if !data.isEmpty, data.allSatisfy({ $0 == 0 }) { return true }
            default: break
            }
            return isAllowed?() ?? true
        }
    }

    private(set) var subscriptions: [UUID: Set<Channel>] = [:]
    private(set) var sessions: [UUID: UUID] = [:]
    private(set) var pending: [PendingReport] = []

    /// A connected keyboard does not imply that the host has subscribed to its
    /// pointer reports yet. Check the report as well as the current session.
    func isReady(report: ReportID, host: UUID, session: UUID?) -> Bool {
        guard let session, sessions[host] == session else { return false }
        return subscriptions[host]?.contains(.report(report)) == true
    }

    mutating func subscribe(_ channel: Channel, host: UUID) {
        subscriptions[host, default: []].insert(channel)
        if channel.isInput, sessions[host] == nil { sessions[host] = UUID() }
    }

    mutating func unsubscribe(_ channel: Channel, host: UUID) {
        subscriptions[host]?.remove(channel)
        pending.removeAll { $0.host == host && $0.channel == channel }
        if !(subscriptions[host]?.contains(where: \.isInput) ?? false) {
            sessions[host] = nil
            pending.removeAll { $0.host == host && $0.channel.isInput }
        }
        if subscriptions[host]?.isEmpty == true { subscriptions[host] = nil }
    }

    /// An old DeviceInput may still have work queued when the same phone reconnects.
    /// Its token must match the current session, as well as the subscription.
    mutating func enqueue(
        _ channel: Channel, data: Data, host: UUID, session: UUID? = nil, isAllowed: (() -> Bool)? = nil
    ) {
        guard subscriptions[host]?.contains(channel) == true else { return }
        if channel.isInput {
            guard let session, sessions[host] == session else { return }
        }
        let report = PendingReport(host: host, channel: channel, data: data, session: session, isAllowed: isAllowed)
        guard report.permissionIsCurrent else { return }
        // Under backpressure only replace consecutive absolute positions with the
        // same button state. Never merge a key, click or relative displacement.
        if channel == .report(.absolutePointer), let last = pending.last,
            last.host == host, last.channel == channel, last.data.first == data.first
        {
            pending[pending.count - 1] = report
        } else {
            pending.append(report)
        }
    }

    /// Backpressure can leave a report queued across identity or connection
    /// changes. Revalidate at the notification boundary, not only at enqueue.
    /// `excludingHosts` skips hosts whose CoreBluetooth transmit slot rejected
    /// an earlier notification in the current drain pass while preserving strict
    /// per-host FIFO order, so a stalled peripheral (such as a suspended Watch)
    /// cannot head-of-line block another subscribed phone.
    mutating func nextPendingReportIndex(
        excludingHosts: Set<UUID> = [],
        onDrop: ((PendingReport) -> Void)? = nil
    ) -> (index: Int, report: PendingReport)? {
        var index = 0
        while index < pending.count {
            let report = pending[index]
            if excludingHosts.contains(report.host) {
                index += 1
                continue
            }
            let subscribed = subscriptions[report.host]?.contains(report.channel) == true
            let currentSession =
                !report.channel.isInput || (report.session != nil && sessions[report.host] == report.session)
            if subscribed, currentSession, report.permissionIsCurrent {
                return (index, report)
            }
            pending.remove(at: index)
            onDrop?(report)
        }
        return nil
    }

    mutating func nextPendingReport() -> PendingReport? {
        nextPendingReportIndex()?.report
    }

    mutating func removePending(at index: Int) {
        pending.remove(at: index)
    }

    mutating func removeFirst() { pending.removeFirst() }

    mutating func reset() {
        subscriptions.removeAll()
        sessions.removeAll()
        pending.removeAll()
    }
}

/// Tracks bounded outbound BLE wake/reconnect attempts separately from CoreBluetooth
/// so late cancellation callbacks cannot drop a newer connection attempt and mid-session
/// disconnects recover within a finite retry budget without infinite loops.
struct HIDReconnectTracker {
    static let maxAutomaticAttempts = 3
    static let retryDelays: [TimeInterval] = [2.0, 6.0]

    enum Phase: Equatable {
        case connecting(attempt: UInt64)
        case established(attempt: UInt64)
        case cancelling(attempt: UInt64, retryDesired: Bool)
        case backoff(token: UInt64)
    }

    enum DisconnectFollowUp: Equatable {
        case none
        case retryNow
        case scheduleBackoff(token: UInt64, delay: TimeInterval)
        case notifyChanged
    }

    private(set) var targets: Set<UUID> = []
    private(set) var phases: [UUID: Phase] = [:]
    private(set) var attemptsUsed: [UUID: Int] = [:]
    private var nextToken: UInt64 = 0

    /// Updates target hosts and returns any hosts whose active outbound peripheral
    /// connection should now be cancelled via `cancelPeripheralConnection`.
    mutating func updateTargets(
        _ newTargets: Set<UUID>,
        activeSessions: Set<UUID>,
        resetExhausted: Bool
    ) -> [UUID] {
        let added = newTargets.subtracting(targets)
        for host in added {
            attemptsUsed[host] = 0
        }
        if resetExhausted {
            for host in newTargets {
                attemptsUsed[host] = 0
            }
        }
        targets = newTargets

        var toCancel: [UUID] = []
        for (host, phase) in phases {
            if !newTargets.contains(host) {
                switch phase {
                case .connecting(let attempt), .established(let attempt):
                    if !activeSessions.contains(host) {
                        phases[host] = .cancelling(attempt: attempt, retryDesired: false)
                        toCancel.append(host)
                    }
                case .cancelling(let attempt, _):
                    phases[host] = .cancelling(attempt: attempt, retryDesired: false)
                case .backoff:
                    phases[host] = nil
                }
            } else if !activeSessions.contains(host) {
                switch phase {
                case .established(let attempt):
                    // The HID input session ended before CBCentralManager reported
                    // disconnect; cancel the stale central link and retry on callback.
                    phases[host] = .cancelling(attempt: attempt, retryDesired: true)
                    toCancel.append(host)
                case .cancelling(let attempt, let retryDesired):
                    if !retryDesired, (attemptsUsed[host] ?? 0) < Self.maxAutomaticAttempts {
                        phases[host] = .cancelling(attempt: attempt, retryDesired: true)
                    }
                case .backoff:
                    if resetExhausted {
                        phases[host] = nil
                    }
                case .connecting:
                    break
                }
            }
        }
        return toCancel
    }

    /// Hosts ready for a fresh `retrievePeripherals` + `connect` right now.
    /// Hosts still `.cancelling` mark `retryDesired = true` and wait for their
    /// disconnect callback so a late callback never deletes the next attempt.
    mutating func connectableHosts(activeSessions: Set<UUID>) -> Set<UUID> {
        var ready: Set<UUID> = []
        for host in targets where !activeSessions.contains(host) {
            guard (attemptsUsed[host] ?? 0) < Self.maxAutomaticAttempts else { continue }
            switch phases[host] {
            case nil:
                ready.insert(host)
            case .cancelling(let attempt, false):
                phases[host] = .cancelling(attempt: attempt, retryDesired: true)
            case .connecting, .established, .cancelling(_, true), .backoff:
                break
            }
        }
        return ready
    }

    mutating func beginConnecting(_ host: UUID) -> UInt64 {
        nextToken &+= 1
        let attempt = nextToken
        attemptsUsed[host, default: 0] += 1
        phases[host] = .connecting(attempt: attempt)
        return attempt
    }

    mutating func markUnretrievable(_ host: UUID) {
        attemptsUsed[host] = Self.maxAutomaticAttempts
        phases[host] = nil
    }

    /// Marks the host's HID session active, resetting its automatic retry budget
    /// while preserving any retained central peripheral reference.
    mutating func noteSessionEstablished(_ host: UUID) {
        attemptsUsed[host] = 0
        switch phases[host] {
        case .connecting(let attempt):
            phases[host] = .established(attempt: attempt)
        case .backoff:
            phases[host] = nil
        case .established, .cancelling, nil:
            break
        }
    }

    /// Transitions a timed-out `.connecting` attempt into `.cancelling` without
    /// dropping peripheral ownership before CoreBluetooth delivers `didDisconnect`.
    mutating func markTimedOut(host: UUID, attempt: UInt64, hasActiveSession: Bool) -> Bool {
        guard !hasActiveSession, phases[host] == .connecting(attempt: attempt) else { return false }
        phases[host] = .cancelling(attempt: attempt, retryDesired: false)
        return true
    }

    /// Handles `didFailToConnect` or `didDisconnectPeripheral`, releasing the
    /// finished attempt and deciding whether to retry immediately, back off within
    /// the bounded budget, or notify completion.
    mutating func handleTermination(host: UUID, hasActiveSession: Bool) -> DisconnectFollowUp {
        guard let previous = phases.removeValue(forKey: host) else { return .none }
        guard !hasActiveSession else { return .none }
        guard targets.contains(host) else { return .notifyChanged }

        let used = attemptsUsed[host] ?? 0
        if case .cancelling(_, true) = previous, used < Self.maxAutomaticAttempts {
            return .retryNow
        }
        if case .established = previous, used < Self.maxAutomaticAttempts {
            return .retryNow
        }
        if used < Self.maxAutomaticAttempts {
            nextToken &+= 1
            let token = nextToken
            let delayIndex = min(max(0, used - 1), Self.retryDelays.count - 1)
            let delay = Self.retryDelays[delayIndex]
            phases[host] = .backoff(token: token)
            return .scheduleBackoff(token: token, delay: delay)
        }
        return .notifyChanged
    }

    mutating func completeBackoff(host: UUID, token: UInt64, hasActiveSession: Bool) -> Bool {
        guard phases[host] == .backoff(token: token) else { return false }
        phases[host] = nil
        return !hasActiveSession
            && targets.contains(host)
            && (attemptsUsed[host] ?? 0) < Self.maxAutomaticAttempts
    }

    /// Hosts with an active or queued bounded reconnection that have not yet
    /// subscribed to HID input reports.
    func reconnectingHosts(activeSessions: Set<UUID>) -> Set<UUID> {
        var result: Set<UUID> = []
        for (host, phase) in phases where !activeSessions.contains(host) {
            switch phase {
            case .connecting, .backoff:
                result.insert(host)
            case .cancelling(_, true):
                result.insert(host)
            case .cancelling(_, false):
                if targets.contains(host), (attemptsUsed[host] ?? 0) < Self.maxAutomaticAttempts {
                    result.insert(host)
                }
            case .established:
                break
            }
        }
        return result
    }

    mutating func cancelEstablishedOnPeripheralReset() -> [UUID] {
        var toCancel: [UUID] = []
        for (host, phase) in phases {
            if case .established(let attempt) = phase {
                phases[host] = .cancelling(attempt: attempt, retryDesired: targets.contains(host))
                toCancel.append(host)
            }
        }
        return toCancel
    }

    mutating func cancelAllForStop() -> [UUID] {
        targets.removeAll()
        var toCancel: [UUID] = []
        for (host, phase) in phases {
            switch phase {
            case .connecting, .established, .cancelling:
                toCancel.append(host)
            case .backoff:
                break
            }
        }
        phases.removeAll()
        attemptsUsed.removeAll()
        return toCancel
    }

    mutating func resetForCentralPowerOff() {
        phases.removeAll()
        attemptsUsed.removeAll()
    }
}
