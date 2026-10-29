import XCTest

@testable import iPhoneUse

final class USBIdentityScreenshotTests: XCTestCase {
    private let greeting: [Any] = ["DLMessageVersionExchange", 400, 0]
    private let ready: [Any] = ["DLMessageDeviceReady"]

    private func reply(_ data: Data) -> [Any] {
        ["DLMessageProcessMessage", ["MessageType": "ScreenShotReply", "ScreenShotData": data]]
    }

    private func read(_ messages: [[Any]], sent: (([Any]) -> Void)? = nil) throws -> Data {
        var index = 0
        return try DeviceLinkScreenshot.read(
            send: { sent?($0) },
            receive: {
                guard index < messages.count else { throw DeviceLinkScreenshot.Failure.invalidReply }
                defer { index += 1 }
                return messages[index]
            })
    }

    func testDeviceLinkNegotiatesBeforeRequestingAndPreservesScreenshotBytes() throws {
        let image = Data([0x89, 0x50, 0x4e, 0x47, 0, 0xff])
        var requests: [[Any]] = []
        XCTAssertEqual(try read([greeting, ready, reply(image)], sent: { requests.append($0) }), image)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0][0] as? String, "DLMessageVersionExchange")
        XCTAssertEqual(requests[0][1] as? String, "DLVersionsOk")
        XCTAssertEqual(requests[0][2] as? Int, 400)
        XCTAssertEqual(requests[1][0] as? String, "DLMessageProcessMessage")
        XCTAssertEqual((requests[1][1] as? [String: String])?["MessageType"], "ScreenShotRequest")
    }

    func testUnsupportedAndMalformedVersionsDoNotSendAnyInputOrRequest() {
        let greetings: [[Any]] = [
            [], ["unrelated", 400, 0], ["DLMessageVersionExchange", 400],
            ["DLMessageVersionExchange", "400", 0], ["DLMessageVersionExchange", -1, 0],
            ["DLMessageVersionExchange", 401, 0], ["DLMessageVersionExchange", 400, 1],
        ]
        for greeting in greetings {
            XCTAssertThrowsError(try read([greeting], sent: { _ in XCTFail("must reject before sending") }))
        }
    }

    func testScreenshotRequestRequiresDeviceReady() {
        var sends = 0
        XCTAssertThrowsError(try read([greeting, ["unrelated"]], sent: { _ in sends += 1 }))
        XCTAssertEqual(sends, 1, "only version negotiation may be sent before readiness")
    }

    func testRejectsUnrelatedRepliesAndMissingOrEmptyImageData() {
        let replies: [[Any]] = [
            [], ["DLMessageDisconnect"],
            ["unrelated", ["MessageType": "ScreenShotReply", "ScreenShotData": Data([1])]],
            ["DLMessageProcessMessage", ["MessageType": "unrelated", "ScreenShotData": Data([1])]],
            ["DLMessageProcessMessage", ["MessageType": "ScreenShotReply"]],
            ["DLMessageProcessMessage", ["MessageType": "ScreenShotReply", "ScreenShotData": "not image data"]],
            reply(Data()),
        ]
        for reply in replies { XCTAssertThrowsError(try read([greeting, ready, reply])) }
    }

    func testTransportFailureStopsTheExchange() {
        enum TransportFailure: Error { case disconnected }
        var reads = 0
        XCTAssertThrowsError(
            try DeviceLinkScreenshot.read(
                send: { _ in throw TransportFailure.disconnected },
                receive: {
                    reads += 1
                    return self.greeting
                }))
        XCTAssertEqual(reads, 1, "do not await another message after a failed send")
    }

    func testWorkerPreservesUnavailableAndFailureExitCodes() {
        for code in [0, USBIdentityScreenshot.unavailableExitCode, USBIdentityScreenshot.failedExitCode] {
            XCTAssertEqual(
                USBIdentityScreenshot.run(
                    executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit \(code)"], timeout: 2), code)
        }
        XCTAssertNil(
            USBIdentityScreenshot.run(
                executable: URL(fileURLWithPath: "/does-not-exist/iphone-use"), arguments: [], timeout: 0.1))
    }

    func testWorkerTimeoutDoesNotTerminateOtherProcesses() throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["10"]
        try other.run()
        defer {
            if other.isRunning { other.terminate() }
            other.waitUntilExit()
        }
        let start = Date()
        XCTAssertNil(
            USBIdentityScreenshot.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(other.isRunning)
    }
}
