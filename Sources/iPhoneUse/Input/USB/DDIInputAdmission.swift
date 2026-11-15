import Foundation

/// Every non-management process owns a shared lifetime lease, even if it only
/// forwards HTTP or reads device data. New owners must not enter after an
/// exclusive management scan, or restart while recovery is pending.
enum DDIInputAdmission {
    static func acquire(arguments: [String],
                        lease: () throws -> DDIProcessLease = DDIProcessLease.input) throws -> DDIProcessLease? {
        if arguments.first == "ddi" { return nil }
        return try lease()
    }
}
