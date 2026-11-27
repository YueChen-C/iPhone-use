import Darwin
import Foundation
import XCTest

@testable import iPhoneUse

final class LegacyAppManagementTests: XCTestCase {
    private let appPath = "/private/var/containers/Example.app/Example"
    private let signature = Data(repeating: 0x31, count: 128)

    func testLegacyProcessSnapshotOmitsOnlyKernelAndNormalizesPaths() throws {
        let rows: [[String: Any]] = [
            ["pid": 0, "isApplication": false, "realAppName": "mach_kernel"],
            ["pid": 21, "isApplication": true, "realAppName": "/var/containers/Example.app/Example"],
            ["pid": 22, "isApplication": false, "realAppName": "unknown"],
        ]
        let processes = try LegacyAppService.decodeProcesses(rows)
        XCTAssertEqual(processes.map(\.pid), [21, 22])
        XCTAssertEqual(processes[0].path, appPath)
        XCTAssertNil(processes[1].path)
        let snapshot = NativeAppServices.ProcessSnapshot(paths: processes.compactMap(\.path), complete: false)
        XCTAssertEqual(snapshot.state(for: appPath), .running)
        XCTAssertEqual(snapshot.state(for: "/Applications/Missing.app/Missing"), .unknown)
        XCTAssertThrowsError(try LegacyAppService.decodeProcesses(rows + [rows[1]]))
        XCTAssertThrowsError(try LegacyAppService.decodeProcesses([["pid": true, "isApplication": false]]))
        XCTAssertThrowsError(try LegacyAppService.decodeProcesses([["pid": 0, "isApplication": true]]))
    }

    func testLegacyLaunchNegotiatesChannelAndDoesNotKillExistingProcess() throws {
        let stream = try Stream([
            // Unsolicited device request must be acknowledged without consuming the launch reply.
            AXDTX.call(id: 30, selector: "notice:", arguments: ["event"], reply: true, channel: .max),
            ack(2, channel: 0),
            response(31, channel: 1, object: 47),
        ])
        let service = try LegacyAppService(stream: stream)
        var launched = 0
        XCTAssertEqual(try service.launch(bundleID: "com.example.app") { launched += 1 }, 47)
        XCTAssertEqual(launched, 1)
        XCTAssertEqual(stream.writes.count, 4)
        let channel = try Stream.packet(stream.writes[1])
        XCTAssertEqual(channel.channel, 0)
        XCTAssertEqual(try AXDTX.integer(channel.payload, 36), 3)  // primitive UInt32, not an archive
        XCTAssertEqual(try AXDTX.integer(channel.payload, 40), 1)
        let noticeAck = try Stream.packet(stream.writes[2])
        XCTAssertEqual(noticeAck.identifier, 30)
        XCTAssertEqual(noticeAck.conversation, 1)
        let request = try Stream.packet(stream.writes[3])
        XCTAssertEqual(request.channel, 1)
        XCTAssertEqual(try AXDTX.object(request.payload) as? String,
                       "launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:")
        let args = try AXDTX.auxiliaryArchives(request.payload).map { try AXArchive($0).decode() }
        XCTAssertEqual(args[1] as? String, "com.example.app")
        XCTAssertEqual(args[4] as? [String: Bool], ["StartSuspendedKey": false, "KillExisting": false])
    }

    func testLegacyTerminationSignalsOnlyExactExecutableAndRequiresReadback() throws {
        let before = [
            ["pid": 42, "realAppName": appPath] as [String: Any],
            ["pid": 43, "realAppName": "/var/containers/Other.app/Example"],
        ]
        let stream = try Stream([
            ack(2, channel: 0), response(3, channel: 1, object: before), ack(4, channel: 0),
            ack(5, channel: 2), response(6, channel: 1, object: [before[1]]),
        ])
        let service = try LegacyAppService(stream: stream)
        var sent = 0
        switch try service.terminate(executablePath: appPath, willSignal: { sent += 1 }) {
        case .terminated(let pid): XCTAssertEqual(pid, 42)
        case .alreadyStopped: XCTFail("Target PID was running")
        }
        XCTAssertEqual(sent, 1)
        let kill = try Stream.packet(stream.writes[4])
        XCTAssertEqual(try AXDTX.object(kill.payload) as? String, "killPid:")
        let args = try AXDTX.auxiliaryArchives(kill.payload).map { try AXArchive($0).decode() }
        XCTAssertEqual(NativeAppServices.positivePID(args.first), 42)
    }

