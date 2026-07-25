import Foundation

/// The compact, tool-agnostic view of active agent work. Provider identity is
/// useful in the expanded session list, but the notch itself should answer the
/// immediate question: what is running, waiting, or blocked right now?
public struct SessionStatusSummary: Equatable, Sendable {
    public let runningCount: Int
    public let waitingCount: Int
    public let blockedCount: Int

    public var activeSessionCount: Int {
        runningCount + waitingCount + blockedCount
    }

    public init(sessions: [AgentSession]) {
        runningCount = sessions.count { $0.status == .working }
        waitingCount = sessions.count { $0.status == .idle }
        blockedCount = sessions.count { $0.status == .needsAttention }
    }

    /// The menu keeps the repository's real status, while the compact bar
    /// downgrades a visited blocked session to the quiet waiting state until
    /// fresh activity changes its acknowledgment fingerprint.
    public init(
        sessions: [AgentSession],
        acknowledgments: AttentionAcknowledgments
    ) {
        self.init(sessions: acknowledgments.silenced(sessions))
    }

    public struct StatusEntry: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable, CaseIterable {
            case running
            case waiting
            case blocked
        }

        public let kind: Kind
        public let count: Int

        public var id: Kind { kind }

        public init(kind: Kind, count: Int) {
            self.kind = kind
            self.count = count
        }
    }

    /// The bar only surfaces states that actually exist right now: a
    /// zero-count indicator is visual noise, so it leaves no slot behind.
    public var visibleEntries: [StatusEntry] {
        [
            StatusEntry(kind: .running, count: runningCount),
            StatusEntry(kind: .waiting, count: waitingCount),
            StatusEntry(kind: .blocked, count: blockedCount),
        ].filter { $0.count > 0 }
    }
}
