import Foundation

/// Tracks notifications already pending at a drain boundary. The registry is
/// confined to the Bluetooth queue; only a Waiter's completion crosses queues.
final class HIDDrainBarrier {
    final class Waiter {
        let id = UUID()
        let host: UUID
        let session: UUID

        private let deadline: DispatchTime
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Bool?

        init(host: UUID, session: UUID, timeout: TimeInterval) {
            self.host = host
            self.session = session
            deadline = .now() + timeout
        }

        var completedResult: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        /// The first completion wins. A late acceptance cannot turn a timeout
        /// into success, including when registration itself waited in the queue.
        func finish(_ success: Bool) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = success && DispatchTime.now() < deadline
            lock.unlock()
            semaphore.signal()
        }

        /// Blocks the caller, never the Bluetooth queue.
        func wait() -> Bool {
            if semaphore.wait(timeout: deadline) == .timedOut { finish(false) }
            return completedResult == true
        }
    }

    private struct Entry {
        let waiter: Waiter
        var remaining: Int
    }

    private var entries: [UUID: Entry] = [:]
    var count: Int { entries.count }

    func register(_ waiter: Waiter, pendingCount: Int) {
        // The caller can time out before its registration reaches this queue.
        guard waiter.completedResult == nil else { return }
        guard pendingCount > 0 else {
            waiter.finish(true)
            return
        }
        entries[waiter.id] = Entry(waiter: waiter, remaining: pendingCount)
    }

    /// Call only after updateValue accepted a report and it left the FIFO.
    func didAccept(host: UUID, session: UUID?) {
        guard let session else { return }
        for id in Array(entries.keys) {
            guard var entry = entries[id], entry.waiter.host == host,
                entry.waiter.session == session
            else { continue }
            entry.remaining -= 1
            if entry.remaining == 0 {
                entries.removeValue(forKey: id)
                entry.waiter.finish(true)
            } else {
                entries[id] = entry
            }
        }
    }

    /// A removed or invalidated report did not drain successfully.
    func invalidate(host: UUID, session: UUID?) {
        for id in Array(entries.keys) {
            guard let entry = entries[id], entry.waiter.host == host,
                session == nil || entry.waiter.session == session
            else { continue }
            entries.removeValue(forKey: id)
            entry.waiter.finish(false)
        }
    }

    func invalidateAll() {
        let waiters = entries.values.map(\.waiter)
        entries.removeAll()
        for waiter in waiters { waiter.finish(false) }
    }

    func cancel(_ waiter: Waiter) {
        entries.removeValue(forKey: waiter.id)
        waiter.finish(false)
    }
}
