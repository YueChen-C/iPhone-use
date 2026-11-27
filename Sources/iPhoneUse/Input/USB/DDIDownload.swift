import CryptoKit
import Darwin
import Foundation

/// Explicit local preparation only: no device calls, mount grant, or input replay.
/// Pins are independent of either server's checksum response.
final class DDIDownload {
    struct Prepared {
        let bundle: URL
        let receipt: URL
    }
    typealias Fetch = (URL, URL, Int64, @escaping (Int64, Int64) -> Void) throws -> Void
    static let revision = "a1020f81b6429f5ce40408cbe21c690512b613b5"
    static let archiveURL = URL(string: "https://gitee.com/YueChen-C/DeveloperDiskImage/releases/download/DDI-27B52/DDI-27B52.zip")!
    static let archiveSHA256 = "b23d634b4fef3a8f95e341d0328e1fcd28c1e371c5fb1e6ef06b16cb6c12170f"
    static let payloadHashes = [
        "Restore/BuildManifest.plist": "3c4eee2be4a0a853044dc32dbbd62699302b1dfd317aaf4f1cf36368b7639bb0",
        "Restore/Image.dmg": "0de55b0ccde9d5790c9c9f4e1a413225443fce7ea75acb503aca11e7d8156646",
        "Restore/Image.dmg.trustcache": "f0fb56da2829f69b8aae113584349635738e68d77c82a726ed72040890f16bf4",
        "version.plist": "58de9f56454a7533673a9791e4596366667d17e4357bbdb68d9c7a805f32d3f9",
    ]
    // Companion metadata for the raw-file fallback, not downloaded executable code.
    private static let version = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>Platform</key><string>iOS</string><key>ProductBuildVersion</key><string>27B52</string><key>ProjectMetadata</key><array><dict><key>Project</key><string>CoreDevice</string><key>Version</key><string>651.32</string></dict></array></dict></plist>
    """.utf8)
    private let lock = NSLock()
    private var cancelled = false
    private var transfer: DDIDownloadTransfer?
    private let injectedFetch: Fetch?

    init(fetch: Fetch? = nil) { injectedFetch = fetch }
    func cancel() {
        let active = lock.withLock { cancelled = true; return transfer }
        active?.cancel()
    }
    private func checkCancelled() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPhoneUse/DDI", isDirectory: true)
    }

    /// A verified shared cache, not a user-selected document or mount grant.
    /// Recheck embedded pins on reuse; serialize writers across device windows.
    func prepareCached(productType: String, cache: URL = DDIDownload.cacheDirectory,
                       progress: @escaping (USBSetupPresentation) -> Void) throws -> Prepared {
        try checkCancelled()
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cache = try Self.canonicalDirectory(cache)
        return try DDILocalFile.withDirectory(cache) { root in
            let lease = try DDIFileLock(directory: root, name: "download.lock", exclusive: true,
                                       unavailable: "Another DDI download is using the cache; retry after it completes")
            return try withExtendedLifetime(lease) {
                let destination = Self.cacheEntry(in: cache)
                if fm.fileExists(atPath: destination.path) {
                    progress(.verifying)
                    let prepared = Self.prepared(at: destination)
                    do {
                        _ = try Self.verifyCached(at: destination, productType: productType)
                    } catch {
                        try checkCancelled()
                        // Only this revision's app-owned cache entry is discarded.
                        try fm.removeItem(at: destination)
                        return try prepare(destination: destination, productType: productType, progress: progress)
                    }
                    try checkCancelled()
                    return prepared
                }
                return try prepare(destination: destination, productType: productType, progress: progress)
            }
        }
    }

    /// The install child rechecks app-embedded pins, holding the cache against
    /// replacement until the native mount and verification finish.
    static func withVerifiedCache<T>(productType: String, _ use: (DDIBundlePreflight) throws -> T) throws -> T {
        let cache = try canonicalDirectory(cacheDirectory)
        return try DDILocalFile.withDirectory(cache) { root in
            let lease = try DDIFileLock(directory: root, name: "download.lock", exclusive: false,
                                       unavailable: "DDI cache is being updated; retry after download finishes")
            return try withExtendedLifetime(lease) { try use(verifyCached(at: cacheEntry(in: cache), productType: productType)) }
        }
    }

    private static func cacheEntry(in cache: URL) -> URL {
        cache.appendingPathComponent("27B52-" + revision, isDirectory: true)
    }

    private static func prepared(at destination: URL) -> Prepared {
        Prepared(bundle: destination.appendingPathComponent("bundle"), receipt: destination.appendingPathComponent("source-receipt.json"))
    }

    private static func verifyCached(at destination: URL, productType: String) throws -> DDIBundlePreflight {
        let data = try DDILocalFile.metadata(root: destination, path: "source-receipt.json", limit: 64 * 1024)
        let source = try JSONDecoder().decode(DDISourceRecord.self, from: data)
        var hashes = payloadHashes
        if source.location == fallbackLocation { hashes["version.plist"] = digest(version) }
        guard source.kind == "third-party-mirror", source.revision == revision,
              [archiveURL.absoluteString, fallbackLocation].contains(source.location), source.sha256 == hashes else {
            throw DDIManagementError("Cached DDI pins differ")
        }
        return try DDIBundlePreflight.inspect(bundle: prepared(at: destination).bundle, source: source, productType: productType)
    }

    private static let fallbackLocation = "https://github.com/doronz88/DeveloperDiskImage/tree/" + revision
    private static func canonicalDirectory(_ directory: URL) throws -> URL {
        // Keep literal /private/var, not Foundation's rewritten /var symlink.
        guard let path = realpath(directory.path, nil) else { throw DDIManagementError("DDI directory is unavailable") }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    /// Run off AppKit. Destination must be new; failure/cancellation removes
    /// only this operation's private staging directory, never an existing bundle.
    func prepare(destination: URL, productType: String,
                 progress: @escaping (USBSetupPresentation) -> Void) throws -> Prepared {
        try checkCancelled()
        let parent = try Self.canonicalDirectory(destination.deletingLastPathComponent())
        let destination = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw DDIManagementError("DDI destination already exists") }
        let work = parent.appendingPathComponent(".ddi-download-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let bundle = work.appendingPathComponent("bundle", isDirectory: true)
        let zip = work.appendingPathComponent("DDI.zip")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var hashes = Self.payloadHashes
        var location = Self.archiveURL.absoluteString
        do {
            progress(.downloading(0, 17_106_321))
            try fetch(Self.archiveURL, to: zip, limit: 17_106_321) { progress(.downloading($0, 17_106_321)) }
            progress(.verifying)
            try verify(zip, expected: Self.archiveSHA256)
            try checkCancelled()
            // Only this exact pinned archive can reach extraction. Never unpack
            // arbitrary network ZIPs, server-selected paths or executable tools.
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-q", zip.path, "-d", bundle.path]
            unzip.standardInput = FileHandle.nullDevice
            unzip.standardOutput = FileHandle.nullDevice; unzip.standardError = FileHandle.nullDevice
            guard try unzip.run(timeout: 30), unzip.terminationStatus == 0 else {
                throw DDIManagementError("Pinned DDI archive extraction failed")
            }
        } catch {
            try checkCancelled() // A cancel never silently becomes a fallback download.
            progress(.retrying)
            try fm.removeItem(at: bundle)
            try fm.createDirectory(at: bundle.appendingPathComponent("Restore"), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            let base = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/\(Self.revision)/PersonalizedImages/Xcode_iOS_DDI_Personalized/"
            location = Self.fallbackLocation
            let files: [(String, Int64)] = [("BuildManifest.plist", 800_656),
                                          ("Image.dmg", 17_084_416), ("Image.dmg.trustcache", 1_851)]
            let total = files.reduce(Int64(0)) { $0 + $1.1 }
            var completed: Int64 = 0
            for (name, limit) in files {
                try checkCancelled()
                let file = bundle.appendingPathComponent("Restore/" + name)
                let offset = completed
                progress(.downloading(offset, total))
                try fetch(URL(string: base + name)!, to: file, limit: limit) { progress(.downloading(offset + $0, total)) }
                try verify(file, expected: hashes["Restore/" + name]!)
                completed += limit
            }
            try Self.version.write(to: bundle.appendingPathComponent("version.plist"), options: .atomic)
            hashes["version.plist"] = Self.digest(Self.version)
        }
        try checkCancelled()
        progress(.verifying)
        for (name, hash) in hashes { try verify(bundle.appendingPathComponent(name), expected: hash) }
        let source = DDISourceRecord(schemaVersion: 1, kind: "third-party-mirror", location: location,
                                     revision: Self.revision, sha256: hashes)
        _ = try DDIBundlePreflight.inspect(bundle: bundle, source: source, productType: productType)
        let receipt = work.appendingPathComponent("source-receipt.json")
        try JSONEncoder().encode(source).write(to: receipt, options: .atomic)
        if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
        // Publication and cancellation have a single ordering point. Never
        // replace an existing directory or publish after cancellation wins.
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try fm.moveItem(at: work, to: destination)
        }
        return Prepared(bundle: destination.appendingPathComponent("bundle"),
                        receipt: destination.appendingPathComponent("source-receipt.json"))
    }

    private func fetch(_ url: URL, to file: URL, limit: Int64,
                       progress: @escaping (Int64) -> Void) throws {
        try checkCancelled()
        if let injectedFetch {
            try injectedFetch(url, file, limit) { received, _ in progress(received) }
        } else {
            let active = DDIDownloadTransfer(destination: file, limit: limit) { received, _ in progress(received) }
            let admitted = lock.withLock { () -> Bool in
                guard !cancelled else { return false }; transfer = active; return true
            }
            guard admitted else { throw CancellationError() }
            defer { lock.withLock { transfer = nil } }
            try active.run(url)
        }
        try checkCancelled()
    }
    private func verify(_ url: URL, expected: String) throws {
        try checkCancelled()
        let actual = try DDILocalFile.withFile(root: url.deletingLastPathComponent(), path: url.lastPathComponent) { handle, _ in
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try checkCancelled(); hash.update(data: chunk)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard actual == expected else { throw DDIManagementError("DDI download integrity check failed") }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// A single bounded, anonymous HTTPS transfer. Progress is throttled off the
/// capture/input queues; an ephemeral session sends no shared cookies or tokens.
final class DDIDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let limit: Int64
    private let timeout: TimeInterval
    private let allowedHosts: Set<String>?
    private let progress: (Int64, Int64) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var error: Error?
    private var copied = false
    private var lastProgress: TimeInterval = -.infinity
    private let finished = DispatchSemaphore(value: 0)
    init(destination: URL, limit: Int64, timeout: TimeInterval = 180, allowedHosts: Set<String>? = nil,
         progress: @escaping (Int64, Int64) -> Void) {
        self.destination = destination; self.limit = limit; self.progress = progress
        self.timeout = timeout; self.allowedHosts = allowedHosts
    }
    private func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https" else { return false }
        guard let allowedHosts else { return true }
        return url.host.map(allowedHosts.contains) == true && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    func run(_ url: URL) throws {
        guard allows(url) else { throw DDIManagementError("DDI download URL is not allowed") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = min(30, timeout); config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: url)
        lock.withLock { self.task = task; if cancelled { task.cancel() } else { task.resume() } }
        guard finished.wait(timeout: .now() + timeout + 5) == .success else {
            cancel(); throw URLError(.timedOut)
        }
        if let error { throw error }
        guard copied else { throw DDIManagementError("DDI download incomplete") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(allows(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten received: Int64, totalBytesExpectedToWrite total: Int64) {
        guard received <= limit, total <= limit else {
            error = DDIManagementError("DDI download exceeds pinned size limit"); downloadTask.cancel(); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgress >= 0.25 || received == total {
            lastProgress = now; progress(received, total)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  allows(response.url),
                  (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else {
                throw DDIManagementError("DDI download did not return a complete bounded HTTP 200 response")
            }
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                try FileManager.default.moveItem(at: location, to: destination); copied = true
            }
        } catch { self.error = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if self.error == nil { self.error = error }
        finished.signal()
    }
}
