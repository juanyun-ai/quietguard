import Foundation
import Darwin

struct PortableIdentity: Codable, Equatable {
    let schema: Int
    let storageID: String
    let volumeUUID: String
}
struct StorageFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Portable data stays beside the .app. No home-directory fallback, directory
// recreation, symlink following or network storage is performed at runtime.
final class PortableStore {
    let root: URL
    let identity: PortableIdentity
    let dataDirectory: URL
    private let rootDevice: dev_t
    private let rootInode: ino_t
    private let dataInode: ino_t
    private var leaseFD: Int32 = -1
    private static let allowed = Set(["settings.json", "events.jsonl", "events.previous.jsonl", "instance.lock"])
    init(root: URL, identity: PortableIdentity) throws {
        self.root = root.standardizedFileURL
        self.identity = identity
        self.dataDirectory = self.root.appendingPathComponent("Data", isDirectory: true)
        guard identity.schema == 1, UUID(uuidString: identity.storageID) != nil,
              UUID(uuidString: identity.volumeUUID) != nil else { throw StorageFailure(message: "便携配置无效") }
        let volume = try URL(fileURLWithPath: root.path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard volume?.uppercased() == identity.volumeUUID.uppercased() else { throw StorageFailure(message: "外接盘身份不匹配") }
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageFailure(message: "便携目录不可访问") }
        defer { Darwin.close(fd) }
        var rootStat = stat()
        guard fstat(fd, &rootStat) == 0 else { throw StorageFailure(message: "目录身份读取失败") }
        rootDevice = rootStat.st_dev; rootInode = rootStat.st_ino
        let d = openat(fd, "Data", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard d >= 0 else { throw StorageFailure(message: "Data 目录缺失；不会另建本机副本") }
        defer { Darwin.close(d) }
        var s = stat()
        guard fstat(d, &s) == 0, s.st_dev == rootDevice else { throw StorageFailure(message: "Data 不在同一存储卷") }
        dataInode = s.st_ino
        try withDataFD { _ in () }
    }
    deinit { if leaseFD >= 0 { Darwin.close(leaseFD) } }
    static func bundled() throws -> PortableStore {
        guard let config = Bundle.main.url(forResource: "PortableConfig", withExtension: "json") else {
            throw StorageFailure(message: "此构建缺少便携配置，请使用外接卷上的完整应用目录")
        }
        let id = try JSONDecoder().decode(PortableIdentity.self, from: Data(contentsOf: config))
        return try PortableStore(root: Bundle.main.bundleURL.deletingLastPathComponent(), identity: id)
    }
    private func fail(_ text: String) -> StorageFailure { StorageFailure(message: text) }
    private static func readFD(_ fd: Int32, maximum: Int) throws -> Data {
        var s = stat()
        guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG,
              s.st_nlink == 1, s.st_size >= 0, s.st_size <= maximum else {
            throw StorageFailure(message: "拒绝非普通文件、硬链接或超限文件")
        }
        var out = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw StorageFailure(message: "读取失败") }
            if n == 0 { return out }
            out.append(contentsOf: buffer.prefix(n))
            guard out.count <= maximum else { throw StorageFailure(message: "文件超过读取上限") }
        }
    }
    private func withDataFD<T>(_ body: (Int32) throws -> T) throws -> T {
        // Re-query rather than relying on cached URL volume metadata.
        let v = try URL(fileURLWithPath: root.path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard v?.uppercased() == identity.volumeUUID.uppercased() else { throw fail("外接存储卷不可用或身份改变") }
        let r = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard r >= 0 else { throw fail("外接目录不可用") }
        defer { Darwin.close(r) }
        var info = stat()
        guard fstat(r, &info) == 0, info.st_dev == rootDevice, info.st_ino == rootInode else { throw fail("便携目录已被替换或移动") }
        let marker = openat(r, "QuietGuard.portable.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard marker >= 0 else { throw fail("便携标识缺失") }
        defer { Darwin.close(marker) }
        let loaded = try JSONDecoder().decode(PortableIdentity.self, from: Self.readFD(marker, maximum: 4096))
        guard loaded == identity else { throw fail("便携标识不匹配") }
        let d = openat(r, "Data", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard d >= 0 else { throw fail("外接 Data 目录不可用") }
        defer { Darwin.close(d) }
        var ds = stat()
        guard fstat(d, &ds) == 0, ds.st_dev == rootDevice, ds.st_ino == dataInode else { throw fail("数据目录身份已改变") }
        return try body(d)
    }
    func validate() throws { try withDataFD { _ in () } }
    func acquireLease() throws {
        if leaseFD >= 0 { return }
        try withDataFD { d in
            let fd = openat(d, "instance.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw fail("无法获取单实例锁") }
            var s = stat()
            guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd); throw fail("已有长安实例运行，或锁文件不安全")
            }
            leaseFD = fd
        }
    }
    func read(_ name: String, maximum: Int = 1_100_000) throws -> Data? {
        guard Self.allowed.contains(name) else { throw fail("不允许的数据文件名") }
        return try withDataFD { d in
            let fd = openat(d, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 && errno == ENOENT { return nil }
            guard fd >= 0 else { throw fail("数据文件不可安全读取") }
            defer { Darwin.close(fd) }
            return try Self.readFD(fd, maximum: maximum)
        }
    }
    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw fail("外接盘写入失败") }
                sent += n
            }
        }
        guard fsync(fd) == 0 else { throw fail("外接盘同步失败") }
    }
    func saveSettings(_ data: Data) throws {
        guard data.count <= 1_000_000 else { throw fail("配置大小超限") }
        try withDataFD { d in
            // Validate existing destination; never overwrite a symlink/hard link.
            let existing = openat(d, "settings.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if existing >= 0 {
                defer { Darwin.close(existing) }
                _ = try Self.readFD(existing, maximum: 1_000_000)
            } else if errno != ENOENT { throw fail("配置目标不安全") }
            let temp = ".settings-" + UUID().uuidString + ".tmp"
            let fd = openat(d, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw fail("无法建立外接盘临时配置") }
            defer { Darwin.close(fd); unlinkat(d, temp, 0) }
            try writeAll(data, fd: fd)
            guard renameat(d, temp, d, "settings.json") == 0 else { throw fail("原子保存配置失败") }
        }
    }
    func appendEvent(_ data: Data) throws {
        guard data.count <= 64000 else { throw fail("日志条目超限") }
        try withDataFD { d in
            var s = stat()
            if fstatat(d, "events.jsonl", &s, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1 else { throw fail("日志目标不安全") }
                if s.st_size > 1_000_000 {
                    guard renameat(d, "events.jsonl", d, "events.previous.jsonl") == 0 else { throw fail("日志轮转失败") }
                }
            } else if errno != ENOENT { throw fail("日志状态不可读") }
            let fd = openat(d, "events.jsonl", O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw fail("外接日志无法打开") }
            defer { Darwin.close(fd) }
            var check = stat()
            guard fstat(fd, &check) == 0, (check.st_mode & S_IFMT) == S_IFREG, check.st_nlink == 1 else { throw fail("日志身份不安全") }
            try writeAll(data, fd: fd)
        }
    }
}

enum PortableRuntime {
    static let result: Result<PortableStore, Error> = Result { try PortableStore.bundled() }
    static var store: PortableStore? { try? result.get() }
}
