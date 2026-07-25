import Foundation

/// Remembers which waiting sessions the user has already visited so the bar
/// semaphore can go quiet without losing the session. An acknowledgment is
/// pinned to the session's exact status and timestamp: any new activity —
/// a fresh permission ask, another idle prompt — produces a different
/// fingerprint and re-arms the light.
public struct AttentionAcknowledgments: Equatable, Sendable {
    private var fingerprints: Set<String> = []

    public init() {}

    public mutating func acknowledge(_ session: AgentSession) {
        fingerprints.insert(Self.fingerprint(session))
    }

    public func isAcknowledged(_ session: AgentSession) -> Bool {
        fingerprints.contains(Self.fingerprint(session))
    }

    /// Sessions for the bar semaphore: acknowledged waiting sessions count
    /// as idle — the app's silent resting state. The menu keeps showing the
    /// repository's real statuses.
    public func silenced(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.map { session in
            guard session.status == .idle || session.status == .needsAttention,
                  isAcknowledged(session) else {
                return session
            }
            return AgentSession(
                schemaVersion: session.schemaVersion,
                tool: session.tool,
                sessionID: session.sessionID,
                pid: session.pid,
                processIdentity: session.processIdentity,
                status: .idle,
                attentionReason: nil,
                cwd: session.cwd,
                startedAt: session.startedAt,
                updatedAt: session.updatedAt,
                terminal: session.terminal,
                source: session.source
            )
        }
    }

    /// Drops fingerprints that no longer match any current session so the
    /// set cannot grow across weeks of agent churn.
    public mutating func prune(keeping sessions: [AgentSession]) {
        fingerprints.formIntersection(sessions.map(Self.fingerprint))
    }

    private static func fingerprint(_ session: AgentSession) -> String {
        "\(session.id)|\(session.status.rawValue)|\(session.updatedAt.timeIntervalSince1970)"
    }
}
