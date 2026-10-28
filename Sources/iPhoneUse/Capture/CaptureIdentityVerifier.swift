import Darwin
import Foundation
import ImageIO

enum ScreenCaptureIdentityState: String {
    case singleDevice
    case pending
    case verified
    /// The optional independent USB screenshot utility is not installed.
    case unavailable
    /// A utility was available, but the images did not prove a complete mapping.
    case failed
}

/// Runs only after capture topology changes or an explicit matching retry. No
/// subprocess, screenshot, or comparison is performed on the video hot path.
enum CaptureIdentityVerifier {
    enum Result {
        case verified([String: String])
        case unavailable
        case failed
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

        var previous: [String: String]?
        for _ in 0..<3 {
            guard isCurrent() else { return .failed }
            var physical: [String: CaptureIdentityImage] = [:]
            for id in physicalIDs {
                guard isCurrent() else { return .failed }
                let path = directory.appendingPathComponent("\(UUID().uuidString).png")
                guard run(tool, arguments: ["-u", id, path.path], timeout: 8),
                    let source = CGImageSourceCreateWithURL(path as CFURL, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                    let signature = CaptureIdentityImage(image: image)
                else { return .failed }
                physical[id] = signature
            }
            guard isCurrent() else { return .failed }
            if let mapping = CaptureIdentityMatcher.match(physical: physical, sources: sourceImages()) {
                // Two independent rounds must agree. A transient frame must not
                // permanently redirect another phone's screen or pointer input.
                if previous == mapping { return .verified(mapping) }
                previous = mapping
            } else {
                previous = nil
            }
        }
        return .failed
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

    private static func run(_ path: String, arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
