import Darwin
import Foundation

/// The pane a herdr-core (`hc`) terminal keeps for its host: its address
/// and the socket of the core that owns it, read from `HC_TERMINAL_ID` and
/// `HC_TERMINAL_SOCKET`. Both come from a state document, so the pair is
/// validated before it can drive a query. The address must be a local one —
/// herdr-core resolves `machine/t7` over ssh, and Moonglade never reaches
/// another host — so only lowercase letters and digits pass, which also keeps
/// it from reading as an option. The socket is validated like Herdr's: an
/// absolute path passed only as an environment override.
public struct HerdrCoreTerminalBinding: Hashable, Sendable {
    static let maximumTerminalIDLength = 32

    public let terminalID: String
    public let socketPath: String

    public init?(terminalID: String?, socketPath: String?) {
        guard let terminalID, let socketPath,
              Self.isLocalTerminalID(terminalID),
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

    /// A local herdr-core address, such as `t2t`: never a host-qualified
    /// one, whatever separator it would use.
    static func isLocalTerminalID(_ value: String) -> Bool {
        (1...maximumTerminalIDLength).contains(value.utf8.count)
            && value.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
    }

    /// `herdr-core get` starts a core when none answers on its socket, so a
    /// query is only ever pointed at a socket that is not a link, belongs to
    /// this user, and has a core listening on it. A socket file outlives the
    /// core that bound it, so existing is not enough: a stale or planted path
    /// must not spawn a daemon.
    /// `owner` is the current user outside tests.
    package func socketIsLiveForCurrentUser(owner: uid_t = getuid()) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(socketPath, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == owner else {
            return false
        }
        // A core can still exit between this probe and the query, and herdr-core
        // has no option to fail instead of starting one; that window remains.
        return Self.acceptsConnections(at: socketPath)
    }

    /// One non-blocking connect, closed at once: a Unix-domain connect either
    /// completes against a listener or is refused, and never waits.
    private static func acceptsConnections(at path: String) -> Bool {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
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

/// Why a herdr-core query failed, which decides what it backs off.
public enum HerdrCoreQueryError: Error, Equatable, Sendable {
    /// The core could not be reached or overran its bounds — no live socket,
    /// a launch error, a timeout, output over the cap. Every terminal of the
    /// socket would fail the same way, so the whole socket backs off.
    case socketUnavailable
    /// The core answered, but not with this terminal — a non-zero exit, or an
    /// answer that does not parse or names another address, as for a closed
    /// pane a state document still references. Only that terminal backs off.
    case terminalUnavailable
}

/// Caches herdr-core's answer per terminal, the way
/// `GhosttyTerminalQueryCache` caches Ghostty's: each answer costs a
/// `herdr-core` subprocess, so the heartbeat must not pay for it on every
/// tick. A terminal seen for the first time is queried at once and a known
/// one refreshes on a TTL that keeps titles reasonably fresh. A failure waits
/// out a shorter cooldown, scoped by its cause: a terminal the core answered
/// for without it backs off alone, so its siblings keep their titles, while a
/// core that cannot be reached backs off its whole socket — a hung core would
/// otherwise cost its full deadline once per pane, every tick, on the
/// observation queue — and no other terminal of that socket is queried in the
/// same tick. Terminals and sockets no longer asked for are forgotten, which
/// bounds the cache by the live sessions.
public final class HerdrCoreTerminalQueryCache: @unchecked Sendable {
    public typealias Query = @Sendable (HerdrCoreTerminalBinding) -> Result<HerdrCoreTerminal, HerdrCoreQueryError>

    private struct Answer {
        let terminal: HerdrCoreTerminal
        let at: Date
    }

    private let timeToLive: TimeInterval
    private let failureTimeToLive: TimeInterval
    private let query: Query
    private let lock = NSLock()
    private var answers: [HerdrCoreTerminalBinding: Answer] = [:]
    private var terminalFailures: [HerdrCoreTerminalBinding: Date] = [:]
    private var socketFailures: [String: Date] = [:]

    public init(
        timeToLive: TimeInterval,
        failureTimeToLive: TimeInterval,
        query: @escaping Query
    ) {
        self.timeToLive = timeToLive
        self.failureTimeToLive = failureTimeToLive
        self.query = query
    }

    public func terminals(
        for bindings: Set<HerdrCoreTerminalBinding>,
        now: Date = Date()
    ) -> [HerdrCoreTerminalBinding: HerdrCoreTerminal] {
        let sockets = Set(bindings.map(\.socketPath))
        func coolingDown(_ failedAt: Date) -> Bool { now.timeIntervalSince(failedAt) < failureTimeToLive }
        lock.lock()
        answers = answers.filter { bindings.contains($0.key) }
        terminalFailures = terminalFailures.filter { bindings.contains($0.key) }
        socketFailures = socketFailures.filter { sockets.contains($0.key) }
        let cachedAnswers = answers
        let failedTerminals = Set(terminalFailures.filter { coolingDown($0.value) }.keys)
        var failedSockets = Set(socketFailures.filter { coolingDown($0.value) }.keys)
        lock.unlock()

        var terminals: [HerdrCoreTerminalBinding: HerdrCoreTerminal] = [:]
        var refreshed: [HerdrCoreTerminalBinding: Answer] = [:]
        var newTerminalFailures: [HerdrCoreTerminalBinding: Date] = [:]
        var newSocketFailures: [String: Date] = [:]
        for binding in bindings {
            if let answer = cachedAnswers[binding], now.timeIntervalSince(answer.at) < timeToLive {
                terminals[binding] = answer.terminal
                continue
            }
            guard !failedSockets.contains(binding.socketPath),
                  !failedTerminals.contains(binding) else { continue }
            switch query(binding) {
            case let .success(terminal):
                terminals[binding] = terminal
                refreshed[binding] = Answer(terminal: terminal, at: now)
            case .failure(.terminalUnavailable):
                newTerminalFailures[binding] = now
            case .failure(.socketUnavailable):
                failedSockets.insert(binding.socketPath)
                newSocketFailures[binding.socketPath] = now
            }
        }
        lock.lock()
        answers.merge(refreshed) { _, latest in latest }
        terminalFailures.merge(newTerminalFailures) { _, latest in latest }
        socketFailures.merge(newSocketFailures) { _, latest in latest }
        lock.unlock()
        return terminals
    }
}
