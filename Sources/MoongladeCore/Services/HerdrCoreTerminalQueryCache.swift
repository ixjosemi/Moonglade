import Darwin
import Foundation

/// The pane a herdr-core (`hc`) terminal keeps for its host: its address
/// and the socket of the core that owns it, read from `HC_TERMINAL_ID` and
/// `HC_TERMINAL_SOCKET`. Both come from a state document, so the pair is
/// validated exactly like a Herdr pane binding before it can drive a query:
/// the address is passed as one argument and must not read as an option, and
/// the socket is an absolute path passed only as an environment override.
public struct HerdrCoreTerminalBinding: Hashable, Sendable {
    public let terminalID: String
    public let socketPath: String

    public init?(terminalID: String?, socketPath: String?) {
        guard let terminalID, let socketPath,
              FocusPlanner.validHerdrPaneID(terminalID),
              FocusPlanner.validHerdrSocketPath(socketPath) else {
            return nil
        }
        self.terminalID = terminalID
        self.socketPath = socketPath
    }

    public init?(_ terminal: TerminalContext) {
        self.init(
            terminalID: terminal.herdrCoreTerminalID,
            socketPath: terminal.herdrCoreSocketPath
        )
    }

    /// `herdr-core get` starts a core when none answers on its socket, so a
    /// query is only ever pointed at a socket that already exists, is not a
    /// link, and belongs to this user — a stale or planted path must not
    /// spawn a daemon.
    package func socketBelongsToCurrentUser() -> Bool {
        var metadata = stat()
        return Darwin.lstat(socketPath, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFSOCK
            && metadata.st_uid == getuid()
    }
}

/// The fields Moonglade reads from `herdr-core get --json`: the address the
/// answer is about, the title the agent gave its pane, and the pane's
/// foreground process. Everything else in the answer is ignored.
public struct HerdrCoreTerminal: Equatable, Sendable {
    /// Titles are display text; anything longer or carrying control
    /// characters is not a title an agent set, and would not fit the
    /// enrichment overlay's bounded size either.
    static let maximumTitleBytes = 1_024

    public let address: String
    public let title: String?
    public let foregroundProcessID: Int32?

    public init(address: String, title: String?, foregroundProcessID: Int32?) {
        self.address = address
        self.title = title
        self.foregroundProcessID = foregroundProcessID
    }

    /// herdr-core reports failures as `{"error": …}` and may exit 0 doing
    /// so; an answer without the requested address is therefore a failure,
    /// never an empty terminal.
    package static func parse(_ output: Data, for binding: HerdrCoreTerminalBinding) throws -> HerdrCoreTerminal {
        let answer = try JSONDecoder().decode(Answer.self, from: output)
        guard answer.address == binding.terminalID else {
            throw POSIXError(.EBADMSG)
        }
        if let processID = answer.foreground?.pid, processID <= 0 {
            throw POSIXError(.EBADMSG)
        }
        return HerdrCoreTerminal(
            address: answer.address,
            title: answer.title.flatMap(validTitle),
            foregroundProcessID: answer.foreground?.pid
        )
    }

    private static func validTitle(_ title: String) -> String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= maximumTitleBytes,
              title.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return title
    }

    private struct Answer: Decodable {
        struct Foreground: Decodable {
            let pid: Int32?
        }

        let address: String
        let title: String?
        let foreground: Foreground?
    }
}

/// Caches herdr-core's answer per terminal, the way
/// `GhosttyTerminalQueryCache` caches Ghostty's: each answer costs a
/// `herdr-core` subprocess, so the heartbeat must not pay for it on every
/// tick. A terminal seen for the first time is queried at once, a known one
/// refreshes on a TTL that keeps titles reasonably fresh, and a failed query
/// waits out a shorter cooldown so a stalled core cannot consume the
/// observation queue. Terminals no longer asked for are forgotten, which
/// bounds the cache by the live sessions.
public final class HerdrCoreTerminalQueryCache: @unchecked Sendable {
    private enum Entry {
        case answered(HerdrCoreTerminal, at: Date)
        case failed(at: Date)
    }

    private let timeToLive: TimeInterval
    private let failureTimeToLive: TimeInterval
    private let query: @Sendable (HerdrCoreTerminalBinding) -> HerdrCoreTerminal?
    private let lock = NSLock()
    private var entries: [HerdrCoreTerminalBinding: Entry] = [:]

    public init(
        timeToLive: TimeInterval,
        failureTimeToLive: TimeInterval,
        query: @escaping @Sendable (HerdrCoreTerminalBinding) -> HerdrCoreTerminal?
    ) {
        self.timeToLive = timeToLive
        self.failureTimeToLive = failureTimeToLive
        self.query = query
    }

    public func terminals(
        for bindings: Set<HerdrCoreTerminalBinding>,
        now: Date = Date()
    ) -> [HerdrCoreTerminalBinding: HerdrCoreTerminal] {
        lock.lock()
        entries = entries.filter { bindings.contains($0.key) }
        let cached = entries
        lock.unlock()

        var terminals: [HerdrCoreTerminalBinding: HerdrCoreTerminal] = [:]
        var refreshed: [HerdrCoreTerminalBinding: Entry] = [:]
        for binding in bindings {
            switch cached[binding] {
            case let .answered(terminal, at) where now.timeIntervalSince(at) < timeToLive:
                terminals[binding] = terminal
            case let .failed(at) where now.timeIntervalSince(at) < failureTimeToLive:
                continue
            default:
                if let terminal = query(binding) {
                    terminals[binding] = terminal
                    refreshed[binding] = .answered(terminal, at: now)
                } else {
                    refreshed[binding] = .failed(at: now)
                }
            }
        }
        lock.lock()
        entries.merge(refreshed) { _, latest in latest }
        lock.unlock()
        return terminals
    }
}
