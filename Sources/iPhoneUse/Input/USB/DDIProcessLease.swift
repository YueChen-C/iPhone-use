import Darwin
import Foundation

/// Offline management boundary. The GUI and touch workers hold shared leases;
/// image mutations require an exclusive lease and no legacy iphone-use process.
/// The fixed per-user location deliberately ignores configurable MCP state dirs.
final class DDIProcessLease {
    private let directory: URL
    private let fd: Int32
    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iPhoneUse/DDIControl")
    }
    private init(exclusive: Bool, directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        fd = try DDILocalFile.withDirectory(directory) { root in
            var info = stat()
            guard fstat(root, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw DDIManagementError("DDI control directory must be private and owned by this user")
            }
            let fd = openat(root, "input.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw DDIManagementError("Cannot open DDI input barrier") }
            var lockInfo = stat()
            guard fstat(fd, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == getuid(),
                  lockInfo.st_nlink == 1, lockInfo.st_mode & 0o077 == 0 else {
                close(fd); throw DDIManagementError("DDI barrier must be a private regular file")
            }
            return fd
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd); throw DDIManagementError("DDI management requires all app/input sessions to be stopped; no forced termination")
        }
        do {
            if !exclusive, try Self.hasPending(directory) {
                throw DDIManagementError("DDI recovery is pending; inspect \(directory.appendingPathComponent("pending.json").path) and use its transaction path/hash with the explicit local restore command before starting input")
            }
        } catch { flock(fd, LOCK_UN); close(fd); throw error }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
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
    struct Pending: Codable, Equatable { let transactionPath: String; let planSHA256: String }
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
