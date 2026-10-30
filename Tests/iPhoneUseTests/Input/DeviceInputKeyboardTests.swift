import XCTest

@testable import iPhoneUse

/// Exercises the public input entry points so payload refactors also preserve
/// report ordering, validation before sending, and held modifier lifetimes.
final class DeviceInputKeyboardTests: XCTestCase {
    func testTypingPreservesShiftPressAndReleaseReports() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.step = 0

        try input.type("aA!\n")

        XCTAssertTrue(reports.allSatisfy { $0.0 == .keyboard })
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [0, 0, 0x04, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
                [2, 0, 0, 0, 0, 0, 0, 0], [2, 0, 0x04, 0, 0, 0, 0, 0],
                [2, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
                [2, 0, 0, 0, 0, 0, 0, 0], [2, 0, 0x1E, 0, 0, 0, 0, 0],
                [2, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
                [0, 0, 0x28, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
            ])
    }

    func testWindowTypingCombinesCharacterAndExplicitModifiers() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.step = 0

        XCTAssertTrue(input.typeFromKeyboard("A", modifiers: ["CMD", "shift"]))
        XCTAssertTrue(input.keyFromKeyboard("RETURN", modifiers: ["Control", "option"]))
        // The synchronous no-op waits for queued keyboard input to finish.
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertTrue(reports.allSatisfy { $0.0 == .keyboard })
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [10, 0, 0, 0, 0, 0, 0, 0], [10, 0, 0x04, 0, 0, 0, 0, 0],
                [10, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
                [5, 0, 0, 0, 0, 0, 0, 0], [5, 0, 0x28, 0, 0, 0, 0, 0],
                [5, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
            ])
    }

    func testInvalidKeyboardInputSendsNoPartialTextOrModifierReports() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.step = 0

        XCTAssertThrowsError(try input.type("a🙂")) { error in
            guard case DeviceInput.InputError.untypeable("🙂") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try input.key("a", modifiers: ["cmd", "invalid"])) { error in
            guard case DeviceInput.InputError.unknownKey("invalid") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(input.typeFromKeyboard("a🙂", modifiers: ["cmd"]))
        XCTAssertFalse(input.keyFromKeyboard("enter", modifiers: ["invalid"]))
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertTrue(reports.isEmpty)
    }

    func testNamedKeyKeepsExplicitModifierMask() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.step = 0

        try input.key("A", modifiers: ["CMD", "command"])

        XCTAssertTrue(reports.allSatisfy { $0.0 == .keyboard })
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [8, 0, 0, 0, 0, 0, 0, 0], [8, 0, 0x04, 0, 0, 0, 0, 0],
                [8, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
            ])
    }

    func testLargeRelativeNudgeChunksSignedCountsBeforeClicking() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.step = 0

        try input.nudge(dx: 300, dy: -130, click: true)

        XCTAssertTrue(reports.allSatisfy { $0.0 == .relativeMouse })
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [0, 127, 129, 0], [0, 127, 253, 0], [0, 46, 0, 0],
                [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testConsumerUsageIsLittleEndianAndReleased() {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.step = 0

        input.consumer(0x0223)

        XCTAssertEqual(reports.map { $0.0 }, [.consumer, .consumer])
        XCTAssertEqual(reports.map { $0.1 }, [[0x23, 0x02], [0, 0]])
    }

    func testPowerKeyIsAShortPressAndReleasesAfterInputBecomesUnavailable() {
        var reports: [(ReportID, [UInt8])] = []
        var allowed = true
        var delays: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), inputIsAllowed: { allowed },
            sleep: { delays.append($0) },
            reportSender: { id, bytes in
                reports.append((id, bytes))
                if bytes == [0x30, 0] { allowed = false }
            })
        input.step = 0

        input.consumer(0x0030)

        XCTAssertEqual(reports.map { $0.0 }, [.consumer, .consumer])
        XCTAssertEqual(reports.map { $0.1 }, [[0x30, 0], [0, 0]])
        XCTAssertEqual(delays, [0.08, 0])
    }
}
