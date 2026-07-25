import Foundation

public enum CLIError: Error, Equatable, Sendable {
    case invalidArguments([String])
}

public enum CLICommand: Equatable, Sendable {
    case debug
    case install
    case uninstall
    case doctor
    case claudeHook(event: String, processID: Int32)
    case codexNotify(processID: Int32)

    public static func parse(arguments: [String]) throws -> CLICommand {
        if arguments == ["debug"] {
            return .debug
        }
        if arguments == ["install"] {
            return .install
        }
        if arguments == ["uninstall"] {
            return .uninstall
        }
        if arguments == ["doctor"] {
            return .doctor
        }
        if arguments.count == 5,
           arguments[0] == "hook",
           arguments[1] == "claude",
           arguments[3] == "--pid",
           let processID = Int32(arguments[4]) {
            return .claudeHook(event: arguments[2], processID: processID)
        }
        if arguments.count == 4,
           arguments[0] == "hook",
           arguments[1] == "codex-notify",
           arguments[2] == "--pid",
           let processID = Int32(arguments[3]) {
            return .codexNotify(processID: processID)
        }
        throw CLIError.invalidArguments(arguments)
    }
}
