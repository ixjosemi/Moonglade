import Foundation

public enum DebugRenderer {
    public static func render(sessions: [AgentSession]) -> String {
        AgentTool.allCases.map { tool in
            let toolSessions = sessions.filter { $0.tool == tool }
            let rows = toolSessions.map { session in
                "  \(session.sessionID)  \(session.status.rawValue)  \(session.projectName)"
            }
            return (["\(tool.rawValue): \(toolSessions.count)"] + rows).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
