import Foundation

/// What Ghostty reports about the terminal the user is looking at.
public struct GhosttyFrontTerminal: Equatable, Sendable {
    public let terminalID: String
    public let workingDirectory: String?

    public init(terminalID: String, workingDirectory: String?) {
        self.terminalID = terminalID
        self.workingDirectory = workingDirectory
    }
}

/// Decides which waiting sessions the user is currently looking at. The
/// exact terminal ID always wins; sessions that never captured an ID —
/// agents started before the hooks were installed — fall back to comparing
/// the front terminal's working directory with the session's cwd. A session
/// whose known ID differs from the front terminal never matches, even from
/// the same directory.
public enum FrontTerminalMatcher {
    public static func sessionsFocused(
        by front: GhosttyFrontTerminal,
        among sessions: [AgentSession]
    ) -> [AgentSession] {
        sessions.filter { session in
            if let terminalID = session.terminal.ghosttyTerminalID {
                return terminalID == front.terminalID
            }
            guard let workingDirectory = front.workingDirectory else { return false }
            return normalized(workingDirectory) == normalized(session.cwd)
        }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
