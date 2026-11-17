import CryptoKit
import Darwin
import Foundation

// Compiles the production transaction/store/lease sources into a separate test
// executable. Only FileDevice is injected; it never calls the native device API.
let manager = FileManager.default
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw DDIManagementError(message) }
}
func encoded<T: Encodable>(_ value: T, to url: URL) throws {
    try DDITransactionStore.encoded(value).write(to: url, options: .atomic)
}
func emit(_ object: [String: Any]) throws {
    try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10]))
}

struct ProcessResult: Codable {
    let arguments: [String]
    let stdout: String
    let stderr: String
    let status: Int32
    let signalled: Bool
}
final class Matrix {
    let root: URL
    var ledger: [ProcessResult] = []
    init(root: URL) { self.root = root }
    func child(_ arguments: [String]) throws -> (Process, Pipe, Pipe) {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = error
        try process.run()
        return (process, output, error)
    }
    func collect(_ child: (Process, Pipe, Pipe)) -> ProcessResult {
        let (process, output, error) = child
        let started = ProcessInfo.processInfo.systemUptime
        while process.isRunning, ProcessInfo.processInfo.systemUptime - started < 15 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let result = ProcessResult(arguments: process.arguments ?? [],
            stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            status: process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal)
        ledger.append(result)
        return result
    }
    func run(_ mode: String, _ directory: URL, status: Int32 = 0, error: String? = nil) throws -> [String: Any] {
        let result = collect(try child([mode, directory.path]))
        try require(!result.signalled && result.status == status, "Unexpected child exit: \(result)")
        if status != 0 {
            try require(error.map { result.stderr.contains($0) } == true, "Wrong refusal: \(result.stderr)")
            return [:]
        }
        guard let data = result.stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DDIManagementError("Invalid child JSON: \(result.stdout)")
        }
        return object
    }
    func interrupt(_ mode: String, _ directory: URL, at boundary: String) throws {
        let reached = directory.appendingPathComponent("reached")
        let child = try self.child([mode, directory.path, boundary])
        let started = ProcessInfo.processInfo.systemUptime
        while !manager.fileExists(atPath: reached.path), child.0.isRunning,
              ProcessInfo.processInfo.systemUptime - started < 10 { Thread.sleep(forTimeInterval: 0.02) }
        // Kill only the process created above, never a running GUI/MCP/AX owner.
        let ready = manager.fileExists(atPath: reached.path)
        if child.0.isRunning { _ = kill(child.0.processIdentifier, SIGKILL) }
        let result = collect(child)
        try require(ready && result.signalled && result.status == SIGKILL, "Child did not reach interruption boundary")
        try require(try String(contentsOf: reached, encoding: .utf8) == boundary, "Wrong interruption boundary")
    }
    func execute() throws {
        let cases: [(String, String, String, String, String)] = [
            ("apply-unmount", "apply", "after-unmount", "unmounting", "none"),
            ("apply-mount-before", "apply", "before-mount-result", "mounting", "none"),
            ("apply-mount-after", "apply", "after-mount-result", "mounting", "NEW"),
            ("restore-unmount", "restore", "after-unmount", "restoreUnmounting", "none"),
            ("restore-mount-after", "restore", "after-mount-result", "restoring", "OLD"),
            ("restore-cleanup", "restore", "before-clear", "restored", "OLD"),
        ]
        defer { try? encoded(ledger, to: root.appendingPathComponent("process-ledger.json")) }
        for (name, mode, boundary, phase, build) in cases {
            let directory = root.appendingPathComponent(name)
            _ = try run("setup", directory)
            if mode == "restore" { _ = try run("apply", directory) }
            try interrupt(mode, directory, at: boundary)
            let status = try run("status", directory)
            try require(status["phase"] as? String == phase && status["build"] as? String == build
                && status["recoveryPending"] as? Bool == true && status["pendingMatchesPlan"] as? Bool == true,
                "Wrong persisted interruption state: \(status)")
            _ = try run("input", directory, status: 70, error: "DDI recovery is pending")
            let calls = directory.appendingPathComponent("calls.txt")
            let before = try Data(contentsOf: calls)
            _ = try run("apply", directory, status: 70, error: "DDI operation already attempted; do not replay")
            try require(try Data(contentsOf: calls) == before, "Apply replayed a mutation")
            if name == "apply-mount-after" {
                try manager.removeItem(at: directory.appendingPathComponent("transaction/candidate"))
            }
            let restored = try run("restore", directory)
            let final = try run("status", directory)
            try require(restored["phase"] as? String == "restored" && final["build"] as? String == "OLD"
                && final["recoveryPending"] as? Bool == false, "Explicit restore did not recover baseline")
            if name == "restore-cleanup" {
                try require(try Data(contentsOf: calls) == before && restored["deviceMutation"] as? Bool == false,
                            "Verified barrier cleanup remounted an image")
            }
            _ = try run("input", directory)
            try emit(["case": name, "phaseAfterKill": phase, "buildAfterKill": build,
                "pendingSurvived": true, "applyReplayRejected": true, "restoredBuild": "OLD",
                "inputAdmittedAfterRestore": true, "actualDeviceCalls": 0])
        }
    }
}

