import Darwin
import Foundation

public enum TerminationError: Error, Equatable, Sendable {
    case signalFailed(pid: Int32, underlyingErrno: Int32)
    case processStillAlive(Int32)
}

/// Plans how to close the terminal container a session lives in once its
/// process is dead. Closing is destructive, so unlike focusing there are no
/// heuristics: only an exact container — a tmux pane id or a Ghostty surface
/// id — is ever closed. No exact container, nothing to close.
public enum TerminationPlanner {
    public static func closeActions(for session: AgentSession) throws -> [FocusAction] {
        if let pane = session.terminal.tmuxPane {
            guard pane.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil else {
                throw FocusError.invalidTmuxPane(pane)
            }
            // Only the pane: the surrounding tab may host other panes.
            return [.run(executable: "tmux", arguments: ["kill-pane", "-t", pane])]
        }
        if session.terminal.termProgram?.lowercased() == "ghostty",
           let terminalID = session.terminal.ghosttyTerminalID {
            return [.appleScript(ghosttyCloseScript(terminalID: terminalID))]
        }
        return []
    }

    private static func ghosttyCloseScript(terminalID: String) -> String {
        let identifier = FocusPlanner.appleScriptString(terminalID)
        return """
        tell application "Ghostty"
          set matches to every terminal whose id is "\(identifier)"
          if (count of matches) is 1 then close item 1 of matches
        end tell
        """
    }
}

public enum TerminationService {
    /// Kills the session's process — SIGTERM first, SIGKILL after the grace
    /// period — and then closes its terminal container. The state document
    /// is deliberately left alone: the scheduler's exit watcher observes the
    /// death and the reaper deletes the document on the next tick.
    public static func terminate(_ session: AgentSession, gracePeriod: TimeInterval = 2) throws {
        // Validate the close plan before sending any signal, so a corrupt
        // document cannot kill the process and then fail to clean up.
        let closeActions = try TerminationPlanner.closeActions(for: session)
        try killProcess(
            session.pid,
            expectedIdentity: session.processIdentity,
            gracePeriod: gracePeriod
        )
        try FocusActionRunner.run(closeActions)
    }

    private static func killProcess(
        _ processID: Int32,
        expectedIdentity: ProcessIdentity?,
        gracePeriod: TimeInterval
    ) throws {
        // kill(0)/kill(-1) would signal a whole process group; refuse.
        guard processID > 0 else {
            throw TerminationError.signalFailed(pid: processID, underlyingErrno: EINVAL)
        }
        // State documents and their PIDs arrive from integrations. A PID
        // alone can be recycled after its agent exits, so a missing identity
        // is not enough authority for this destructive operation. The reaper
        // records the current kernel identity before an actionable session is
        // displayed; legacy or malformed documents fail closed here.
        guard let expectedIdentity else {
            throw TerminationError.signalFailed(pid: processID, underlyingErrno: ESRCH)
        }
        // A process that already exited (including an unreaped zombie) has
        // reached the requested end state. Do not turn this benign race into
        // a failure merely because it no longer exposes an identity.
        guard isRunning(processID) else { return }
        guard SystemProcessScanner.processIdentity(of: processID) == expectedIdentity else {
            throw TerminationError.signalFailed(pid: processID, underlyingErrno: ESRCH)
        }
        if Darwin.kill(processID, SIGTERM) != 0 {
            if errno == ESRCH { return }
            throw TerminationError.signalFailed(pid: processID, underlyingErrno: errno)
        }
        if waitForExit(
            processID,
            expectedIdentity: expectedIdentity,
            gracePeriod: gracePeriod
        ) { return }
        if SystemProcessScanner.processIdentity(of: processID) != expectedIdentity {
            return
        }
        if Darwin.kill(processID, SIGKILL) != 0, errno != ESRCH {
            throw TerminationError.signalFailed(pid: processID, underlyingErrno: errno)
        }
        guard waitForExit(
            processID,
            expectedIdentity: expectedIdentity,
            gracePeriod: gracePeriod
        ) else {
            throw TerminationError.processStillAlive(processID)
        }
    }

    private static func waitForExit(
        _ processID: Int32,
        expectedIdentity: ProcessIdentity?,
        gracePeriod: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(gracePeriod)
        while isRunning(processID)
            && expectedIdentity.map({ SystemProcessScanner.processIdentity(of: processID) == $0 }) != false {
            guard Date() < deadline else { return false }
            usleep(50_000)
        }
        return true
    }

    private static func isRunning(_ processID: Int32) -> Bool {
        if Darwin.kill(processID, 0) != 0 {
            return errno == EPERM
        }
        // A zombie still answers signal 0; ask the kernel for the real state
        // so a child its parent has not reaped yet does not read as alive.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return true
        }
        return info.pbi_status != UInt32(SZOMB)
    }
}
