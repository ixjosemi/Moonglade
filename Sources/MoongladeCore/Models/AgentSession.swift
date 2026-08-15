import Foundation

public enum AgentSessionError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

public enum AgentTool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case convoy
    case opencode
    case pi
}

public enum SessionStatus: String, Codable, Sendable {
    case working
    case needsAttention = "needs_attention"
    case idle
    case ended
}

public enum AttentionReason: String, Codable, Sendable {
    case permission
    case turnComplete = "turn_complete"
}

public enum SessionSource: String, Codable, Sendable {
    case reaper
}

/// A PID names a process only until the kernel recycles it. Pairing it with
/// the kernel's creation timestamp gives persisted sessions a stable process
/// generation to reconcile against.
public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public let processID: Int32
    public let kernelStartTimeMicroseconds: UInt64

    public init(processID: Int32, kernelStartTimeMicroseconds: UInt64) {
        self.processID = processID
        self.kernelStartTimeMicroseconds = kernelStartTimeMicroseconds
    }

    enum CodingKeys: String, CodingKey {
        case processID = "pid"
        case kernelStartTimeMicroseconds = "kernel_start_time_us"
    }
}

public struct TerminalContext: Codable, Equatable, Sendable {
    public let termProgram: String?
    /// Orca's stable terminal identity. It is meaningful only when the
    /// hosting terminal is Orca and is used instead of cwd or tmux guesses.
    public let orcaTerminalHandle: String?
    public let ghosttyTerminalID: String?
    /// cmux reports `TERM_PROGRAM=ghostty` but is a separate application
    /// (`com.cmuxterm.app`), so its surface ID is the only signal that
    /// distinguishes it from an actual Ghostty surface. cmux also exports
    /// this value as the legacy `CMUX_PANEL_ID`; Moonglade reads only the
    /// canonical name.
    public let cmuxSurfaceID: String?
    /// Herdr's exact pane identity. It is meaningful only together with the
    /// socket path below; neither value is used as a fallback terminal hint.
    public let herdrPaneID: String?
    public let herdrSocketPath: String?
    public let itermSessionID: String?
    public let tmuxPane: String?
    public let tty: String?
    public let windowTitleHint: String?

    public init(
        termProgram: String? = nil,
        orcaTerminalHandle: String? = nil,
        ghosttyTerminalID: String? = nil,
        cmuxSurfaceID: String? = nil,
        herdrPaneID: String? = nil,
        herdrSocketPath: String? = nil,
        itermSessionID: String? = nil,
        tmuxPane: String? = nil,
        tty: String? = nil,
        windowTitleHint: String? = nil
    ) {
        self.termProgram = termProgram
        self.orcaTerminalHandle = orcaTerminalHandle
        self.ghosttyTerminalID = ghosttyTerminalID
        self.cmuxSurfaceID = cmuxSurfaceID
        self.herdrPaneID = herdrPaneID
        self.herdrSocketPath = herdrSocketPath
        self.itermSessionID = itermSessionID
        self.tmuxPane = tmuxPane
        self.tty = tty
        self.windowTitleHint = windowTitleHint
    }

    enum CodingKeys: String, CodingKey {
        case termProgram = "term_program"
        case orcaTerminalHandle = "orca_terminal_handle"
        case ghosttyTerminalID = "ghostty_terminal_id"
        case cmuxSurfaceID = "cmux_surface_id"
        case herdrPaneID = "herdr_pane_id"
        case herdrSocketPath = "herdr_socket_path"
        case itermSessionID = "iterm_session_id"
        case tmuxPane = "tmux_pane"
        case tty
        case windowTitleHint = "window_title_hint"
    }

    /// Applies identifiers exported by the current integration. Host-owned
    /// Orca and Herdr identity is intentionally not carried forward here: the
    /// repository preserves a known target only when the lifecycle process
    /// matches.
    public func mergingEnvironment(_ environment: [String: String]) -> TerminalContext {
        func value(_ key: String) -> String? {
            guard let candidate = environment[key], !candidate.isEmpty else { return nil }
            return candidate
        }

        let capturedTermProgram = value("TERM_PROGRAM") ?? termProgram
        return TerminalContext(
            termProgram: capturedTermProgram,
            orcaTerminalHandle: capturedTermProgram?.lowercased() == "orca"
                ? value("ORCA_TERMINAL_HANDLE")
                : nil,
            ghosttyTerminalID: ghosttyTerminalID,
            cmuxSurfaceID: value("CMUX_SURFACE_ID") ?? cmuxSurfaceID,
            herdrPaneID: value("HERDR_PANE_ID"),
            herdrSocketPath: value("HERDR_SOCKET_PATH"),
            itermSessionID: value("ITERM_SESSION_ID") ?? itermSessionID,
            tmuxPane: value("TMUX_PANE") ?? tmuxPane,
            tty: value("MOONGLADE_TTY") ?? tty,
            windowTitleHint: windowTitleHint
        )
    }
}

