import Foundation
import Darwin

enum SecureFileReaderError: Error, Equatable, Sendable {
    case insecure
    case tooLarge
    case changedWhileReading
}

enum SecureFileReader {
    static let defaultMaximumSize = 1_048_576

    static func read(
        at url: URL,
        maximumSize: Int = defaultMaximumSize,
        requiredPermissions: mode_t? = nil,
        followSymlinks: Bool = true
    ) throws -> Data {
        let flags = O_RDONLY | O_NONBLOCK | (followSymlinks ? 0 : O_NOFOLLOW)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var initialMetadata = stat()
        guard Darwin.fstat(descriptor, &initialMetadata) == 0,
              isSecure(initialMetadata, maximumSize: maximumSize, requiredPermissions: requiredPermissions)
        else { throw SecureFileReaderError.insecure }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= maximumSize {
            let remaining = maximumSize + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }

        var finalMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              isSecure(finalMetadata, maximumSize: maximumSize, requiredPermissions: requiredPermissions)
        else { throw SecureFileReaderError.insecure }
        guard data.count <= maximumSize,
              finalMetadata.st_size == data.count,
              sameFingerprint(initialMetadata, finalMetadata)
        else { throw SecureFileReaderError.changedWhileReading }
        return data
    }

    private static func isSecure(
        _ metadata: stat,
        maximumSize: Int,
        requiredPermissions: mode_t?
    ) -> Bool {
        let permissionsAreValid = requiredPermissions.map {
            metadata.st_mode & 0o7777 == $0
        } ?? (metadata.st_mode & 0o022 == 0)
        return metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == getuid()
            && permissionsAreValid
            && metadata.st_size >= 0
            && metadata.st_size <= maximumSize
    }

    private static func sameFingerprint(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

enum SecureFileWriter {
    static func writeIfAbsent(
        _ data: Data,
        to destinationURL: URL,
        permissions: mode_t = 0o600
    ) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try writeTemporary(data, to: temporaryURL, permissions: permissions)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard Darwin.link(temporaryURL.path, destinationURL.path) == 0 else {
            if errno == EEXIST { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func writeAtomically(
        _ data: Data,
        to destinationURL: URL,
        permissions: mode_t = 0o600
    ) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try writeTemporary(data, to: temporaryURL, permissions: permissions)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func writeTemporary(
        _ data: Data,
        to temporaryURL: URL,
        permissions: mode_t
    ) throws {
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            permissions
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