    func testLegacyChannelFailureDoesNotSendProcessMutation() throws {
        let error = AXDTX.packet(id: 2, conversation: 1, payload: AXDTX.number(4) + Data(count: 12))
        let stream = Stream([error])
        let service = try LegacyAppService(stream: stream)
        XCTAssertThrowsError(try service.launch(bundleID: "com.example.app") { XCTFail("Mutation was not allowed") })
        XCTAssertEqual(stream.writes.count, 2)
    }

    func testWorkerPreparesOnlyForUnavailableDVTAndRetriesAtMostOnce() throws {
        let unavailable = AXUSBProxy.LegacyInstrumentsUnavailable(version: "15.4")
        var prepares = [String]()
        var attempts = 0
        func execute() throws -> Int {
            attempts += 1
            throw unavailable
        }
        XCTAssertThrowsError(try NativeAppManagement.withLegacySetup(
            eligible: { true }, prepare: { prepares.append($0) }, execute: execute))
        XCTAssertEqual(prepares, ["15.4"])
        XCTAssertEqual(attempts, 2)
        XCTAssertThrowsError(try NativeAppManagement.withLegacySetup(
            eligible: { false }, prepare: { prepares.append($0) }, execute: execute))
        XCTAssertEqual(prepares, ["15.4"])
        XCTAssertEqual(attempts, 3)
        XCTAssertThrowsError(try NativeAppManagement.withLegacySetup(
            eligible: { true }, prepare: { prepares.append($0) }, execute: { throw AXDTX.Failure("transport lost") }))
        XCTAssertEqual(prepares, ["15.4"])
    }

    func testFirstMountOnlyWritesAfterEmptyLookupAndChecksReturnedSignature() throws {
        let image = Data(repeating: 0x5a, count: 65_539)
        let stream = try Stream(plists: [
            ["Status": "Complete", "ImagePresent": false], ["Status": "Complete"],
            ["Status": "ReceiveBytesAck"], ["Status": "Complete"], ["Status": "Complete"],
            ["Status": "Complete", "ImageSignature": [signature]],
        ])
        XCTAssertTrue(try LegacyDeveloperImage.ensureMounted(stream) { .init(bytes: image, signature: signature) })
        XCTAssertEqual(stream.writes.count, 7)
        XCTAssertEqual(stream.writes[3] + stream.writes[4], image)
        let frames = try [0, 1, 2, 5, 6].map { try stream.plistWrite($0) }
        XCTAssertEqual(frames.compactMap { $0["Command"] as? String },
                       ["LookupImage", "LookupImage", "ReceiveBytes", "MountImage", "LookupImage"])
        XCTAssertTrue(frames.allSatisfy { $0["ImageType"] as? String == "Developer" })
        XCTAssertEqual(frames[2]["ImageSize"] as? Int, image.count)
        XCTAssertEqual(frames[3]["ImageSignature"] as? Data, signature)
    }

    func testExistingOrConcurrentlyMountedImageIsNeverReplaced() throws {
        let existing: [String: Any] = ["Status": "Complete", "ImageSignature": [signature]]
        let stream = try Stream(plists: [existing])
        XCTAssertFalse(try LegacyDeveloperImage.ensureMounted(stream) {
            XCTFail("An existing DDI should not depend on local files")
            throw AXDTX.Failure("unexpected")
        })
        XCTAssertEqual(stream.writes.count, 1)

        let concurrent = try Stream(plists: [["Status": "Complete"], existing])
        XCTAssertFalse(try LegacyDeveloperImage.ensureMounted(concurrent) { .init(bytes: Data([1]), signature: Data([2])) })
        XCTAssertEqual(concurrent.writes.count, 2)
    }

    func testSetupFailsClosedForMalformedLookupRejectedUploadAndWrongReadback() throws {
        let absent = ["Status": "Complete"]
        let image = LegacyDeveloperImage.Image(bytes: Data([1]), signature: signature)
        let invalid = try Stream(plists: [["Status": "Complete", "ImageSignature": "malformed"]])
        XCTAssertThrowsError(try LegacyDeveloperImage.ensureMounted(invalid) { image })
        XCTAssertEqual(invalid.writes.count, 1)
        let rejected = try Stream(plists: [absent, absent, ["Error": "DeviceLocked"]])
        XCTAssertThrowsError(try LegacyDeveloperImage.ensureMounted(rejected) { image })
        XCTAssertEqual(rejected.writes.count, 3)  // no raw upload or mount
        let wrong = try Stream(plists: [absent, absent, ["Status": "ReceiveBytesAck"], absent, absent,
                                       ["Status": "Complete", "ImageSignature": [Data([2])]]])
        XCTAssertThrowsError(try LegacyDeveloperImage.ensureMounted(wrong) { image })
        XCTAssertEqual(wrong.writes.count, 6)  // one mount, no replay
    }

