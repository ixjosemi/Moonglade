import Foundation
import Darwin

public enum FocusAction: Equatable, Sendable {
    case run(executable: String, arguments: [String])
    case appleScript(String)
}

public enum FocusError: Error, Equatable, Sendable {
    case invalidTmuxPane(String)
    case missingTerminalTarget
    case sessionUnavailable
    case commandFailed(String, Int32)
}

public enum FocusPlanner {
    public static func actions(for session: AgentSession) throws -> [FocusAction] {
        var actions: [FocusAction] = []
        if let pane = session.terminal.tmuxPane {
            guard pane.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil else {
                throw FocusError.invalidTmuxPane(pane)
            }
            actions.append(.run(executable: "tmux", arguments: ["select-window", "-t", pane]))
            actions.append(.run(executable: "tmux", arguments: ["select-pane", "-t", pane]))
        }
        actions.append(try terminalAction(for: session))
        return actions
    }

    private static func terminalAction(for session: AgentSession) throws -> FocusAction {
        // cmux ships Ghostty's engine and reports TERM_PROGRAM=ghostty, so it
        // must be resolved before the Ghostty branch — otherwise its sessions
        // address an application that need not be installed at all.
        if let surfaceID = session.terminal.cmuxSurfaceID, !surfaceID.isEmpty {
            return .appleScript(cmuxScript(surfaceID: surfaceID))
        }
        if session.terminal.termProgram?.lowercased() == "ghostty" {
            return .appleScript(ghosttyScript(for: session))
        }
        if let identifier = session.terminal.itermSessionID {
            let normalizedIdentifier = normalizedITermIdentifier(identifier)
            if !normalizedIdentifier.isEmpty {
                return .appleScript(iTermScript(
                    identifier: normalizedIdentifier,
                    tty: session.terminal.tty
                ))
            }
            if let tty = session.terminal.tty {
                return .appleScript(iTermScript(identifier: nil, tty: tty))
            }
            throw FocusError.missingTerminalTarget
        }
        if session.terminal.termProgram == "iTerm.app",
           let tty = session.terminal.tty {
            return .appleScript(iTermScript(identifier: nil, tty: tty))
        }
        if let tty = session.terminal.tty,
           session.terminal.termProgram == "Apple_Terminal" {
            return .appleScript(terminalScript(tty: tty))
        }
        throw FocusError.missingTerminalTarget
    }

    /// cmux exposes the same scripting vocabulary as Ghostty — a `terminal`
    /// class keyed by `id` plus a `focus` command — and its `CMUX_SURFACE_ID`
    /// equals that `id` exactly, so identity is always strong. There is no
    /// working-directory fallback: a stale surface is reported, never guessed at.
    private static func cmuxScript(surfaceID: String) -> String {
        let identifier = appleScriptString(surfaceID)
        return """
        tell application "cmux"
          set matches to every terminal whose id is "\(identifier)"
          if (count of matches) is not 1 then error "Moonglade could not uniquely identify the cmux terminal"
          focus item 1 of matches
          activate
        end tell
        """
    }

    private static func ghosttyScript(for session: AgentSession) -> String {
        let cwd = appleScriptString(session.cwd)
        let hint = appleScriptString(session.terminal.windowTitleHint ?? session.projectName)
        let identifier = session.terminal.ghosttyTerminalID.map(appleScriptString)
        if let identifier {
            // A surface ID is strong identity. If it disappeared, choosing a
            // different same-project tab would be worse than reporting that
            // the target is stale.
            return """
            tell application "Ghostty"
              set matches to every terminal whose id is "\(identifier)"
              if (count of matches) is not 1 then error "Moonglade could not uniquely identify the Ghostty terminal"
              focus item 1 of matches
              activate
            end tell
            """
        }
        // Ghostty 1.3 exposes surface ID, title, and working directory but not
        // TTY/PID. Newer versions let the scanner use those fields to obtain
        // an exact ID; focus itself remains compatible with 1.3.
        return """
        tell application "Ghostty"
          set matches to every terminal whose working directory is "\(cwd)"
          if (count of matches) is not 1 then
            set titleMatches to every terminal whose name contains "\(hint)"
            if (count of titleMatches) is 1 then set matches to titleMatches
          end if
          if (count of matches) is not 1 then error "Moonglade could not uniquely identify the Ghostty terminal"
          focus item 1 of matches
          activate
        end tell
        """
    }

