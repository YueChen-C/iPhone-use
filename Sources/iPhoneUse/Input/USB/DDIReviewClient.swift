import Darwin
import Foundation

/// The desktop review surface deliberately has no apply/restore request. Its
/// isolated child is this app's native CLI, never a shell or external mounter.
enum DDIReviewRequest {
    case inspect(String)
    case plan(device: String, candidate: String, candidateReceipt: String,
              baseline: String, baselineReceipt: String, directory: String)
    case status(String)

    func arguments() throws -> [String] {
        let arguments: [String]
        switch self {
        case .inspect(let id): arguments = ["inspect", id]
        case let .plan(id, candidate, receipt, baseline, baselineReceipt, directory):
            arguments = ["plan", id, candidate, receipt, baseline, baselineReceipt, directory]
        case .status(let directory): arguments = ["status", directory]
        }
        _ = try DDIManagementCLI.parse(arguments)
        return ["ddi"] + arguments
    }
    var timeout: TimeInterval { if case .plan = self { return 245 }; return 35 }
    var transactionPath: String? {
        switch self { case .inspect: return nil; case .plan(_, _, _, _, _, let path), .status(let path): return path }
    }
}

struct DDIReviewResult {
    let json: String
    let offlineCommands: String?

    init(data: Data, request: DDIReviewRequest, executable: URL) throws {
        guard data.count <= 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["inputSent"] as? Bool == false else { throw DDIManagementError("Invalid native DDI review reply") }
        switch request {
        case .inspect(let id):
            guard object["physicalID"] as? String == id, object["deviceMutation"] as? Bool == false else {
                throw DDIManagementError("DDI review device identity or mutation mismatch")
            }
        case .plan(let id, _, _, _, _, _):
            guard object["deviceMutation"] as? Bool == false,
                  let plan = object["plan"] as? [String: Any], plan["physicalID"] as? String == id else {
                throw DDIManagementError("DDI planning identity or mutation mismatch")
            }
        case .status: break // A journal can describe earlier device mutations.
        }
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        json = String(decoding: pretty, as: UTF8.self)
        if let directory = request.transactionPath {
            guard object["transactionPath"] as? String == directory, let hash = object["planSHA256"] as? String,
                  hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw DDIManagementError("DDI review plan path/hash mismatch")
            }
            // A newline would escape the comment on a mutation template.
            // Such paths may still be reviewed, but never copied as commands.
            guard !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !executable.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                offlineCommands = nil; return
            }
            // Copyable text only. Never run through a shell or feed a reply back
            // into Process.arguments. Quote every local path, even newlines/'.
            let prefix = Self.quote(executable.path) + " ddi "
            let suffix = Self.quote(directory) + " --confirm " + hash + " --acknowledge-source-risk"
            offlineCommands = prefix + "status " + Self.quote(directory) + "\n"
                + "# Review and explicitly uncomment ONE intended operation while offline; never paste a batch of mutations.\n"
                + "# " + prefix + "apply " + suffix + "\n# " + prefix + "restore " + suffix
        } else { offlineCommands = nil }
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

final class DDIReviewClient {
    private let executable: URL
    init(executable: URL) { self.executable = executable }

    /// Call off the AppKit queue. A child deadline cannot terminate the GUI.
    /// stdout/stderr use private files to avoid pipe deadlock on large reports.
    func run(_ request: DDIReviewRequest) throws -> DDIReviewResult {
        let arguments = try request.arguments()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-use-ddi-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func output(_ name: String) throws -> FileHandle {
            let fd = open(root.appendingPathComponent(name).path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw DDIManagementError("Cannot create private DDI review output") }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let stdout = try output("stdout"), stderr = try output("stderr")
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + request.timeout) == .success else {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 1)
            }
            throw DDIManagementError("Native DDI review timed out; no automatic retry. Inspect the local transaction before continuing")
        }
        func read(_ handle: FileHandle, limit: Int) throws -> Data {
            try handle.seek(toOffset: 0)
            let bytes = try handle.read(upToCount: limit + 1) ?? Data()
            guard bytes.count <= limit else { throw DDIManagementError("Native DDI review output exceeds limit") }
            return bytes
        }
        let data = try read(stdout, limit: 1024 * 1024), diagnostic = try read(stderr, limit: 256 * 1024)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw DDIManagementError("Native DDI review failed (\(process.terminationStatus)): \(String(decoding: diagnostic, as: UTF8.self))")
        }
        return try DDIReviewResult(data: data, request: request, executable: executable)
    }
}