guard CommandLine.arguments.count >= 3 else { exit(64) }
if CommandLine.arguments[1] == "matrix" {
    do {
        try Matrix(root: URL(fileURLWithPath: CommandLine.arguments[2])).execute()
        print("Six native process recovery cases passed; injected file device, no phone/global DDI mutation.")
    } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    exit(0)
}

let root = URL(fileURLWithPath: CommandLine.arguments[2])
let mode = CommandLine.arguments[1]
let transaction = root.appendingPathComponent("transaction")
let control = root.appendingPathComponent("isolated-control")
let state = root.appendingPathComponent("device.json")
let calls = root.appendingPathComponent("calls.txt")

struct DeviceState: Codable {
    let physicalID: String
    let build: String?
    let version: String?
    let signature: String?
}
func pause(_ boundary: String) throws {
    try Data(boundary.utf8).write(to: root.appendingPathComponent("reached"), options: .atomic)
    while true { Thread.sleep(forTimeInterval: 0.1) }
}
final class FileDevice: DDITransactionDevice {
    private func append(_ value: String) throws {
        let handle = try FileHandle(forWritingTo: calls)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data((value + "\n").utf8)); try handle.synchronize()
    }
    func inspect(physicalID: String) throws -> NativeDDIInspection.Report {
        let value = try JSONDecoder().decode(DeviceState.self, from: Data(contentsOf: state))
        return .init(physicalID: value.physicalID, productType: "iPhone13,2", productVersion: "26.5", productBuild: "23F77",
            mountedImages: value.build.map { [.init(mountPath: "/System/Developer", isMounted: true,
                imageType: "Personalized", build: $0, version: value.version, imageSignature: value.signature)] } ?? [],
            frameworkVersion: NativeDDIInspection.frameworkVersion)
    }
    func unmount(physicalID: String) throws {
        try append("unmount")
        try encoded(DeviceState(physicalID: physicalID, build: nil, version: nil, signature: nil), to: state)
        if CommandLine.arguments.last == "after-unmount" { try pause("after-unmount") }
    }
    func mount(physicalID: String, bundle: URL) throws {
        try append("mount:" + bundle.lastPathComponent)
        if CommandLine.arguments.last == "before-mount-result" { try pause("before-mount-result") }
        let version = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("version.plist")), format: nil) as! [String: Any]
        let build = version["ProductBuildVersion"] as! String
        let image = try Data(contentsOf: bundle.appendingPathComponent("Restore/Image.dmg"))
        try encoded(DeviceState(physicalID: physicalID, build: build, version: build == "OLD" ? "397.24" : "651.32",
            signature: Data(SHA384.hash(data: image)).base64EncodedString()), to: state)
        if CommandLine.arguments.last == "after-mount-result" { try pause("after-mount-result") }
    }
}
func fixture(_ build: String, core: String) throws -> DDIBundlePreflight {
    let bundle = root.appendingPathComponent(build)
    try manager.createDirectory(at: bundle.appendingPathComponent("Restore"), withIntermediateDirectories: true)
    let image = Data((build + " fixture image").utf8), trust = Data((build + " fixture trust").utf8)
    try image.write(to: bundle.appendingPathComponent("Restore/Image.dmg"))
    try trust.write(to: bundle.appendingPathComponent("Restore/Trust"))
    let manifest: [String: Any] = ["ProductBuildVersion": build, "SupportedProductTypes": ["iPhone13,2"],
        "BuildIdentities": [["Ap,ProductType": "iPhone13,2", "Manifest": [
            "PersonalizedDMG": ["Info": ["Path": "Image.dmg", "HashMethod": "sha2-384"], "Digest": Data(SHA384.hash(data: image))],
            "LoadableTrustCache": ["Info": ["Path": "Trust"], "Digest": Data(SHA384.hash(data: trust))]]]]]
    let version: [String: Any] = ["ProductBuildVersion": build, "Platform": "iOS",
        "ProjectMetadata": [["Project": "CoreDevice", "Version": core]]]
    for (path, value) in [("version.plist", version), ("Restore/BuildManifest.plist", manifest)] {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: bundle.appendingPathComponent(path))
    }
    var hashes: [String: String] = [:]
    for path in ["version.plist", "Restore/BuildManifest.plist", "Restore/Image.dmg", "Restore/Trust"] {
        hashes[path] = DDITransactionStore.digest(try Data(contentsOf: bundle.appendingPathComponent(path)))
    }
    return try DDIBundlePreflight.inspect(bundle: bundle, source: .init(schemaVersion: 1, kind: "third-party-mirror",
        location: "https://example.invalid/fixture", revision: String(repeating: "a", count: 40), sha256: hashes), productType: "iPhone13,2")
}

