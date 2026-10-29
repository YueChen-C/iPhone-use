import Darwin
import Foundation
import ImageIO

enum ScreenCaptureIdentityState: String {
    case singleDevice
    case pending
    case verified
    case partiallyVerified
    /// The optional independent USB screenshot utility is not installed.
    case unavailable
    /// A utility was available, but the images did not prove a complete mapping.
    case failed

    func permitsAssociation(identityVerified: Bool) -> Bool {
        switch self {
        case .singleDevice, .verified, .unavailable: true
        case .partiallyVerified: identityVerified
        case .pending, .failed: false
        }
    }
}

/// Subscription callbacks arrive separately for each HID report. Retry a
/// blocked capture identity once per new BLE session, never once per callback
/// or status poll. Disconnecting another phone does not restart verification.
struct CaptureIdentityRetrySchedule {
    private var sessions: [UUID: UUID] = [:]

    mutating func update(_ current: [UUID: UUID]) -> Bool {
        let hasNewSession = current.contains { sessions[$0.key] != $0.value }
        sessions = current
        return hasNewSession
    }
}

/// A newly attached AVFoundation stream can remain empty after startRunning.
/// Recover only empty streams, once per source instance, without a timer loop.
struct CaptureSourceRecovery {
    private var attempted: Set<UUID> = []

    mutating func take(empty: Set<UUID>) -> Set<UUID> {
        let fresh = empty.subtracting(attempted)
        attempted.formUnion(fresh)
        return fresh
    }

    mutating func retain(sources: Set<UUID>) {
        attempted.formIntersection(sources)
    }
}

/// Runs only after capture topology changes or an explicit matching retry. No
/// subprocess, screenshot, or comparison is performed on the video hot path.
enum CaptureIdentityVerifier {
    enum Result {
        case verified([String: String])
        case partiallyVerified([String: String])
        case unavailable
        case failed
    }

    enum Screenshot {
        case image(CaptureIdentityImage)
        case unavailable
        case failed
    }

    /// Injectable screenshot collection keeps missing screenshotr services and
    /// mixed-device verification covered without requiring physical phones.
    static func verify(
        physicalIDs: [String], sourceImages: () -> [String: CaptureIdentityImage],
        isCurrent: () -> Bool, waitForRetry: () -> Void = {}, screenshot: (String) -> Screenshot
    ) -> Result {
        var previous: [String: String]?
        for attempt in 0..<3 {
            if attempt > 0 { waitForRetry() }
            guard isCurrent() else { return .failed }
            var physical: [String: CaptureIdentityImage] = [:]
            var unavailable: Set<String> = []
            for id in physicalIDs {
                guard isCurrent() else { return .failed }
                switch screenshot(id) {
                case .image(let image): physical[id] = image
                case .unavailable: unavailable.insert(id)
                case .failed: break
                }
            }
            guard isCurrent() else { return .failed }
            if unavailable.count == physicalIDs.count { return .unavailable }
            let mapping = CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: Set(physicalIDs), physical: physical,
                sources: sourceImages(), unavailable: unavailable)
            if !mapping.isEmpty, previous == mapping {
                return mapping.count == physicalIDs.count ? .verified(mapping) : .partiallyVerified(mapping)
            }
            previous = mapping
        }
        return .failed
    }

    static func verify(
        physicalIDs: [String], sourceImages: () -> [String: CaptureIdentityImage],
        isCurrent: () -> Bool
    ) -> Result {
        guard let tool = screenshotTool() else { return .unavailable }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-use-capture-identity-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch { return .failed }
        defer { try? FileManager.default.removeItem(at: directory) }

        return verify(
            physicalIDs: physicalIDs, sourceImages: sourceImages, isCurrent: isCurrent,
            waitForRetry: { Thread.sleep(forTimeInterval: 0.5) },
            screenshot: { id in
                let path = directory.appendingPathComponent("\(UUID().uuidString).png")
                let diagnostic = directory.appendingPathComponent("\(UUID().uuidString).txt")
                let success = run(tool, arguments: ["-u", id, path.path], timeout: 8, diagnostic: diagnostic)
                if !success {
                    let message = (try? String(contentsOf: diagnostic, encoding: .utf8)) ?? ""
                    if message.contains("Could not start screenshotr service: Invalid service") {
                        log("capture identity screenshot unavailable for \(id): screenshotr service unavailable")
                        return .unavailable
                    }
                    log("capture identity screenshot failed for \(id)")
                    return .failed
                }
                guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                    let signature = CaptureIdentityImage(image: image)
                else { return .failed }
                return .image(signature)
            })
    }

    private static func screenshotTool() -> String? {
        var paths = [
            "/opt/homebrew/bin/idevicescreenshot",
            "/opt/homebrew/opt/libimobiledevice/bin/idevicescreenshot",
            "/usr/local/bin/idevicescreenshot",
            "/usr/local/opt/libimobiledevice/bin/idevicescreenshot",
        ]
        // A stale /usr/local symlink can coexist with a working Homebrew Cellar
        // installation. Check executable health before selecting a candidate.
        for root in ["/opt/homebrew/Cellar/libimobiledevice", "/usr/local/Cellar/libimobiledevice"] {
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: root) {
                paths += versions.sorted().reversed().map { "\(root)/\($0)/bin/idevicescreenshot" }
            }
        }
        var tried: Set<String> = []
        return paths.first {
            tried.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0)
                && run($0, arguments: ["--version"], timeout: 2)
        }
    }

    private static func run(
        _ path: String, arguments: [String], timeout: TimeInterval, diagnostic: URL? = nil
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var output: FileHandle?
        if let diagnostic {
            guard FileManager.default.createFile(atPath: diagnostic.path, contents: nil) else { return false }
            output = try? FileHandle(forWritingTo: diagnostic)
        }
        defer { try? output?.close() }
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            // Only this invocation's child is terminated. Never reset the USB,
            // camera assistant, or another application's capture process.
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 1)
            }
            return false
        }
        return process.terminationStatus == 0
    }
}
