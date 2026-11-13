import XCTest
@testable import iPhoneUse

final class DDIReviewTests: XCTestCase {
    private let id = "00000001-0000000000000001"
    private let planHash = String(repeating: "a", count: 64)
    private let executable = URL(fileURLWithPath: "/Applications/iPhone Use.app/Contents/MacOS/iphone-use")

    func testReviewOnlyConstructsThreeNonMutatingCLIRequests() throws {
        let request = DDIReviewRequest.plan(device: id, candidate: "/candidate", candidateReceipt: "/candidate.json",
            baseline: "/baseline", baselineReceipt: "/baseline.json", directory: "/new transaction")
        XCTAssertEqual(try request.arguments(), ["ddi", "plan", id, "/candidate", "/candidate.json", "/baseline", "/baseline.json", "/new transaction"])
        XCTAssertEqual(try DDIReviewRequest.inspect(id).arguments(), ["ddi", "inspect", id])
        XCTAssertEqual(try DDIReviewRequest.status("/transaction").arguments(), ["ddi", "status", "/transaction"])
        XCTAssertEqual(request.timeout, 245)
        XCTAssertEqual(DDIReviewRequest.inspect(id).timeout, 35)
        XCTAssertThrowsError(try DDIReviewRequest.inspect("first phone").arguments())
        XCTAssertThrowsError(try DDIReviewRequest.status("relative").arguments())
    }

    func testPathsRemainLiteralArgumentsNotShellCode() throws {
        let value = "/tmp/DDI ' $(touch PAYLOAD); report"
        XCTAssertEqual(try DDIReviewRequest.status(value).arguments(), ["ddi", "status", value])
        let data = try JSONSerialization.data(withJSONObject: ["inputSent": false, "transactionPath": value, "planSHA256": planHash])
        let result = try DDIReviewResult(data: data, request: .status(value), executable: executable)
        let commands = try XCTUnwrap(result.offlineCommands)
        XCTAssertTrue(commands.contains("'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"))
        XCTAssertTrue(commands.hasPrefix("'/Applications/iPhone Use.app/Contents/MacOS/iphone-use' ddi status "))
        XCTAssertTrue(commands.contains("--confirm " + planHash + " --acknowledge-source-risk"))
        let activeLines = commands.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(activeLines.count, 1)
        XCTAssertTrue(activeLines[0].contains(" ddi status "))
    }

    func testMultilinePathIsReviewableButCannotEscapeCommentedMutationTemplates() throws {
        let value = "/tmp/DDI\nPAYLOAD"
        XCTAssertEqual(try DDIReviewRequest.status(value).arguments(), ["ddi", "status", value])
        let data = try JSONSerialization.data(withJSONObject: ["inputSent": false, "transactionPath": value, "planSHA256": planHash])
        XCTAssertNil(try DDIReviewResult(data: data, request: .status(value), executable: executable).offlineCommands)
    }

    func testInspectReplyRequiresExactDeviceNoTouchAndNoMutation() throws {
        for object: [String: Any] in [
            ["physicalID": id, "inputSent": false, "deviceMutation": false],
            ["physicalID": "other", "inputSent": false, "deviceMutation": false],
            ["physicalID": id, "inputSent": true, "deviceMutation": false],
            ["physicalID": id, "inputSent": false, "deviceMutation": true]] {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            if object["physicalID"] as? String == id && object["inputSent"] as? Bool == false && object["deviceMutation"] as? Bool == false {
                XCTAssertNil(try DDIReviewResult(data: bytes, request: .inspect(id), executable: executable).offlineCommands)
            } else { XCTAssertThrowsError(try DDIReviewResult(data: bytes, request: .inspect(id), executable: executable)) }
        }
    }

