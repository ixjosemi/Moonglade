import Foundation

/// Caches the front-terminal AppleScript result so repeated observations within
/// one acknowledgment window do not spawn duplicate osascript processes. A
/// successful result remains useful for two seconds, matching the observer's
/// tab-switch polling bound; a failed query is held for five seconds.
public final class FrontTerminalQueryCache: @unchecked Sendable {
    public static let successTimeToLive: TimeInterval = 2
    public static let failureTimeToLive: TimeInterval = 5

    private let query: @Sendable () -> GhosttyFrontTerminal?
    private let successTimeToLive: TimeInterval
    private let failureTimeToLive: TimeInterval
    private let lock = NSLock()
    private var cached: GhosttyFrontTerminal?
    private var cachedAt = Date.distantPast
    private var lastQueryFailed = false

    public init(
        successTimeToLive: TimeInterval = FrontTerminalQueryCache.successTimeToLive,
        failureTimeToLive: TimeInterval = FrontTerminalQueryCache.failureTimeToLive,
        query: @escaping @Sendable () -> GhosttyFrontTerminal?
    ) {
        self.successTimeToLive = successTimeToLive
        self.failureTimeToLive = failureTimeToLive
        self.query = query
    }

    public func frontTerminal(now: Date = Date(), forceRefresh: Bool = false) -> GhosttyFrontTerminal? {
        lock.lock()
        let ttl = lastQueryFailed ? failureTimeToLive : successTimeToLive
        if !forceRefresh, now.timeIntervalSince(cachedAt) < ttl {
            let result = lastQueryFailed ? nil : cached
            lock.unlock()
            return result
        }
        lock.unlock()

        let result = query()
        lock.lock()
        cached = result
        cachedAt = now
        lastQueryFailed = result == nil
        lock.unlock()
        return result
    }

    public func invalidate() {
        lock.lock()
        cachedAt = .distantPast
        lock.unlock()
    }
}
