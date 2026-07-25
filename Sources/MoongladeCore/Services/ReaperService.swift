import Darwin
import Foundation

public struct ReaperResult: Equatable, Sendable {
    public let removedSessionIDs: [String]
    public let createdSessionIDs: [String]
}

public struct ReaperService: Sendable {
    /// The observation scheduler runs at this cadence. A native hook document
    /// that has been quiet for at least one full pass is verified against the
    /// detected agent set; two consecutive misses distinguish stale state
    /// from one transient per-process metadata read failure.
    public static let staleSessionInterval: TimeInterval = 5

    private let repository: StateRepository
    private let processScanner: any ProcessScanning
    private let now: @Sendable () -> Date
    private let nativeMisses = NativeSessionMissTracker()

    public init(
        repository: StateRepository,
        processScanner: any ProcessScanning = SystemProcessScanner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.processScanner = processScanner
        self.now = now
    }

    public func reap() throws -> ReaperResult {
        try reap(detected: try processScanner.activeProcesses())
    }

    /// Reaps against an already-completed scan, so callers that drive several
    /// consumers from one scan (for example the observation scheduler) do not
    /// trigger a rescan per consumer.
    public func reap(detected activeProcesses: [DetectedAgentProcess]) throws -> ReaperResult {
        try reap(detected: activeProcesses, preservingSessionIDs: [])
    }

    public func reap(
        detected activeProcesses: [DetectedAgentProcess],
        preservingSessionIDs: Set<String>
    ) throws -> ReaperResult {
        var snapshot = try repository.loadSnapshot()
        return try reap(
            detected: activeProcesses,
            preservingSessionIDs: preservingSessionIDs,
            snapshot: &snapshot
        )
    }

    package func reap(
        detected activeProcesses: [DetectedAgentProcess],
        preservingSessionIDs: Set<String>,
        snapshot: inout StateSnapshot
    ) throws -> ReaperResult {
        let sessions = snapshot.sessions
        nativeMisses.retain(sessionIDs: Set(sessions.map(\.id)))
        let activeProcessKeys = Set(activeProcesses.map(processKey))
        var removedSessionIDs: [String] = []
        var survivors: [AgentSession] = []
        for session in sessions {
            if preservingSessionIDs.contains(session.id) {
                survivors.append(session)
                continue
            }
            if shouldRemove(
                session,
                activeProcessKeys: activeProcessKeys,
                activeProcesses: activeProcesses
            ) {
                try repository.remove(session, updating: &snapshot)
                removedSessionIDs.append(session.sessionID)
            } else {
                survivors.append(session)
            }
        }
        let remaining = try rebindDaemonHostedSessions(
            survivors,
            to: activeProcesses,
            snapshot: &snapshot
        )
        let tracked = try pruneSupersededSessions(
            remaining,
            removedSessionIDs: &removedSessionIDs,
            snapshot: &snapshot
        )
        var createdSessionIDs: [String] = []
        for process in activeProcesses {
            let processKey = processKey(process)
            if let existing = tracked[processKey]
                ?? tracked.values.first(where: { processMatches($0, process) }) {
                try refreshFallback(existing, from: process, snapshot: &snapshot)
                try adoptScannedTerminal(existing, from: process, snapshot: &snapshot)
                continue
            }
            // No plugin/hook has spoken for this process yet — idle (the
            // silent baseline) beats guessing "working" and lighting the
            // spinner for what may just be a session sitting at a prompt.
            let sessionID = "reaper-\(process.processID)"
            try repository.save(AgentSession(
                tool: process.tool,
                sessionID: sessionID,
                pid: process.processID,
                processIdentity: process.processIdentity,
                status: .idle,
                cwd: process.cwd,
                startedAt: Date(),
                updatedAt: Date(),
                terminal: process.terminal,
                source: .reaper
            ), updating: &snapshot)
            createdSessionIDs.append(sessionID)
        }
        return ReaperResult(
            removedSessionIDs: removedSessionIDs.sorted(),
            createdSessionIDs: createdSessionIDs.sorted()
        )
    }

