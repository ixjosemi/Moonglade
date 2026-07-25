import Foundation

import MoongladeCore

let arguments = Array(CommandLine.arguments.dropFirst())
let isHookInvocation = arguments.first == "hook"

/// The kernel-resolved path of this binary. argv[0] is whatever the caller
/// typed: invoked by bare name via PATH it resolves against the current
/// directory and could name a different file than the one running.
func currentExecutableURL() throws -> URL {
    guard let path = Bundle.main.executablePath else {
        throw CocoaError(.fileNoSuchFile)
    }
    return URL(fileURLWithPath: path).standardizedFileURL
}

do {
    let command = try CLICommand.parse(arguments: arguments)
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = environment["MOONGLADE_HOME"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".moonglade",
        isDirectory: true
    )
    let repository = StateRepository(
        directoryURL: homeDirectory.appendingPathComponent("state", isDirectory: true)
    )

    switch command {
    case .debug:
        _ = try ReaperService(repository: repository).reap()
        print(DebugRenderer.render(sessions: try repository.loadSessions()))
    case .install:
        try Installer(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            executableURL: try currentExecutableURL()
        ).install()
        print("Moonglade hooks installed.")
    case .uninstall:
        try Installer(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            executableURL: try currentExecutableURL()
        ).uninstall()
        print("Moonglade files removed.")
    case .doctor:
        let checks = InstallationDoctor(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        ).diagnose()
        for check in checks {
            print("\(check.passed ? "✓" : "✗") \(check.title): \(check.detail)")
        }
        if checks.contains(where: { !$0.passed }) {
            exit(1)
        }
    case let .claudeHook(event, processID):
        let payload = try BoundedInput.read(from: .standardInput)
        try ClaudeHookProcessor(repository: repository).process(
            event: event,
            payload: payload,
            environment: environment,
            processID: processID
        )
    case let .codexNotify(processID):
        try CodexNotifyProcessor(repository: repository).process(
            payload: try BoundedInput.read(from: .standardInput),
            processID: processID
        )
    }
} catch {
    if !isHookInvocation {
        FileHandle.standardError.write(Data("moonglade: \(error)\n".utf8))
        exit(1)
    }
}
