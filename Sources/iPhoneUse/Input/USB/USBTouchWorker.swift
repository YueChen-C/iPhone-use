import Darwin
import Foundation

struct USBTouchWorkerCommand: Codable {
    let id: UUID
    let operation: String
    let points: [USBTouchPoint]
    let duration: Double
    var strokes: [USBKeyboardStroke]? = nil
}

enum USBTouchWorker {
    static let argument = "--usb-touch-worker"

    static func emit(_ object: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
    }

    /// Used only after execute succeeds. These terminal operations already
    /// release touch/keys/buttons and PING; down/move still own a held contact.
    static func acknowledgement(_ command: USBTouchWorkerCommand, physicalID: String) -> [String: Any] {
        let terminal = ["tap", "swipe", "up", "cancel", "keyboard"].contains(command.operation)
            || USBHardwareButton(rawValue: command.operation) != nil
        return ["event": "ack", "id": command.id.uuidString, "physicalID": physicalID,
                "inputReleased": terminal, "uiVerified": false]
    }

    static func run(physicalID: String) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var sessionPrepared = false
        // The parent closes stdin on cancellation. SIGTERM is only used after
        // that graceful interval; no other application's sessions are touched.
        do {
            try CoreDeviceTouchBroker.withSession(physicalID: physicalID) { service, queue, identifier, version in
                func connect(_ name: String) throws -> USBRemoteXPC {
                    try CoreDeviceTouchBroker.connect(name, service: service, queue: queue,
                        deviceIdentifier: identifier, version: version)
                }
                // Optional service: an older DDI must retain touch/keyboard.
                let indigo: USBRemoteXPC? = try? {
                    let client = try connect(USBHardwareButton.service)
                    try client.ping()
                    return client
                }()
                let session = try USBTouchSession(physicalID: physicalID,
                    control: connect("com.apple.coredevice.deviceinfo"), discovery: connect(USBTouchWire.hidService),
                    sender: connect(USBTouchWire.hidService), identifier: identifier, indigo: indigo)
                sessionPrepared = true
                session.interrupted = {
                    var state = pollfd(fd: STDIN_FILENO, events: Int16(POLLHUP), revents: 0)
                    return poll(&state, 1, 0) > 0 && state.revents & Int16(POLLHUP | POLLERR) != 0
                }
                var released = false
                defer {
                    if !released {
                        session.cancel()
                        if (try? session.finish()) != nil { emit(["event": "released"]) }
                    }
                }
                emit(["event": "ready", "physicalID": physicalID, "width": session.width,
                      "height": session.height, "surface": session.surface, "session": UUID().uuidString,
                      "keyboard": session.keyboardSurface != nil, "buttons": session.supportsButtons])
                var pending = Data()
                while true {
                    var pollFD = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
                    let result = poll(&pollFD, 1, 30)
                    if result < 0 { if errno == EINTR { continue }; throw AXDTX.Failure("USB worker stdin poll failed") }
                    if result == 0 { try session.tick(); continue }
                    if pollFD.revents & Int16(POLLIN | POLLHUP) != 0 {
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                        if count == 0 {
                            try session.finish()
                            released = true
                            emit(["event": "released"])
                            return
                        }
                        if count < 0 { if errno == EINTR { continue }; throw AXDTX.Failure("USB worker stdin closed") }
                        pending.append(contentsOf: buffer.prefix(count))
                        guard pending.count <= 256 * 1024 else { throw AXDTX.Failure("USB worker command exceeds limit") }
                        while let newline = pending.firstIndex(of: 10) {
                            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                            let command = try JSONDecoder().decode(USBTouchWorkerCommand.self, from: line)
                            do {
                                try session.execute(command.operation, points: command.points, duration: command.duration, strokes: command.strokes)
                                emit(acknowledgement(command, physicalID: physicalID))
                            } catch {
                                session.cancel()
                                emit(["event": "error", "id": command.id.uuidString, "error": "\(error)",
                                      "mayHaveExecuted": true, "replayAllowed": false])
                                throw error
                            }
                        }
                    } else { throw AXDTX.Failure("USB worker stdin unavailable") }
                }
            }
            return 0
        } catch {
            // Before session construction completes, only discovery has run:
            // no command loop or contact report can have been entered. This is
            // not a release acknowledgement for a session that became ready.
            if !sessionPrepared { emit(["event": "unprepared", "physicalID": physicalID, "inputSent": false]) }
            emit(USBPreparationFailure(error).workerEvent); return 70
        }
    }
}