    /// Applies optional terminal enrichment after liveness reconciliation.
    /// Terminal automation must never sit in front of the reaper, so the
    /// scheduler calls this only after the basic libproc pass has completed.
    /// Missing enrichment is not evidence that a basic detection has died.
    public func applyTerminalEnrichment(
        basic: [DetectedAgentProcess],
        enriched: [DetectedAgentProcess]
    ) throws {
        var snapshot = try repository.loadSnapshot()
        try applyTerminalEnrichment(basic: basic, enriched: enriched, snapshot: &snapshot)
    }

    package func applyTerminalEnrichment(
        basic: [DetectedAgentProcess],
        enriched: [DetectedAgentProcess],
        snapshot: inout StateSnapshot
    ) throws {
        let sessions = snapshot.sessions
        for session in sessions {
            guard let process = enriched.first(where: { processMatches(session, $0) }) else { continue }
            try adoptScannedTerminal(session, from: process, snapshot: &snapshot)
        }
    }

    /// A terminal shows one session at a time, so several documents pointing
    /// at the same process describe at most one visible session. OpenCode
    /// accumulates the rest — child sessions spawned for subagents and chats
    /// abandoned inside a long-lived TUI — all rebound to the same visible
    /// process. Keep the winner per process, delete the noise.
    private func pruneSupersededSessions(
        _ sessions: [AgentSession],
        removedSessionIDs: inout [String],
        snapshot: inout StateSnapshot
    ) throws -> [String: AgentSession] {
        var tracked: [String: AgentSession] = [:]
        for session in sessions {
            let key = processKey(session)
            guard let incumbent = tracked[key] else {
                tracked[key] = session
                continue
            }
            let loser: AgentSession
            if supersedes(session, incumbent) {
                tracked[key] = session
                loser = incumbent
            } else {
                loser = session
            }
            try repository.remove(loser, updating: &snapshot)
            removedSessionIDs.append(loser.sessionID)
        }
        return tracked
    }

    /// Native documents always beat reaper fallbacks — a fallback carries no
    /// real status, only "the process exists". Among peers, freshest wins;
    /// the session identifier breaks exact timestamp ties deterministically.
    private func supersedes(_ candidate: AgentSession, _ incumbent: AgentSession) -> Bool {
        if (candidate.source == .reaper) != (incumbent.source == .reaper) {
            return incumbent.source == .reaper
        }
        if candidate.updatedAt != incumbent.updatedAt {
            return candidate.updatedAt > incumbent.updatedAt
        }
        return candidate.sessionID > incumbent.sessionID
    }

    private func shouldRemove(
        _ session: AgentSession,
        activeProcessKeys: Set<String>,
        activeProcesses: [DetectedAgentProcess]
    ) -> Bool {
        if session.status == .ended || !isAlive(session) {
            nativeMisses.clear(sessionID: session.id)
            return true
        }
        let key = processKey(session)
        if session.source == .reaper {
            return !activeProcessKeys.contains(key)
        }
        // A freshly written native document gets one full scheduler interval
        // to be correlated with its terminal. Hooks/plugins can write before
        // the scanner observes the process, so removing it earlier races a
        // legitimate startup.
        guard now().timeIntervalSince(session.updatedAt) >= Self.staleSessionInterval,
              !activeProcessKeys.contains(key) else {
            nativeMisses.clear(sessionID: session.id)
            return false
        }
        // OpenCode plugins can be hosted by a daemon rather than the visible
        // terminal process. Keep the document only when it can be rebound to
        // exactly one live same-tool process in its working directory.
        let rebindCandidates = candidatesForRebinding(session, to: activeProcesses)
        guard rebindCandidates.count != 1 else {
            nativeMisses.clear(sessionID: session.id)
            return false
        }
        // One per-process metadata read can fail while the process table is
        // changing. Require the same old native document to miss two complete
        // scans before treating its still-live PID as unrelated.
        return nativeMisses.recordMiss(sessionID: session.id) >= 2
    }