    func testPlanReplyRequiresBoundIdentityPathHashAndNonMutation() throws {
        let request = DDIReviewRequest.plan(device: id, candidate: "/c", candidateReceipt: "/c.json", baseline: "/b", baselineReceipt: "/b.json", directory: "/new")
        let valid: [String: Any] = ["inputSent": false, "deviceMutation": false, "transactionPath": "/new", "planSHA256": planHash, "plan": ["physicalID": id]]
        XCTAssertNotNil(try DDIReviewResult(data: JSONSerialization.data(withJSONObject: valid), request: request, executable: executable).offlineCommands)
        for (key, value): (String, Any) in [("deviceMutation", true), ("transactionPath", "/other"), ("planSHA256", "SHA256"), ("plan", ["physicalID": "other"])] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try DDIReviewResult(data: JSONSerialization.data(withJSONObject: invalid), request: request, executable: executable))
        }
    }

    func testStatusMayReviewEarlierMutationButNeverClaimsToRunIt() throws {
        let data = try JSONSerialization.data(withJSONObject: ["inputSent": false, "deviceMutation": true, "transactionPath": "/existing", "planSHA256": planHash])
        let report = try DDIReviewResult(data: data, request: .status("/existing"), executable: executable)
        XCTAssertTrue(report.json.contains("deviceMutation"))
        XCTAssertNotNil(report.offlineCommands)
    }

    func testMalformedAndOversizedOutputIsRejected() {
        for data in [Data("[]".utf8), Data("not JSON".utf8), Data(repeating: 32, count: 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try DDIReviewResult(data: data, request: .inspect(id), executable: executable))
        }
    }

    func testNativeChildFailureAndEmptyOutputAreNotSuccess() {
        XCTAssertThrowsError(try DDIReviewClient(executable: URL(fileURLWithPath: "/usr/bin/false")).run(.inspect(id)))
        XCTAssertThrowsError(try DDIReviewClient(executable: URL(fileURLWithPath: "/usr/bin/true")).run(.inspect(id)))
    }

    func testBothLanguagesExplicitlyDescribeNonMutationAndOfflineBoundary() {
        XCTAssertTrue(StringsDDIReview.en.notice.contains("No phone image changes"))
        XCTAssertTrue(StringsDDIReview.zh.notice.contains("不更改手机镜像"))
        XCTAssertTrue(StringsDDIReview.en.offline.contains("cannot mount or restore"))
        XCTAssertTrue(StringsDDIReview.zh.offline.contains("不执行挂载或恢复"))
    }

    func testNativeProductReviewWhenExplicitlyConfigured() throws {
        let env = ProcessInfo.processInfo.environment
        guard let binary = env["DDI_REVIEW_TEST_EXECUTABLE"], let device = env["DDI_REVIEW_TEST_DEVICE"],
              let candidate = env["DDI_REVIEW_TEST_CANDIDATE"], let candidateReceipt = env["DDI_REVIEW_TEST_CANDIDATE_RECEIPT"],
              let baseline = env["DDI_REVIEW_TEST_BASELINE"], let baselineReceipt = env["DDI_REVIEW_TEST_BASELINE_RECEIPT"],
              let transaction = env["DDI_REVIEW_TEST_NEW_TRANSACTION"] else {
            throw XCTSkip("Explicit local device/bundle configuration required; never auto-select a phone")
        }
        let client = DDIReviewClient(executable: URL(fileURLWithPath: binary))
        let inspected = try client.run(.inspect(device))
        XCTAssertNil(inspected.offlineCommands)
        let planned = try client.run(.plan(device: device, candidate: candidate, candidateReceipt: candidateReceipt,
            baseline: baseline, baselineReceipt: baselineReceipt, directory: transaction))
        let status = try client.run(.status(transaction))
        XCTAssertEqual(planned.json, status.json)
        XCTAssertNotNil(status.offlineCommands)
        if let output = env["DDI_REVIEW_TEST_OUTPUT"] {
            try status.json.write(toFile: output, atomically: true, encoding: .utf8)
        }
    }
}
