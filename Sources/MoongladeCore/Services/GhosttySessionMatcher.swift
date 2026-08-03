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

/// The outcome of one matching pass: every process that ended up hosted by a
/// surface, plus the subset of assignments founded on identity rather than on
/// enumeration order. Only the identified ones may be remembered — freezing a
/// guess is what turns a single bad tick into a permanently wrong assignment.
public struct GhosttySessionMatch: Sendable {
    public let processes: [DetectedAgentProcess]
    /// `assignmentKey(for:)` to surface id, for identified matches only.
    public let identifiedTerminalIDs: [String: String]
}

public enum GhosttySessionMatcher {
    /// A surface is claimed on evidence: its PID or TTY, the session title the
    /// agent itself reported, an earlier identified match, or a title that
    /// singles the tool out among the tabs sharing a directory. Ghostty 1.3
    /// exposes neither PID nor TTY per surface, so several agents in one
    /// directory can leave nothing to tell their panes apart — then the pass
    /// falls back to enumeration order, marks the result a guess, and refuses
    /// panes visibly running another command. No evidence at all means no
    /// surface: `FocusService` reports a stale target rather than raising a
    /// stranger's tab, and the row still reads from the reported session name.
    ///
    /// `previousAssignments` maps `assignmentKey(for:)` to the surface a
    /// process was identified with on an earlier scan. A Ghostty surface never
    /// migrates to another process, so a remembered match outranks the title
    /// heuristics — titles drift as agents rename their tabs, the hosting
    /// surface does not.
    public static func match(
        processes: [DetectedAgentProcess],
        terminals: [GhosttyTerminal],
        sessionTitles: [Int32: String] = [:],
        previousAssignments: [String: String] = [:]
    ) -> GhosttySessionMatch {
        var availableTerminals = terminals
        var unmatchedProcesses: [DetectedAgentProcess] = []
        var matchedProcesses: [DetectedAgentProcess] = []
        var identifiedTerminalIDs: [String: String] = [:]

        // Remembered processes claim first so a newcomer can never steal a
        // surface that already belongs to someone via a weaker heuristic.
        // The rest claim oldest first, because Ghostty enumerates surfaces in
        // creation order and an agent is started in its pane shortly after
        // the pane appears — so when nothing else distinguishes them, the
        // k-th oldest agent belongs to the k-th oldest pane. Process IDs say
        // nothing about age once the kernel has wrapped them around.
        let orderedProcesses = processes.sorted { lhs, rhs in
            let lhsRemembered = previousAssignments[assignmentKey(for: lhs)] != nil
            let rhsRemembered = previousAssignments[assignmentKey(for: rhs)] != nil
            if lhsRemembered != rhsRemembered {
                return lhsRemembered
            }
            return lhs.elapsedSeconds > rhs.elapsedSeconds
        }
        for process in orderedProcesses {
            guard let choice = bestTerminal(
                for: process,
                in: availableTerminals,
                among: terminals,
                sessionTitle: sessionTitles[process.processID],
                rememberedTerminalID: previousAssignments[assignmentKey(for: process)]
            ) else {
                unmatchedProcesses.append(process)
                continue
            }
            let terminal = availableTerminals.remove(at: choice.index)
            matchedProcesses.append(enrich(process, with: terminal))
            if choice.isIdentified {
                identifiedTerminalIDs[assignmentKey(for: process)] = terminal.id
            }
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
        // Pairing the newest process with a surface Ghostty could not place is
        // inference, not identity, so these stay out of the memory too.
        for (process, terminal) in zip(newestUnmatched, blankTerminals) {
            matchedProcesses.append(enrich(process, with: terminal))
        }
        return GhosttySessionMatch(
            processes: matchedProcesses,
            identifiedTerminalIDs: identifiedTerminalIDs
        )
    }

    public static func assignmentKey(for process: DetectedAgentProcess) -> String {
        if let identity = process.processIdentity {
            return "\(process.tool.rawValue)-\(identity.processID)-\(identity.kernelStartTimeMicroseconds)"
        }
        return "\(process.tool.rawValue)-\(process.processID)"
    }

    private struct TerminalChoice {
        let index: Int
        let isIdentified: Bool
    }

    /// `terminals` are the surfaces still unclaimed; `allTerminals` is every
    /// surface this scan saw. Evidence is judged against the whole set: a
    /// signal that singles out a pane only because its rivals were claimed
    /// first is enumeration order wearing identity's clothes.
    private static func bestTerminal(
        for process: DetectedAgentProcess,
        in terminals: [GhosttyTerminal],
        among allTerminals: [GhosttyTerminal],
        sessionTitle: String?,
        rememberedTerminalID: String?
    ) -> TerminalChoice? {
        let sameProcess = terminals.indices.filter {
            terminals[$0].pid == process.processID
        }
        if sameProcess.count == 1 {
            return TerminalChoice(index: sameProcess[0], isIdentified: true)
        }
        if let tty = process.terminal.tty {
            let sameTTY = terminals.indices.filter { terminals[$0].tty == tty }
            if sameTTY.count == 1 {
                return TerminalChoice(index: sameTTY[0], isIdentified: true)
            }
        }
        // The agent named the session and its TUI wrote that name into the
        // pane, so an exact match is identity — strong enough to correct a
        // remembered assignment that was made before the name existed.
        if let titled = onlyTerminal(in: allTerminals, titled: sessionTitle),
           let index = terminals.firstIndex(where: { $0.id == titled.id }) {
            return TerminalChoice(index: index, isIdentified: true)
        }
        if let rememberedTerminalID,
           let rememberedIndex = terminals.firstIndex(where: { $0.id == rememberedTerminalID }) {
            return TerminalChoice(index: rememberedIndex, isIdentified: true)
        }
        let directoryPeers = allTerminals.filter {
            !$0.cwd.isEmpty && $0.cwd == process.cwd
        }
        guard !directoryPeers.isEmpty else {
            let projectName = URL(fileURLWithPath: process.cwd).lastPathComponent.lowercased()
            guard projectName.count >= 8, projectName != "development" else { return nil }
            return terminals.firstIndex { $0.name.lowercased().contains(projectName) }
                .map { TerminalChoice(index: $0, isIdentified: false) }
        }
        // Several tabs share one project directory. A title that names the
        // tool, or carries its known decoration signature, identifies the pane
        // only when it singles one out among all of them — three panes wearing
        // the same TUI decoration tell three sessions apart not at all.
        if let named = onlyTerminal(in: directoryPeers, where: {
                $0.name.lowercased().contains(process.tool.rawValue)
            }) ?? onlyTerminal(in: directoryPeers, where: {
                titleSignatureMatches(process.tool, $0.name)
            }),
           let index = terminals.firstIndex(where: { $0.id == named.id }) {
            return TerminalChoice(index: index, isIdentified: true)
        }
        // Nothing distinguishes the tabs. Enumeration order is all that is
        // left, it is a guess, and it may never claim a tab visibly running
        // something else.
        return terminals.indices.first {
            !terminals[$0].cwd.isEmpty
                && terminals[$0].cwd == process.cwd
                && !titleLooksLikeForeignCommand(terminals[$0].name, for: process.tool)
        }.map { TerminalChoice(index: $0, isIdentified: false) }
    }

    /// The one surface whose display-cleaned title equals the session name.
    /// Both sides go through the row formatter so the TUI's status decoration
    /// ("🟡 | ") is stripped exactly the way the notch strips it. Ambiguity is
    /// answered with nil: two sessions sharing a name identify neither.
    private static func onlyTerminal(
        in terminals: [GhosttyTerminal],
        titled sessionTitle: String?
    ) -> GhosttyTerminal? {
        guard let sessionTitle else { return nil }
        let wanted = SessionTitleFormatter.rowTitle(tabTitle: sessionTitle, fallback: "")
        guard !wanted.isEmpty else { return nil }
        return onlyTerminal(in: terminals) {
            SessionTitleFormatter.rowTitle(tabTitle: $0.name, fallback: "") == wanted
        }
    }

    private static func onlyTerminal(
        in terminals: [GhosttyTerminal],
        where predicate: (GhosttyTerminal) -> Bool
    ) -> GhosttyTerminal? {
        let matches = terminals.filter(predicate)
        return matches.count == 1 ? matches[0] : nil
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