    private static func iTermScript(identifier: String?, tty: String?) -> String {
        let predicate: String
        if let identifier, !identifier.isEmpty {
            predicate = "unique ID of aSession is \"\(appleScriptString(identifier))\""
        } else if let tty {
            predicate = "tty of aSession is \"\(appleScriptString(tty))\""
        } else {
            // terminalAction never plans this form, but keep generation
            // fail-closed if a future caller violates that invariant.
            predicate = "false"
        }
        return """
        tell application "iTerm2"
          set matchCount to 0
          set targetWindow to missing value
          set targetTab to missing value
          set targetSession to missing value
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              repeat with aSession in sessions of aTab
                if \(predicate) then
                  set matchCount to matchCount + 1
                  set targetWindow to aWindow
                  set targetTab to aTab
                  set targetSession to aSession
                end if
              end repeat
            end repeat
          end repeat
          if matchCount is not 1 then error "Moonglade could not uniquely identify the iTerm session"
          select targetSession
          select targetTab
          select targetWindow
          activate
        end tell
        """
    }

    private static func terminalScript(tty: String) -> String {
        let normalizedTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let value = appleScriptString(normalizedTTY)
        return """
        tell application "Terminal"
          set matchCount to 0
          set targetWindow to missing value
          set targetTab to missing value
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              if (tty of aTab) is "\(value)" then
                set matchCount to matchCount + 1
                set targetWindow to aWindow
                set targetTab to aTab
              end if
            end repeat
          end repeat
          if matchCount is not 1 then error "Moonglade could not uniquely identify the Terminal tab"
          set selected tab of targetWindow to targetTab
          set frontmost of targetWindow to true
          activate
        end tell
        """
    }

    private static func normalizedITermIdentifier(_ identifier: String) -> String {
        identifier.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init)
            ?? identifier
    }

    package static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

public enum FocusService {
    public static func focus(_ session: AgentSession) throws {
        try FocusActionRunner.run(FocusPlanner.actions(for: session))
    }
}

/// Executes planned terminal actions — subprocess or AppleScript — for both
/// focusing and terminating sessions. Every action runs even after an
/// earlier one fails, so a dead tmux binding never blocks the terminal
/// action behind it; the first failure is still reported.
enum FocusActionRunner {
    static func run(_ actions: [FocusAction]) throws {
        var firstError: Error?
        for action in actions {
            let resolvedExecutableURL: URL
            let arguments: [String]
            switch action {
            case let .run(executable, actionArguments):
                resolvedExecutableURL = try executableURL(named: executable)
                arguments = actionArguments
            case let .appleScript(script):
                resolvedExecutableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                arguments = ["-e", script]
            }
            do {
                let result = try BoundedProcessRunner.run(
                    executableURL: resolvedExecutableURL,
                    arguments: arguments,
                    timeout: 10
                )
                if result.status != 0, firstError == nil {
                    firstError = FocusError.commandFailed(
                        resolvedExecutableURL.path,
                        result.status
                    )
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private static func executableURL(named executable: String) throws -> URL {
        if executable.hasPrefix("/") {
            return URL(fileURLWithPath: executable)
        }
        let trustedDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in trustedDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(executable)
                .resolvingSymlinksInPath()
            var metadata = stat()
            guard Darwin.lstat(candidate.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & 0o022 == 0,
                  metadata.st_uid == 0 || metadata.st_uid == getuid(),
                  FileManager.default.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            return candidate
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
