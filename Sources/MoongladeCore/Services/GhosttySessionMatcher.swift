import Foundation

public struct GhosttyTerminal: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let cwd: String
    public let pid: Int32?
    public let tty: String?

    public init(
        id: String,
        name: String,
        cwd: String,
        pid: Int32? = nil,
        tty: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.pid = pid
        self.tty = tty
    }
}

public enum GhosttySessionMatcher {
    /// `previousAssignments` maps `assignmentKey(for:)` to the terminal id a
    /// process was matched to on an earlier scan. A Ghostty surface never
    /// migrates to another process, so a remembered match outranks every
    /// title heuristic — titles drift as agents rename their tabs, the
    /// hosting surface does not.
    public static func match(
        processes: [DetectedAgentProcess],
        terminals: [GhosttyTerminal],
        previousAssignments: [String: String] = [:]
    ) -> [DetectedAgentProcess] {
        var availableTerminals = terminals
        var unmatchedProcesses: [DetectedAgentProcess] = []
        var matchedProcesses: [DetectedAgentProcess] = []

        // Remembered processes claim first so a newcomer can never steal a
        // surface that already belongs to someone via a weaker heuristic.
        let orderedProcesses = processes.sorted { lhs, rhs in
            let lhsRemembered = previousAssignments[assignmentKey(for: lhs)] != nil
            let rhsRemembered = previousAssignments[assignmentKey(for: rhs)] != nil
            if lhsRemembered != rhsRemembered {
                return lhsRemembered
            }
            return lhs.processID < rhs.processID
        }
        for process in orderedProcesses {
            guard let index = bestTerminalIndex(
                for: process,
                in: availableTerminals,
                rememberedTerminalID: previousAssignments[assignmentKey(for: process)]
            ) else {
                unmatchedProcesses.append(process)
                continue
            }
            matchedProcesses.append(enrich(process, with: availableTerminals.remove(at: index)))
        }

        let blankTerminals = availableTerminals.filter { $0.cwd.isEmpty }
        // A convoy pipeline's embedded `opencode serve` child shares its cwd
        // and competes for the same leftover slot when Ghostty's scripting
        // bridge never enumerates their shared tab. The child only becomes
        // visible once ConvoyRunsWatcher suppresses it in favor of the
        // pipeline row, so convoy must win this tie-break first.
        let newestUnmatched = unmatchedProcesses.sorted { lhs, rhs in
            if (lhs.tool == .convoy) != (rhs.tool == .convoy) {
                return lhs.tool == .convoy
            }
            return lhs.elapsedSeconds < rhs.elapsedSeconds
        }
        for (process, terminal) in zip(newestUnmatched, blankTerminals) {
            matchedProcesses.append(enrich(process, with: terminal))
        }
        return matchedProcesses
    }

    public static func assignmentKey(for process: DetectedAgentProcess) -> String {
        if let identity = process.processIdentity {
            return "\(process.tool.rawValue)-\(identity.processID)-\(identity.kernelStartTimeMicroseconds)"
        }
        return "\(process.tool.rawValue)-\(process.processID)"
    }

    private static func bestTerminalIndex(
        for process: DetectedAgentProcess,
        in terminals: [GhosttyTerminal],
        rememberedTerminalID: String?
    ) -> Int? {
        let sameProcess = terminals.indices.filter {
            terminals[$0].pid == process.processID
        }
        if sameProcess.count == 1 {
            return sameProcess[0]
        }
        if let tty = process.terminal.tty {
            let sameTTY = terminals.indices.filter { terminals[$0].tty == tty }
            if sameTTY.count == 1 {
                return sameTTY[0]
            }
        }
        if let rememberedTerminalID,
           let rememberedIndex = terminals.firstIndex(where: { $0.id == rememberedTerminalID }) {
            return rememberedIndex
        }
        let sameDirectory = terminals.indices.filter {
            !terminals[$0].cwd.isEmpty && terminals[$0].cwd == process.cwd
        }
        if !sameDirectory.isEmpty {
            // Several tabs can share one project directory. In preference
            // order: the tab whose title names the tool, the tab whose title
            // carries the tool's known decoration signature, any tab not
            // visibly running a different command, and only then the first.
            return sameDirectory.first {
                terminals[$0].name.lowercased().contains(process.tool.rawValue)
            } ?? sameDirectory.first {
                titleSignatureMatches(process.tool, terminals[$0].name)
            } ?? sameDirectory.first {
                !titleLooksLikeForeignCommand(terminals[$0].name, for: process.tool)
            } ?? sameDirectory.first
        }
        let projectName = URL(fileURLWithPath: process.cwd).lastPathComponent.lowercased()
        guard projectName.count >= 8, projectName != "development" else { return nil }
        return terminals.firstIndex { $0.name.lowercased().contains(projectName) }
    }

    /// Tools decorate their tab titles distinctively: OpenCode's TUI writes
    /// "<status emoji> | <title>", Claude Code prefixes a braille spinner or
    /// an asterisk mark. Signatures break ties when no title names a tool.
    private static func titleSignatureMatches(_ tool: AgentTool, _ title: String) -> Bool {
        switch tool {
        case .opencode:
            return title.range(of: #"^\S{1,2} \| "#, options: .regularExpression) != nil
        case .claude:
            guard let firstScalar = title.unicodeScalars.first else { return false }
            return (0x2800...0x28FF).contains(firstScalar.value)
                || "✳✻✽".unicodeScalars.contains(firstScalar)
        case .codex, .convoy, .pi:
            return false
        }
    }

    /// Ghostty's default tab title is the foreground command line — a title
    /// like "caffeinate -di" reveals the tab runs something that is not this
    /// agent. Foreign commands only remain as the assignment of last resort.
    private static func titleLooksLikeForeignCommand(
        _ title: String,
        for tool: AgentTool
    ) -> Bool {
        let tokens = title.split(separator: " ")
        guard let commandToken = tokens.first,
              commandToken.range(of: #"^[a-z0-9._-]+$"#, options: .regularExpression) != nil,
              String(commandToken) != tool.rawValue else {
            return false
        }
        return tokens.count == 1 || tokens[1].hasPrefix("-")
    }

    private static func enrich(
        _ process: DetectedAgentProcess,
        with terminal: GhosttyTerminal
    ) -> DetectedAgentProcess {
        DetectedAgentProcess(
            tool: process.tool,
            processID: process.processID,
            processIdentity: process.processIdentity,
            cwd: process.cwd,
            terminal: TerminalContext(
                termProgram: "ghostty",
                ghosttyTerminalID: terminal.id,
                tmuxPane: process.terminal.tmuxPane,
                tty: process.terminal.tty,
                windowTitleHint: terminal.name
            ),
            elapsedSeconds: process.elapsedSeconds
        )
    }
}
