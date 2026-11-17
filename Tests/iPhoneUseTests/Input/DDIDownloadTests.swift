import Darwin
import XCTest
@testable import iPhoneUse

final class DDIDownloadTests: XCTestCase {
    private var root: URL!
    private var destination: URL { root.appendingPathComponent("prepared") }

    override func setUpWithError() throws {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("ddi-download-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func assertClean() throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testExistingDestinationIsNeverOverwrittenOrFetched() throws {
        let sentinel = Data("keep original".utf8)
        try sentinel.write(to: destination)
        let download = DDIDownload { _, _, _, _ in XCTFail("Must not fetch") }
        XCTAssertThrowsError(try download.prepare(destination: destination, productType: "iPhone13,2") { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }
    func testCancellationBeforePreparationDoesNotFetchOrStage() throws {
        let download = DDIDownload { _, _, _, _ in XCTFail("Must not fetch") }
        download.cancel()
        XCTAssertThrowsError(try download.prepare(destination: destination, productType: "iPhone13,2") { _ in }) {
            XCTAssertTrue($0 is CancellationError)
        }
        try assertClean()
    }
    func testCancellationDuringFetchNeverFallsBackAndCleansStaging() throws {
        var calls = 0
        var download: DDIDownload!
        download = DDIDownload { _, file, _, _ in
            calls += 1
            try Data("partial".utf8).write(to: file)
            download.cancel()
            throw URLError(.cancelled)
        }
        XCTAssertThrowsError(try download.prepare(destination: destination, productType: "iPhone13,2") { _ in }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(calls, 1); try assertClean()
    }
    func testInvalidArchiveAndFallbackFailClosedAndCleanStaging() throws {
        var calls: [URL] = [], states: [USBSetupPresentation] = []
        let download = DDIDownload { url, file, _, progress in
            calls.append(url)
            try Data("not a pinned image".utf8).write(to: file)
            progress(18, 18)
        }
        XCTAssertThrowsError(try download.prepare(destination: destination, productType: "iPhone13,2") { states.append($0) })
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first, DDIDownload.archiveURL)
        XCTAssertTrue(calls.last?.path.contains(DDIDownload.revision) == true)
        XCTAssertTrue(states.contains(.retrying)); try assertClean()
    }
    func testBothConnectionsFailWithoutPublishingOrLeavingPartialFiles() throws {
        var calls = 0
        let download = DDIDownload { _, _, _, _ in calls += 1; throw URLError(.cannotConnectToHost) }
        XCTAssertThrowsError(try download.prepare(destination: destination, productType: "iPhone13,2") { _ in })
        XCTAssertEqual(calls, 2); try assertClean()
    }

    func testCancelledCachePreparationDoesNotCreateDirectories() throws {
        let cache = root.appendingPathComponent("cache")
        let download = DDIDownload { _, _, _, _ in XCTFail("Must not fetch") }
        download.cancel()
        XCTAssertThrowsError(try download.prepareCached(productType: "iPhone13,2", cache: cache) { _ in }) {
            XCTAssertTrue($0 is CancellationError)
        }
        try assertClean()
    }

    func testCacheReusesVerifiedBytesAndReplacesTamperingWhenExplicitlyConfigured() throws {
        let zip = try fixture("DDI_DOWNLOAD_TEST_ARCHIVE")
        let cache = root.appendingPathComponent("cache")
        var fetches = 0
        let download = DDIDownload { _, file, _, _ in
            fetches += 1; try FileManager.default.copyItem(at: zip, to: file)
        }
        let first = try download.prepareCached(productType: "iPhone13,2", cache: cache) { _ in }
        XCTAssertTrue(first.bundle.path.hasPrefix(cache.path + "/")); XCTAssertEqual(fetches, 1)
        let second = try download.prepareCached(productType: "iPhone13,2", cache: cache) { _ in }
        XCTAssertEqual(first.bundle, second.bundle); XCTAssertEqual(fetches, 1)
        let sibling = cache.appendingPathComponent("unrelated")
        let keep = Data("do not remove".utf8); try keep.write(to: sibling)
        try Data("untrusted receipt".utf8).write(to: first.receipt)
        _ = try download.prepareCached(productType: "iPhone13,2", cache: cache) { _ in }
        XCTAssertEqual(fetches, 2)
        try Data("tampered image".utf8).write(to: first.bundle.appendingPathComponent("Restore/Image.dmg"))
        let refreshed = try download.prepareCached(productType: "iPhone13,2", cache: cache) { _ in }
        XCTAssertEqual(fetches, 3); XCTAssertEqual(try Data(contentsOf: sibling), keep)
        let report = try DDIBundlePreflight.inspect(bundlePath: refreshed.bundle.path,
            receiptPath: refreshed.receipt.path, productType: "iPhone13,2")
        XCTAssertTrue(report.integrityVerified); XCTAssertFalse(report.deviceMutation)
    }

    // Opt-in integration fixtures stay outside the repo; never bundle Apple bytes.
    private func fixture(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key] else { throw XCTSkip("Requires explicit local pinned fixture") }
        return URL(fileURLWithPath: path)
    }
    private func verify(_ prepared: DDIDownload.Prepared) throws {
        let report = try DDIBundlePreflight.inspect(bundlePath: prepared.bundle.path,
            receiptPath: prepared.receipt.path, productType: "iPhone13,2")
        XCTAssertEqual(report.build, "27B52"); XCTAssertEqual(report.files.count, 4)
        XCTAssertTrue(report.integrityVerified); XCTAssertFalse(report.deviceMutation); XCTAssertFalse(report.inputSent)
        XCTAssertFalse(report.mountAuthorized); XCTAssertFalse(report.provenanceVerified)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), ["bundle", "source-receipt.json"])
    }
    func testPinnedArchivePreparationWhenExplicitlyConfigured() throws {
        let zip = try fixture("DDI_DOWNLOAD_TEST_ARCHIVE")
        let download = DDIDownload { url, file, limit, progress in
            XCTAssertEqual(url, DDIDownload.archiveURL)
            try FileManager.default.copyItem(at: zip, to: file)
            progress(limit, limit)
        }
        try verify(download.prepare(destination: destination, productType: "iPhone13,2") { _ in })
    }
    func testPinnedRawFallbackWhenExplicitlyConfigured() throws {
        let bundle = try fixture("DDI_DOWNLOAD_TEST_BUNDLE")
        var states: [USBSetupPresentation] = []
        let download = DDIDownload { url, file, limit, progress in
            if url == DDIDownload.archiveURL { throw URLError(.cannotConnectToHost) }
            try FileManager.default.copyItem(at: bundle.appendingPathComponent("Restore/" + url.lastPathComponent), to: file)
            progress(limit, limit)
        }
        try verify(download.prepare(destination: destination, productType: "iPhone13,2") { states.append($0) })
        XCTAssertTrue(states.contains(.retrying))
        let values = states.compactMap { state -> Int64? in
            if case let .downloading(bytes, total) = state, total == 17_886_923 { return bytes }
            return nil
        }
        XCTAssertEqual(values, values.sorted()); XCTAssertEqual(values.last, 17_886_923)
    }
    func testCancellationDuringVerificationDoesNotPublishWhenExplicitlyConfigured() throws {
        let zip = try fixture("DDI_DOWNLOAD_TEST_ARCHIVE")
        let download = DDIDownload { _, file, _, _ in try FileManager.default.copyItem(at: zip, to: file) }
        XCTAssertThrowsError(try download.prepare(destination: destination, productType: "iPhone13,2") {
            if $0 == .verifying { download.cancel() }
        }) { XCTAssertTrue($0 is CancellationError) }
        try assertClean()
    }
    func testAnonymousNativeDownloadWhenExplicitlyConfigured() throws {
        guard ProcessInfo.processInfo.environment["DDI_DOWNLOAD_TEST_NETWORK"] == "1" else {
            throw XCTSkip("Explicit network-download opt-in required; no phone operations")
        }
        var states: [USBSetupPresentation] = []
        try verify(DDIDownload().prepare(destination: destination, productType: "iPhone13,2") { states.append($0) })
        XCTAssertFalse(states.contains(.retrying), "Primary release should be anonymously downloadable")
        XCTAssertTrue(states.contains(.verifying))
        XCTAssertTrue(states.contains { $0.fraction == 1 })
        print("Native anonymous DDI download: progress + pinned SHA256 + product preflight passed; phone unchanged")
    }
}
