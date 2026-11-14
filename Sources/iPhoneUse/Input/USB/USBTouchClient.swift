import Darwin
import Foundation

/// Exit alone never proves safety. A worker that explicitly failed before
/// session construction needs no contact release, provided no command was sent.
struct USBTouchWorkerLifetime {
    var becameReady = false
    var commandDispatched = false
    var released = false
    var unprepared = false
    var exited = false
    var retirementConfirmed: Bool {
        exited && (released || (unprepared && !becameReady && !commandDispatched))
    }
}

/// Parent-side owner of exactly one native worker. JSON lines are bounded and
/// writes are serialized with replies; stdout is never used as a shell command.
final class USBTouchClient {
    let physicalID: String
    private let condition = NSCondition()
    private let commandLock = NSLock()
    private var pending = Data()
    private var ready: [String: Any]?
    private var replies: [String: [String: Any]] = [:]
    private var failure: String?
    private var closed = false
    private var lifetime = USBTouchWorkerLifetime()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    var dimensions: (Int, Int)? {
        condition.lock(); defer { condition.unlock() }
        guard !closed, failure == nil, let ready,
              let width = ready["width"] as? Int, let height = ready["height"] as? Int else { return nil }
        return (width, height)
    }
    var sessionID: UUID? {
        condition.lock(); defer { condition.unlock() }
        guard !closed, failure == nil, let text = ready?["session"] as? String else { return nil }
        return UUID(uuidString: text)
    }
    var error: String? { condition.lock(); defer { condition.unlock() }; return failure }
    var supportsKeyboard: Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && failure == nil && ready?["keyboard"] as? Bool == true
    }

    init(physicalID: String) throws {
        self.physicalID = physicalID
        guard let executable = Bundle.main.executableURL else { throw AXDTX.Failure("Application executable unavailable") }
        process.executableURL = executable
        process.arguments = [USBTouchWorker.argument, physicalID]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.condition.lock()
            self.lifetime.exited = true
            if !self.closed { self.failure = self.failure ?? "USB worker exited; prepare again to reconnect" }
            self.condition.broadcast(); self.condition.unlock()
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil; throw error
        }
    }
    /// The owner registers this client before waiting, so shutdown can close
    /// stdin even while readiness is blocked or eventually fails.
    func waitUntilReady() throws {
        condition.lock()
        let deadline = Date().addingTimeInterval(35)
        while ready == nil && failure == nil && !closed {
            if !condition.wait(until: deadline) { failure = "USB preparation timed out"; break }
        }
        let failed = failure ?? (ready == nil ? "USB preparation cancelled" : nil)
        condition.unlock()
        if let failed { close(); throw AXDTX.Failure(failed) }
    }
    private func fail(_ message: String) {
        condition.lock(); if failure == nil && !closed { failure = message }; condition.broadcast(); condition.unlock()
    }
    private func receive(_ bytes: Data) {
        condition.lock(); defer { condition.unlock() }
        if bytes.isEmpty {
            output.fileHandleForReading.readabilityHandler = nil
            if !closed { failure = failure ?? "USB worker disconnected" }
            condition.broadcast(); return
        }
        pending.append(bytes)
        guard pending.count <= 256 * 1024 else { failure = "USB worker output exceeds limit"; condition.broadcast(); return }
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                failure = "Invalid USB worker reply"; condition.broadcast(); return
            }
            if object["event"] as? String == "ready" {
                guard object["physicalID"] as? String == physicalID, ready == nil else {
                    failure = "USB worker identity mismatch"; condition.broadcast(); return
                }
                lifetime.becameReady = true
                ready = object
            } else if object["event"] as? String == "released" {
                lifetime.released = true
            } else if object["event"] as? String == "unprepared" {
                guard object["physicalID"] as? String == physicalID, object["inputSent"] as? Bool == false,
                      !lifetime.becameReady, !lifetime.commandDispatched else {
                    failure = "Invalid USB worker pre-session proof"; condition.broadcast(); return
                }
                lifetime.unprepared = true
            } else if let id = object["id"] as? String {
                replies[id] = object
            } else if object["event"] as? String == "failed" { failure = object["error"] as? String ?? "USB worker failed" }
            condition.broadcast()
        }
    }
    func send(_ operation: String, points: [USBTouchPoint] = [], duration: Double = 0,
              strokes: [USBKeyboardStroke]? = nil) throws {
        try USBTouchRequest.validate(operation, points: points, duration: duration, strokes: strokes)
        if operation == "keyboard", !supportsKeyboard { throw AXDTX.Failure("USB keyboard surface unavailable") }
        try commandLock.withLock {
            let id = UUID()
            let command = USBTouchWorkerCommand(id: id, operation: operation, points: points, duration: duration, strokes: strokes)
            let bytes = try JSONEncoder().encode(command) + Data([10])
            condition.lock()
            if closed || failure != nil { let message = failure ?? "USB session closed"; condition.unlock(); throw AXDTX.Failure(message) }
            lifetime.commandDispatched = true // Even a partial pipe write invalidates no-contact proof.
            condition.unlock()
            do { try input.fileHandleForWriting.write(contentsOf: bytes) }
            catch { fail("USB write failed; mayHaveExecuted=true; replayAllowed=false"); close(); throw error }
            condition.lock()
            let deadline = Date().addingTimeInterval(duration + Double(strokes?.count ?? 0) * 0.1 + 8)
            while replies[id.uuidString] == nil && failure == nil && !closed {
                if !condition.wait(until: deadline) { failure = "USB acknowledgement timed out; mayHaveExecuted=true; replayAllowed=false"; break }
            }
            let reply = replies.removeValue(forKey: id.uuidString)
            let message = failure ?? (reply?["error"] as? String)
            condition.unlock()
            guard reply?["event"] as? String == "ack", message == nil else {
                close(); throw AXDTX.Failure(message ?? "USB action uncertain; replayAllowed=false")
            }
        }
    }
    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true; condition.broadcast(); condition.unlock()
        try? input.fileHandleForWriting.close() // EOF -> worker best-effort release.
        let child = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if child.isRunning { child.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    /// A process being killed is not proof of contact release. Keep the next
    /// transport gated unless release/PING was confirmed, or explicit pre-session
    /// failure proved no contact was possible. Both paths also require exit.
    func closeAndWait() -> Bool {
        close()
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(4)
        while !lifetime.retirementConfirmed {
            if !condition.wait(until: deadline) { break }
        }
        return lifetime.retirementConfirmed
    }
    deinit { close(); output.fileHandleForReading.readabilityHandler = nil }
}
