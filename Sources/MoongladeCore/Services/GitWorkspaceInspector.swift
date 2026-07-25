import Foundation

private func normalizedAbsolutePath(_ path: String) -> String? {
    guard !path.isEmpty,
          !path.utf8.contains(0),
          (path as NSString).isAbsolutePath else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
}

/// Resolves the git branch a session works on by reading `.git`/`HEAD`
/// directly — no `git` subprocess, so the menu can call it per row.
public enum GitWorkspaceInspector {
    private static let referencePrefix = "ref: refs/heads/"
    private static let worktreePointerPrefix = "gitdir: "

    public static func branchName(forWorkingDirectory path: String) -> String? {
        guard let path = normalizedAbsolutePath(path) else { return nil }
        var directory = URL(fileURLWithPath: path, isDirectory: true)
        // Bounded walk toward the filesystem root; PATH_MAX-deep repos are
        // not a thing worth supporting.
        for _ in 0..<64 {
            guard !Task.isCancelled else { return nil }
            if let head = headContents(gitEntry: directory.appendingPathComponent(".git")) {
                return branch(fromHead: head)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
        return nil
    }

    private static func headContents(gitEntry: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory)
        else { return nil }
        let headURL: URL
        if isDirectory.boolValue {
            headURL = gitEntry.appendingPathComponent("HEAD")
        } else {
            // A linked worktree's `.git` is a one-line file pointing at the
            // repository's `.git/worktrees/<name>` metadata directory.
            guard let pointer = try? String(contentsOf: gitEntry, encoding: .utf8),
                  let firstLine = pointer.split(separator: "\n").first,
                  firstLine.hasPrefix(worktreePointerPrefix)
            else { return nil }
            let metadataPath = String(firstLine.dropFirst(worktreePointerPrefix.count))
            headURL = URL(fileURLWithPath: metadataPath).appendingPathComponent("HEAD")
        }
        return try? String(contentsOf: headURL, encoding: .utf8)
    }

    private static func branch(fromHead head: String) -> String? {
        guard let firstLine = head.split(separator: "\n").first else { return nil }
        if firstLine.hasPrefix(referencePrefix) {
            return String(firstLine.dropFirst(referencePrefix.count))
        }
        // Detached HEAD stores a raw commit hash; show the short form.
        return String(firstLine.prefix(7))
    }
}

/// Coalesces branch reads for rows sharing a working directory and admits a
/// fixed number of filesystem probes at once. The bounded LRU includes misses
/// so sessions outside repositories cannot repeatedly walk to the root.
public actor GitBranchResolutionCoordinator {
    public typealias Resolver = @Sendable (String) -> String?

    private struct CacheEntry {
        let branchName: String?
        var lastAccess: UInt64
    }

    private struct Job {
        let token: UUID
        var continuations: [UUID: CheckedContinuation<String?, Never>]
        var task: Task<Void, Never>?
    }

    private let maximumConcurrentResolutions: Int
    private let maximumCacheEntries: Int
    private let resolver: Resolver
    private var cache: [String: CacheEntry] = [:]
    private var jobs: [String: Job] = [:]
    private var queuedPaths: [String] = []
    private var activeTokens: Set<UUID> = []
    private var accessSequence: UInt64 = 0

    public init(
        maximumConcurrentResolutions: Int = 4,
        maximumCacheEntries: Int = 128,
        resolver: @escaping Resolver = { path in
            GitWorkspaceInspector.branchName(forWorkingDirectory: path)
        }
    ) {
        self.maximumConcurrentResolutions = max(1, maximumConcurrentResolutions)
        self.maximumCacheEntries = max(1, maximumCacheEntries)
        self.resolver = resolver
    }

    public func branchName(forWorkingDirectory rawPath: String) async -> String? {
        guard let path = normalizedAbsolutePath(rawPath) else { return nil }
        if var cached = cache[path] {
            accessSequence &+= 1
            cached.lastAccess = accessSequence
            cache[path] = cached
            return cached.branchName
        }

        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(path: path, requestID: requestID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelRequest(path: path, requestID: requestID) }
        }
    }

    private func enqueue(
        path: String,
        requestID: UUID,
        continuation: CheckedContinuation<String?, Never>
    ) {
        if var job = jobs[path] {
            job.continuations[requestID] = continuation
            jobs[path] = job
        } else {
            jobs[path] = Job(
                token: UUID(),
                continuations: [requestID: continuation],
                task: nil
            )
            queuedPaths.append(path)
        }
        scheduleQueuedJobs()
    }

    private func scheduleQueuedJobs() {
        while activeTokens.count < maximumConcurrentResolutions,
              !queuedPaths.isEmpty {
            let path = queuedPaths.removeFirst()
            guard var job = jobs[path], job.task == nil, !job.continuations.isEmpty else {
                continue
            }
            let token = job.token
            let resolver = resolver
            activeTokens.insert(token)
            job.task = Task.detached(priority: .utility) {
                let result = Task.isCancelled ? nil : resolver(path)
                await self.complete(path: path, token: token, result: result)
            }
            jobs[path] = job
        }
    }

    private func cancelRequest(path: String, requestID: UUID) {
        guard var job = jobs[path],
              let continuation = job.continuations.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: nil)
        if job.continuations.isEmpty {
            job.task?.cancel()
            jobs.removeValue(forKey: path)
            scheduleQueuedJobs()
        } else {
            jobs[path] = job
        }
    }

    private func complete(path: String, token: UUID, result: String?) {
        guard activeTokens.remove(token) != nil else { return }
        if let job = jobs[path], job.token == token {
            jobs.removeValue(forKey: path)
            cacheResult(result, for: path)
            for continuation in job.continuations.values {
                continuation.resume(returning: result)
            }
        }
        scheduleQueuedJobs()
    }

    private func cacheResult(_ result: String?, for path: String) {
        accessSequence &+= 1
        cache[path] = CacheEntry(branchName: result, lastAccess: accessSequence)
        guard cache.count > maximumCacheEntries,
              let leastRecentlyUsedPath = cache.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              })?.key else { return }
        cache.removeValue(forKey: leastRecentlyUsedPath)
    }
}
