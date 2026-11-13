import Darwin
import Foundation

/// Local-only management branch, before AppKit/BLE/HTTP. These two commands
/// cannot mount, unmount, pair or send input. No HTTP/MCP path accepts a bundle.
enum DDIManagementCLI {
    enum Command: Equatable {
        case inspect(String)
        case preflight(bundle: String, receipt: String, product: String)
    }
    static let usage = "Usage: iphone-use ddi inspect FULL_USB_UDID | ddi preflight ABS_BUNDLE ABS_SOURCE_RECEIPT_JSON PRODUCT_TYPE"

    static func parse(_ arguments: [String]) throws -> Command {
        if arguments.count == 2, arguments[0] == "inspect" {
            try NativeDDIInspection.validateIdentity(arguments[1])
            return .inspect(arguments[1])
        }
        if arguments.count == 4, arguments[0] == "preflight" {
            _ = try DDILocalFile.absoluteURL(arguments[1]); _ = try DDILocalFile.absoluteURL(arguments[2])
            return .preflight(bundle: arguments[1], receipt: arguments[2], product: arguments[3])
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
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let result: Data
            switch command {
            case .inspect(let physicalID):
                alarm(30)
                result = try encoder.encode(NativeDDIInspection.inspect(physicalID: physicalID))
            case let .preflight(bundle, receipt, product):
                result = try encoder.encode(DDIBundlePreflight.inspect(bundlePath: bundle, receiptPath: receipt, productType: product))
            }
            try FileHandle.standardOutput.write(contentsOf: result + Data([10]))
            return 0
        } catch { emitError(error); return 70 }
    }

    private static func emitError(_ error: Error) {
        let object: [String: Any] = ["error": "\(error)", "inputSent": false, "deviceMutation": false, "mountAuthorized": false]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? FileHandle.standardError.write(contentsOf: data + Data([10]))
        }
    }
}
