import Foundation

/// Exclusive advisory lock on a file (flock), so the app, the CLI and the API server do not
/// overwrite each other's history or journal. Blocks until the lock is free.
struct FileLock {
    let url: URL

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
