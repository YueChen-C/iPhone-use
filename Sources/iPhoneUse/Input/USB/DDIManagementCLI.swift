import Darwin
import Foundation

/// Local-only management branch, before AppKit/BLE/HTTP. Mutations require an
/// offline exclusive lease plus plan-bound source-risk acknowledgement.
enum DDIManagementCLI {
    enum Command: Equatable {
        case inspect(String)
        case preflight(bundle: String, receipt: String, product: String)
        case plan(device: String, candidate: String, candidateReceipt: String, baseline: String, baselineReceipt: String, directory: String)
        case status(String)
        case execute(directory: String, confirmation: String, restore: Bool)
    }
    static let usage = "Usage: iphone-use ddi inspect FULL_USB_UDID | ddi preflight ABS_BUNDLE ABS_RECEIPT PRODUCT_TYPE | ddi plan FULL_USB_UDID ABS_CANDIDATE ABS_RECEIPT ABS_BASELINE ABS_RECEIPT ABS_NEW_TRANSACTION | ddi status ABS_TRANSACTION | ddi apply|restore ABS_TRANSACTION --confirm PLAN_SHA256 --acknowledge-source-risk"

    static func parse(_ arguments: [String]) throws -> Command {
        if arguments.count == 2, arguments[0] == "inspect" {
            try NativeDDIInspection.validateIdentity(arguments[1])
            return .inspect(arguments[1])
        }
        if arguments.count == 4, arguments[0] == "preflight" {
            _ = try DDILocalFile.absoluteURL(arguments[1]); _ = try DDILocalFile.absoluteURL(arguments[2])
            return .preflight(bundle: arguments[1], receipt: arguments[2], product: arguments[3])
        }
        if arguments.count == 7, arguments[0] == "plan" {
            try NativeDDIInspection.validateIdentity(arguments[1])
            for path in arguments.dropFirst(2) { _ = try DDILocalFile.absoluteURL(path) }
            return .plan(device: arguments[1], candidate: arguments[2], candidateReceipt: arguments[3],
                         baseline: arguments[4], baselineReceipt: arguments[5], directory: arguments[6])
        }
        if arguments.count == 2, arguments[0] == "status" {
            _ = try DDILocalFile.absoluteURL(arguments[1]); return .status(arguments[1])
        }
        if arguments.count == 5, ["apply", "restore"].contains(arguments[0]), arguments[2] == "--confirm",
           arguments[4] == "--acknowledge-source-risk", arguments[3].count == 64,
           arguments[3].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            _ = try DDILocalFile.absoluteURL(arguments[1])
            return .execute(directory: arguments[1], confirmation: arguments[3], restore: arguments[0] == "restore")
        }
        throw DDIManagementError(usage)
    }

    static func run(arguments: [String]) -> Int32 {
        let command: Command
        do { command = try parse(arguments) }
        catch { emitError(error); return 64 }
        // Process-wide deadline belongs only to this early CLI branch, not GUI.
        signal(SIGALRM, SIG_DFL); alarm(120)
        defer { alarm(0) }
        var deviceMutationPossible = false
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let result: Data
            switch command {
            case .inspect(let physicalID):
                alarm(30)
                result = try encoder.encode(NativeDDIInspection.inspect(physicalID: physicalID))
            case let .preflight(bundle, receipt, product):
                result = try encoder.encode(DDIBundlePreflight.inspect(bundlePath: bundle, receiptPath: receipt, productType: product))
            case let .plan(device, candidate, candidateReceipt, baseline, baselineReceipt, directory):
                alarm(240)
                let adapter = NativeDDITransactionDevice()
                let identity = try adapter.inspect(physicalID: device)
                let next = try DDIBundlePreflight.inspect(bundlePath: candidate, receiptPath: candidateReceipt, productType: identity.productType)
                let previous = try DDIBundlePreflight.inspect(bundlePath: baseline, receiptPath: baselineReceipt, productType: identity.productType)
                result = try encoder.encode(DDITransaction.plan(physicalID: device, candidate: next, baseline: previous,
                    directory: URL(fileURLWithPath: directory), device: adapter))
            case .status(let directory):
                result = try encoder.encode(DDITransaction.status(directory: URL(fileURLWithPath: directory)))
            case let .execute(directory, confirmation, restore):
                alarm(300)
                let lease = try DDIProcessLease.management()
                deviceMutationPossible = true
                result = try encoder.encode(DDITransaction.execute(directory: URL(fileURLWithPath: directory),
                    confirmation: confirmation, acknowledgeSourceRisk: true, restore: restore,
                    device: NativeDDITransactionDevice(), markPending: lease.markPending, clearPending: lease.clearPending))
            }
            try FileHandle.standardOutput.write(contentsOf: result + Data([10]))
            return 0
        } catch { emitError(error, deviceMutationPossible: deviceMutationPossible); return 70 }
    }

    private static func emitError(_ error: Error, deviceMutationPossible: Bool = false) {
        let object: [String: Any] = ["error": "\(error)", "inputSent": false,
            "deviceMutationPossible": deviceMutationPossible, "automaticReplay": false]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? FileHandle.standardError.write(contentsOf: data + Data([10]))
        }
    }
}
