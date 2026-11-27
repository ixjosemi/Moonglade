import Foundation

/// A fixed set of sessions for taking screenshots of the real app.
///
/// `MOONGLADE_DEMO=1` points the app at a throwaway root seeded from here
/// instead of `~/.moonglade/state`, and the app then skips process
/// observation, so nothing reaps sessions whose processes do not exist. The
/// user's own state, session names and terminals are never read or touched.
public struct DemoWorkspace: Sendable {
    public static let environmentKey = "MOONGLADE_DEMO"

    public let rootURL: URL

    public var stateDirectoryURL: URL {
        rootURL.appendingPathComponent("state", isDirectory: true)
    }

    public var nameOverridesFileURL: URL {
        rootURL.appendingPathComponent("session-names.json")
    }

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public static func isEnabled(in environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    /// Writes the demo projects and their state documents, and returns the
    /// sessions it saved. Elapsed times are measured back from `now`.
    @discardableResult
    public func seed(now: Date) throws -> [AgentSession] {
        let repository = StateRepository(directoryURL: stateDirectoryURL)
        try repository.prepareDirectory()
        let sessions = try Self.fixtures.map { fixture in
            let project = try makeProject(fixture.project, branch: fixture.branch)
            return AgentSession(
                tool: fixture.tool,
                sessionID: fixture.sessionID,
                pid: ProcessInfo.processInfo.processIdentifier,
                status: fixture.status,
                attentionReason: fixture.attentionReason,
                cwd: project.path,
                startedAt: now.addingTimeInterval(-fixture.elapsed),
                updatedAt: now,
                currentStep: fixture.currentStep,
                sessionTitle: fixture.title
            )
        }
        for session in sessions {
            try repository.save(session)
        }
        return sessions
    }

    /// Each project is a directory with only a `.git/HEAD`, which is all
    /// `GitWorkspaceInspector` reads to name the branch.
    private func makeProject(_ project: DemoProject, branch: String) throws -> URL {
        let directory = rootURL
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(project.slot, isDirectory: true)
            .appendingPathComponent(project.name, isDirectory: true)
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        return directory
    }

    private struct DemoProject {
        /// Keeps two checkouts of one project apart on disk while the row,
        /// which shows only the last path component, names both the same.
        let slot: String
        let name: String
    }

    private struct Fixture {
        let tool: AgentTool
        let sessionID: String
        let status: SessionStatus
        let attentionReason: AttentionReason?
        let title: String
        let project: DemoProject
        let branch: String
        let currentStep: String?
        let elapsed: TimeInterval
    }

    /// Two running, one waiting at the prompt, one blocked on a permission
    /// ask: one of every state the collapsed bar counts.
    private static let fixtures: [Fixture] = [
        Fixture(
            tool: .claude, sessionID: "demo-claude", status: .working, attentionReason: nil,
            title: "Refactor the session matcher",
            project: DemoProject(slot: "a", name: "moonglade"), branch: "feat/ghostty-identity",
            currentStep: nil, elapsed: 252
        ),
        Fixture(
            tool: .opencode, sessionID: "demo-opencode", status: .needsAttention, attentionReason: .permission,
            title: "Wire the release pipeline",
            project: DemoProject(slot: "b", name: "moonglade"), branch: "ci/release-pipeline",
            currentStep: nil, elapsed: 18
        ),
        Fixture(
            tool: .convoy, sessionID: "demo-convoy", status: .working, attentionReason: nil,
            title: "Add inline session actions",
            project: DemoProject(slot: "c", name: "api"), branch: "feat/inline-actions",
            currentStep: "implement", elapsed: 428
        ),
        Fixture(
            tool: .codex, sessionID: "demo-codex", status: .idle, attentionReason: nil,
            title: "Audit the state repository",
            project: DemoProject(slot: "d", name: "moonglade"), branch: "main",
            currentStep: nil, elapsed: 100
        ),
    ]
}
