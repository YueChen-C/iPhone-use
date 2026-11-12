import Foundation

/// One packet in flight at most. A quiet timeout never cancels/restarts a partial
/// DTX packet. Used only by the isolated AX worker: an outstanding blocking Apple
/// receive is reclaimed when that worker exits (the parent enforces 25 seconds).
final class AXMessageReader {
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "iphone-use.ax.receive")
    private let receive: () throws -> AXDTX.Message
    private var result: Result<AXDTX.Message, Error>?
    private var reading = false

    init(receive: @escaping () throws -> AXDTX.Message) { self.receive = receive }

    func next(timeout: TimeInterval) throws -> AXDTX.Message? {
        condition.lock()
        defer { condition.unlock() }
        if !reading && result == nil {
            reading = true
            queue.async { [self] in
                let received = Result { try receive() }
                condition.lock()
                result = received; reading = false
                condition.signal(); condition.unlock()
            }
        }
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        while result == nil {
            if !condition.wait(until: deadline) && result == nil { return nil }
        }
        let received = result!; result = nil
        return try received.get()
    }
}
