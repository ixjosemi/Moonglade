import Darwin
import Foundation

/// A process-scoped advisory lock shared by bundled and `swift run` builds.
/// Bundle-identifier checks cannot see an unbundled development executable;
/// the lock file gives every launch path the same identity and is released by
/// the kernel if the process exits or crashes.
public final class SingleInstanceLock: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private static let heldPathsLock = NSLock()
    nonisolated(unsafe) private static var heldPaths: Set<String> = []

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    deinit {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        _ = Darwin.close(descriptor)
        Self.releaseInProcess(path)
    }

    /// Returns nil when another process already owns the lock.
    public static func acquire(at fileURL: URL) throws -> SingleInstanceLock? {
        let path = fileURL.standardizedFileURL.path
        guard reserveInProcess(path) else { return nil }
        var keepsReservation = false
        defer {
            if !keepsReservation { releaseInProcess(path) }
        }
        let descriptor = Darwin.open(
            path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let error = posixError()
            _ = Darwin.close(descriptor)
            throw error
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid() else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EACCES)
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let error = posixError()
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN || code == EACCES {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        keepsReservation = true
        return SingleInstanceLock(descriptor: descriptor, path: path)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func reserveInProcess(_ path: String) -> Bool {
        heldPathsLock.lock()
        defer { heldPathsLock.unlock() }
        return heldPaths.insert(path).inserted
    }

    private static func releaseInProcess(_ path: String) {
        heldPathsLock.lock()
        heldPaths.remove(path)
        heldPathsLock.unlock()
    }
}
