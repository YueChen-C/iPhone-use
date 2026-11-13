import CryptoKit
import Darwin
import Foundation

/// Private, local transaction directory. Each replacement is synced before its
/// atomic rename, then the directory is synced. Lock files are never unlinked.
final class DDITransactionStore {
    let root: URL
    private let descriptor: Int32
    private let lockDescriptor: Int32
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    init(root: URL, create: Bool) throws {
        self.root = try DDILocalFile.absoluteURL(root.path)
        if create {
            try DDILocalFile.withDirectory(root.deletingLastPathComponent()) { parent in
                guard mkdirat(parent, root.lastPathComponent, 0o700) == 0 else {
                    throw DDIManagementError("Transaction directory must be new")
                }
            }
        }
        descriptor = try DDILocalFile.withDirectory(root) { fd in
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw DDIManagementError("Transaction directory must be owned by the current user and private (0700)")
            }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw DDIManagementError("Cannot retain transaction directory") }
            return copy
        }
        let fd = openat(descriptor, "transaction.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { close(descriptor); throw DDIManagementError("Cannot open transaction lock") }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == getuid(),
              lockInfo.st_nlink == 1, lockInfo.st_mode & 0o077 == 0 else {
            close(fd); close(descriptor); throw DDIManagementError("Transaction lock must be a private regular file")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); close(descriptor); throw DDIManagementError("Transaction is already in use")
        }
        lockDescriptor = fd
    }
    deinit { flock(lockDescriptor, LOCK_UN); close(lockDescriptor); close(descriptor) }

    func write<T: Encodable>(_ value: T, name: String) throws { try write(try Self.encoded(value), name: name) }
    func write(_ data: Data, name: String) throws {
        guard !name.contains("/"), !name.hasPrefix(".") else { throw DDIManagementError("Invalid transaction record name") }
        let temporary = "." + UUID().uuidString
        let fd = openat(descriptor, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DDIManagementError("Cannot create durable transaction record") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(descriptor, temporary, 0) }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, renameat(descriptor, temporary, descriptor, name) == 0, fsync(descriptor) == 0 else {
            throw DDIManagementError("Cannot persist transaction phase; device operation refused")
        }
    }
    func read(_ name: String) throws -> Data { try DDILocalFile.metadata(root: root, path: name) }
    func read<T: Decodable>(_ type: T.Type, name: String) throws -> T { try JSONDecoder().decode(type, from: read(name)) }

    func stage(_ report: DDIBundlePreflight, name: String) throws {
        guard ["candidate", "baseline"].contains(name), mkdirat(descriptor, name, 0o700) == 0 else {
            throw DDIManagementError("DDI snapshot must be new")
        }
        let destination = root.appendingPathComponent(name)
        for file in report.files {
            let path = destination.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try DDILocalFile.withFile(root: URL(fileURLWithPath: report.bundlePath), path: file.path) { input, size in
                guard size == file.bytes else { throw DDIManagementError("DDI source changed before staging") }
                try DDILocalFile.withDirectory(path.deletingLastPathComponent()) { directory in
                    let fd = openat(directory, path.lastPathComponent, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o400)
                    guard fd >= 0 else { throw DDIManagementError("Cannot stage DDI snapshot") }
                    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? output.close() }
                    var count: UInt64 = 0
                    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                        count += UInt64(data.count)
                        guard count <= size else { throw DDIManagementError("DDI source grew during staging") }
                        try output.write(contentsOf: data)
                    }
                    guard count == size, fsync(fd) == 0, fsync(directory) == 0 else {
                        throw DDIManagementError("DDI snapshot incomplete or not durable")
                    }
                }
            }
        }
        let staged = try DDIBundlePreflight.inspect(bundle: destination, source: report.source, productType: report.productType)
        guard staged.files == report.files else { throw DDIManagementError("Staged DDI differs from preflight") }
        // Sync every directory so nested payload entries survive a process or
        // machine interruption before any device operation is permitted.
        var directories: Set<URL> = [destination]
        for file in report.files {
            var directory = destination.appendingPathComponent(file.path).deletingLastPathComponent()
            while directory.path.hasPrefix(destination.path + "/") {
                directories.insert(directory); directory.deleteLastPathComponent()
            }
        }
        for directory in directories { try DDILocalFile.withDirectory(directory) { fd in
            guard fsync(fd) == 0 else { throw DDIManagementError("Cannot sync DDI snapshot directory") }
        } }
        guard fsync(descriptor) == 0 else { throw DDIManagementError("Cannot sync transaction snapshots") }
    }
}
