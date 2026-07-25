import Foundation

public enum ClaudeHookError: Error, Equatable, Sendable {
    case unsupportedEvent(String)
    case unsupportedNotification(String?)
}

public struct ClaudeHookProcessor: Sendable {
    private struct Payload: Decodable {
        let sessionID: String
        let cwd: String
        let notificationType: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd
            case notificationType = "notification_type"
        }
    }

    private let repository: StateRepository

    public init(repository: StateRepository) {
        self.repository = repository
    }

    public func process(
        event: String,
        payload: Data,
        environment: [String: String],
        processID: Int32,
        now: Date = Date()
    ) throws {
        let input = try JSONDecoder().decode(Payload.self, from: payload)
        let existing = try repository.loadLifecycleSessions().first {
            $0.sessionID == input.sessionID
        }
        let state = try state(for: event, notificationType: input.notificationType, existing: existing)
        let session = AgentSession(
            tool: .claude,
            sessionID: input.sessionID,
            pid: processID,
            status: state.status,
            attentionReason: state.reason,
            cwd: input.cwd,
            startedAt: existing?.startedAt ?? now,
            updatedAt: now,
            terminal: existing?.terminal ?? terminalContext(for: input.cwd, environment: environment)
        )
        try repository.save(session)
    }

    private func state(
        for event: String,
        notificationType: String?,
        existing: AgentSession?
    ) throws -> (status: SessionStatus, reason: AttentionReason?) {
        switch event {
        case "SessionStart":
            // Fires on launch but also mid-conversation (resume, /clear,
            // /compact, auto-compaction), so it carries no signal about
            // activity: keep whatever status the session already has, and
            // treat a brand-new session as sitting idle at the prompt.
            return (existing?.status ?? .idle, existing?.attentionReason)
        case "Notification" where notificationType == "permission_prompt":
            return (.needsAttention, .permission)
        case "Notification" where notificationType == "idle_prompt":
            // Claude Code nudges "still waiting for your input" a minute
            // after the turn ends. The row already shows amber for exactly
            // that; escalating to red (and chiming) would drown the real
            // needs-you signal, so the nudge carries no status change.
            return (existing?.status ?? .idle, existing?.attentionReason)
        case "Notification":
            throw ClaudeHookError.unsupportedNotification(notificationType)
        case "UserPromptSubmit":
            return (.working, nil)
        case "PostToolUse":
            // Answering a permission prompt (or an AskUserQuestion, which
            // Claude Code notifies about the same way) arrives as a tool
            // result, not a typed prompt — UserPromptSubmit never fires for
            // it. The tool call it was blocking cannot complete until the
            // user responds, so its completion is the resume signal.
            return (.working, nil)
        case "Stop":
            return (.idle, nil)
        case "SessionEnd":
            return (.ended, nil)
        default:
            throw ClaudeHookError.unsupportedEvent(event)
        }
    }

    private func terminalContext(
        for cwd: String,
        environment: [String: String]
    ) -> TerminalContext {
        TerminalContext(
            termProgram: environment["TERM_PROGRAM"],
            cmuxPanelID: environment["CMUX_PANEL_ID"],
            itermSessionID: environment["ITERM_SESSION_ID"],
            tmuxPane: environment["TMUX_PANE"],
            tty: environment["MOONGLADE_TTY"],
            windowTitleHint: "\(URL(fileURLWithPath: cwd).lastPathComponent) — claude"
        )
    }
}
