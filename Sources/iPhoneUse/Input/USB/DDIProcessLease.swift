import Darwin
import Foundation

/// Offline management boundary. Every non-management entry holds a shared lease;
/// image mutations require an exclusive lease and no legacy iphone-use process.
/// The fixed per-user location deliberately ignores configurable MCP state dirs.
final class DDIProcessLease {
    private let directory: URL
    private let fileLock: DDIFileLock
    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iPhoneUse/DDIControl")
    }
    private init(exclusive: Bool, directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        fileLock = try DDILocalFile.withDirectory(directory) { root in
            var info = stat()
            guard fstat(root, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw DDIManagementError("DDI control directory must be private and owned by this user")
            }
            return try DDIFileLock(directory: root, name: "input.lock", exclusive: exclusive,
                unavailable: "DDI management requires all app/input sessions to be stopped; no forced termination")
        }
        if !exclusive, try Self.hasPending(directory) {
            throw DDIManagementError("DDI recovery is pending; run iphone-use ddi recovery to discover the transaction path/hash, then review status and explicitly restore before starting input. Never delete pending.json to bypass recovery")
        }
    }
    static func input() throws -> DDIProcessLease { try DDIProcessLease(exclusive: false, directory: directory) }
    static func management() throws -> DDIProcessLease {
        let lease = try DDIProcessLease(exclusive: true, directory: directory)
        // Older binaries do not hold input.lock. Refuse rather than assume
        // their exit/release or kill unrelated user processes. MCPs also count.
        guard try otherApplicationProcesses().isEmpty else {
            throw DDIManagementError("Other iphone-use processes are running (including legacy/MCP instances); close them before offline DDI management")
        }
        return lease
    }
    /// Hold under a shared lifetime input lease. First mount and same-device
    /// USB workers must not overlap; other phones retain their own sessions.
    func deviceService(physicalID: String, exclusive: Bool) throws -> DDIFileLock {
        try NativeDDIInspection.validateIdentity(physicalID)
        return try DDILocalFile.withDirectory(directory) { root in
            try DDIFileLock(directory: root, name: "usb-" + physicalID.uppercased() + ".lock",
                            exclusive: exclusive, unavailable: "USB device is busy; retry after setup or input has stopped")
        }
    }
    struct Pending: Codable, Equatable { let transactionPath: String; let planSHA256: String }
    /// Discovery must work while pending blocks input, without acquiring an
    /// input/exclusive lease, creating a directory or clearing any barrier.
    static func pendingRecovery() throws -> Pending? { try pendingRecovery(directory: directory) }
    static func pendingRecovery(directory: URL) throws -> Pending? {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw DDIManagementError("Cannot inspect DDI recovery directory") }
            return nil
        }
        return try DDILocalFile.withDirectory(directory) { root in
            var rootInfo = stat()
            guard fstat(root, &rootInfo) == 0, rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o077 == 0 else {
                throw DDIManagementError("DDI recovery directory must be private and owned by this user")
            }
            var pendingInfo = stat()
            if fstatat(root, "pending.json", &pendingInfo, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw DDIManagementError("Cannot inspect pending DDI recovery") }
                return nil
            }
            guard pendingInfo.st_mode & S_IFMT == S_IFREG, pendingInfo.st_uid == getuid(),
                  pendingInfo.st_nlink == 1, pendingInfo.st_mode & 0o077 == 0 else {
                throw DDIManagementError("DDI recovery record must be a private regular file")
            }
            let bytes = try DDILocalFile.withFile(root: directory, path: "pending.json") { handle, size in
                var opened = stat()
                guard fstat(handle.fileDescriptor, &opened) == 0, opened.st_dev == pendingInfo.st_dev,
                      opened.st_ino == pendingInfo.st_ino, opened.st_uid == getuid(), opened.st_nlink == 1,
                      opened.st_mode & 0o077 == 0, size <= 16 * 1024 else {
                    throw DDIManagementError("DDI recovery record changed or exceeds its private metadata limit")
                }
                let data = try handle.read(upToCount: 16 * 1024 + 1) ?? Data()
                guard data.count == size else { throw DDIManagementError("DDI recovery record was truncated") }
                return data
            }
            let pending = try JSONDecoder().decode(Pending.self, from: bytes)
            _ = try DDILocalFile.absoluteURL(pending.transactionPath)
            guard pending.planSHA256.count == 64,
                  pending.planSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw DDIManagementError("Invalid DDI recovery plan hash")
            }
            return pending
        }
    }
    func markPending(_ pending: Pending) throws {
        try withStore { store in
            if try Self.hasPending(directory) {
                guard try store.read(Pending.self, name: "pending.json") == pending else {
                    throw DDIManagementError("Another DDI transaction needs recovery first")
                }
            } else { try store.write(pending, name: "pending.json") }
        }
    }
    func clearPending(_ pending: Pending) throws {
        try withStore { store in
            guard try store.read(Pending.self, name: "pending.json") == pending else {
                throw DDIManagementError("DDI recovery barrier does not match this transaction")
            }
            try DDILocalFile.withDirectory(directory) { fd in
                guard unlinkat(fd, "pending.json", 0) == 0, fsync(fd) == 0 else {
                    throw DDIManagementError("Cannot clear verified DDI recovery barrier")
                }
            }
        }
    }
    private func withStore<T>(_ body: (DDITransactionStore) throws -> T) throws -> T {
        try body(DDITransactionStore(root: directory, create: false))
    }
    // Injectable directory only for focused barrier tests, never a CLI option.
    static func testLease(exclusive: Bool, directory: URL) throws -> DDIProcessLease {
        try DDIProcessLease(exclusive: exclusive, directory: directory)
    }
    private static func hasPending(_ directory: URL) throws -> Bool {
        try DDILocalFile.withDirectory(directory) { fd in
            var info = stat()
            if fstatat(fd, "pending.json", &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw DDIManagementError("Cannot inspect pending DDI barrier") }
            return false
        }
    }
    private static func otherApplicationProcesses() throws -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { throw DDIManagementError("Cannot audit legacy app processes") }
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 64)
        var count = entries.count * MemoryLayout<kinfo_proc>.stride
        let result = entries.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &count, nil, 0) }
        guard result == 0 else { throw DDIManagementError("Cannot audit legacy app processes") }
        return entries.prefix(count / MemoryLayout<kinfo_proc>.stride).compactMap { entry in
            var entry = entry
            let name = withUnsafePointer(to: &entry.kp_proc.p_comm) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            return name == "iphone-use" && entry.kp_proc.p_pid != getpid() ? entry.kp_proc.p_pid : nil
        }
    }
}