    /// Sessions written by a plugin hosted in a shared daemon (OpenCode's
    /// `opencode2 serve`) record the daemon PID, which no scan ever
    /// contains. When exactly one visible same-tool process shares the
    /// session's directory, the session adopts that PID, so fallback dedup
    /// and process liveness track the terminal the user actually sees.
    private func rebindDaemonHostedSessions(
        _ sessions: [AgentSession],
        to activeProcesses: [DetectedAgentProcess],
        snapshot: inout StateSnapshot
    ) throws -> [AgentSession] {
        let processesByTool = Dictionary(grouping: activeProcesses, by: \.tool)
        var reserved = Set<String>()
        for session in sessions {
            guard let process = activeProcesses.first(where: { processMatches(session, $0) }) else { continue }
            reserved.insert(processKey(process))
        }
        var assignments: [String: DetectedAgentProcess] = [:]
        var changed = true
        while changed {
            changed = false
            let proposals: [(AgentSession, DetectedAgentProcess)] = sessions.compactMap { session in
                guard session.source != .reaper,
                      assignments[session.id] == nil,
                      !(processesByTool[session.tool] ?? []).contains(where: { processMatches(session, $0) }) else {
                    return nil
                }
                let available = candidatesForRebinding(
                    session,
                    to: processesByTool[session.tool] ?? []
                ).filter { !reserved.contains(processKey($0)) }
                return available.count == 1 ? (session, available[0]) : nil
            }
            let claims = Dictionary(grouping: proposals, by: { processKey($0.1) })
            for (key, claimants) in claims where claimants.count == 1 {
                let (session, process) = claimants[0]
                assignments[session.id] = process
                reserved.insert(key)
                changed = true
            }
        }
        return try sessions.map { session in
            guard let process = assignments[session.id] else {
                // A legacy exact PID match safely adopts the scanned kernel
                // identity without changing its activity timestamp.
                guard session.processIdentity == nil,
                      let exact = activeProcesses.first(where: {
                          $0.tool == session.tool && $0.processID == session.pid
                      }), exact.processIdentity != nil else { return session }
                return try repository.saveEnrichment(
                    for: session,
                    process: exact,
                    terminal: nil,
                    updating: &snapshot
                ) ?? session
            }
            return try repository.saveEnrichment(
                for: session,
                process: process,
                terminal: nil,
                updating: &snapshot
            ) ?? session
        }
    }

    private func refreshFallback(
        _ session: AgentSession,
        from process: DetectedAgentProcess,
        snapshot: inout StateSnapshot
    ) throws {
        guard session.source == .reaper,
              session.terminal != process.terminal || session.cwd != process.cwd else {
            return
        }
        try repository.save(AgentSession(
            tool: session.tool,
            sessionID: session.sessionID,
            pid: session.pid,
            processIdentity: session.processIdentity,
            status: session.status,
            attentionReason: session.attentionReason,
            cwd: process.cwd,
            startedAt: session.startedAt,
            updatedAt: Date(),
            terminal: process.terminal,
            source: .reaper
        ), updating: &snapshot)
    }

    /// Hook- and plugin-written documents often lack the controlling TTY and
    /// cannot see which Ghostty surface hosts their process. The process scan
    /// supplies those exact identifiers without changing lifecycle activity.
    private func adoptScannedTerminal(
        _ session: AgentSession,
        from process: DetectedAgentProcess,
        snapshot: inout StateSnapshot
    ) throws {
        guard session.source != .reaper else { return }
        guard let session = try repository.reload(session, updating: &snapshot),
              session.source != .reaper,
              processMatches(session, process) else {
            return
        }
        let scannedTerminalID = process.terminal.ghosttyTerminalID
        let adoptsIdentifier = scannedTerminalID != nil
            && session.terminal.ghosttyTerminalID != scannedTerminalID
        let adoptsProgram = session.terminal.termProgram == nil
            && process.terminal.termProgram != nil
        let adoptsTmuxPane = session.terminal.tmuxPane == nil
            && process.terminal.tmuxPane != nil
        let adoptsTTY = session.terminal.tty == nil
            && process.terminal.tty != nil
        let adoptsTitle = session.tool != .convoy && titleMeaningfullyChanged(
            scanned: process.terminal.windowTitleHint,
            current: session.terminal.windowTitleHint
        )
        guard adoptsIdentifier || adoptsProgram || adoptsTmuxPane || adoptsTTY || adoptsTitle else {
            return
        }
        _ = try repository.saveEnrichment(
            for: session,
            process: process,
            terminal: TerminalContext(
                termProgram: process.terminal.termProgram ?? session.terminal.termProgram,
                ghosttyTerminalID: scannedTerminalID ?? session.terminal.ghosttyTerminalID,
                itermSessionID: session.terminal.itermSessionID,
                tmuxPane: session.terminal.tmuxPane ?? process.terminal.tmuxPane,
                tty: session.terminal.tty ?? process.terminal.tty,
                windowTitleHint: session.tool == .convoy
                    ? nil
                    : process.terminal.windowTitleHint ?? session.terminal.windowTitleHint
            ),
            updating: &snapshot
        )
    }