    func testLocalImageOnlyUsesMatchingVersionDirectoriesAndRejectsSymlinks() throws {
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let dir = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ version: String, byte: UInt8) throws {
            let sub = dir.appendingPathComponent(version)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data([byte]).write(to: sub.appendingPathComponent("DeveloperDiskImage.dmg"))
            try signature.write(to: sub.appendingPathComponent("DeveloperDiskImage.dmg.signature"))
        }
        try write("15.5", byte: 5)
        XCTAssertThrowsError(try LegacyDeveloperImage.localImage(version: "15.4.1", roots: [dir]))
        try write("15.4", byte: 4)
        XCTAssertEqual(try LegacyDeveloperImage.localImage(version: "15.4.1", roots: [dir]).bytes, Data([4]))
        try write("15.4.1", byte: 1)
        XCTAssertEqual(try LegacyDeveloperImage.localImage(version: "15.4.1", roots: [dir]).bytes, Data([1]))
        let local = try LegacyDeveloperImage.imageForMount(version: "15.4.1", roots: [dir]) { _ in
            XCTFail("a valid local pair must not contact Gitee")
            throw URLError(.badURL)
        }
        XCTAssertEqual(local.bytes, Data([1]))
        let remote = try LegacyDeveloperImage.imageForMount(version: "15.6.1", roots: [dir]) { version in
            XCTAssertEqual(version, "15.6.1")
            return .init(bytes: Data([6]), signature: signature)
        }
        XCTAssertEqual(remote.bytes, Data([6]))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("15.3"),
                                                   withDestinationURL: dir.appendingPathComponent("15.4"))
        XCTAssertThrowsError(try LegacyDeveloperImage.localImage(version: "15.3", roots: [dir]))
        XCTAssertThrowsError(try LegacyDeveloperImage.versionDirectories("15.4/../../"))
        XCTAssertThrowsError(try LegacyDeveloperImage.versionDirectories("17.5"))
    }

    func testFailedGiteeFallbackDoesNotUploadOrMountAnything() throws {
        let stream = try Stream(plists: [["Status": "Complete"]])
        XCTAssertThrowsError(try LegacyDeveloperImage.ensureMounted(stream) {
            try LegacyDeveloperImage.imageForMount(version: "15.4", roots: []) { _ in throw URLError(.timedOut) }
        }) { error in
            XCTAssertTrue(String(describing: error).contains("Gitee fallback failed"))
            XCTAssertTrue(String(describing: error).contains(LegacyDeveloperImage.rootVariable))
        }
        XCTAssertEqual(stream.writes.count, 1)  // LookupImage only
    }

    private func ack(_ id: UInt32, channel: UInt32) -> Data {
        AXDTX.packet(id: id, conversation: 1, channel: channel, payload: Data(count: 16))
    }

    private func response(_ id: UInt32, channel: UInt32, object: Any) throws -> Data {
        try AXDTX.response(to: .init(identifier: id, conversation: 0, channel: channel,
                                    expectsReply: true, payload: Data()), object: object)
    }

    private final class Stream: AXByteStream {
        private var pending: Data
        private(set) var writes: [Data] = []

        init(_ packets: [Data]) { pending = packets.reduce(into: Data()) { $0 += $1 } }

        convenience init(plists: [[String: Any]]) throws {
            try self.init(plists.map { reply in
                let data = try PropertyListSerialization.data(fromPropertyList: reply, format: .binary, options: 0)
                return AXUSBProxy.big(UInt64(data.count), 4) + data
            })
        }

        func send(_ data: Data) throws { writes.append(data) }

        func read(_ count: Int) throws -> Data {
            guard count <= pending.count else { throw AXDTX.Failure("Fixture EOF") }
            let bytes = Data(pending.prefix(count))
            pending.removeFirst(count)
            return bytes
        }

        func plistWrite(_ index: Int) throws -> [String: Any] {
            let data = Data(writes[index].dropFirst(4))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }

        static func packet(_ data: Data) throws -> AXDTX.Message {
            try AXDTX.receive(read: Stream([data]).read)
        }
    }
}
