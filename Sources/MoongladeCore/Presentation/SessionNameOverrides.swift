import Foundation

/// User-chosen display names for sessions, keyed by session identity so a
/// name survives status churn but never outlives its session. Purely a
/// presentation overlay: the state documents on disk are rewritten by hooks
/// and watchers, so a name stored there would be lost on the next write.
public struct SessionNameOverrides: Equatable, Sendable, Codable {
    private var namesBySessionKey: [String: String] = [:]

    public init() {}

    /// A blank or empty name clears the override, so the row falls back to
    /// the project name — renaming to nothing is the undo gesture.
    public mutating func rename(_ session: AgentSession, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            namesBySessionKey[Self.key(for: session)] = nil
        } else {
            namesBySessionKey[Self.key(for: session)] = trimmedName
        }
    }

    public func displayName(for session: AgentSession) -> String? {
        namesBySessionKey[Self.key(for: session)]
    }

    /// Drops names whose session no longer exists so the set cannot grow
    /// across weeks of agent churn.
    public mutating func prune(keeping sessions: [AgentSession]) {
        let liveKeys = Set(sessions.map(Self.key))
        namesBySessionKey = namesBySessionKey.filter { liveKeys.contains($0.key) }
    }

    private static func key(for session: AgentSession) -> String {
        "\(session.tool.rawValue)|\(session.sessionID)"
    }
}
