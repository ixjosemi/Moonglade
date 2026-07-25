import Foundation

public struct CodexRolloutParser: Sendable {
    private struct Envelope: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let id: String?
        let cwd: String?
        let timestamp: String?
        let type: String?
    }

    // Both are expensive to construct and get called once per rollout line;
    // ISO8601DateFormatter is documented thread-safe and JSONDecoder keeps
    // no state between decode calls.
    private static let decoder = JSONDecoder()
    private static let dateFormatter = ISO8601DateFormatter()

    private let processID: Int32
    private var sessionID: String?
    private var cwd: String?
    private var startedAt: Date?

    public init(processID: Int32) {
        self.processID = processID
    }

    public mutating func consume(line: Data) -> AgentSession? {
        guard let envelope = try? Self.decoder.decode(Envelope.self, from: line) else {
            return nil
        }
        guard let updatedAt = Self.parseDate(envelope.timestamp) else { return nil }
        if envelope.type == "session_meta" {
            sessionID = envelope.payload.id
            cwd = envelope.payload.cwd
            startedAt = envelope.payload.timestamp.flatMap(Self.parseDate) ?? updatedAt
            return makeSession(status: .working, reason: nil, updatedAt: updatedAt)
        }
        guard envelope.type == "event_msg", let eventType = envelope.payload.type else {
            return nil
        }
        guard let transition = Self.transition(for: eventType) else { return nil }
        return makeSession(status: transition.0, reason: transition.1, updatedAt: updatedAt)
    }

    private func makeSession(
        status: SessionStatus,
        reason: AttentionReason?,
        updatedAt: Date
    ) -> AgentSession? {
        guard let sessionID, let cwd, let startedAt else { return nil }
        return AgentSession(
            tool: .codex,
            sessionID: sessionID,
            pid: processID,
            status: status,
            attentionReason: reason,
            cwd: cwd,
            startedAt: startedAt,
            updatedAt: updatedAt
        )
    }

    private static func transition(
        for eventType: String
    ) -> (SessionStatus, AttentionReason?)? {
        let approvalEvents = [
            "exec_approval_request",
            "apply_patch_approval_request",
            "request_permissions",
            "request_user_input",
            "elicitation_request",
        ]
        if approvalEvents.contains(eventType) {
            return (.needsAttention, .permission)
        }
        if ["task_complete", "turn_complete"].contains(eventType) {
            return (.idle, .turnComplete)
        }
        if ["task_started", "turn_started", "exec_command_begin", "patch_apply_begin"]
            .contains(eventType) {
            return (.working, nil)
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        dateFormatter.date(from: value)
    }
}