    /// Agents decorate tab titles with spinners and status emoji that churn
    /// every few seconds; comparing display-cleaned titles keeps that churn
    /// from rewriting the document — and storming the state observers — on
    /// every tick. A scan without a title never clears an existing one.
    private func titleMeaningfullyChanged(scanned: String?, current: String?) -> Bool {
        guard let scanned else { return false }
        return SessionTitleFormatter.rowTitle(tabTitle: scanned, fallback: "")
            != SessionTitleFormatter.rowTitle(tabTitle: current, fallback: "")
    }

    private func isAlive(_ session: AgentSession) -> Bool {
        guard session.pid > 0 else { return false }
        if let currentIdentity = SystemProcessScanner.processIdentity(of: session.pid) {
            return session.processIdentity.map { $0 == currentIdentity } ?? true
        }
        // A zombie has no active identity. EPERM remains conservative for a
        // process owned by another user, although integrations normally only
        // publish the current user's agents.
        return Darwin.kill(session.pid, 0) != 0 && errno == EPERM
    }

    private func processMatches(_ session: AgentSession, _ process: DetectedAgentProcess) -> Bool {
        guard session.tool == process.tool, session.pid == process.processID else { return false }
        guard let sessionIdentity = session.processIdentity,
              let detectedIdentity = process.processIdentity else { return true }
        return sessionIdentity == detectedIdentity
    }

    private func processKey(_ process: DetectedAgentProcess) -> String {
        if let identity = process.processIdentity {
            return "\(process.tool.rawValue)-\(identity.processID)-\(identity.kernelStartTimeMicroseconds)"
        }
        return "\(process.tool.rawValue)-\(process.processID)"
    }

    private func processKey(_ session: AgentSession) -> String {
        if let identity = session.processIdentity {
            return "\(session.tool.rawValue)-\(identity.processID)-\(identity.kernelStartTimeMicroseconds)"
        }
        return "\(session.tool.rawValue)-\(session.pid)"
    }

    /// Prefer a terminal identity over cwd when several agents of the same
    /// kind run in one repository. Cwd remains the fallback for daemon-hosted
    /// plugins that cannot report a tty or terminal surface.
    private func candidatesForRebinding(
        _ session: AgentSession,
        to activeProcesses: [DetectedAgentProcess]
    ) -> [DetectedAgentProcess] {
        let sameDirectory = activeProcesses.filter {
            $0.tool == session.tool && $0.cwd == session.cwd
        }
        let relationships = sameDirectory.map { process in
            (process, terminalRelationship(session.terminal, process.terminal))
        }
        let terminalMatches = relationships.compactMap { process, relationship in
            relationship == .match ? process : nil
        }
        if !terminalMatches.isEmpty { return terminalMatches }
        // A known-but-different tty or terminal surface is positive evidence
        // that cwd alone refers to another session. Fall back to cwd only
        // when neither side exposes a comparable identity.
        if relationships.contains(where: { $0.1 == .conflict }) { return [] }
        return sameDirectory
    }

    private enum TerminalRelationship {
        case match
        case conflict
        case unavailable
    }

    private func terminalRelationship(
        _ lhs: TerminalContext,
        _ rhs: TerminalContext
    ) -> TerminalRelationship {
        let identities: [(String?, String?)] = [
            (lhs.ghosttyTerminalID, rhs.ghosttyTerminalID),
            (lhs.itermSessionID, rhs.itermSessionID),
            (lhs.tmuxPane, rhs.tmuxPane),
            (lhs.tty, rhs.tty),
        ]
        for (left, right) in identities {
            guard let left, let right else { continue }
            return left == right ? .match : .conflict
        }
        return .unavailable
    }
}

private final class NativeSessionMissTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func recordMiss(sessionID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        counts[sessionID, default: 0] += 1
        return counts[sessionID, default: 0]
    }

    func clear(sessionID: String) {
        lock.lock()
        counts[sessionID] = nil
        lock.unlock()
    }

    func retain(sessionIDs: Set<String>) {
        lock.lock()
        counts = counts.filter { sessionIDs.contains($0.key) }
        lock.unlock()
    }
}
