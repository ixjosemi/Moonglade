import Foundation

public enum CodexNotifyError: Error, Equatable, Sendable {
    case unsupportedEvent(String)
    case invalidWorkingDirectory
}

public struct CodexNotifyProcessor: Sendable {
    private struct Payload: Decodable {
        let type: String
        let threadID: String
        let cwd: String?

        enum CodingKeys: String, CodingKey {
            case type
            case threadID = "thread-id"
            case cwd
        }
    }

    private let repository: StateRepository

    public init(repository: StateRepository) {
        self.repository = repository
    }

    public func process(payload: Data, processID: Int32, now: Date = Date()) throws {
        let event = try JSONDecoder().decode(Payload.self, from: payload)
        guard event.type == "agent-turn-complete" else {
            throw CodexNotifyError.unsupportedEvent(event.type)
        }
        let existing = try repository.loadLifecycleSessions().first {
            $0.tool == .codex && $0.sessionID == event.threadID
        }
        let cwd: String
        if let suppliedCWD = event.cwd {
            guard let normalized = normalizedAbsolutePath(suppliedCWD) else {
                throw CodexNotifyError.invalidWorkingDirectory
            }
            cwd = normalized
        } else if let existingCWD = existing?.cwd {
            cwd = existingCWD
        } else {
            throw CodexNotifyError.invalidWorkingDirectory
        }
        let session = AgentSession(
            tool: .codex,
            sessionID: event.threadID,
            pid: existing?.pid ?? processID,
            status: .idle,
            attentionReason: .turnComplete,
            cwd: cwd,
            startedAt: existing?.startedAt ?? now,
            updatedAt: now,
            terminal: existing?.terminal ?? TerminalContext()
        )
        try repository.save(session)
    }
}