public struct AgentSession: Codable, Identifiable, Equatable, Sendable {
    public let schemaVersion: Int
    public let tool: AgentTool
    public let sessionID: String
    public let pid: Int32
    public let processIdentity: ProcessIdentity?
    public let status: SessionStatus
    public let attentionReason: AttentionReason?
    public let cwd: String
    public let startedAt: Date
    public let updatedAt: Date
    public let terminal: TerminalContext
    public let source: SessionSource?
    /// The pipeline step a convoy run is currently executing; nil for
    /// conversational tools, which have no notion of a step.
    public let currentStep: String?
    /// The name the agent gave this session, reported by its own integration.
    /// Unlike `terminal.windowTitleHint` it cannot point at the wrong pane, so
    /// it outranks the scraped tab title for display and for surface matching.
    /// Nil until the agent names the session, and for tools that never do.
    public let sessionTitle: String?

    public var id: String { "\(tool.rawValue)-\(sessionID)" }
    public var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }

    public func replacingProcessID(_ processID: Int32) -> AgentSession {
        AgentSession(
            schemaVersion: schemaVersion,
            tool: tool,
            sessionID: sessionID,
            pid: processID,
            processIdentity: nil,
            status: status,
            attentionReason: attentionReason,
            cwd: cwd,
            startedAt: startedAt,
            updatedAt: updatedAt,
            terminal: terminal,
            source: source,
            currentStep: currentStep,
            sessionTitle: sessionTitle
        )
    }

    public func replacingTerminal(_ terminal: TerminalContext) -> AgentSession {
        AgentSession(
            schemaVersion: schemaVersion,
            tool: tool,
            sessionID: sessionID,
            pid: pid,
            processIdentity: processIdentity,
            status: status,
            attentionReason: attentionReason,
            cwd: cwd,
            startedAt: startedAt,
            updatedAt: updatedAt,
            terminal: terminal,
            source: source,
            currentStep: currentStep,
            sessionTitle: sessionTitle
        )
    }

    public func replacingProcess(_ process: DetectedAgentProcess) -> AgentSession {
        AgentSession(
            schemaVersion: schemaVersion,
            tool: tool,
            sessionID: sessionID,
            pid: process.processID,
            processIdentity: process.processIdentity,
            status: status,
            attentionReason: attentionReason,
            cwd: cwd,
            startedAt: startedAt,
            updatedAt: updatedAt,
            terminal: process.terminal,
            source: source,
            currentStep: currentStep,
            sessionTitle: sessionTitle
        )
    }

    func replacingProcessIdentity(_ processIdentity: ProcessIdentity) -> AgentSession {
        AgentSession(
            schemaVersion: schemaVersion,
            tool: tool,
            sessionID: sessionID,
            pid: pid,
            processIdentity: processIdentity,
            status: status,
            attentionReason: attentionReason,
            cwd: cwd,
            startedAt: startedAt,
            updatedAt: updatedAt,
            terminal: terminal,
            source: source,
            currentStep: currentStep,
            sessionTitle: sessionTitle
        )
    }

    public init(
        schemaVersion: Int = 1,
        tool: AgentTool,
        sessionID: String,
        pid: Int32,
        processIdentity: ProcessIdentity? = nil,
        status: SessionStatus,
        attentionReason: AttentionReason? = nil,
        cwd: String,
        startedAt: Date,
        updatedAt: Date,
        terminal: TerminalContext = TerminalContext(),
        source: SessionSource? = nil,
        currentStep: String? = nil,
        sessionTitle: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.sessionID = sessionID
        self.pid = pid
        self.processIdentity = processIdentity?.processID == pid ? processIdentity : nil
        self.status = status
        self.attentionReason = attentionReason
        self.cwd = cwd
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.terminal = terminal
        self.source = source
        self.currentStep = currentStep
        self.sessionTitle = sessionTitle
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tool
        case sessionID = "session_id"
        case pid
        case processIdentity = "process_identity"
        case status
        case attentionReason = "attention_reason"
        case cwd
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case terminal
        case source
        case currentStep = "current_step"
        case sessionTitle = "session_title"
    }

    public static func decode(from data: Data) throws -> AgentSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: data)
        guard session.schemaVersion == 1 else {
            throw AgentSessionError.unsupportedSchemaVersion(session.schemaVersion)
        }
        return session
    }
}
