import Foundation

/// Remembers which Ghostty surface each agent process was matched to, so
/// later scans keep the match even after every title signal has drifted
/// away. Entries for processes no longer visible are dropped on each
/// remember pass — pid recycling cannot resurrect a stale assignment.
public final class GhosttyAssignmentMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var assignmentsByProcessKey: [String: String] = [:]

    public init() {}

    public func assignments() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return assignmentsByProcessKey
    }

    public func remember(_ matched: [DetectedAgentProcess]) {
        let current = Dictionary(
            uniqueKeysWithValues: matched.compactMap { process in
                process.terminal.ghosttyTerminalID.map {
                    (GhosttySessionMatcher.assignmentKey(for: process), $0)
                }
            }
        )
        lock.lock()
        assignmentsByProcessKey = current
        lock.unlock()
    }
}

/// Caches the answer to "which terminals does Ghostty show right now".
/// Each query spawns osascript (~50 ms of CPU) and makes Ghostty service
/// Apple Events, so the observation heartbeat must not pay for it on every
/// tick. The cache refreshes immediately when the set of Ghostty-hosted
/// agent processes changes — a new session needs its terminal right away —
/// and otherwise ages out on a TTL that keeps tab titles reasonably fresh.
/// Failed queries use a shorter TTL so a stalled osascript cannot consume the
/// observation queue on every tick.
public final class GhosttyTerminalQueryCache: @unchecked Sendable {
    private let timeToLive: TimeInterval
    private let failureTimeToLive: TimeInterval
    private let query: @Sendable () -> [GhosttyTerminal]?
    private let lock = NSLock()
    private var cachedTerminals: [GhosttyTerminal]?
    private var cachedProcessKeys: Set<String> = []
    private var refreshedAt: Date = .distantPast
    private var failedProcessKeys: Set<String>?
    private var failedAt: Date = .distantPast

    public init(
        timeToLive: TimeInterval,
        failureTimeToLive: TimeInterval,
        query: @escaping @Sendable () -> [GhosttyTerminal]?
    ) {
        self.timeToLive = timeToLive
        self.failureTimeToLive = failureTimeToLive
        self.query = query
    }

    public func terminals(
        hostingProcessIDs processIDs: Set<pid_t>,
        processGenerationKeys: Set<String> = [],
        now: Date = Date()
    ) -> [GhosttyTerminal]? {
        let processKeys = processGenerationKeys.isEmpty
            ? Set(processIDs.map(String.init))
            : processGenerationKeys
        lock.lock()
        if let cachedTerminals,
           processKeys == cachedProcessKeys,
           now.timeIntervalSince(refreshedAt) < timeToLive {
            lock.unlock()
            return cachedTerminals
        }
        if let failedProcessKeys,
           processKeys == failedProcessKeys,
           now.timeIntervalSince(failedAt) < failureTimeToLive {
            lock.unlock()
            return nil
        }
        lock.unlock()
        guard let refreshed = query() else {
            lock.lock()
            failedProcessKeys = processKeys
            failedAt = now
            lock.unlock()
            return nil
        }
        lock.lock()
        cachedTerminals = refreshed
        cachedProcessKeys = processKeys
        refreshedAt = now
        failedProcessKeys = nil
        lock.unlock()
        return refreshed
    }
}