do {
    switch mode {
    case "setup":
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let baseline = try fixture("OLD", core: "397.24"), candidate = try fixture("NEW", core: "651.32")
        let image = try Data(contentsOf: URL(fileURLWithPath: baseline.bundlePath).appendingPathComponent("Restore/Image.dmg"))
        let id = "12345678-1234567890ABCDEF"
        try encoded(DeviceState(physicalID: id, build: "OLD", version: "397.24",
            signature: Data(SHA384.hash(data: image)).base64EncodedString()), to: state)
        try Data().write(to: calls)
        let result = try DDITransaction.plan(physicalID: id, candidate: candidate, baseline: baseline,
            directory: transaction, device: FileDevice())
        try emit(["phase": result.journal.phase.rawValue, "inputSent": false, "deviceMutation": false])
    case "input":
        let lease = try DDIProcessLease.testLease(exclusive: false, directory: control)
        try withExtendedLifetime(lease) { try emit(["inputAdmitted": true, "inputSent": false]) }
    case "status":
        let result = try DDITransaction.status(directory: transaction)
        let pending = try DDIProcessLease.pendingRecovery(directory: control)
        try emit(["phase": result.journal.phase.rawValue, "recoveryPending": pending != nil,
            "pendingMatchesPlan": pending?.transactionPath == transaction.path && pending?.planSHA256 == result.planSHA256,
            "build": try JSONDecoder().decode(DeviceState.self, from: Data(contentsOf: state)).build ?? "none", "inputSent": false])
    case "apply", "restore":
        let status = try DDITransaction.status(directory: transaction)
        let lease = try DDIProcessLease.testLease(exclusive: true, directory: control)
        let result = try DDITransaction.execute(directory: transaction, confirmation: status.planSHA256,
            acknowledgeSourceRisk: true, restore: mode == "restore", device: FileDevice(),
            markPending: lease.markPending, clearPending: { pending in
                if CommandLine.arguments.last == "before-clear" { try pause("before-clear") }
                try lease.clearPending(pending)
            })
        try emit(["phase": result.journal.phase.rawValue, "deviceMutation": result.deviceMutation, "inputSent": false])
    default: throw DDIManagementError("Unknown isolated harness mode")
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: JSONSerialization.data(withJSONObject: ["error": "\(error)", "inputSent": false], options: [.sortedKeys]) + Data([10]))
    exit(70)
}
