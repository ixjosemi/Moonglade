import Foundation
import Observation

import MoongladeCore

enum TestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case let .expectation(message): message
        }
    }
}

final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        value -= 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class TestOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return false }
        isOpen = false
        return true
    }
}

func expect<T: Equatable>(_ actual: T, equals expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure.expectation("\(message): expected \(expected), got \(actual)")
    }
}

func testVersionOneStateDocumentReconstructsSession() throws {
    let data = Data(
        """
        {
          "schema_version": 1,
          "tool": "claude",
          "session_id": "session-1",
          "pid": 12345,
          "status": "needs_attention",
          "attention_reason": "permission",
          "cwd": "/Users/example/project",
          "started_at": "2026-07-18T10:00:00Z",
          "updated_at": "2026-07-18T10:05:32Z",
          "terminal": {
            "term_program": "ghostty",
            "iterm_session_id": null,
            "tmux_pane": "%3",
            "tty": "/dev/ttys004",
            "window_title_hint": "project — claude"
          }
        }
        """.utf8
    )

    let session = try AgentSession.decode(from: data)

    try expect(session.tool, equals: .claude, "tool")
    try expect(session.status, equals: .needsAttention, "status")
    try expect(session.attentionReason, equals: .permission, "attention reason")
    try expect(session.terminal.tmuxPane, equals: "%3", "tmux pane")
    try expect(session.projectName, equals: "project", "project name")
}

func testConvoySessionDecodesCurrentStep() throws {
    let data = Data(
        """
        {
          "schema_version": 1,
          "tool": "convoy",
          "session_id": "20260719-101010-abcd",
          "pid": 4242,
          "status": "working",
          "attention_reason": null,
          "cwd": "/tmp/project",
          "started_at": "2026-07-19T10:00:00Z",
          "updated_at": "2026-07-19T10:05:00Z",
          "terminal": {},
          "current_step": "security-audit"
        }
        """.utf8
    )

    let session = try AgentSession.decode(from: data)

    try expect(session.tool, equals: .convoy, "tool")
    try expect(session.currentStep, equals: "security-audit", "current step")

    let withoutStep = try AgentSession.decode(from: validStateJSON(sessionID: "plain", status: "idle"))
    try expect(withoutStep.currentStep, equals: nil, "absent step decodes as nil")
}

func testUnsupportedSchemaVersionIsRejected() throws {
    let data = Data(
        """
        {
          "schema_version": 2,
          "tool": "claude",
          "session_id": "session-1",
          "pid": 12345,
          "status": "working",
          "attention_reason": null,
          "cwd": "/tmp/project",
          "started_at": "2026-07-18T10:00:00Z",
          "updated_at": "2026-07-18T10:00:00Z",
          "terminal": {}
        }
        """.utf8
    )

    do {
        _ = try AgentSession.decode(from: data)
        throw TestFailure.expectation("schema version 2 was accepted")
    } catch let error as AgentSessionError {
        try expect(error, equals: .unsupportedSchemaVersion(2), "schema error")
    }
}

func testStateRepositoryReconstructsSessionsFromDisk() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = validStateJSON(sessionID: "session-1", status: "working")
    let second = validStateJSON(sessionID: "session-2", status: "idle")
    try first.write(to: directory.appendingPathComponent("claude-session-1.json"))
    try second.write(to: directory.appendingPathComponent("claude-session-2.json"))

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(Set(sessions.map(\.sessionID)), equals: ["session-1", "session-2"], "session IDs")
}

func testMissingStateDirectoryLoadsAsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(sessions.isEmpty, equals: true, "sessions")
}

func testMalformedStateDoesNotHideValidSessions() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try validStateJSON(sessionID: "valid", status: "working")
        .write(to: directory.appendingPathComponent("claude-valid.json"))
    try Data("not-json".utf8)
        .write(to: directory.appendingPathComponent("claude-broken.json"))

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(sessions.map(\.sessionID), equals: ["valid"], "valid sessions")
}

func testSavingSessionPublishesCanonicalStateFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try AgentSession.decode(
        from: validStateJSON(sessionID: "session/unsafe", status: "working")
    )

    try StateRepository(directoryURL: directory).save(session)

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    try expect(names, equals: ["claude-c2Vzc2lvbi91bnNhZmU.json"], "state file names")
}

func testStateFilesArePrivateAndSessionNamesDoNotCollide() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let first = try AgentSession.decode(from: validStateJSON(sessionID: "a/b", status: "working"))
    let second = try AgentSession.decode(from: validStateJSON(sessionID: "a_b", status: "working"))

    try repository.save(first)
    try repository.save(second)

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    try expect(names.count, equals: 2, "collision-resistant state file names")
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(names[0]).path)[.posixPermissions] as? NSNumber
    try expect(directoryMode?.intValue, equals: 0o700, "state directory permissions")
    try expect(fileMode?.intValue, equals: 0o600, "state file permissions")
}

func testStateRepositoryIgnoresSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let external = root.appendingPathComponent("external.json")
    try validStateJSON(sessionID: "linked", status: "working").write(to: external)
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("claude-linked.json"),
        withDestinationURL: external
    )

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(sessions.isEmpty, equals: true, "symbolic-link states")
}

func testStateRepositoryRejectsFIFOWithoutBlocking() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fifoURL = directory.appendingPathComponent("claude-fifo.json")
    guard Darwin.mkfifo(fifoURL.path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--load-state-directory", directory.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    try process.run()

    let completedPromptly = completion.wait(timeout: .now() + 0.5) == .success
    if !completedPromptly {
        process.terminate()
    }
    process.waitUntilExit()

    try expect(completedPromptly, equals: true, "FIFO state read returns without a writer")
    try expect(process.terminationStatus, equals: 0, "FIFO state read child status")
}

func testStateRepositoryDoesNotPreserveIdentityFromOversizedDocument() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processID = Int32(getpid())
    let identity = try SystemProcessScanner.processIdentity(of: processID)
        .unwrap(or: "test process identity was unavailable")
    let sessionID = "oversized-identity"
    let existing = AgentSession(
        tool: .claude,
        sessionID: sessionID,
        pid: processID,
        processIdentity: identity,
        status: .working,
        cwd: "/tmp/project",
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var oversizedData = try encoder.encode(existing)
    oversizedData.append(Data(repeating: 0x20, count: 1_048_577 - oversizedData.count))
    let encodedIdentifier = Data(sessionID.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let stateURL = directory.appendingPathComponent("claude-\(encodedIdentifier).json")
    try oversizedData.write(to: stateURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)

    try repository.save(AgentSession(
        tool: .claude,
        sessionID: sessionID,
        pid: processID,
        status: .idle,
        cwd: "/tmp/project",
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 200)
    ))

    let saved = try repository.loadSessions().first.unwrap(or: "replacement state was not saved")
    try expect(saved.processIdentity, equals: nil, "oversized document identity has no authority")
    let savedSize = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.size] as? NSNumber
    try expect(
        (savedSize?.intValue ?? Int.max) <= 1_048_576,
        equals: true,
        "replacement state remains within the secure-read limit"
    )
}

func testStateReadToleratesAConcurrentAtomicReplacement() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let stateURL = directory.appendingPathComponent("claude-replaced.json")
    try validStateJSON(sessionID: "replaced", status: "working").write(to: stateURL)
    let replacementGate = TestOnceGate()
    var repository = StateRepository(directoryURL: directory)
    repository.didReadDocumentForTesting = {
        guard replacementGate.consume() else { return }
        let temporaryURL = directory.appendingPathComponent("replacement.tmp")
        try? validStateJSON(sessionID: "replaced", status: "idle").write(to: temporaryURL)
        _ = Darwin.rename(temporaryURL.path, stateURL.path)
    }

    let sessions = try repository.loadSessions()

    try expect(sessions.map(\.sessionID), equals: ["replaced"], "concurrent replacement keeps session")
}

func testAnUnreadableDocumentDoesNotDeleteACustomSessionName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stateDirectory = root.appendingPathComponent("state")
    let namesURL = root.appendingPathComponent("session-names.json")
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let repository = StateRepository(directoryURL: stateDirectory)
    let session = try AgentSession.decode(from: validStateJSON(sessionID: "named", status: "idle"))
    try repository.save(session)
    let store = StateStore(repository: repository, nameOverridesFileURL: namesURL)
    try store.reload()
    store.rename(session, to: "Keep this name")
    let namesBefore = try Data(contentsOf: namesURL)
    let stateURL = try FileManager.default.contentsOfDirectory(
        at: stateDirectory,
        includingPropertiesForKeys: nil
    ).first { $0.pathExtension == "json" }.unwrap(or: "state file missing")
    try Data("not-json".utf8).write(to: stateURL)

    try store.reload()

    try expect(
        store.nameOverrides.displayName(for: session),
        equals: "Keep this name",
        "custom name survives incomplete load"
    )
    try expect(try Data(contentsOf: namesURL), equals: namesBefore, "name file is not rewritten")
}

func testAnUnreadableDocumentDoesNotRearmAnAcknowledgedSession() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let repository = StateRepository(directoryURL: directory)
    let session = try AgentSession.decode(
        from: validStateJSON(sessionID: "acknowledged", status: "needs_attention")
    )
    try repository.save(session)
    let store = StateStore(repository: repository)
    try store.reload()
    store.acknowledge(session)
    var attentionRaised = 0
    store.onAttentionRaised = { _ in attentionRaised += 1 }
    let stateURL = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).first { $0.pathExtension == "json" }.unwrap(or: "state file missing")
    try Data("not-json".utf8).write(to: stateURL)

    try store.reload()

    try expect(
        store.acknowledgments.isAcknowledged(session),
        equals: true,
        "acknowledgment survives incomplete load"
    )
    try expect(attentionRaised, equals: 0, "incomplete load does not rearm attention")
}

func testTwoDocumentsNamingTheSameSessionProduceOneRow() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let older = validStateJSON(sessionID: "duplicate", status: "working")
    var newer = validStateJSON(sessionID: "duplicate", status: "idle")
    newer = Data(String(decoding: newer, as: UTF8.self)
        .replacingOccurrences(of: "2026-07-18T10:00:00Z", with: "2026-07-18T10:01:00Z")
        .utf8)
    try older.write(to: directory.appendingPathComponent("claude-Z.json"))
    try newer.write(to: directory.appendingPathComponent("claude-A.json"))

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(sessions.count, equals: 1, "duplicate identity is deduplicated")
    try expect(sessions[0].status, equals: .idle, "newer duplicate wins")
}

func testClaudeSettingsMergeRefusesHooksValueThatIsNotAnObject() throws {
    do {
        _ = try ClaudeSettingsMerger.merge(
            settingsData: Data(#"{"hooks":[]}"#.utf8),
            hookCommand: "/tmp/moonglade-hook.sh"
        )
        throw TestFailure.expectation("malformed hooks value was accepted")
    } catch let error as InstallationError {
        try expect(error, equals: .invalidClaudeSettings, "malformed hooks value")
    }
}

func testClaudeSettingsMergeRefusesEventArrayContainingNonObject() throws {
    let original = Data(#"{"hooks":{"Stop":[{"hooks":[]},null]}}"#.utf8)
    do {
        _ = try ClaudeSettingsMerger.merge(
            settingsData: original,
            hookCommand: "/tmp/moonglade-hook.sh"
        )
        throw TestFailure.expectation("malformed event array was accepted")
    } catch let error as InstallationError {
        try expect(error, equals: .invalidClaudeSettings, "malformed event array")
    }
    try expect(original, equals: original, "malformed settings remain unchanged")
}

func testClaudeSettingsMergePreservesUnrelatedEventHooks() throws {
    let eventNames = ["SessionStart", "Notification", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
    let hooks = Dictionary(uniqueKeysWithValues: eventNames.map { event in
        (event, [["hooks": [["type": "command", "command": "user-\(event)" ]]]])
    })
    let original = try JSONSerialization.data(withJSONObject: ["hooks": hooks])

    let merged = try ClaudeSettingsMerger.merge(
        settingsData: original,
        hookCommand: "/tmp/moonglade-hook.sh"
    )
    let root = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
    let mergedHooks = root?["hooks"] as? [String: Any]
    for event in eventNames {
        let groups = mergedHooks?[event] as? [[String: Any]]
        let commands = groups?.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        try expect(commands?.contains("user-\(event)"), equals: true, "user hook survives \(event)")
    }
}

func testClaudeSettingsRemoveRefusesMalformedShapesAndLeavesNoEmptyHusks() throws {
    for malformed in [
        Data(#"{"hooks":[]}"#.utf8),
        Data(#"{"hooks":{"Stop":[null]}}"#.utf8),
    ] {
        do {
            _ = try ClaudeSettingsMerger.remove(
                settingsData: malformed,
                hookCommand: "/tmp/moonglade-hook.sh"
            )
            throw TestFailure.expectation("malformed settings were accepted")
        } catch let error as InstallationError {
            try expect(error, equals: .invalidClaudeSettings, "malformed remove shape")
        }
    }

    let removed = try ClaudeSettingsMerger.remove(
        settingsData: Data("{}".utf8),
        hookCommand: "/tmp/moonglade-hook.sh"
    )
    let root = try JSONSerialization.jsonObject(with: removed) as? [String: Any]
    try expect(root?["hooks"] == nil, equals: true, "remove leaves no empty hooks object")
}

func testFirstInstallWritesOneTimeSettingsBackup() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDirectory = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
    let original = Data(#"{"custom":true}"#.utf8)
    try original.write(to: settingsURL)
    let installer = Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!)

    try installer.install()
    let backupURL = claudeDirectory.appendingPathComponent("settings.json.moonglade-backup")
    try expect(try Data(contentsOf: backupURL), equals: original, "first settings backup bytes")
    let mode = try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber
    try expect(mode?.intValue, equals: 0o600, "settings backup permissions")
    try installer.install()
    try expect(try Data(contentsOf: backupURL), equals: original, "backup is one-time")
}

func testInstallingThroughASymlinkedSettingsFileWritesTheTarget() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDirectory = home.appendingPathComponent(".claude")
    let targetURL = home.appendingPathComponent("dotfiles/settings.json")
    let linkURL = claudeDirectory.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("{}".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    var metadata = stat()
    try expect(Darwin.lstat(linkURL.path, &metadata), equals: 0, "settings link remains")
    try expect(metadata.st_mode & S_IFMT, equals: S_IFLNK, "settings remains a symlink")
    let installed = String(decoding: try Data(contentsOf: targetURL), as: UTF8.self)
    try expect(installed.contains("claude-hook.sh"), equals: true, "target is updated")
}

func testPreparingAnAlreadyPrivateDirectoryDoesNotTouchItsMode() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.prepareDirectory()
    var firstStat = stat()
    guard Darwin.lstat(directory.path, &firstStat) == 0 else { throw POSIXError(.EIO) }
    try repository.prepareDirectory()
    var secondStat = stat()
    guard Darwin.lstat(directory.path, &secondStat) == 0 else { throw POSIXError(.EIO) }

    try expect(firstStat.st_ctimespec.tv_sec, equals: secondStat.st_ctimespec.tv_sec, "directory ctime seconds")
    try expect(firstStat.st_ctimespec.tv_nsec, equals: secondStat.st_ctimespec.tv_nsec, "directory ctime nanoseconds")
}

func testConvoyOwnedOpenCodeDocumentsAreNotDecoded() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.mergeConvoyOwnedOpenCodeSessionIDs(["owned"])
    try repository.save(AgentSession(
        tool: .opencode,
        sessionID: "owned",
        pid: 1,
        status: .working,
        cwd: "/tmp/owned",
        startedAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    ))
    try repository.save(AgentSession(
        tool: .claude,
        sessionID: "native",
        pid: 2,
        status: .working,
        cwd: "/tmp/native",
        startedAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    ))
    StateRepository.documentsDecodedForTesting = 0

    let snapshot = try repository.loadSnapshot()

    try expect(snapshot.sessions.map(\.sessionID), equals: ["native"], "owned OpenCode is filtered")
    try expect(StateRepository.documentsDecodedForTesting, equals: 1, "owned OpenCode is not decoded")
}

func testPruningKeepsOverlaysForConvoyOwnedOpenCodeSessions() throws {
    // Skipping the decode of a Convoy-owned document keeps it out of the
    // lifecycle list, but the document and its overlay are still owned and
    // still on disk. Orphan pruning reads that list, so it must not mistake a
    // suppressed session for one whose owner is gone.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let owned = AgentSession(
        tool: .opencode,
        sessionID: "owned-phase",
        pid: Int32(getpid()),
        status: .working,
        cwd: "/tmp/owned-phase",
        startedAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    try repository.save(owned)
    var snapshot = try repository.loadSnapshot()
    _ = try repository.saveEnrichment(
        for: owned,
        process: DetectedAgentProcess(
            tool: .opencode,
            processID: Int32(getpid()),
            processIdentity: SystemProcessScanner.processIdentity(of: Int32(getpid())),
            cwd: "/tmp/owned-phase",
            terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys001")
        ),
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys001"),
        updating: &snapshot
    )
    let overlayURL = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).first { $0.pathExtension == "overlay" }.unwrap(or: "overlay was not written")
    try repository.mergeConvoyOwnedOpenCodeSessionIDs(["owned-phase"])

    try repository.pruneOrphanedEnrichments(against: try repository.loadSnapshot())

    try expect(
        FileManager.default.fileExists(atPath: overlayURL.path),
        equals: true,
        "a suppressed session's overlay is not an orphan"
    )
}

func testPruningRemovesOverlaysWithNoLifecycleOwner() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let orphanURL = directory.appendingPathComponent("enrichment-claude-b3JwaGFu.overlay")
    try Data("{}".utf8).write(to: orphanURL)

    try repository.pruneOrphanedEnrichments(against: try repository.loadSnapshot())

    try expect(
        FileManager.default.fileExists(atPath: orphanURL.path),
        equals: false,
        "an overlay with no lifecycle owner is still pruned"
    )
}

func testStateFilenameIdentifierRoundTripsSpecialCharacters() throws {
    let repository = StateRepository(directoryURL: FileManager.default.temporaryDirectory)
    let identifier = "session/+with/slash"
    let encoded = try repository.encodedIdentifierForTesting(identifier)
    try expect(
        repository.decodedIdentifierForTesting(encoded),
        equals: identifier,
        "state filename identifier round trip"
    )
}

func testASubprocessThatNeverExitsIsTerminatedAtItsDeadline() throws {
    let startedAt = Date()
    do {
        _ = try BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.2
        )
        throw TestFailure.expectation("non-terminating process was accepted")
    } catch let error as POSIXError {
        try expect(error.code, equals: .ETIMEDOUT, "process timeout error")
    }
    try expect(Date().timeIntervalSince(startedAt) < 1, equals: true, "timeout is bounded")
}

func testASubprocessThatOverfillsItsPipeStillCompletes() throws {
    let result = try BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/dd"),
        arguments: ["if=/dev/zero", "bs=1048576", "count=1"],
        timeout: 2,
        maximumOutputBytes: 2 * 1_048_576
    )

    try expect(result.status, equals: 0, "large-output process status")
    try expect(result.output.count, equals: 1_048_576, "large output is drained")
}

func testAnOrphanHoldingThePipeDoesNotTurnSuccessIntoATimeout() throws {
    // A child may leave behind a grandchild that inherited its stdout — a
    // shell backgrounding a helper is enough. The command itself exited
    // successfully and wrote everything it ever will, so the runner must
    // return that output after its drain grace instead of throwing ETIMEDOUT.
    // The shell here is a test fixture creating the orphan, not a production
    // codepath; product code never executes strings through a shell.
    let result = try BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "echo ready; sleep 5 &"],
        timeout: 3
    )

    try expect(result.status, equals: 0, "the command itself exited cleanly")
    try expect(
        String(decoding: result.output, as: UTF8.self),
        equals: "ready\n",
        "output written before exit is returned despite the held pipe"
    )
}

func testTheFrontTerminalQueryIsNotRepeatedWithinItsTTL() throws {
    let queryCount = TestCounter()
    let cache = FrontTerminalQueryCache(
        successTimeToLive: 30,
        failureTimeToLive: 60
    ) {
        queryCount.increment()
        return GhosttyFrontTerminal(terminalID: "front", workingDirectory: "/tmp/project")
    }
    let first = Date(timeIntervalSince1970: 1_000)
    _ = cache.frontTerminal(now: first)
    _ = cache.frontTerminal(now: first.addingTimeInterval(2))

    try expect(queryCount.read(), equals: 1, "front terminal query TTL")
}

func testTheHeartbeatBacksOffAfterAScanFindsNoAgents() throws {
    try expect(ObservationCadence.interval(afterAgentCount: 0), equals: 30, "idle heartbeat interval")
    try expect(ObservationCadence.interval(afterAgentCount: 1), equals: 5, "active heartbeat interval")
}

func testTheHeartbeatReturnsToFiveSecondsAsSoonAsAnAgentAppears() throws {
    try expect(ObservationCadence.interval(afterAgentCount: 0), equals: 30, "empty cadence")
    try expect(ObservationCadence.interval(afterAgentCount: 2), equals: 5, "active cadence")
    try expect(
        ObservationCadence.staleSessionInterval(afterAgentCount: 0),
        equals: 30,
        "stale session interval follows idle cadence"
    )
}

func testPointerMonitorsAreUnnecessaryWithOneDisplay() throws {
    try expect(PanelSynchronizationPolicy.needsPointerMonitors(displayCount: 1), equals: false, "single display monitors")
    try expect(PanelSynchronizationPolicy.needsPointerMonitors(displayCount: 2), equals: true, "multi-display monitors")
    try expect(
        PanelSynchronizationPolicy.shouldDeferSelection(
            current: 1,
            desired: 2,
            available: [2],
            menuIsVisible: true
        ),
        equals: false,
        "disconnected display is not deferred"
    )
}

func testTheCardHeightBudgetIncludesTheErrorRow() throws {
    try expect(SessionMenuLayout.maximumCardHeight(), equals: 316, "card height without error")
    try expect(SessionMenuLayout.maximumCardHeight(hasError: true), equals: 341, "card height with error")
    try expect(NotchLayout.menuMaxHeight, equals: 341, "the panel budget always reserves the error row")
}

func testAHardwareNotchWithNoMenuBarStillUsesNotchGeometry() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 0,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    try expect(layout.presentation, equals: .notch, "hardware notch presentation")
    // A zero-height bar would be invisible and unhoverable; the standard
    // menu-bar height stands in until the safe area returns.
    try expect(layout.height, equals: 24, "the bar keeps a usable height without a safe area")
}

func testNotchLayoutSupportsASecondaryDisplayOrigin() throws {
    let layout = NotchLayout(
        screenMinX: 1_920,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 2_586,
        rightNotchEdgeX: 2_766
    )
    try expect(layout.originX >= 1_920, equals: true, "secondary display origin")
}

func testNotchLayoutGuardsNonFiniteGeometry() throws {
    let layout = NotchLayout(
        screenMinX: .nan,
        screenWidth: .infinity,
        screenMaxY: .nan,
        safeAreaTop: .infinity,
        leftNotchEdgeX: .nan,
        rightNotchEdgeX: .infinity,
        menuBarHeight: .nan
    )
    try expect(layout.originX.isFinite, equals: true, "finite origin")
    try expect(layout.originY.isFinite, equals: true, "finite vertical origin")
    try expect(layout.width.isFinite, equals: true, "finite width")
}

func testAppleScriptStringEscapesEverySpecialCharacter() throws {
    let values = [
        "quote\"value": "quote\\\"value",
        "slash\\value": "slash\\\\value",
        "trailing\\": "trailing\\\\",
        "line\nvalue": "line value",
        "return\rvalue": "return value",
        #"curly“quote”"#: #"curly“quote”"#,
        "emoji 🧪": "emoji 🧪",
    ]
    for (input, expected) in values {
        try expect(FocusPlanner.appleScriptString(input), equals: expected, "AppleScript escaping")
    }
}

/// A freshly launched Claude sits at the prompt waiting for input, so its
/// lifecycle starts idle rather than pretending the agent is already working.
func testClaudeSessionStartCreatesIdleState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let processor = ClaudeHookProcessor(repository: StateRepository(directoryURL: directory))
    let payload = Data(#"{"session_id":"claude-1","cwd":"/tmp/my-project"}"#.utf8)
    let now = Date(timeIntervalSince1970: 1_752_836_400)

    try processor.process(
        event: "SessionStart",
        payload: payload,
        environment: ["TERM_PROGRAM": "ghostty", "TMUX_PANE": "%7"],
        processID: 4321,
        now: now
    )

    let session = try StateRepository(directoryURL: directory).loadSessions().first
        .unwrap(or: "session was not saved")
    try expect(session.status, equals: .idle, "session status")
    try expect(session.startedAt, equals: now, "started at")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal program")
    try expect(session.terminal.tmuxPane, equals: "%7", "tmux pane")
}

/// SessionStart also fires after /compact, /clear, and auto-compaction —
/// mid-conversation moments that say nothing about whether Claude is
/// working. An existing session keeps its current status.
func testClaudeSessionStartPreservesExistingStatus() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processor = ClaudeHookProcessor(repository: repository)
    let payload = Data(#"{"session_id":"claude-1","cwd":"/tmp/project"}"#.utf8)
    try processor.process(
        event: "UserPromptSubmit",
        payload: payload,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 100)
    )

    try processor.process(
        event: "SessionStart",
        payload: payload,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 200)
    )

    let session = try repository.loadSessions().first.unwrap(or: "session was not saved")
    try expect(session.status, equals: .working, "status preserved across auto-compact")
    try expect(session.startedAt, equals: Date(timeIntervalSince1970: 100), "original start time")
}

func testClaudeLifecycleUpdatePreservesOnlyMatchingProcessIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processID = Int32(getpid())
    let identity = try SystemProcessScanner.processIdentity(of: processID)
        .unwrap(or: "test process identity was unavailable")
    try repository.save(AgentSession(
        tool: .claude,
        sessionID: "claude-identity",
        pid: identity.processID,
        processIdentity: identity,
        status: .working,
        cwd: "/tmp/project",
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    ))
    let processor = ClaudeHookProcessor(repository: repository)
    let payload = Data(#"{"session_id":"claude-identity","cwd":"/tmp/project"}"#.utf8)

    try processor.process(
        event: "Stop",
        payload: payload,
        environment: [:],
        processID: processID,
        now: Date(timeIntervalSince1970: 200)
    )

    let updated = try repository.loadSessions().first.unwrap(or: "session was not saved")
    try expect(updated.status, equals: .idle, "lifecycle status")
    try expect(updated.processIdentity, equals: identity, "same-process identity")

    try processor.process(
        event: "UserPromptSubmit",
        payload: payload,
        environment: [:],
        processID: 5432,
        now: Date(timeIntervalSince1970: 300)
    )

    let rebound = try repository.loadSessions().first.unwrap(or: "rebound session was not saved")
    try expect(rebound.pid, equals: 5432, "rebound process ID")
    try expect(rebound.processIdentity, equals: nil, "stale identity after process change")

    let staleIdentity = ProcessIdentity(
        processID: processID,
        kernelStartTimeMicroseconds: identity.kernelStartTimeMicroseconds + 1
    )
    try repository.save(AgentSession(
        tool: .claude,
        sessionID: "claude-identity",
        pid: processID,
        processIdentity: staleIdentity,
        status: .working,
        cwd: "/tmp/project",
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 400)
    ))
    try processor.process(
        event: "Stop",
        payload: payload,
        environment: [:],
        processID: processID,
        now: Date(timeIntervalSince1970: 500)
    )

    let recycled = try repository.loadSessions().first.unwrap(or: "recycled session was not saved")
    try expect(recycled.processIdentity, equals: nil, "stale identity for recycled PID")
}

func testClaudePermissionNotificationRequestsAttention() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let processor = ClaudeHookProcessor(repository: StateRepository(directoryURL: directory))
    let start = Data(#"{"session_id":"claude-1","cwd":"/tmp/project"}"#.utf8)
    try processor.process(
        event: "SessionStart",
        payload: start,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 100)
    )
    let notification = Data(
        #"{"session_id":"claude-1","cwd":"/tmp/project","notification_type":"permission_prompt"}"#.utf8
    )

    try processor.process(
        event: "Notification",
        payload: notification,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 200)
    )

    let session = try StateRepository(directoryURL: directory).loadSessions().first
        .unwrap(or: "session was not saved")
    try expect(session.status, equals: .needsAttention, "session status")
    try expect(session.attentionReason, equals: .permission, "attention reason")
    try expect(session.startedAt, equals: Date(timeIntervalSince1970: 100), "original start time")

    let idleNudge = Data(
        #"{"session_id":"claude-1","cwd":"/tmp/project","notification_type":"idle_prompt"}"#.utf8
    )
    try processor.process(
        event: "Notification",
        payload: idleNudge,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 300)
    )

    let nudged = try StateRepository(directoryURL: directory).loadSessions().first
        .unwrap(or: "session was not saved")
    try expect(nudged.status, equals: .needsAttention, "idle nudge keeps pending permission red")
    try expect(nudged.attentionReason, equals: .permission, "idle nudge keeps permission reason")
}

/// Live incident 2026-07-20: answering a permission prompt (or an
/// AskUserQuestion, which Claude Code notifies about the same way) is a
/// tool result, not a typed prompt — no UserPromptSubmit ever fires for it.
/// Without a signal tied to the tool call actually completing, the red dot
/// stays lit through every bit of work Claude does for the rest of the turn.
func testClaudePostToolUseClearsResolvedPermissionPrompt() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processor = ClaudeHookProcessor(repository: repository)
    let payload = Data(#"{"session_id":"claude-1","cwd":"/tmp/project"}"#.utf8)
    try processor.process(
        event: "SessionStart",
        payload: payload,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 100)
    )
    try processor.process(
        event: "Notification",
        payload: Data(
            #"{"session_id":"claude-1","cwd":"/tmp/project","notification_type":"permission_prompt"}"#.utf8
        ),
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 200)
    )

    try processor.process(
        event: "PostToolUse",
        payload: payload,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 300)
    )

    let session = try repository.loadSessions().first.unwrap(or: "session was not saved")
    try expect(session.status, equals: .working, "resolved permission prompt resumes work")
    try expect(session.attentionReason, equals: nil, "attention reason clears with the prompt")
}

func testClaudeLifecycleEventsProduceExpectedStates() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processor = ClaudeHookProcessor(repository: repository)
    let basePayload = #"{"session_id":"claude-1","cwd":"/tmp/project"}"#
    try processor.process(
        event: "SessionStart",
        payload: Data(basePayload.utf8),
        environment: [:],
        processID: 99
    )
    let transitions: [(event: String, payload: String, status: SessionStatus, reason: AttentionReason?)] = [
        (
            "Notification",
            #"{"session_id":"claude-1","cwd":"/tmp/project","notification_type":"idle_prompt"}"#,
            .idle,
            nil
        ),
        ("UserPromptSubmit", basePayload, .working, nil),
        ("Stop", basePayload, .idle, nil),
        ("SessionEnd", basePayload, .ended, nil),
    ]

    for transition in transitions {
        try processor.process(
            event: transition.event,
            payload: Data(transition.payload.utf8),
            environment: [:],
            processID: 99
        )
        let session = try repository.loadSessions().first.unwrap(or: "session was not saved")
        try expect(session.status, equals: transition.status, "\(transition.event) status")
        try expect(session.attentionReason, equals: transition.reason, "\(transition.event) reason")
    }
}

extension Optional {
    func unwrap(or message: String) throws -> Wrapped {
        guard let self else { throw TestFailure.expectation(message) }
        return self
    }
}

func validStateJSON(
    sessionID: String,
    status: String,
    pid: Int32 = 12345,
    tool: String = "claude",
    cwd: String = "/tmp/project",
    source: String? = nil
) -> Data {
    let sourceField = source.map { ",\n  \"source\": \"\($0)\"" } ?? ""
    return Data(
        """
        {
          "schema_version": 1,
          "tool": "\(tool)",
          "session_id": "\(sessionID)",
          "pid": \(pid),
          "status": "\(status)",
          "attention_reason": null,
          "cwd": "\(cwd)",
          "started_at": "2026-07-18T10:00:00Z",
          "updated_at": "2026-07-18T10:00:00Z",
          "terminal": {}\(sourceField)
        }
        """.utf8
    )
}

func testReaperDeletesStateForDeadProcess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ghost", status: "working", pid: 999_999)
    ))

    let result = try ReaperService(repository: repository, processScanner: TestProcessScanner([])).reap()

    try expect(result.removedSessionIDs, equals: ["ghost"], "removed sessions")
    try expect(try repository.loadSessions().isEmpty, equals: true, "remaining sessions")
}

func testReaperDropsStaleNativeStateWhenTheAgentIsNoLongerDetected() throws {
    // A hook can miss its shutdown event when its terminal is killed. Once a
    // document has been quiet for a full reaper interval, a live but unrelated
    // PID must not keep that stale native session visible forever.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 10_000)
    try repository.save(AgentSession(
        tool: .claude,
        sessionID: "stale-native",
        pid: Int32(getpid()),
        status: .working,
        cwd: "/tmp/stale-native",
        startedAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-6)
    ))

    let reaper = ReaperService(repository: repository, now: { now })

    let firstResult = try reaper.reap(detected: [])

    try expect(
        firstResult.removedSessionIDs,
        equals: [],
        "one scanner miss does not delete a live native session"
    )
    try expect(
        try repository.loadSessions().map(\.sessionID),
        equals: ["stale-native"],
        "native document survives the first scanner miss"
    )

    let result = try reaper.reap(detected: [])

    try expect(result.removedSessionIDs, equals: ["stale-native"], "stale native session removed")
    try expect(try repository.loadSessions().isEmpty, equals: true, "stale document removed")
}

func testReaperRebindsByTerminalWhenSeveralProcessesShareADirectory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 10_000)
    try repository.save(AgentSession(
        tool: .opencode,
        sessionID: "terminal-specific",
        pid: 1,
        status: .needsAttention,
        cwd: "/tmp/shared-project",
        startedAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-30),
        terminal: TerminalContext(tty: "/dev/ttys001")
    ))
    let matchingProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/shared-project",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )
    let otherProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getppid()),
        cwd: "/tmp/shared-project",
        terminal: TerminalContext(tty: "/dev/ttys002")
    )

    _ = try ReaperService(repository: repository, now: { now }).reap(
        detected: [matchingProcess, otherProcess]
    )

    let rebound = try repository.loadSessions().first {
        $0.sessionID == "terminal-specific"
    }.unwrap(or: "terminal-specific native session disappeared")
    try expect(rebound.pid, equals: matchingProcess.processID, "terminal identity selects the right process")
    try expect(rebound.status, equals: .needsAttention, "native status survives an unambiguous terminal rebind")
}

func testReaperDoesNotRebindAcrossConflictingTerminalIdentities() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 10_000)
    try repository.save(AgentSession(
        tool: .opencode,
        sessionID: "stale-terminal",
        pid: 1,
        status: .needsAttention,
        cwd: "/tmp/shared-project",
        startedAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-30),
        terminal: TerminalContext(tty: "/dev/ttys001")
    ))
    let differentTerminal = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/shared-project",
        terminal: TerminalContext(tty: "/dev/ttys002")
    )

    _ = try ReaperService(repository: repository, now: { now }).reap(
        detected: [differentTerminal]
    )

    let original = try repository.loadSessions().first {
        $0.sessionID == "stale-terminal"
    }.unwrap(or: "native session was rebound across conflicting terminal identities")
    try expect(original.pid, equals: 1, "different tty must not be treated as the same session")
}

struct TestProcessScanner: ProcessScanning {
    let processes: [DetectedAgentProcess]

    init(_ processes: [DetectedAgentProcess]) {
        self.processes = processes
    }

    func activeProcesses() throws -> [DetectedAgentProcess] { processes }
}

func testReaperRejectsRecycledProcessIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let pid = Int32(getpid())
    let currentIdentity = try SystemProcessScanner.processIdentity(of: pid)
        .unwrap(or: "test process has no kernel identity")
    let oldIdentity = ProcessIdentity(
        processID: pid,
        kernelStartTimeMicroseconds: currentIdentity.kernelStartTimeMicroseconds - 1
    )
    try repository.save(AgentSession(
        tool: .claude, sessionID: "old-generation", pid: pid,
        processIdentity: oldIdentity, status: .working, cwd: "/tmp/reused",
        startedAt: Date(), updatedAt: Date()
    ))
    let replacement = DetectedAgentProcess(
        tool: .claude, processID: pid, processIdentity: currentIdentity,
        cwd: "/tmp/reused", terminal: TerminalContext(tty: "/dev/ttys001")
    )

    let result = try ReaperService(repository: repository).reap(detected: [replacement])

    try expect(result.removedSessionIDs, equals: ["old-generation"], "recycled PID removes old state")
    let surviving = try repository.loadSessions().first.unwrap(or: "replacement fallback missing")
    try expect(surviving.source, equals: .reaper, "new process gets fresh fallback state")
    try expect(surviving.processIdentity, equals: currentIdentity, "replacement identity persisted")
}

func testReaperTreatsZombieAsDead() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var child: pid_t = 0
    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
    defer { free(arguments[0]) }
    let spawnStatus = arguments.withUnsafeMutableBufferPointer {
        posix_spawn(&child, "/usr/bin/true", nil, nil, $0.baseAddress, environ)
    }
    guard spawnStatus == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: spawnStatus) ?? .EAGAIN)
    }
    defer { var status: Int32 = 0; waitpid(child, &status, 0) }
    usleep(50_000)
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession(
        tool: .claude, sessionID: "zombie", pid: child, status: .working,
        cwd: "/tmp/zombie", startedAt: Date(), updatedAt: Date()
    ))

    let result = try ReaperService(repository: repository).reap(detected: [])

    try expect(result.removedSessionIDs, equals: ["zombie"], "zombie removed immediately")
}

func testReaperCreatesFallbackStateForUntrackedProcess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let process = DetectedAgentProcess(
        tool: .claude,
        processID: Int32(getpid()),
        cwd: "/tmp/fallback",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    _ = try ReaperService(
        repository: repository,
        processScanner: TestProcessScanner([process])
    ).reap()

    let session = try repository.loadSessions().first.unwrap(or: "fallback state was not saved")
    try expect(session.source, equals: .reaper, "session source")
    try expect(session.pid, equals: Int32(getpid()), "session PID")
    // A freshly-detected process carries no real signal yet — idle (the
    // silent baseline) beats guessing "working" and lighting the spinner
    // for a session that may just be sitting at an idle prompt.
    try expect(session.status, equals: .idle, "fallback status before any plugin/hook signal arrives")
}

func testReaperSkipsFallbackForProcessWithoutTerminalIdentity() throws {
    // Editor extension hosts spawn bundled agent binaries with pipes, not
    // terminals: Cursor's ChatGPT extension runs its own `codex` with no
    // controlling tty, no terminal-app ancestor, and no surface. A reaper
    // fallback for such a process is a phantom session — it owns no
    // surface the user could ever see it on.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let process = DetectedAgentProcess(
        tool: .codex,
        processID: Int32(getpid()),
        cwd: "/",
        terminal: TerminalContext()
    )

    let result = try ReaperService(
        repository: repository,
        processScanner: TestProcessScanner([process])
    ).reap()

    try expect(result.createdSessionIDs, equals: [], "no fallback for a terminal-less process")
    try expect(try repository.loadSessions().isEmpty, equals: true, "phantom session not persisted")
}

func testReaperRemovesFallbackWhoseProcessHasNoTerminalIdentity() throws {
    // Phantoms persisted before the visibility gate must not linger: the
    // process is still alive, so plain liveness keeps the document, but it
    // owns no terminal and was never a user-visible session.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let pid = Int32(getpid())
    let identity = try SystemProcessScanner.processIdentity(of: pid)
        .unwrap(or: "test process has no kernel identity")
    try repository.save(AgentSession(
        tool: .codex, sessionID: "reaper-\(pid)", pid: pid,
        processIdentity: identity, status: .idle, cwd: "/",
        startedAt: Date(), updatedAt: Date(), source: .reaper
    ))
    let process = DetectedAgentProcess(
        tool: .codex, processID: pid, processIdentity: identity,
        cwd: "/", terminal: TerminalContext()
    )

    let result = try ReaperService(repository: repository).reap(detected: [process])

    try expect(result.removedSessionIDs, equals: ["reaper-\(pid)"], "phantom fallback removed")
    try expect(try repository.loadSessions().isEmpty, equals: true, "no sessions remain")
}

func testReaperCreatesFallbackWithTerminalHostButNoTTY() throws {
    // tmux panes, cmux windows, and shells detached from their controlling
    // terminal can lack a tty while a terminal-app ancestor still marks the
    // process as user-visible. Any single surface signal is enough.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let process = DetectedAgentProcess(
        tool: .codex,
        processID: Int32(getpid()),
        cwd: "/tmp/terminal-hosted",
        terminal: TerminalContext(termProgram: "ghostty")
    )

    let result = try ReaperService(
        repository: repository,
        processScanner: TestProcessScanner([process])
    ).reap()

    try expect(
        result.createdSessionIDs,
        equals: ["reaper-\(getpid())"],
        "terminal-hosted process still earns its fallback"
    )
}

func testReaperReapsAgainstProvidedScan() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ghost", status: "working", pid: 999_999)
    ))
    let liveProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/shared-scan",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    // A scheduler scans once per tick and hands the result to the reaper,
    // so reaping must work against a provided scan without rescanning.
    let result = try ReaperService(repository: repository).reap(detected: [liveProcess])

    try expect(result.removedSessionIDs, equals: ["ghost"], "removed sessions")
    try expect(result.createdSessionIDs, equals: ["reaper-\(getpid())"], "created sessions")
    let session = try repository.loadSessions().first.unwrap(or: "fallback state was not saved")
    try expect(session.cwd, equals: "/tmp/shared-scan", "fallback cwd")
}

func testReaperRebindsDaemonHostedSessionToVisibleProcess() throws {
    // The OpenCode plugin runs inside the detached `opencode2 serve` daemon,
    // so its state documents record the daemon PID — alive forever and never
    // present in a scan. Such a session must adopt the PID of the visible
    // same-tool process in its directory: no duplicate fallback appears and
    // the session dies with the terminal instead of outliving it.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 100)
    try repository.save(AgentSession(
        tool: .opencode, sessionID: "daemon-doc", pid: 1, status: .idle,
        cwd: "/tmp/oc-project", startedAt: now, updatedAt: now
    ))
    let visibleProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/oc-project",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    let result = try ReaperService(repository: repository).reap(detected: [visibleProcess])

    try expect(result.createdSessionIDs, equals: [], "no fallback for an adopted process")
    let session = try repository.loadSessions().first.unwrap(or: "daemon session disappeared")
    try expect(session.sessionID, equals: "daemon-doc", "session identity survives")
    try expect(session.pid, equals: Int32(getpid()), "session adopts the visible PID")
}

func testReaperAdoptsScannedGhosttyTerminalForNativeSession() throws {
    // Hook- and plugin-written documents cannot know which Ghostty surface
    // hosts their process, so focusing them falls back to title heuristics
    // that break as soon as agents rewrite tab titles. The process scan
    // resolves the exact surface — native documents must adopt it.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let writtenAt = Date(timeIntervalSince1970: 1_000)
    try repository.save(AgentSession(
        tool: .opencode,
        sessionID: "native-doc",
        pid: Int32(getpid()),
        status: .working,
        cwd: "/tmp/oc-project",
        startedAt: writtenAt,
        updatedAt: writtenAt,
        terminal: TerminalContext(
            termProgram: "ghostty",
            tty: "/dev/ttys009",
            windowTitleHint: "oc-project — opencode"
        )
    ))
    let lifecycleURL = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).first { $0.pathExtension == "json" }.unwrap(or: "lifecycle file missing")
    let lifecycleDataBeforeEnrichment = try Data(contentsOf: lifecycleURL)
    let scannedProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/oc-project",
        terminal: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "term-42",
            windowTitleHint: "🟢 live agent title"
        )
    )

    _ = try ReaperService(repository: repository).reap(detected: [scannedProcess])

    let session = try repository.loadSessions().first.unwrap(or: "native session disappeared")
    try expect(session.terminal.ghosttyTerminalID, equals: "term-42", "adopted terminal ID")
    try expect(session.terminal.tty, equals: "/dev/ttys009", "document tty preserved")
    try expect(session.terminal.windowTitleHint, equals: "🟢 live agent title", "live title adopted")
    try expect(session.updatedAt, equals: writtenAt, "enrichment is not activity")
    try expect(
        try Data(contentsOf: lifecycleURL),
        equals: lifecycleDataBeforeEnrichment,
        "enrichment does not replace integration lifecycle bytes"
    )
    let enrichmentFileURLs = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    let enrichmentURL = try enrichmentFileURLs.first { $0.pathExtension == "overlay" }
        .unwrap(or: "enrichment overlay missing from \(enrichmentFileURLs.map(\.lastPathComponent))")
    try expect(
        enrichmentURL.lastPathComponent,
        equals: "enrichment-opencode-bmF0aXZlLWRvYw.overlay",
        "enrichment uses canonical encoded filename"
    )
    let enrichmentMode = try FileManager.default.attributesOfItem(
        atPath: enrichmentURL.path
    )[.posixPermissions] as? NSNumber
    try expect(enrichmentMode?.intValue, equals: 0o600, "enrichment overlay permissions")
    let enrichmentJSON = try JSONSerialization.jsonObject(
        with: Data(contentsOf: enrichmentURL)
    ) as? [String: Any]
    try expect(enrichmentJSON?["schema_version"] as? Int, equals: 1, "enrichment schema")

    // A second pass with the same scan must not rewrite the document.
    let firstPassData = try Data(contentsOf: lifecycleURL)
    let firstPassModifiedAt = try lifecycleURL.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
    let firstEnrichmentData = try Data(contentsOf: enrichmentURL)
    let firstEnrichmentModifiedAt = try enrichmentURL.resourceValues(
        forKeys: [.contentModificationDateKey]
    ).contentModificationDate
    usleep(100_000)
    _ = try ReaperService(repository: repository).reap(detected: [scannedProcess])
    try expect(try Data(contentsOf: lifecycleURL), equals: firstPassData, "document content stable")
    let secondPassModifiedAt = try lifecycleURL.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
    try expect(secondPassModifiedAt, equals: firstPassModifiedAt, "document not rewritten")
    try expect(
        try Data(contentsOf: enrichmentURL),
        equals: firstEnrichmentData,
        "unchanged enrichment content stable"
    )
    let secondEnrichmentModifiedAt = try enrichmentURL.resourceValues(
        forKeys: [.contentModificationDateKey]
    ).contentModificationDate
    try expect(
        secondEnrichmentModifiedAt,
        equals: firstEnrichmentModifiedAt,
        "unchanged enrichment not rewritten"
    )

    // The tab title feeds the row title, so a meaningful rename must land
    // in the document even though the surface id is already adopted.
    let retitledProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/oc-project",
        terminal: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "term-42",
            windowTitleHint: "🟢 fixing the reaper loop"
        )
    )
    _ = try ReaperService(repository: repository).reap(detected: [retitledProcess])
    let retitled = try repository.loadSessions().first.unwrap(or: "native session disappeared")
    try expect(
        retitled.terminal.windowTitleHint,
        equals: "🟢 fixing the reaper loop",
        "meaningful title change adopted"
    )
    try expect(retitled.updatedAt, equals: writtenAt, "title refresh is not activity")

    // Spinner and status-emoji churn cleans to the same display title and
    // must not rewrite the document every tick.
    let decoratedData = try Data(contentsOf: lifecycleURL)
    let decoratedEnrichmentData = try Data(contentsOf: enrichmentURL)
    let spinnerProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/oc-project",
        terminal: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "term-42",
            windowTitleHint: "🟡 fixing the reaper loop…"
        )
    )
    _ = try ReaperService(repository: repository).reap(detected: [spinnerProcess])
    try expect(
        try Data(contentsOf: lifecycleURL),
        equals: decoratedData,
        "decoration churn not persisted to lifecycle"
    )
    try expect(
        try Data(contentsOf: enrichmentURL),
        equals: decoratedEnrichmentData,
        "decoration churn not persisted to enrichment"
    )
}

func testReaperAdoptsControllingTTYWithoutGhosttySurface() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processID = Int32(getpid())
    let processIdentity = try SystemProcessScanner.processIdentity(of: processID)
        .unwrap(or: "test process identity unavailable")
    try repository.save(AgentSession(
        tool: .opencode,
        sessionID: "tty-only-native",
        pid: processID,
        processIdentity: processIdentity,
        status: .working,
        cwd: "/tmp/tty-only",
        startedAt: Date(),
        updatedAt: Date(),
        terminal: TerminalContext(termProgram: "ghostty")
    ))
    let process = DetectedAgentProcess(
        tool: .opencode,
        processID: processID,
        processIdentity: processIdentity,
        cwd: "/tmp/tty-only",
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys046")
    )

    _ = try ReaperService(repository: repository).reap(detected: [process])

    let session = try repository.loadSessions().first.unwrap(or: "native session disappeared")
    try expect(
        session.terminal.tty,
        equals: "/dev/ttys046",
        "controlling TTY remains available when Ghostty cannot enumerate a surface"
    )
}

func testTerminalEnrichmentPreservesConcurrentLifecycleWrite() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processIdentity = ProcessIdentity(
        processID: 424_242,
        kernelStartTimeMicroseconds: 1_000
    )
    let staleUpdatedAt = Date(timeIntervalSince1970: 1_000)
    let lifecycleUpdatedAt = Date(timeIntervalSince1970: 2_000)
    let stale = AgentSession(
        tool: .opencode,
        sessionID: "concurrent-native-doc",
        pid: processIdentity.processID,
        processIdentity: processIdentity,
        status: .working,
        cwd: "/tmp/concurrent-enrichment",
        startedAt: staleUpdatedAt,
        updatedAt: staleUpdatedAt,
        terminal: TerminalContext(
            termProgram: "ghostty",
            tty: "/dev/ttys009",
            windowTitleHint: "old title"
        )
    )
    try repository.save(stale)
    var staleSnapshot = try repository.loadSnapshot()

    // Simulate permission.asked landing while the scheduler is blocked in
    // Ghostty. Enrichment must merge into this newer document, not its snapshot.
    try repository.save(AgentSession(
        tool: stale.tool,
        sessionID: stale.sessionID,
        pid: stale.pid,
        processIdentity: stale.processIdentity,
        status: .needsAttention,
        attentionReason: .permission,
        cwd: stale.cwd,
        startedAt: stale.startedAt,
        updatedAt: lifecycleUpdatedAt,
        terminal: stale.terminal
    ))
    let enrichedProcess = DetectedAgentProcess(
        tool: stale.tool,
        processID: stale.pid,
        processIdentity: processIdentity,
        cwd: stale.cwd,
        terminal: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "term-concurrent",
            windowTitleHint: "new live title"
        )
    )

    try ReaperService(repository: repository).applyTerminalEnrichment(
        basic: [enrichedProcess],
        enriched: [enrichedProcess],
        snapshot: &staleSnapshot
    )

    let merged = try repository.loadSessions().first
        .unwrap(or: "concurrently updated session disappeared")
    try expect(merged.status, equals: .needsAttention, "newer lifecycle status survives")
    try expect(merged.attentionReason, equals: .permission, "newer lifecycle reason survives")
    try expect(merged.updatedAt, equals: lifecycleUpdatedAt, "newer lifecycle timestamp survives")
    try expect(
        merged.terminal.ghosttyTerminalID,
        equals: "term-concurrent",
        "terminal identifier is enriched"
    )
    try expect(
        merged.terminal.windowTitleHint,
        equals: "new live title",
        "terminal title is enriched"
    )
}

/// cmux documents `CMUX_SURFACE_ID` as the canonical name and `CMUX_PANEL_ID`
/// as a legacy alias it still exports. Reading the alias makes Moonglade
/// depend on a compatibility surface cmux is free to drop.
func testClaudeHookCapturesCanonicalCmuxSurfaceIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let processor = ClaudeHookProcessor(repository: StateRepository(directoryURL: directory))

    try processor.process(
        event: "SessionStart",
        payload: Data(#"{"session_id":"cmux-canonical","cwd":"/tmp/project"}"#.utf8),
        environment: ["TERM_PROGRAM": "ghostty", "CMUX_SURFACE_ID": "SURFACE-9"],
        processID: 4321,
        now: Date(timeIntervalSince1970: 1_752_836_400)
    )

    let session = try StateRepository(directoryURL: directory).loadSessions().first
        .unwrap(or: "session was not saved")
    try expect(
        session.terminal.cmuxSurfaceID,
        equals: "SURFACE-9",
        "the hook reads cmux's canonical surface variable"
    )
}

/// The surface identity is a persisted schema field, so the key on disk is a
/// contract in its own right: it has to match the canonical name, not the
/// alias the first implementation happened to read.
func testTerminalContextPersistsCmuxSurfaceIdentityUnderCanonicalKey() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(
        AgentSession(
            tool: .claude,
            sessionID: "cmux-key",
            pid: 4321,
            status: .working,
            cwd: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            terminal: TerminalContext(
                termProgram: "ghostty",
                cmuxSurfaceID: "SURFACE-9"
            )
        )
    )

    let stateURL = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).first.unwrap(or: "state document was not written")
    let document = String(decoding: try Data(contentsOf: stateURL), as: UTF8.self)
    try expect(
        document.contains("\"cmux_surface_id\""),
        equals: true,
        "the surface identity persists under its canonical key"
    )
    try expect(
        document.contains("cmux_panel_id"),
        equals: false,
        "the legacy alias never reaches disk"
    )
}

func testTerminalEnrichmentPreservesCmuxSurfaceIdentity() throws {
    // Only the hook sees CMUX_SURFACE_ID — the process scanner reads proc_pidinfo
    // and can never recover it. If the enrichment merge drops the hook's value,
    // the session permanently loses its only focusable identity.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processIdentity = ProcessIdentity(
        processID: 424_243,
        kernelStartTimeMicroseconds: 2_000
    )
    let lifecycle = AgentSession(
        tool: .claude,
        sessionID: "cmux-enrichment",
        pid: processIdentity.processID,
        processIdentity: processIdentity,
        status: .working,
        cwd: "/tmp/cmux-enrichment",
        startedAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_000),
        terminal: TerminalContext(
            termProgram: "ghostty",
            cmuxSurfaceID: "SURFACE-ABC",
            tty: "/dev/ttys010",
            windowTitleHint: "old title"
        )
    )
    try repository.save(lifecycle)
    var snapshot = try repository.loadSnapshot()

    // The scanner enriches title and surface, and knows nothing about cmux.
    let enrichedProcess = DetectedAgentProcess(
        tool: lifecycle.tool,
        processID: lifecycle.pid,
        processIdentity: processIdentity,
        cwd: lifecycle.cwd,
        terminal: TerminalContext(
            termProgram: "ghostty",
            windowTitleHint: "new live title"
        )
    )

    try ReaperService(repository: repository).applyTerminalEnrichment(
        basic: [enrichedProcess],
        enriched: [enrichedProcess],
        snapshot: &snapshot
    )

    let merged = try repository.loadSessions().first
        .unwrap(or: "enriched session disappeared")
    try expect(
        merged.terminal.cmuxSurfaceID,
        equals: "SURFACE-ABC",
        "enrichment never discards the hook's cmux surface identity"
    )
    try expect(
        merged.terminal.windowTitleHint,
        equals: "new live title",
        "unrelated enrichment still applies"
    )
}

func testTerminalEnrichmentDoesNotReplaceLifecycleWriteAfterReload() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lifecycleRepository = StateRepository(directoryURL: directory)
    let processID = Int32(getpid())
    let processIdentity = try SystemProcessScanner.processIdentity(of: processID)
        .unwrap(or: "test process identity was unavailable")
    let initialUpdatedAt = Date(timeIntervalSince1970: 1_000)
    let lifecycleUpdatedAt = Date(timeIntervalSince1970: 2_000)
    let initial = AgentSession(
        tool: .opencode,
        sessionID: "reload-rename-race",
        pid: processID,
        processIdentity: processIdentity,
        status: .working,
        cwd: "/tmp/reload-rename-race",
        startedAt: initialUpdatedAt,
        updatedAt: initialUpdatedAt,
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys009")
    )
    try lifecycleRepository.save(initial)
    var staleSnapshot = try lifecycleRepository.loadSnapshot()
    let lifecycleUpdate = AgentSession(
        tool: initial.tool,
        sessionID: initial.sessionID,
        pid: initial.pid,
        processIdentity: initial.processIdentity,
        status: .needsAttention,
        attentionReason: .permission,
        cwd: initial.cwd,
        startedAt: initial.startedAt,
        updatedAt: lifecycleUpdatedAt,
        terminal: initial.terminal
    )
    let enrichmentRepository = StateRepository(
        directoryURL: directory,
        reloadObserver: {
            try lifecycleRepository.save(lifecycleUpdate)
        }
    )
    let enrichedProcess = DetectedAgentProcess(
        tool: initial.tool,
        processID: processID,
        processIdentity: processIdentity,
        cwd: initial.cwd,
        terminal: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "term-after-reload",
            windowTitleHint: "live title after reload"
        )
    )

    try ReaperService(repository: enrichmentRepository).applyTerminalEnrichment(
        basic: [enrichedProcess],
        enriched: [enrichedProcess],
        snapshot: &staleSnapshot
    )

    let merged = try lifecycleRepository.loadSessions().first
        .unwrap(or: "concurrently updated session disappeared")
    try expect(merged.status, equals: .needsAttention, "post-read lifecycle status survives")
    try expect(merged.attentionReason, equals: .permission, "post-read lifecycle reason survives")
    try expect(merged.updatedAt, equals: lifecycleUpdatedAt, "post-read lifecycle timestamp survives")
    try expect(
        merged.terminal.ghosttyTerminalID,
        equals: "term-after-reload",
        "post-read terminal identifier is enriched"
    )
    try expect(
        merged.terminal.windowTitleHint,
        equals: "live title after reload",
        "post-read terminal title is enriched"
    )
}

func testTerminalEnrichmentRejectsConcurrentProcessGenerationChange() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processID: Int32 = 424_243
    let staleIdentity = ProcessIdentity(
        processID: processID,
        kernelStartTimeMicroseconds: 1_000
    )
    let replacementIdentity = ProcessIdentity(
        processID: processID,
        kernelStartTimeMicroseconds: 2_000
    )
    let stale = AgentSession(
        tool: .opencode,
        sessionID: "recycled-native-doc",
        pid: processID,
        processIdentity: staleIdentity,
        status: .working,
        cwd: "/tmp/recycled-enrichment",
        startedAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_000),
        terminal: TerminalContext(termProgram: "ghostty")
    )
    try repository.save(stale)
    var staleSnapshot = try repository.loadSnapshot()

    let replacement = AgentSession(
        tool: stale.tool,
        sessionID: stale.sessionID,
        pid: processID,
        processIdentity: replacementIdentity,
        status: .idle,
        cwd: stale.cwd,
        startedAt: Date(timeIntervalSince1970: 2_000),
        updatedAt: Date(timeIntervalSince1970: 2_000),
        terminal: TerminalContext(termProgram: "ghostty", windowTitleHint: "replacement")
    )
    try repository.save(replacement)
    let staleEnrichment = DetectedAgentProcess(
        tool: stale.tool,
        processID: processID,
        processIdentity: staleIdentity,
        cwd: stale.cwd,
        terminal: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "stale-terminal",
            windowTitleHint: "stale generation"
        )
    )

    try ReaperService(repository: repository).applyTerminalEnrichment(
        basic: [staleEnrichment],
        enriched: [staleEnrichment],
        snapshot: &staleSnapshot
    )

    let preserved = try repository.loadSessions().first
        .unwrap(or: "replacement generation disappeared")
    try expect(
        preserved.processIdentity,
        equals: replacementIdentity,
        "replacement process identity survives"
    )
    try expect(preserved.status, equals: .idle, "replacement lifecycle survives")
    try expect(
        preserved.terminal.ghosttyTerminalID,
        equals: nil,
        "stale generation terminal is rejected"
    )
    try expect(
        preserved.terminal.windowTitleHint,
        equals: "replacement",
        "replacement terminal title survives"
    )
}

func testStateRepositoryValidatesAndPrunesEnrichmentOverlays() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent("state", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = StateRepository(directoryURL: directory)
    let processID = Int32(getpid())
    let processIdentity = try SystemProcessScanner.processIdentity(of: processID)
        .unwrap(or: "test process identity was unavailable")
    let session = AgentSession(
        tool: .opencode,
        sessionID: "overlay-security",
        pid: processID,
        status: .working,
        cwd: "/tmp/overlay-security",
        startedAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_000),
        terminal: TerminalContext(termProgram: "ghostty")
    )
    try repository.save(session)
    let process = DetectedAgentProcess(
        tool: session.tool,
        processID: processID,
        processIdentity: processIdentity,
        cwd: session.cwd,
        terminal: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "secure-terminal",
            windowTitleHint: "secure title"
        )
    )
    _ = try ReaperService(repository: repository).reap(detected: [process])
    let fileURLs = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    let lifecycleURL = try fileURLs.first { $0.pathExtension == "json" }
        .unwrap(or: "lifecycle file missing")
    let enrichmentURL = try fileURLs.first { $0.pathExtension == "overlay" }
        .unwrap(or: "enrichment overlay missing")
    let validEnrichment = try Data(contentsOf: enrichmentURL)

    var staleJSON = try JSONSerialization.jsonObject(with: validEnrichment) as? [String: Any]
    var staleIdentity = staleJSON?["process_identity"] as? [String: Any]
    staleIdentity?["kernel_start_time_us"] = NSNumber(
        value: processIdentity.kernelStartTimeMicroseconds + 1
    )
    staleJSON?["process_identity"] = staleIdentity
    try JSONSerialization.data(withJSONObject: staleJSON ?? [:], options: [.sortedKeys])
        .write(to: enrichmentURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: enrichmentURL.path
    )
    let recycled = try repository.loadSessions().first
        .unwrap(or: "lifecycle session disappeared with stale overlay")
    try expect(recycled.processIdentity, equals: nil, "stale overlay grants no process identity")
    try expect(
        recycled.terminal.ghosttyTerminalID,
        equals: nil,
        "stale overlay grants no terminal identity"
    )
    try expect(
        FileManager.default.fileExists(atPath: enrichmentURL.path),
        equals: true,
        "stale generation overlay stays on the read path"
    )

    var unknownSchemaJSON = try JSONSerialization.jsonObject(
        with: validEnrichment
    ) as? [String: Any]
    unknownSchemaJSON?["schema_version"] = 2
    try JSONSerialization.data(
        withJSONObject: unknownSchemaJSON ?? [:],
        options: [.sortedKeys]
    ).write(to: enrichmentURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: enrichmentURL.path
    )
    _ = try repository.loadSessions()
    try expect(
        FileManager.default.fileExists(atPath: enrichmentURL.path),
        equals: true,
        "unknown overlay schema stays on the read path"
    )

    try Data("not-json".utf8).write(to: enrichmentURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: enrichmentURL.path
    )
    _ = try repository.loadSessions()
    try expect(
        FileManager.default.fileExists(atPath: enrichmentURL.path),
        equals: true,
        "malformed overlay stays on the read path"
    )

    try validEnrichment.write(to: enrichmentURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: enrichmentURL.path
    )
    _ = try repository.loadSessions()
    try expect(
        FileManager.default.fileExists(atPath: enrichmentURL.path),
        equals: true,
        "non-private overlay stays on the read path"
    )

    let externalURL = root.appendingPathComponent("external-overlay")
    try validEnrichment.write(to: externalURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: externalURL.path
    )
    try FileManager.default.removeItem(at: enrichmentURL)
    try FileManager.default.createSymbolicLink(
        at: enrichmentURL,
        withDestinationURL: externalURL
    )
    _ = try repository.loadSessions()
    var symlinkMetadata = stat()
    try expect(Darwin.lstat(enrichmentURL.path, &symlinkMetadata), equals: 0, "overlay symlink remains")
    try expect(
        symlinkMetadata.st_mode & S_IFMT,
        equals: S_IFLNK,
        "symlinked overlay stays on the read path"
    )
    try expect(
        FileManager.default.fileExists(atPath: externalURL.path),
        equals: true,
        "symlink target is untouched"
    )

    var oversized = validEnrichment
    oversized.append(Data(
        repeating: 0x20,
        count: max(0, 16_385 - validEnrichment.count)
    ))
    try oversized.write(to: enrichmentURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: enrichmentURL.path
    )
    _ = try repository.loadSessions()
    try expect(
        FileManager.default.fileExists(atPath: enrichmentURL.path),
        equals: true,
        "oversized overlay stays on the read path"
    )

    _ = try ReaperService(repository: repository).reap(detected: [process])
    let merged = try repository.loadSessions().first
        .unwrap(or: "enriched session was not restored")
    try repository.remove(merged)
    try expect(
        FileManager.default.fileExists(atPath: lifecycleURL.path),
        equals: false,
        "session removal deletes lifecycle document"
    )
    try expect(
        FileManager.default.fileExists(atPath: enrichmentURL.path),
        equals: false,
        "session removal deletes enrichment overlay"
    )

    try repository.save(session)
    _ = try ReaperService(repository: repository).reap(detected: [process])
    try FileManager.default.removeItem(at: lifecycleURL)
    try expect(try repository.loadSessions(), equals: [], "orphan overlay creates no session")
    let snapshot = try repository.loadSnapshot()
    try repository.pruneOrphanedEnrichments(against: snapshot)
    try expect(
        FileManager.default.fileExists(atPath: enrichmentURL.path),
        equals: false,
        "orphan overlay is pruned"
    )
}

func testTerminalEnrichmentPreservesLiveFallbackWhenGhosttyOmitsProcess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let liveProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/ghostty-enrichment-failure",
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys001")
    )
    let scanner = SystemProcessScanner(ghosttyTerminalSource: { [] })
    let enriched = scanner.enrichTerminalContexts(in: [liveProcess])
    try expect(enriched.count, equals: 1, "failed Ghostty match preserves basic process context")
    try expect(
        enriched.first?.terminal.ghosttyTerminalID,
        equals: nil,
        "failed Ghostty match fabricates no surface ID"
    )
    try expect(
        enriched.first?.terminal.tty,
        equals: "/dev/ttys001",
        "failed Ghostty match retains controlling TTY"
    )

    let reaper = ReaperService(repository: repository)
    _ = try reaper.reap(detected: [liveProcess])
    try reaper.applyTerminalEnrichment(basic: [liveProcess], enriched: enriched)

    let sessions = try repository.loadSessions()
    try expect(sessions.map(\.sessionID), equals: ["reaper-\(getpid())"], "live fallback survives optional enrichment miss")
}

func testReaperPrunesSupersededSessionsForSameProcess() throws {
    // A terminal shows one session at a time, so several documents pointing
    // at the same process describe at most one visible session — the most
    // recently updated one. OpenCode accumulates the rest: child sessions
    // spawned for subagents and chats abandoned inside a long-lived TUI.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let pid = Int32(getpid())
    for (sessionID, updatedAt) in [("abandoned-chat", 100.0), ("subagent-child", 200.0), ("current", 300.0)] {
        try repository.save(AgentSession(
            tool: .opencode, sessionID: sessionID, pid: pid, status: .working,
            cwd: "/tmp/oc-project", startedAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        ))
    }
    let visibleProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: pid,
        cwd: "/tmp/oc-project",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    let result = try ReaperService(repository: repository).reap(detected: [visibleProcess])

    try expect(result.removedSessionIDs, equals: ["abandoned-chat", "subagent-child"], "pruned sessions")
    try expect(result.createdSessionIDs, equals: [], "no fallback while a native doc tracks the process")
    let sessions = try repository.loadSessions()
    try expect(sessions.map(\.sessionID), equals: ["current"], "surviving session")
}

func testReaperPrefersNativeSessionOverNewerFallback() throws {
    // The OpenCode plugin writes documents directly (bypassing save()'s
    // fallback supersession), so a reaper fallback can coexist with native
    // documents for the same process. The fallback loses even when its
    // updated_at is newer — it carries no real status.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let pid = Int32(getpid())
    try repository.save(AgentSession(
        tool: .opencode, sessionID: "reaper-\(pid)", pid: pid, status: .working,
        cwd: "/tmp/oc-project", startedAt: Date(timeIntervalSince1970: 400),
        updatedAt: Date(timeIntervalSince1970: 400), source: .reaper
    ))
    // Written directly so save() cannot apply its supersession rules.
    let nativeJSON = validStateJSON(sessionID: "native", status: "idle", pid: pid, tool: "opencode")
    try nativeJSON.write(to: directory.appendingPathComponent(
        "opencode-\(Data("native".utf8).base64EncodedString()).json"
    ))
    let visibleProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: pid,
        cwd: "/tmp/project",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    let result = try ReaperService(repository: repository).reap(detected: [visibleProcess])

    try expect(result.removedSessionIDs, equals: ["reaper-\(pid)"], "fallback pruned")
    let sessions = try repository.loadSessions()
    try expect(sessions.map(\.sessionID), equals: ["native"], "native session survives")
}

func testObservationSchedulerTickPersistsFallbackState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let liveProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/scheduler-project",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: TestProcessScanner([liveProcess]),
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true)
    )

    scheduler.requestTick()

    let deadline = Date().addingTimeInterval(2)
    var sessions: [AgentSession] = []
    repeat {
        sessions = (try? repository.loadSessions()) ?? []
        if sessions.isEmpty { usleep(20_000) }
    } while sessions.isEmpty && Date() < deadline
    try expect(sessions.map(\.sessionID), equals: ["reaper-\(getpid())"], "fallback session")
    try expect(sessions.first?.cwd, equals: "/tmp/scheduler-project", "fallback cwd")
}

func testCodexRecoveryDoesNotAuthorizeHistoricalRolloutForReplacementProcess() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sessionsDirectory = root.appendingPathComponent("codex", isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = "/tmp/codex-reused-directory"
    let processID = Int32(getpid())
    let processIdentity = try SystemProcessScanner.processIdentity(of: processID)
        .unwrap(or: "replacement process identity unavailable")
    let processStartedAt = Date(
        timeIntervalSince1970: TimeInterval(processIdentity.kernelStartTimeMicroseconds) / 1_000_000
    )
    // Process A wrote this rollout and exited. Its recent mtime still puts it
    // inside the watcher's one-hour recovery window when process B appears.
    let oldActivityAt = processStartedAt.addingTimeInterval(-60)
    let oldTimestamp = ISO8601DateFormatter().string(from: oldActivityAt)
    let oldMetadata = #"{"timestamp":"\#(oldTimestamp)","type":"session_meta","payload":{"id":"process-a-session","cwd":"/tmp/codex-reused-directory","timestamp":"\#(oldTimestamp)"}}"#
    let rolloutURL = sessionsDirectory.appendingPathComponent("rollout-process-a.jsonl")
    try Data("\(oldMetadata)\n".utf8).write(to: rolloutURL)
    try FileManager.default.setAttributes(
        [.modificationDate: oldActivityAt],
        ofItemAtPath: rolloutURL.path
    )
    let processB = DetectedAgentProcess(
        tool: .codex,
        processID: processID,
        processIdentity: processIdentity,
        cwd: cwd,
        terminal: TerminalContext(tty: "/dev/ttys009")
    )
    let repository = StateRepository(directoryURL: stateDirectory)
    let reaper = ReaperService(repository: repository)
    _ = try reaper.reap(detected: [processB])
    let watcher = CodexSessionsWatcher(
        sessionsDirectoryURL: sessionsDirectory,
        repository: repository,
        ingestionWindow: 3600,
        processResolver: { session in session.cwd == cwd ? processB : nil }
    )

    try watcher.scan()
    _ = try reaper.reap(detected: [processB])

    let recovered = try repository.loadSessions()
    let fallback = try recovered.first {
        $0.sessionID == "reaper-\(processID)"
    }.unwrap(or: "replacement process lost its safe fallback")
    try expect(fallback.processIdentity, equals: processIdentity, "replacement fallback identity")
    let historical = recovered.first { $0.sessionID == "process-a-session" }
    try expect(historical?.processIdentity, equals: nil, "historical rollout has no destructive authority")
}

func testObservationSchedulerPublishesConvoyRunOnTick() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-161616-schd",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [("implementer", "running", "ses_impl")]
    )
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: TestProcessScanner([detectedConvoyProcess()]),
        codexSessionsDirectoryURL: stateDirectoryURL.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: runsDirectoryURL
    )

    scheduler.requestTick()

    let deadline = Date().addingTimeInterval(2)
    var published: AgentSession?
    repeat {
        published = (try? repository.loadSessions())?
            .first { $0.sessionID == "20260719-161616-schd" }
        if published == nil { usleep(20_000) }
    } while published == nil && Date() < deadline
    let session = try published.unwrap(or: "scheduler never published the convoy run")
    try expect(session.tool, equals: .convoy, "tool")
    try expect(session.status, equals: .working, "status")
    try expect(session.currentStep, equals: "implementer", "current step")
}

final class StateMaterializationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var materializationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

func testObservationSchedulerMaterializesStateOncePerTick() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let phaseStateURL = stateDirectoryURL.appendingPathComponent("opencode-c2VzX2ltcGw.json")
    try validStateJSON(
        sessionID: "ses_impl",
        status: "working",
        pid: Int32(getpid()),
        tool: "opencode",
        cwd: "/tmp/phase-session"
    ).write(to: phaseStateURL)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260722-171717-materialization",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [("implementer", "running", "ses_impl")]
    )
    let embeddedServer = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getppid()),
        cwd: "/tmp/convoy-target",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )
    let counter = StateMaterializationCounter()
    let scheduler = ObservationScheduler(
        repository: StateRepository(
            directoryURL: stateDirectoryURL,
            materializationObserver: { counter.increment() }
        ),
        processScanner: TestProcessScanner([detectedConvoyProcess(), embeddedServer]),
        codexSessionsDirectoryURL: stateDirectoryURL.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: runsDirectoryURL,
        debounceInterval: 0.01
    )

    scheduler.requestTick()

    let deadline = Date().addingTimeInterval(2)
    while (try StateRepository(directoryURL: stateDirectoryURL).loadSessions())
        .contains(where: { $0.tool == .opencode }), Date() < deadline {
        usleep(1_000)
    }
    scheduler.waitUntilIdle()
    try expect(
        FileManager.default.fileExists(atPath: phaseStateURL.path),
        equals: true,
        "tick keeps the producer-owned Convoy phase lifecycle document"
    )
    try expect(
        counter.materializationCount,
        equals: 1,
        "one verified state snapshot per observation tick"
    )
    let sessions = try StateRepository(directoryURL: stateDirectoryURL).loadSessions()
    try expect(
        sessions.filter { $0.tool == .opencode }.isEmpty,
        equals: true,
        "later suppression sees the reaper fallback added to the snapshot"
    )
    try expect(
        sessions.contains { $0.sessionID == "20260722-171717-materialization" },
        equals: true,
        "reaper sees the Convoy session added to the snapshot"
    )
}

final class CountingProcessScanner: ProcessScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let detected: [DetectedAgentProcess]
    private var count = 0

    init(_ detected: [DetectedAgentProcess] = []) {
        self.detected = detected
    }

    func activeProcesses() throws -> [DetectedAgentProcess] {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return detected
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class StartupOrderingProcessScanner: ProcessScanning, @unchecked Sendable {
    let baselineStarted = DispatchSemaphore(value: 0)
    let releaseBaseline = DispatchSemaphore(value: 0)
    let recurringScanStarted = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let detected: [DetectedAgentProcess]
    private var count = 0
    private var firstScanWasOnMain = false

    init(_ detected: [DetectedAgentProcess] = []) {
        self.detected = detected
    }

    func activeProcesses() throws -> [DetectedAgentProcess] {
        try basicActiveProcesses()
    }

    func basicActiveProcesses() throws -> [DetectedAgentProcess] {
        lock.lock()
        count += 1
        let currentCount = count
        if currentCount == 1 {
            firstScanWasOnMain = Thread.isMainThread
        }
        lock.unlock()

        if currentCount == 1 {
            baselineStarted.signal()
            _ = releaseBaseline.wait(timeout: .now() + 2)
        } else {
            recurringScanStarted.signal()
        }
        return detected
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var baselineRanOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstScanWasOnMain
    }
}

func testObservationSchedulerQueuesInitialReconciliationBeforeRecurringWork() throws {
    try expect(Thread.isMainThread, equals: true, "startup API is invoked from main")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scanner = StartupOrderingProcessScanner()
    let scheduler = ObservationScheduler(
        repository: StateRepository(directoryURL: directory),
        processScanner: scanner,
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: directory.appendingPathComponent("convoy", isDirectory: true),
        debounceInterval: 0.01
    )
    defer {
        scanner.releaseBaseline.signal()
        scheduler.stop()
        scheduler.waitUntilIdle()
    }

    scheduler.startWithInitialReconciliation()

    guard scanner.baselineStarted.wait(timeout: .now() + 2) == .success else {
        throw TestFailure.expectation("queued initial reconciliation never started")
    }
    try expect(scanner.baselineRanOnMain, equals: false, "baseline process scan runs off main")
    usleep(100_000)
    try expect(scanner.scanCount, equals: 1, "recurring work waits for baseline reconciliation")

    scanner.releaseBaseline.signal()
    guard scanner.recurringScanStarted.wait(timeout: .now() + 2) == .success else {
        throw TestFailure.expectation("normal startup tick never followed initial reconciliation")
    }
    try expect(scanner.scanCount, equals: 2, "normal startup tick follows baseline reconciliation")
}

final class StartupCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false
    private var ranOnMain = false

    func record() {
        lock.lock()
        didRun = true
        ranOnMain = Thread.isMainThread
        lock.unlock()
    }

    var completionRan: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRun
    }

    var completionRanOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ranOnMain
    }
}

func testStartupReconciliationCompletionRefreshesStoreWithoutPolling() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let store = StateStore(repository: repository)
    try store.startObserving(pollInterval: nil, layers: [])
    defer { store.stopObserving() }
    let process = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/startup-handshake",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: TestProcessScanner([process]),
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: directory.appendingPathComponent("convoy", isDirectory: true),
        debounceInterval: 0.01
    )
    defer {
        scheduler.stop()
        scheduler.waitUntilIdle()
    }
    let completion = StartupCompletionProbe()

    scheduler.startWithInitialReconciliation {
        store.reloadRecordingError()
        completion.record()
    }

    let deadline = Date().addingTimeInterval(2)
    while !completion.completionRan, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(completion.completionRan, equals: true, "startup reconciliation completion")
    try expect(completion.completionRanOnMain, equals: true, "startup completion runs on main")
    try expect(
        store.sessions.map(\.sessionID),
        equals: ["reaper-\(getpid())"],
        "post-reconciliation baseline converges without polling or notifications"
    )
}

func testStoppingSchedulerSuppressesLateStartupCompletion() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scanner = StartupOrderingProcessScanner()
    let scheduler = ObservationScheduler(
        repository: StateRepository(directoryURL: directory),
        processScanner: scanner,
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: directory.appendingPathComponent("convoy", isDirectory: true),
        debounceInterval: 0.01
    )
    let completion = StartupCompletionProbe()
    scheduler.startWithInitialReconciliation {
        completion.record()
    }
    guard scanner.baselineStarted.wait(timeout: .now() + 2) == .success else {
        throw TestFailure.expectation("stoppable initial reconciliation never started")
    }

    scheduler.stop()
    scanner.releaseBaseline.signal()
    scheduler.waitUntilIdle()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    try expect(completion.completionRan, equals: false, "stop invalidates late startup completion")
}

/// Reports the process only while it is actually alive, mimicking a real
/// scan across a process death.
struct LivenessProcessScanner: ProcessScanning {
    let process: DetectedAgentProcess

    func activeProcesses() throws -> [DetectedAgentProcess] {
        Darwin.kill(process.processID, 0) == 0 ? [process] : []
    }
}

func testObservationSchedulerReapsImmediatelyWhenProcessExits() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["300"]
    try child.run()
    defer { child.terminate() }
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: LivenessProcessScanner(process: DetectedAgentProcess(
            tool: .claude,
            processID: child.processIdentifier,
            cwd: "/tmp/exit-watch",
            terminal: TerminalContext(tty: "/dev/ttys001")
        )),
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true),
        debounceInterval: 0.05
    )

    scheduler.requestTick()
    var deadline = Date().addingTimeInterval(2)
    while (try repository.loadSessions()).isEmpty, Date() < deadline {
        usleep(20_000)
    }
    try expect((try repository.loadSessions()).count, equals: 1, "session tracked while alive")

    // No heartbeat is running and no further ticks are requested: only the
    // kernel exit event can trigger the reap.
    child.terminate()
    deadline = Date().addingTimeInterval(1.5)
    while !(try repository.loadSessions()).isEmpty, Date() < deadline {
        usleep(20_000)
    }
    try expect(
        (try repository.loadSessions()).isEmpty,
        equals: true,
        "session reaped on process exit without a heartbeat"
    )
}

func testObservationSchedulerCoalescesTickBursts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scanner = CountingProcessScanner()
    let scheduler = ObservationScheduler(
        repository: StateRepository(directoryURL: directory),
        processScanner: scanner,
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true),
        debounceInterval: 0.1
    )

    for _ in 0..<5 {
        scheduler.requestTick()
    }
    usleep(400_000)

    try expect(
        scanner.scanCount,
        equals: 1,
        "a burst of tick requests must coalesce into a single scan"
    )
}

func testConvoyMetadataTickReusesLastVerifiedProcessScan() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let runID = "20260722-181818-metadata-tick"
    let process = detectedConvoyProcess()
    let serverStartedAt = Date().addingTimeInterval(-300)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: process.processID,
        serverStartedAt: serverStartedAt,
        phases: [("implementer", "running", "ses_impl")]
    )
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let materializationCounter = StateMaterializationCounter()
    let scanner = CountingProcessScanner([process])
    let scheduler = ObservationScheduler(
        repository: StateRepository(
            directoryURL: stateDirectoryURL,
            materializationObserver: { materializationCounter.increment() }
        ),
        processScanner: scanner,
        codexSessionsDirectoryURL: stateDirectoryURL.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: runsDirectoryURL,
        debounceInterval: 0.01
    )
    defer {
        scheduler.stop()
        scheduler.waitUntilIdle()
    }

    scheduler.requestTick()
    var deadline = Date().addingTimeInterval(2)
    while (try repository.loadSessions()).first?.status != .working, Date() < deadline {
        usleep(1_000)
    }
    scheduler.waitUntilIdle()
    try expect(scanner.scanCount, equals: 1, "initial explicit tick scans processes")
    try expect(materializationCounter.materializationCount, equals: 1, "explicit tick snapshot")

    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: process.processID,
        serverStartedAt: serverStartedAt,
        phases: [("implementer", "completed", "ses_impl")]
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)],
        ofItemAtPath: runsDirectoryURL
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("metadata.json").path
    )
    scheduler.requestConvoyMetadataTick()
    deadline = Date().addingTimeInterval(2)
    while (try repository.loadSessions()).first?.status != .idle, Date() < deadline {
        usleep(1_000)
    }
    scheduler.waitUntilIdle()

    try expect(
        (try repository.loadSessions()).first?.status,
        equals: .idle,
        "metadata-only tick processes the changed run"
    )
    try expect(scanner.scanCount, equals: 1, "metadata-only tick reuses the verified process snapshot")
    try expect(materializationCounter.materializationCount, equals: 2, "metadata-only tick snapshot")

    scheduler.requestHeartbeatTick()
    deadline = Date().addingTimeInterval(2)
    while scanner.scanCount < 2, Date() < deadline {
        usleep(1_000)
    }
    scheduler.waitUntilIdle()
    try expect(scanner.scanCount, equals: 2, "heartbeat still refreshes process liveness")
    try expect(materializationCounter.materializationCount, equals: 3, "heartbeat tick snapshot")
}

func testConvoyMetadataTickRemovesSupersededRunImmediately() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let processID = Int32(getpid())
    let processIdentity = try SystemProcessScanner.processIdentity(of: processID)
        .unwrap(or: "test process identity was unavailable")
    let process = DetectedAgentProcess(
        tool: .convoy,
        processID: processID,
        processIdentity: processIdentity,
        cwd: "/tmp/convoy-target",
        terminal: TerminalContext(termProgram: "ghostty"),
        elapsedSeconds: 120
    )
    let scanner = CountingProcessScanner([process])
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: scanner,
        codexSessionsDirectoryURL: stateDirectoryURL.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: runsDirectoryURL,
        debounceInterval: 0.01
    )
    defer {
        scheduler.stop()
        scheduler.waitUntilIdle()
    }
    let firstRunID = "20260722-191000-first"
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: firstRunID,
        serverPid: processID,
        serverStartedAt: Date().addingTimeInterval(-60),
        phases: [("implementer", "running", "ses_first")]
    )

    scheduler.requestTick()
    var deadline = Date().addingTimeInterval(2)
    while !(try repository.loadSessions()).contains(where: { $0.sessionID == firstRunID }),
          Date() < deadline {
        usleep(1_000)
    }
    scheduler.waitUntilIdle()
    try expect(scanner.scanCount, equals: 1, "initial tick verifies the live process generation")

    let now = Date()
    let otherGenerationID = "other-generation"
    try repository.save(AgentSession(
        tool: .convoy,
        sessionID: otherGenerationID,
        pid: processID,
        processIdentity: ProcessIdentity(
            processID: processID,
            kernelStartTimeMicroseconds: processIdentity.kernelStartTimeMicroseconds + 1
        ),
        status: .working,
        cwd: "/tmp/other-generation",
        startedAt: now,
        updatedAt: now
    ))
    let otherProcessID = "other-pid"
    try repository.save(AgentSession(
        tool: .convoy,
        sessionID: otherProcessID,
        pid: processID + 1,
        processIdentity: ProcessIdentity(
            processID: processID + 1,
            kernelStartTimeMicroseconds: 987_654_321
        ),
        status: .working,
        cwd: "/tmp/other-pid",
        startedAt: now,
        updatedAt: now
    ))

    let secondRunID = "20260722-191100-second"
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: secondRunID,
        serverPid: processID,
        serverStartedAt: Date().addingTimeInterval(-30),
        phases: [("implementer", "running", "ses_second")]
    )
    scheduler.requestConvoyMetadataTick()
    deadline = Date().addingTimeInterval(2)
    while !(try repository.loadSessions()).contains(where: { $0.sessionID == secondRunID }),
          Date() < deadline {
        usleep(1_000)
    }
    scheduler.waitUntilIdle()

    try expect(scanner.scanCount, equals: 1, "supersession runs on a metadata-only observation")
    try expect(
        Set(try repository.loadSessions().map(\.sessionID)),
        equals: [secondRunID, otherGenerationID, otherProcessID],
        "metadata-only supersession removes only the old same-generation run"
    )
}

func testNativeStateReplacesReaperFallbackForSameProcess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 100)
    try repository.save(AgentSession(
        tool: .claude, sessionID: "reaper-10", pid: 10, status: .working,
        cwd: "/tmp/project", startedAt: now, updatedAt: now, source: .reaper
    ))
    try repository.save(AgentSession(
        tool: .claude, sessionID: "native", pid: 10, status: .working,
        cwd: "/tmp/project", startedAt: now, updatedAt: now
    ))

    let sessions = try repository.loadSessions()
    try expect(sessions.map(\.sessionID), equals: ["native"], "sessions")
}

func testSessionDurationFormatterRendersCompactDurations() throws {
    let start = Date(timeIntervalSince1970: 0)
    let cases: [(elapsed: TimeInterval, expected: String)] = [
        (30, "<1m"),
        (59, "<1m"),
        (60, "1m"),
        (47 * 60, "47m"),
        (3_600, "1h"),
        (3_600 + 12 * 60, "1h 12m"),
        (26 * 3_600, "1d 2h"),
        (3 * 86_400, "3d"),
        (-5, "<1m"),
    ]
    for (elapsed, expected) in cases {
        try expect(
            SessionDurationFormatter.string(from: start, to: start.addingTimeInterval(elapsed)),
            equals: expected,
            "duration for \(elapsed)s"
        )
    }
}

func testDebugRendererShowsToolCountsAndSessionState() throws {
    let claude = try AgentSession.decode(from: validStateJSON(sessionID: "c1", status: "working"))
    let output = DebugRenderer.render(sessions: [claude])

    guard output.contains("claude: 1"), output.contains("c1  working  project") else {
        throw TestFailure.expectation("unexpected debug output: \(output)")
    }
}

func testCLIParsesDebugCommand() throws {
    try expect(try CLICommand.parse(arguments: ["debug"]), equals: .debug, "CLI command")
}

func testCLIParsesClaudeHookCommand() throws {
    let command = try CLICommand.parse(
        arguments: ["hook", "claude", "Notification", "--pid", "42"]
    )
    try expect(command, equals: .claudeHook(event: "Notification", processID: 42), "CLI command")
}

func testCLIParsesCodexNotifyCommand() throws {
    let command = try CLICommand.parse(arguments: ["hook", "codex-notify", "--pid", "42"])
    try expect(command, equals: .codexNotify(processID: 42), "CLI command")
}

func testCaptureContextEmitsTerminalJSON() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        try BundledResources.captureContextScriptURL.path,
        "/tmp/my-project",
        "claude",
        "1",
    ]
    process.environment = [
        "PATH": "/usr/bin:/bin",
        "TERM_PROGRAM": "ghostty",
        "TMUX_PANE": "%8",
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    try expect(process.terminationStatus, equals: 0, "capture-context exit status")
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    try expect(json?["term_program"] as? String, equals: "ghostty", "terminal program")
    try expect(json?["tmux_pane"] as? String, equals: "%8", "tmux pane")
    try expect(
        json?["window_title_hint"] as? String,
        equals: "my-project — claude",
        "window title hint"
    )
}

func testClaudeHookWrapperForwardsPayloadAndEvent() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let wrapperURL = directory.appendingPathComponent("claude-hook.sh")
    try FileManager.default.copyItem(at: BundledResources.claudeHookScriptURL, to: wrapperURL)
    let binaryURL = directory.appendingPathComponent("moonglade")
    try Data(
        """
        #!/bin/sh
        /usr/bin/printf '%s|%s|%s|%s|%s' "$#" "$1" "$2" "$3" "$4" > "$CAPTURE_DIR/args"
        /bin/cat > "$CAPTURE_DIR/payload"
        """.utf8
    ).write(to: binaryURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: binaryURL.path
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [wrapperURL.path, "Stop"]
    process.environment = ["PATH": "/usr/bin:/bin", "CAPTURE_DIR": directory.path]
    let input = Pipe()
    process.standardInput = input
    try process.run()
    input.fileHandleForWriting.write(Data(#"{"session_id":"abc"}"#.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    try expect(process.terminationStatus, equals: 0, "wrapper exit status")
    let arguments = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
    guard arguments.hasPrefix("5|hook|claude|Stop|--pid") else {
        throw TestFailure.expectation("unexpected wrapper arguments: \(arguments)")
    }
    let payload = try String(contentsOf: directory.appendingPathComponent("payload"), encoding: .utf8)
    try expect(payload, equals: #"{"session_id":"abc"}"#, "hook payload")
}

func testStateStoreReloadFiltersEndedSessionsWithoutWriting() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "active", status: "working", pid: Int32(getpid()))
    ))
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ended", status: "ended", pid: Int32(getpid()))
    ))
    let store = StateStore(repository: repository)

    try store.reload()

    try expect(store.sessions.map(\.sessionID), equals: ["active"], "active sessions")
    // Reloading is a pure read: deleting ended state belongs to the reaper.
    // A reload that writes re-triggers its own directory observation and can
    // storm the main thread (observed 2026-07-18 at ~100% CPU).
    try expect(
        try repository.loadSessions().map(\.sessionID).sorted(),
        equals: ["active", "ended"],
        "state files on disk"
    )
}

final class StartupStateMutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didPublish = false
    private var failureDescription: String?

    func publishOnce(_ data: Data, to fileURL: URL) {
        lock.lock()
        guard !didPublish else {
            lock.unlock()
            return
        }
        didPublish = true
        lock.unlock()

        do {
            try data.writeAtomically(to: fileURL)
            StateChangeNotifier.post()
        } catch {
            lock.lock()
            failureDescription = String(describing: error)
            lock.unlock()
        }
    }

    func checkForFailure() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failureDescription {
            throw TestFailure.expectation("startup mutation failed: \(failureDescription)")
        }
    }
}

func testStateStoreArmsNotificationsBeforeStartupBaselineMutation() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("claude-startup-race.json")
    let state = validStateJSON(
        sessionID: "startup-race",
        status: "working",
        pid: Int32(getpid())
    )
    let mutation = StartupStateMutationProbe()
    let repository = StateRepository(
        directoryURL: directory,
        materializationObserver: {
            mutation.publishOnce(state, to: stateURL)
        }
    )
    let store = StateStore(repository: repository)

    try store.startObserving(pollInterval: nil, layers: .darwinNotification)
    defer { store.stopObserving() }
    try mutation.checkForFailure()

    let deadline = Date().addingTimeInterval(1)
    while store.sessions.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    try expect(
        store.sessions.map(\.sessionID),
        equals: ["startup-race"],
        "startup state converges without polling"
    )
}

func testStateStorePollingObservesNewStateFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(repository: StateRepository(directoryURL: directory))
    try store.startObserving(pollInterval: 0.05, layers: .polling)
    defer { store.stopObserving() }
    try validStateJSON(sessionID: "appeared", status: "working", pid: Int32(getpid()))
        .writeAtomically(to: directory.appendingPathComponent("claude-appeared.json"))

    let deadline = Date().addingTimeInterval(1)
    while store.sessions.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    try expect(store.sessions.map(\.sessionID), equals: ["appeared"], "observed sessions")
}

func testStateStoreFileEventsObserveNewStateFilesWithoutPolling() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(repository: StateRepository(directoryURL: directory))
    try store.startObserving(pollInterval: nil, layers: .fileSystem)
    defer { store.stopObserving() }
    try validStateJSON(sessionID: "file-event", status: "working", pid: Int32(getpid()))
        .writeAtomically(to: directory.appendingPathComponent("claude-file-event.json"))

    let deadline = Date().addingTimeInterval(1)
    while store.sessions.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    try expect(store.sessions.map(\.sessionID), equals: ["file-event"], "observed sessions")
}

func testStateStoreDarwinNotificationObservesNewStateFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(repository: StateRepository(directoryURL: directory))
    try store.startObserving(pollInterval: nil, layers: .darwinNotification)
    defer { store.stopObserving() }
    try validStateJSON(sessionID: "notified", status: "working", pid: Int32(getpid()))
        .writeAtomically(to: directory.appendingPathComponent("claude-notified.json"))
    StateChangeNotifier.post()

    let deadline = Date().addingTimeInterval(1)
    while store.sessions.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    try expect(store.sessions.map(\.sessionID), equals: ["notified"], "observed sessions")
}

func testStateStoreDarwinNotificationObservesRemovedStateFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let session = try AgentSession.decode(
        from: validStateJSON(sessionID: "removed", status: "working", pid: Int32(getpid()))
    )
    try repository.save(session)
    let store = StateStore(repository: repository)
    try store.startObserving(pollInterval: nil, layers: .darwinNotification)
    defer { store.stopObserving() }
    try expect(store.sessions.map(\.sessionID), equals: ["removed"], "baseline session")

    try repository.remove(session)

    let deadline = Date().addingTimeInterval(1)
    while !store.sessions.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    try expect(store.sessions.isEmpty, equals: true, "removed session observed through Darwin notification")
}

func testSessionStatusSummaryCountsGlobalRunningWaitingAndBlockedSessions() throws {
    let sessions = [
        try AgentSession.decode(from: validStateJSON(sessionID: "running", status: "working")),
        try AgentSession.decode(from: validStateJSON(sessionID: "waiting", status: "idle")),
        try AgentSession.decode(from: validStateJSON(sessionID: "blocked", status: "needs_attention")),
        try AgentSession.decode(from: validStateJSON(sessionID: "ended", status: "ended")),
    ]

    let summary = SessionStatusSummary(sessions: sessions)

    try expect(summary.runningCount, equals: 1, "running count")
    try expect(summary.waitingCount, equals: 1, "waiting count")
    try expect(summary.blockedCount, equals: 1, "blocked count")
    try expect(summary.activeSessionCount, equals: 3, "ended sessions excluded")
}

func testSessionStatusSummaryVisibleEntriesOmitsZeroCounts() throws {
    let sessions = [
        try AgentSession.decode(from: validStateJSON(sessionID: "running", status: "working")),
        try AgentSession.decode(from: validStateJSON(sessionID: "blocked", status: "needs_attention")),
    ]

    let summary = SessionStatusSummary(sessions: sessions)

    try expect(
        summary.visibleEntries,
        equals: [
            SessionStatusSummary.StatusEntry(kind: .running, count: 1),
            SessionStatusSummary.StatusEntry(kind: .blocked, count: 1),
        ],
        "zero-count kinds disappear from the bar instead of rendering dimmed"
    )
    try expect(
        SessionStatusSummary(sessions: []).visibleEntries,
        equals: [],
        "an empty summary renders no indicators at all"
    )
}

func testSessionStatusSummarySilencesAcknowledgedBlockedSessions() throws {
    let blocked = try AgentSession.decode(
        from: validStateJSON(sessionID: "acknowledged", status: "needs_attention")
    )
    var acknowledgments = AttentionAcknowledgments()
    acknowledgments.acknowledge(blocked)

    let summary = SessionStatusSummary(
        sessions: [blocked],
        acknowledgments: acknowledgments
    )

    try expect(summary.blockedCount, equals: 0, "visited session no longer keeps the bar red")
    try expect(summary.waitingCount, equals: 1, "visited session remains visible as a quiet wait")
}

func testIdleStatusIndicatorsUseTheGreenDotStyle() throws {
    try expect(
        SessionStatus.idle.indicatorStyle,
        equals: .greenDot,
        "an idle session row uses a green dot"
    )
    try expect(
        SessionStatusSummary.StatusEntry.Kind.waiting.indicatorStyle,
        equals: .greenDot,
        "the compact waiting summary uses the same green dot"
    )
    try expect(SessionStatus.working.indicatorStyle, equals: .spinner, "working remains animated")
    try expect(SessionStatus.needsAttention.indicatorStyle, equals: .redDot, "attention remains red")
}

func testPointerMovementGateStaysLockedUntilPointerMoves() throws {
    var gate = PointerMovementGate()

    try expect(gate.isUnlocked, equals: true, "a fresh gate starts unlocked")

    gate.lock(at: DisplayPoint(x: 100, y: 100))

    try expect(gate.isUnlocked, equals: false, "locking arms the gate")
    try expect(
        gate.update(pointerLocation: DisplayPoint(x: 102, y: 101)),
        equals: false,
        "a stationary pointer stays locked"
    )
    try expect(
        gate.update(pointerLocation: DisplayPoint(x: 140, y: 100)),
        equals: true,
        "real movement unlocks hover expansion"
    )
    try expect(
        gate.update(pointerLocation: DisplayPoint(x: 140, y: 100)),
        equals: true,
        "once unlocked the gate stays open"
    )
}

func testPointerSamplesPublishOnlyContainmentTransitions() throws {
    var reducer = PointerSampleReducer()
    var gate = PointerMovementGate()
    gate.lock(at: DisplayPoint(x: 100, y: 100))
    var publications: [PointerContainmentState] = []
    let outsideBeforeEntry = (0..<50).map { offset in
        (isInside: false, location: DisplayPoint(x: CGFloat(100 + offset % 2), y: 100))
    }
    let insideMoves = (0..<100).map { offset in
        (isInside: true, location: DisplayPoint(x: CGFloat(102 + offset), y: 100))
    }
    let outsideAfterLeave = (0..<50).map { offset in
        (isInside: false, location: DisplayPoint(x: CGFloat(202 + offset), y: 100))
    }
    let samples = outsideBeforeEntry + insideMoves + outsideAfterLeave

    for sample in samples {
        let reduction = reducer.reduce(
            isInside: sample.isInside,
            location: sample.location
        )
        if sample.isInside {
            _ = gate.update(pointerLocation: reduction.location)
        }
        if let containment = reduction.containmentChange {
            publications.append(containment)
        }
    }

    try expect(
        publications,
        equals: [
            PointerContainmentState(isInside: true, revision: 1),
            PointerContainmentState(isInside: false, revision: 2),
        ],
        "only entering and leaving publish observable pointer state"
    )
    try expect(gate.isUnlocked, equals: true, "unpublished coordinates still reach movement gate")
    try expect(reducer.revision, equals: 2, "same-containment moves do not advance revision")
}

func testHoverInteractionIgnoresSyntheticExitWhilePointerRemainsInside() throws {
    let compactFrame = DisplayFrame(minX: 20, minY: 0, width: 100, height: 30)

    try expect(
        HoverInteraction.pointerIsInside(
            DisplayPoint(x: 150, y: 885),
            localTopLeadingFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900
        ),
        equals: true,
        "tracking-area replacement does not turn an inside pointer into a real exit"
    )
    try expect(
        HoverInteraction.pointerIsInside(
            DisplayPoint(x: 150, y: 850),
            localTopLeadingFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900
        ),
        equals: false,
        "a pointer below the interactive frame is a real exit"
    )
}

func testHoverInteractionKeepsCompactTargetOnTheVisibleBar() throws {
    let compactFrame = DisplayFrame(minX: 192, minY: 0, width: 300, height: 38)

    let frame = HoverInteraction.interactiveFrame(
        compactFrame: compactFrame,
        expandedPanelWidth: 800,
        expandedMaximumHeight: 398,
        measuredContentHeight: 240,
        isExpanded: false,
        isHidden: false
    )

    try expect(
        frame,
        equals: compactFrame,
        "stale broad-panel geometry cannot offset the collapsed hover target"
    )
}

func testHoverInteractionOpensTheWholeExpandedSurfaceToClicks() throws {
    let compactFrame = DisplayFrame(minX: 309, minY: 0, width: 102, height: 24)

    try expect(
        HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 384,
            measuredContentHeight: 210,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 0, width: 800, height: 210),
        "settings, rows, and chevrons across the expanded card all receive clicks"
    )
    try expect(
        HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 384,
            measuredContentHeight: compactFrame.height,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 0, width: 800, height: 384),
        "expansion accepts the full destination while SwiftUI is still measuring it"
    )
}

func testHoverInteractionUsesOnlyVisibleContentForHoverExit() throws {
    let compactFrame = DisplayFrame(minX: 309, minY: 0, width: 102, height: 24)

    try expect(
        HoverInteraction.visibleHoverFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 384,
            measuredContentHeight: 120,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 0, width: 800, height: 120),
        "transparent space below the measured card does not keep hover alive"
    )
    try expect(
        HoverInteraction.visibleHoverFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 384,
            measuredContentHeight: compactFrame.height,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 0, width: 800, height: 384),
        "the provisional expanded card stays hoverable before its first measurement"
    )
}

func testHoverInteractionDoesNotReexpandFromTheCollapsingCard() throws {
    let compactFrame = DisplayFrame(minX: 309, minY: 0, width: 102, height: 24)

    try expect(
        HoverInteraction.shouldScheduleExpansion(
            pointer: DisplayPoint(x: 460, y: 750),
            compactFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900,
            isExpanded: false
        ),
        equals: false,
        "an active event from the former session-card area cannot reverse collapse"
    )
    try expect(
        HoverInteraction.shouldScheduleExpansion(
            pointer: DisplayPoint(x: 460, y: 890),
            compactFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900,
            isExpanded: false
        ),
        equals: true,
        "a real hover over the final compact pill still expands"
    )
    try expect(
        HoverInteraction.shouldScheduleExpansion(
            pointer: DisplayPoint(x: 410, y: 895),
            compactFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900,
            isExpanded: false,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "the transparent concave shoulder cannot trigger expansion"
    )
}

func testSingleInstanceLockExcludesBundledAndUnbundledProcesses() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = directory.appendingPathComponent(".app.lock")

    var firstLock = try SingleInstanceLock.acquire(at: lockURL)
    try expect(firstLock != nil, equals: true, "first app instance acquires the lock")
    try expect(
        try SingleInstanceLock.acquire(at: lockURL) == nil,
        equals: true,
        "a second process identity cannot acquire the same lock"
    )
    let permissions = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions]
        as? NSNumber
    try expect(permissions?.intValue, equals: 0o600, "instance lock is user-private")

    func externalLockAttemptStatus() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-t", "0", lockURL.path, "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    try expect(
        try externalLockAttemptStatus() == 0,
        equals: false,
        "a separate process cannot acquire the application lock"
    )

    firstLock = nil
    let replacementLock = try SingleInstanceLock.acquire(at: lockURL)
    try expect(replacementLock != nil, equals: true, "lock is released when the first instance exits")
    withExtendedLifetime(replacementLock) {}
}

func testSingleInstanceLockRejectsNonRegularLockPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target")
    try Data("user-owned".utf8).write(to: target)
    let symlink = root.appendingPathComponent("symlink-lock")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let directory = root.appendingPathComponent("directory-lock", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    for unsafePath in [symlink, directory] {
        do {
            _ = try SingleInstanceLock.acquire(at: unsafePath)
            throw TestFailure.expectation("non-regular lock path was accepted: \(unsafePath.lastPathComponent)")
        } catch is TestFailure {
            throw TestFailure.expectation("non-regular lock path was accepted: \(unsafePath.lastPathComponent)")
        } catch {
            // O_NOFOLLOW and the regular-file check must reject an existing
            // user-controlled link or directory instead of mutating it.
        }
    }
    try expect(
        try String(contentsOf: target, encoding: .utf8),
        equals: "user-owned",
        "symlink target remains untouched"
    )
}

func testNotchLayoutStatusWingWidthHidesZeroCountIndicators() throws {
    try expect(
        NotchLayout.statusWingWidth(visibleIndicatorCount: 0, showsIdleMark: false),
        equals: 0,
        "an empty wing claims no width"
    )
    try expect(
        NotchLayout.statusWingWidth(visibleIndicatorCount: 0, showsIdleMark: true),
        equals: 46,
        "the quiet idle drop bottoms out at the minimum capsule width"
    )
    try expect(NotchLayout.statusWingEdgePadding, equals: 6, "compact pill hugs its counters instead of padding them out")
    let one = NotchLayout.statusWingWidth(visibleIndicatorCount: 1, showsIdleMark: false)
    let two = NotchLayout.statusWingWidth(visibleIndicatorCount: 2, showsIdleMark: false)
    try expect(
        one,
        equals: NotchLayout.statusIndicatorSlotWidth + 2 * NotchLayout.statusWingEdgePadding,
        "one visible indicator: slot plus symmetric edge padding"
    )
    try expect(
        two,
        equals: 2 * NotchLayout.statusIndicatorSlotWidth
            + NotchLayout.statusIndicatorSpacing
            + 2 * NotchLayout.statusWingEdgePadding,
        "two visible indicators: slots, one gap, symmetric edge padding"
    )
}

func testScreenSelectionFollowsThePointerAndFallsBackToFocusedDisplay() throws {
    let displays = [
        DisplaySnapshot(id: 11, frame: DisplayFrame(minX: 0, minY: 0, width: 1_512, height: 982)),
        DisplaySnapshot(id: 22, frame: DisplayFrame(minX: 1_512, minY: 0, width: 2_560, height: 1_440)),
    ]

    try expect(
        ScreenSelection.selectDisplayID(
            mode: .pointer,
            pointerLocation: DisplayPoint(x: 2_000, y: 400),
            focusedDisplayID: 11,
            lastSelectedDisplayID: nil,
            displays: displays
        ),
        equals: 22,
        "pointer display wins over focused display"
    )
    try expect(
        ScreenSelection.selectDisplayID(
            mode: .pointer,
            pointerLocation: DisplayPoint(x: -10, y: 400),
            focusedDisplayID: 22,
            lastSelectedDisplayID: 11,
            displays: displays
        ),
        equals: 22,
        "pointer gap falls back to focused display"
    )
    try expect(
        ScreenSelection.selectDisplayID(
            mode: .focusedWindow,
            pointerLocation: DisplayPoint(x: 2_000, y: 400),
            focusedDisplayID: 11,
            lastSelectedDisplayID: 22,
            displays: displays
        ),
        equals: 11,
        "focused-window mode ignores pointer when a focused display exists"
    )
}

func testFocusedWindowFrameWinsOverPointerAndDefaultDisplay() throws {
    // Display B is first to model Moonglade's own main/default screen, while
    // the frontmost external application's window is on display A.
    let displays = [
        DisplaySnapshot(id: 22, frame: DisplayFrame(minX: 1_000, minY: 0, width: 1_000, height: 800)),
        DisplaySnapshot(id: 11, frame: DisplayFrame(minX: 0, minY: 0, width: 1_000, height: 800)),
    ]

    try expect(
        ScreenSelection.selectDisplayID(
            mode: .focusedWindow,
            pointerLocation: DisplayPoint(x: 1_500, y: 400),
            focusedWindowFrame: DisplayFrame(minX: 100, minY: 100, width: 700, height: 500),
            lastSelectedDisplayID: 22,
            displays: displays
        ),
        equals: 11,
        "external focused-window frame wins over pointer and app default"
    )
}

func testFocusedWindowFrameUsesGreatestIntersectionAndStableTieBreak() throws {
    let displays = [
        DisplaySnapshot(id: 40, frame: DisplayFrame(minX: 0, minY: 0, width: 1_000, height: 800)),
        DisplaySnapshot(id: 20, frame: DisplayFrame(minX: 1_000, minY: 0, width: 1_000, height: 800)),
    ]

    try expect(
        ScreenSelection.displayID(
            containingMostOf: DisplayFrame(minX: 800, minY: 100, width: 900, height: 500),
            displays: displays
        ),
        equals: 20,
        "spanning window selects the display with the greatest intersection"
    )
    try expect(
        ScreenSelection.displayID(
            containingMostOf: DisplayFrame(minX: 500, minY: 100, width: 1_000, height: 500),
            displays: displays
        ),
        equals: 20,
        "equal intersections use the lowest stable display ID"
    )
    try expect(
        ScreenSelection.displayID(
            containingMostOf: DisplayFrame(minX: 3_000, minY: 100, width: 500, height: 500),
            displays: displays
        ),
        equals: nil,
        "offscreen window bounds are unavailable"
    )
    try expect(
        ScreenSelection.displayID(
            containingMostOf: DisplayFrame(minX: .nan, minY: 100, width: 500, height: 500),
            displays: displays
        ),
        equals: nil,
        "invalid window bounds are unavailable"
    )
}

func testFocusedWindowUnavailableFallsBackWithoutChangingPrivacyPermissions() throws {
    let displays = [
        DisplaySnapshot(id: 22, frame: DisplayFrame(minX: 1_000, minY: 0, width: 1_000, height: 800)),
        DisplaySnapshot(id: 11, frame: DisplayFrame(minX: 0, minY: 0, width: 1_000, height: 800)),
    ]

    try expect(
        ScreenSelection.selectDisplayID(
            mode: .focusedWindow,
            pointerLocation: DisplayPoint(x: 1_500, y: 400),
            focusedWindowFrame: nil,
            lastSelectedDisplayID: 11,
            displays: displays
        ),
        equals: 22,
        "unavailable or restricted window data falls back to the pointer"
    )
    try expect(
        ScreenSelection.selectDisplayID(
            mode: .focusedWindow,
            pointerLocation: nil,
            focusedWindowFrame: nil,
            lastSelectedDisplayID: 11,
            displays: displays
        ),
        equals: 11,
        "missing pointer then falls back to the last selected display"
    )
    try expect(
        ScreenSelection.selectDisplayID(
            mode: .focusedWindow,
            pointerLocation: nil,
            focusedWindowFrame: nil,
            lastSelectedDisplayID: nil,
            displays: displays
        ),
        equals: 22,
        "missing observations finally fall back to the first available display"
    )
}

func testScreenSelectionReturnsEveryDisplayWhenConfiguredForAllDisplays() throws {
    let displays = [
        DisplaySnapshot(id: 11, frame: DisplayFrame(minX: 0, minY: 0, width: 1_512, height: 982)),
        DisplaySnapshot(id: 22, frame: DisplayFrame(minX: 1_512, minY: 0, width: 2_560, height: 1_440)),
    ]

    try expect(
        ScreenSelection.selectDisplayIDs(
            mode: .allDisplays,
            pointerLocation: DisplayPoint(x: 2_000, y: 400),
            focusedDisplayID: 11,
            lastSelectedDisplayID: 11,
            displays: displays
        ),
        equals: [11, 22],
        "all-displays mode keeps a notch panel on every connected display"
    )
}

func testPanelSynchronizationSchedulesNoIdlePollingOutsideFocusedWindowMode() throws {
    let allDisplays = PanelSynchronizationPolicy.schedule(for: .allDisplays)
    try expect(allDisplays.resources, equals: [], "all-displays resources")
    try expect(allDisplays.idlePollInterval, equals: nil, "all-displays idle polling")

    let pointer = PanelSynchronizationPolicy.schedule(for: .pointer)
    try expect(
        pointer.resources,
        equals: [.pointerEventMonitor],
        "pointer mode reacts through pointer events"
    )
    try expect(pointer.idlePollInterval, equals: nil, "pointer mode has no fixed-rate work")

    var pointerDisplays = PointerDisplayChangeReducer(initialDisplayID: 11)
    try expect(
        pointerDisplays.update(displayID: 11),
        equals: false,
        "high-rate movement inside one display is ignored"
    )
    try expect(
        pointerDisplays.update(displayID: 22),
        equals: true,
        "crossing a display boundary requests synchronization"
    )
    try expect(
        pointerDisplays.update(displayID: 22),
        equals: false,
        "movement after crossing is ignored again"
    )
}

func testFocusedWindowSynchronizationUsesOnlyDocumentedSlowFallback() throws {
    let focused = PanelSynchronizationPolicy.schedule(for: .focusedWindow)

    try expect(
        focused.resources,
        equals: [.focusedWindowFallbackTimer],
        "focused-window mode installs only its fallback resource"
    )
    try expect(
        focused.idlePollInterval,
        equals: PanelSynchronizationPolicy.focusedWindowFallbackInterval,
        "focused-window fallback uses the documented cadence"
    )
    try expect(
        (focused.idlePollInterval ?? 0) >= 2,
        equals: true,
        "focused-window fallback is substantially slower than the old 250ms poll"
    )
}

func testPanelSynchronizationModeTransitionsChangeResourcesExactlyOnce() throws {
    var policy = PanelSynchronizationPolicy()

    let initialPointer = policy.transition(to: .pointer)
    try expect(initialPointer.installed, equals: [.pointerEventMonitor], "initial pointer install")
    try expect(initialPointer.removed, equals: [], "initial pointer removal")
    let repeatedPointer = policy.transition(to: .pointer)
    try expect(repeatedPointer.installed, equals: [], "repeated pointer install")
    try expect(repeatedPointer.removed, equals: [], "repeated pointer removal")

    let focused = policy.transition(to: .focusedWindow)
    try expect(focused.installed, equals: [.focusedWindowFallbackTimer], "focused install")
    try expect(focused.removed, equals: [.pointerEventMonitor], "pointer removal")
    let repeatedFocused = policy.transition(to: .focusedWindow)
    try expect(repeatedFocused.installed, equals: [], "repeated focused install")
    try expect(repeatedFocused.removed, equals: [], "repeated focused removal")

    let allDisplays = policy.transition(to: .allDisplays)
    try expect(allDisplays.installed, equals: [], "all-displays install")
    try expect(
        allDisplays.removed,
        equals: [.focusedWindowFallbackTimer],
        "focused fallback removal"
    )
    let repeatedAllDisplays = policy.transition(to: .allDisplays)
    try expect(repeatedAllDisplays.installed, equals: [], "repeated all-displays install")
    try expect(repeatedAllDisplays.removed, equals: [], "repeated all-displays removal")
}

func testAttentionAcknowledgmentsSilenceVisitedSessionsUntilNewActivity() throws {
    let waiting = try AgentSession.decode(
        from: validStateJSON(sessionID: "ack", status: "needs_attention")
    )
    var acknowledgments = AttentionAcknowledgments()

    try expect(
        SessionStatusSummary(sessions: [waiting], acknowledgments: acknowledgments).blockedCount,
        equals: 1,
        "unvisited session keeps its red light"
    )

    acknowledgments.acknowledge(waiting)
    try expect(
        SessionStatusSummary(sessions: [waiting], acknowledgments: acknowledgments).blockedCount,
        equals: 0,
        "visited session goes quiet in the bar"
    )
    try expect(
        acknowledgments.silenced([waiting]).first?.sessionID,
        equals: "ack",
        "silencing keeps the session listed"
    )

    let reraised = AgentSession(
        tool: waiting.tool,
        sessionID: waiting.sessionID,
        pid: waiting.pid,
        status: .needsAttention,
        cwd: waiting.cwd,
        startedAt: waiting.startedAt,
        updatedAt: waiting.updatedAt.addingTimeInterval(60),
        terminal: waiting.terminal
    )
    try expect(
        SessionStatusSummary(sessions: [reraised], acknowledgments: acknowledgments).blockedCount,
        equals: 1,
        "new activity re-arms the light"
    )
}

func testGitWorkspaceInspectorResolvesBranchNames() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = FileManager.default

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try filesystem.createDirectory(
        at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
    )
    try Data("ref: refs/heads/feat/notch-menu\n".utf8)
        .write(to: repo.appendingPathComponent(".git/HEAD"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: repo.path),
        equals: "feat/notch-menu",
        "branch of a normal repository"
    )

    let nested = repo.appendingPathComponent("deep/subdir", isDirectory: true)
    try filesystem.createDirectory(at: nested, withIntermediateDirectories: true)
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: nested.path),
        equals: "feat/notch-menu",
        "branch found walking up from a subdirectory"
    )

    let homeWorktreeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".moonglade-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: homeWorktreeRoot) }
    let worktreeMetadata = homeWorktreeRoot.appendingPathComponent("worktrees/glance", isDirectory: true)
    try filesystem.createDirectory(at: worktreeMetadata, withIntermediateDirectories: true)
    try Data("ref: refs/heads/fix/menu\n".utf8)
        .write(to: worktreeMetadata.appendingPathComponent("HEAD"))
    let linkedWorktree = root.appendingPathComponent("repo.fix-menu", isDirectory: true)
    try filesystem.createDirectory(at: linkedWorktree, withIntermediateDirectories: true)
    try Data("gitdir: \(worktreeMetadata.path)\n".utf8)
        .write(to: linkedWorktree.appendingPathComponent(".git"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: linkedWorktree.path),
        equals: "fix/menu",
        "branch of a linked worktree"
    )

    let detached = root.appendingPathComponent("detached", isDirectory: true)
    try filesystem.createDirectory(
        at: detached.appendingPathComponent(".git"), withIntermediateDirectories: true
    )
    try Data("0123456789abcdef0123456789abcdef01234567\n".utf8)
        .write(to: detached.appendingPathComponent(".git/HEAD"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: detached.path),
        equals: "0123456",
        "short hash for a detached HEAD"
    )

    let bare = root.appendingPathComponent("not-a-repo", isDirectory: true)
    try filesystem.createDirectory(at: bare, withIntermediateDirectories: true)
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: bare.path),
        equals: nil,
        "nil outside any repository"
    )
}

final class AsyncTestResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

func waitForAsync<Value: Sendable>(
    timeout: TimeInterval = 10,
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let completion = DispatchSemaphore(value: 0)
    let box = AsyncTestResultBox<Value>()
    Task.detached {
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
        completion.signal()
    }
    guard completion.wait(timeout: .now() + timeout) == .success,
          let result = box.load() else {
        throw TestFailure.expectation("async test timed out")
    }
    return try result.get()
}

final class GitBranchResolverProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)

    private let blocks: Bool
    private let lock = NSLock()
    private var invocationCounts: [String: Int] = [:]
    private var activeCount = 0
    private var highestActiveCount = 0

    init(blocks: Bool) {
        self.blocks = blocks
    }

    func resolve(_ path: String) -> String? {
        lock.lock()
        invocationCounts[path, default: 0] += 1
        activeCount += 1
        highestActiveCount = max(highestActiveCount, activeCount)
        lock.unlock()

        if blocks {
            _ = release.wait(timeout: .now() + 5)
        }

        lock.lock()
        activeCount -= 1
        lock.unlock()
        return "branch-\(URL(fileURLWithPath: path).lastPathComponent)"
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCounts.values.reduce(0, +)
    }

    func invocations(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCounts[path, default: 0]
    }

    var maximumActiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return highestActiveCount
    }

    func waitForInvocations(_ expectedCount: Int) async throws {
        for _ in 0..<2_000 {
            if invocationCount >= expectedCount { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw TestFailure.expectation("Git resolver did not receive \(expectedCount) requests")
    }
}

func testGitBranchResolutionCoordinatorCoalescesAndCachesWorkingDirectory() throws {
    try waitForAsync {
        let probe = GitBranchResolverProbe(blocks: true)
        let coordinator = GitBranchResolutionCoordinator(
            maximumConcurrentResolutions: 4,
            maximumCacheEntries: 8,
            resolver: { path in probe.resolve(path) }
        )
        let requests = [
            Task { await coordinator.branchName(forWorkingDirectory: "/tmp/shared-repo") },
            Task { await coordinator.branchName(forWorkingDirectory: "/tmp/shared-repo/./") },
        ]
        try await probe.waitForInvocations(1)
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(probe.invocationCount, equals: 1, "concurrent normalized requests coalesce")

        probe.release.signal()
        var concurrentResults: [String?] = []
        for request in requests {
            concurrentResults.append(await request.value)
        }
        try expect(
            concurrentResults,
            equals: ["branch-shared-repo", "branch-shared-repo"],
            "coalesced callers receive the same branch"
        )
        let repeated = await coordinator.branchName(forWorkingDirectory: "/tmp/shared-repo")
        try expect(repeated, equals: "branch-shared-repo", "repeated request returns cached branch")
        try expect(probe.invocationCount, equals: 1, "repeated request avoids another probe")
    }
}

func testGitBranchResolutionCoordinatorBoundsConcurrentProbes() throws {
    try waitForAsync {
        let probe = GitBranchResolverProbe(blocks: true)
        let coordinator = GitBranchResolutionCoordinator(
            maximumConcurrentResolutions: 2,
            maximumCacheEntries: 8,
            resolver: { path in probe.resolve(path) }
        )
        let requests = (0..<6).map { index in
            Task {
                await coordinator.branchName(forWorkingDirectory: "/tmp/repo-\(index)")
            }
        }
        try await probe.waitForInvocations(2)
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(probe.invocationCount, equals: 2, "queued probes wait for a concurrency slot")
        try expect(probe.maximumActiveCount, equals: 2, "active Git probes respect the bound")

        for _ in requests { probe.release.signal() }
        for request in requests { _ = await request.value }
        try expect(probe.invocationCount, equals: 6, "every distinct directory eventually resolves")
        try expect(probe.maximumActiveCount, equals: 2, "later probes also respect the bound")
    }
}

func testGitBranchResolutionCoordinatorEvictsLeastRecentlyUsedEntry() throws {
    try waitForAsync {
        let probe = GitBranchResolverProbe(blocks: false)
        let coordinator = GitBranchResolutionCoordinator(
            maximumConcurrentResolutions: 1,
            maximumCacheEntries: 2,
            resolver: { path in probe.resolve(path) }
        )
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-a")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-b")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-a")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-c")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-a")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-b")

        try expect(probe.invocations(for: "/tmp/repo-a"), equals: 1, "recent entry stays cached")
        try expect(probe.invocations(for: "/tmp/repo-b"), equals: 2, "least-recent entry is evicted")
        try expect(probe.invocations(for: "/tmp/repo-c"), equals: 1, "new entry is cached")
    }
}

func testNotchLayoutExtendsFromLeftSideOfHardwareNotch() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(layout.presentation, equals: .notch, "a screen with a camera housing keeps the notch")
    try expect(layout.width, equals: 800, "wide expanded panel leaves room for smooth side curves")
    try expect(layout.height, equals: 38, "collapsed panel height")
    try expect(layout.expandedHeight, equals: 387, "expanded panel reserves the error row")
    try expect(layout.originX, equals: 356, "expanded panel x")
    try expect(layout.originY, equals: 944, "panel y")
    try expect(layout.notchWidth, equals: 180, "hardware notch width")
}

func testNotchLayoutKeepsExpandedContentCloseToTheSideEdges() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(layout.width, equals: 800, "outer panel keeps its rounded outer shape")
    try expect(NotchLayout.expandedContentWidth, equals: 784, "session content sits close to the expanded side edges")
    try expect(
        NotchLayout.contentWidth(forExpandedPanelWidth: 600),
        equals: 584,
        "narrow screens keep only a small safe gutter"
    )
}

func testNotchLayoutPinsCompactBarToPhysicalNotchWhenExpandedPanelIsClamped() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 600,
        screenMaxY: 900,
        safeAreaTop: 32,
        leftNotchEdgeX: 350,
        rightNotchEdgeX: 430
    )

    try expect(layout.originX, equals: 0, "expanded panel is clamped to the narrow display")
    try expect(
        layout.barLeadingOffset(leftWidth: 42, rightWidth: 0),
        equals: 308,
        "compact left wing remains attached to the physical notch edge"
    )
    try expect(
        layout.barLeadingOffset(leftWidth: 0, rightWidth: 42),
        equals: 350,
        "same-width status transition still moves the interactive origin"
    )
}

func testNotchLayoutExpandedHeaderWingsFlankTheCamera() throws {
    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    let notchedWings = notched.expandedHeaderWingWidths()
    try expect(notchedWings.left, equals: 310, "left wing spans the panel edge to the camera")
    try expect(notchedWings.right, equals: 310, "right wing spans the camera to the panel edge")
    try expect(
        notchedWings.left + notched.notchWidth + notchedWings.right,
        equals: notched.width,
        "wings and camera cutout tile the expanded panel exactly"
    )

    // A panel clamped to a narrow display keeps the camera cutout pinned to
    // the physical notch, so the wings become asymmetric but still tile.
    let clamped = NotchLayout(
        screenMinX: 0,
        screenWidth: 600,
        screenMaxY: 900,
        safeAreaTop: 32,
        leftNotchEdgeX: 350,
        rightNotchEdgeX: 430
    )
    let clampedWings = clamped.expandedHeaderWingWidths()
    try expect(clampedWings.left, equals: 350, "clamped left wing reaches the physical notch edge")
    try expect(
        clampedWings.left + clamped.notchWidth + clampedWings.right,
        equals: clamped.width,
        "clamped wings and cutout still tile the panel"
    )

    let pill = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )
    let pillWings = pill.expandedHeaderWingWidths()
    try expect(pillWings.left, equals: 400, "pill has no cutout so the wings split the panel")
    try expect(pillWings.right, equals: 400, "pill wings stay symmetric")
    try expect(pill.notchWidth, equals: 0, "no phantom camera gap between pill wings")

    try expect(
        SessionMenuLayout.maximumCardHeight(),
        equals: 316,
        "headerless card holds only the list and its vertical insets"
    )
}

func testNotchLayoutAddsOnlyAMinimalFixedRightWing() throws {
    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    let activeNotchWing = notched.statusWingWidth(
        side: .left,
        visibleIndicatorCount: 1,
        showsIdleMark: false
    )
    try expect(
        notched.statusWingEdgePadding,
        equals: NotchLayout.hardwareNotchOuterWingPadding,
        "hardware-notch outer edge clears the concave shoulder with breathing room"
    )
    try expect(
        notched.leftStatusWingLeadingPadding,
        equals: NotchLayout.hardwareNotchOuterWingPadding,
        "left wing outer glyph clears the black's straight side, not hugging the curve"
    )
    try expect(notched.leftStatusWingTrailingPadding, equals: 12, "left wing leaves a small camera-facing gap")
    try expect(notched.rightStatusWingLeadingPadding, equals: 12, "right wing mirrors the small camera gap")
    try expect(
        notched.rightStatusWingTrailingPadding,
        equals: NotchLayout.hardwareNotchOuterWingPadding,
        "right count clears the curve exactly like the left dot"
    )
    try expect(
        activeNotchWing,
        equals: NotchLayout.statusIndicatorSlotWidth + 12 + NotchLayout.hardwareNotchOuterWingPadding,
        "hardware-notch wing = slot + camera gap + outer shoulder clearance"
    )
    let balanced = notched.balancedStatusWingWidths(leftWidth: activeNotchWing, rightWidth: 0)

    try expect(balanced.left, equals: activeNotchWing, "visible left wing keeps its real content width")
    try expect(balanced.right, equals: 28, "empty right wing is only a minimal fixed visual extension")

    let pill = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )
    try expect(pill.statusWingEdgePadding, equals: 6, "virtual pill keeps a slim horizontal padding")
    let unbalanced = pill.balancedStatusWingWidths(leftWidth: 54, rightWidth: 0)
    try expect(unbalanced.left, equals: 54, "notchless drop preserves its real left content")
    try expect(unbalanced.right, equals: 0, "notchless drop adds no phantom status wing")
}

func testNotchLayoutAddsOnlyAMinimalFixedLeftWing() throws {
    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    let activeRightWing = notched.statusWingWidth(
        side: .right,
        visibleIndicatorCount: 1,
        showsIdleMark: false
    )
    let balanced = notched.balancedStatusWingWidths(leftWidth: 0, rightWidth: activeRightWing)

    try expect(balanced.left, equals: 28, "empty left wing is only a minimal fixed visual extension")
    try expect(balanced.right, equals: activeRightWing, "visible right wing keeps its real content width")

    let pill = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )
    let unbalanced = pill.balancedStatusWingWidths(leftWidth: 0, rightWidth: 54)
    try expect(unbalanced.left, equals: 0, "notchless drop adds no phantom status wing")
    try expect(unbalanced.right, equals: 54, "notchless drop preserves its real right content")
}

func testNotchLayoutReservesRightOuterCurveClearanceForBlockedCount() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(
        layout.rightStatusWingTrailingPadding,
        equals: layout.leftStatusWingLeadingPadding,
        "both outer insets match so a bar with wings on each side reads symmetric"
    )
    // The core invariant behind the bisected-dot fix: neither outer inset may
    // be smaller than the shoulder radius, or the outermost glyph enters the
    // concave band the black has curved away from and spills onto the
    // wallpaper. Guarding both wings keeps the fix from silently regressing.
    try expect(
        layout.leftStatusWingLeadingPadding >= HangingNotchMetrics.topShoulderRadius,
        equals: true,
        "left outer inset covers the concave shoulder"
    )
    try expect(
        layout.rightStatusWingTrailingPadding >= HangingNotchMetrics.topShoulderRadius,
        equals: true,
        "right outer inset covers the concave shoulder"
    )
    try expect(
        layout.statusWingWidth(
            side: .right,
            visibleIndicatorCount: 1,
            showsIdleMark: false
        ),
        equals: NotchLayout.statusIndicatorSlotWidth
            + layout.rightStatusWingLeadingPadding
            + layout.rightStatusWingTrailingPadding,
        "the right wing width is calculated from its own mirrored paddings"
    )
}

func testNotchLayoutUsesPillStyleOnNotchlessScreen() throws {
    // A Studio Display: no safe area, no camera housing, a real 24 pt menu
    // bar. The compact surface floats as a detached capsule slightly below
    // the top edge instead of fusing with it like a notch.
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )

    try expect(layout.presentation, equals: .pill, "notchless screen gets the pill")
    try expect(layout.cornerStyle, equals: .bubble, "detached pill rounds every corner instead of faking a notch")
    try expect(layout.notchWidth, equals: 0, "no phantom camera gap")
    try expect(layout.topGap, equals: 4, "pill floats below the top edge")
    try expect(layout.height, equals: 16, "gap, pill, and bottom inset stay within the real menu bar")
    try expect(layout.originY, equals: 1_424, "panel keeps its top on the screen edge; the gap lives inside it")
    try expect(layout.originY + layout.height, equals: 1_440, "pill and notch panels share the top edge")
    try expect(layout.width, equals: 800, "panel wide enough for session details and side curves")
    try expect(layout.originX, equals: 880, "centered on screen")
    try expect(layout.expandedTopGap, equals: 8, "open bubble detaches further from the screen edge")
    try expect(layout.expandedContentSideInset, equals: 0, "bubble sides are the panel edges, no extra content inset")
    try expect(layout.expandedHeaderTopPadding, equals: 14, "expanded bubble grows breathing room above its header")
    try expect(layout.expandedBottomPadding, equals: 8, "last row clears the bubble's rounded bottom corners")
    try expect(layout.expandedHeight, equals: 387, "expanded shell reserves the error row")
}

func testNotchLayoutPillFallsBackToStandardMenuBarHeight() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 0
    )

    try expect(layout.height, equals: 16, "standard menu bar minus both margins bounds the virtual pill height")
}

func testNotchLayoutNotchKeepsScreenEdgeAttachment() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(layout.cornerStyle, equals: .hangingNotch, "hardware notch keeps its concave shoulders")
    try expect(layout.topGap, equals: 0, "hardware notch stays fused to the screen edge")
    try expect(layout.expandedTopGap, equals: 0, "notch stays fused to the edge while open too")
    try expect(
        layout.expandedContentSideInset,
        equals: HangingNotchMetrics.topShoulderRadius,
        "notch content absorbs the shoulder radius that pulls its sides inward"
    )
    try expect(layout.expandedHeaderTopPadding, equals: 0, "notch header sits beside the camera and needs no extra room")
    try expect(layout.expandedBottomPadding, equals: 8, "notch card matches its lateral margins below the list")
    try expect(layout.expandedHeight, equals: 387, "the notch shell reserves the error row")
}

func testHangingNotchGeometryCreatesConcaveShouldersAndRoundedBase() throws {
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 1, y: 7),
            width: 102,
            height: 38,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "compact drop cuts out the upper-left shoulder"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 16, y: 7),
            width: 102,
            height: 38,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "compact drop keeps the body beside the concave shoulder"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 101, y: 7),
            width: 102,
            height: 38,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "upper shoulders stay symmetric"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 11, y: 37),
            width: 102,
            height: 38,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "compact drop rounds away the lower-left corner"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 400, y: 119),
            width: 800,
            height: 120,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "expanded drop preserves its broad rounded body"
    )
}

func testHangingNotchGeometryKeepsExpandedSidesStraightWithCircularCorners() throws {
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 13, y: 150),
            width: 800,
            height: 300,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "the expanded side begins just inside the shallow top shoulder"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 15, y: 150),
            width: 800,
            height: 300,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "the expanded side remains a vertical line between its corners"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 17, y: 291),
            width: 800,
            height: 300,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "the lower corner follows a true rounded arc instead of an S sweep"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 19, y: 291),
            width: 800,
            height: 300,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "the lower corner retains the visible interior of its circular arc"
    )
}

func testBubbleGeometryRoundsEveryCornerAndCapsulesWhenShort() throws {
    // Collapsed pill: 102×20 with the 20 pt profile radius clamps to the
    // half-height, a true capsule.
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 1, y: 1),
            width: 102,
            height: 20,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "capsule rounds away the upper-left corner instead of flaring into it"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 1, y: 10),
            width: 102,
            height: 20,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "capsule keeps its rounded tip at mid-height"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 101, y: 19),
            width: 102,
            height: 20,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "capsule rounds away the lower-right corner symmetrically"
    )

    // Expanded bubble: the sides span the full width — no shoulder inset —
    // and the top corners are convex arcs of the profile radius.
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 13, y: 150),
            width: 800,
            height: 300,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "bubble sides reach the full panel width instead of the notch body inset"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 3, y: 3),
            width: 800,
            height: 300,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "bubble top corner is a convex arc, not a concave shoulder flare"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 400, y: 1),
            width: 800,
            height: 300,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "bubble keeps a straight top edge between its corner arcs"
    )
}

func testHangingNotchMetricsShareOneCornerProfileAcrossModes() throws {
    try expect(
        HangingNotchMetrics.topShoulderRadius,
        equals: 14,
        "one shoulder gives physical and virtual notches the same curve"
    )
    try expect(
        HangingNotchMetrics.bottomCornerRadius,
        equals: 20,
        "one generous lower radius serves compact and expanded alike"
    )
    try expect(
        HangingNotchMetrics.topShoulderRadius + HangingNotchMetrics.bottomCornerRadius,
        equals: 34,
        "both curves fit the shared compact-notch height without being distorted"
    )
    try expect(
        SessionMenuLayout.contentHorizontalInset,
        equals: 4,
        "expanded content hugs the bubble sides with a slim inset"
    )
    try expect(
        SessionMenuLayout.expandedHeaderLeadingInset,
        equals: SessionMenuLayout.contentHorizontalInset
            + SessionMenuLayout.sessionRowLeadingInset
            + NotchLayout.expandedCurveGutter,
        "the header title stays column-aligned with the row icons below"
    )
    try expect(
        SessionMenuLayout.sessionRowHeight,
        equals: 52,
        "session rows gain vertical breathing room"
    )
    try expect(
        SessionMenuLayout.sessionListHeight(sessionCount: 1, hasExpandedActions: true),
        equals: 196,
        "one row grows to reveal its roomier action list"
    )
    try expect(
        SessionMenuLayout.sessionListHeight(sessionCount: 5, hasExpandedActions: true),
        equals: 300,
        "several rows scroll instead of escaping the panel"
    )
}

func testSessionMenuLayoutKeepsThreeExpandedSessionsOutOfAScrollView() throws {
    try expect(
        SessionMenuLayout.sessionListHeight(sessionCount: 3, hasExpandedActions: true),
        equals: 300,
        "three sessions plus the expanded action area fit before scrolling"
    )
    try expect(
        SessionMenuLayout.requiresScrolling(sessionCount: 3, hasExpandedActions: true),
        equals: false,
        "opening the final row of a three-session list does not introduce a scroll bar"
    )
    try expect(
        SessionMenuLayout.requiresScrolling(sessionCount: 4, hasExpandedActions: true),
        equals: true,
        "a fourth expanded session still scrolls instead of exceeding the menu"
    )
}

func testHoverInteractionKeepsInlineRowInteractionsOpenDuringDelayedExit() throws {
    try expect(
        HoverInteraction.shouldCollapse(
            isExpanded: true,
            isHoveringPanel: false,
            openMenuTrackingCount: 0,
            rowInteractionActive: true
        ),
        equals: false,
        "a delayed exit cannot collapse an inline row interaction"
    )
}

func testNotchLayoutUsesNormalizedCameraClearance() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(
        layout.leftStatusWingLeadingPadding,
        equals: NotchLayout.hardwareNotchOuterWingPadding,
        "the running spinner clears the concave shoulder instead of riding it"
    )
    try expect(
        layout.leftStatusWingTrailingPadding,
        equals: 12,
        "the waiting counter has a small camera-facing gap"
    )
    try expect(
        layout.rightStatusWingLeadingPadding,
        equals: 12,
        "the opposite wing mirrors the camera clearance"
    )

    let leftWingWidth = layout.statusWingWidth(
        side: .left,
        visibleIndicatorCount: 2,
        showsIdleMark: false
    )
    let balancedWings = layout.balancedStatusWingWidths(
        leftWidth: leftWingWidth,
        rightWidth: 0
    )
    let barLeadingX = layout.originX + layout.barLeadingOffset(
        leftWidth: balancedWings.left,
        rightWidth: balancedWings.right
    )
    let waitingCounterTrailingX = barLeadingX
        + balancedWings.left
        - layout.leftStatusWingTrailingPadding
    try expect(
        waitingCounterTrailingX,
        equals: 654,
        "the waiting counter ends 12 points before the physical notch edge"
    )
}

func testHangingNotchInteractionRegionPassesTransparentCornersThrough() throws {
    let region = HangingNotchInteractionRegion(
        frame: DisplayFrame(minX: 309, minY: 0, width: 102, height: 24),
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
    )

    try expect(
        region.contains(DisplayPoint(x: 310, y: 7)),
        equals: false,
        "AppKit gate passes the concave shoulder through"
    )
    try expect(
        region.contains(DisplayPoint(x: 325, y: 7)),
        equals: true,
        "AppKit gate accepts the visible drop body"
    )
    try expect(
        region.contains(DisplayPoint(x: 360, y: 25)),
        equals: false,
        "AppKit gate passes space below the compact drop through"
    )
}

func testBubbleInteractionRegionFloatsBelowTheTopEdge() throws {
    // A detached pill: the region starts 4 pt below the panel top and hit
    // tests as a capsule, so both the gap strip and the rounded corner
    // pockets pass through to whatever sits behind the panel.
    let region = HangingNotchInteractionRegion(
        frame: DisplayFrame(minX: 309, minY: 4, width: 102, height: 20),
        cornerStyle: .bubble,
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
    )

    try expect(
        region.contains(DisplayPoint(x: 360, y: 2)),
        equals: false,
        "the top gap strip passes through to the menu bar behind the panel"
    )
    try expect(
        region.contains(DisplayPoint(x: 310, y: 5)),
        equals: false,
        "the capsule's rounded corner pocket passes through"
    )
    try expect(
        region.contains(DisplayPoint(x: 360, y: 14)),
        equals: true,
        "the capsule body accepts events"
    )
    try expect(
        region.contains(DisplayPoint(x: 310, y: 14)),
        equals: true,
        "the capsule tip accepts events at mid-height"
    )
}

func testHoverInteractionPreservesTheTopGapWhileExpanded() throws {
    let compactFrame = DisplayFrame(minX: 309, minY: 4, width: 102, height: 20)

    try expect(
        HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 340,
            measuredContentHeight: 210,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 4, width: 800, height: 210),
        "without its own inset the expanded gate inherits the compact bar's gap"
    )
    try expect(
        HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 340,
            measuredContentHeight: 210,
            isExpanded: true,
            isHidden: false,
            expandedTopInset: 8
        ),
        equals: DisplayFrame(minX: 0, minY: 8, width: 800, height: 210),
        "the open bubble's own larger gap moves the click gate down with it"
    )
    try expect(
        HoverInteraction.visibleHoverFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 340,
            measuredContentHeight: 120,
            isExpanded: true,
            isHidden: false,
            expandedTopInset: 8
        ),
        equals: DisplayFrame(minX: 0, minY: 8, width: 800, height: 120),
        "the hover surface follows the bubble's gap so the strip above never holds hover"
    )
}

func testNotchLayoutMenuCardWidthNeverCrampedInPillMode() throws {
    let pill = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )
    try expect(pill.width, equals: 800, "outer pill panel gives its curves lateral room")

    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    try expect(notched.width, equals: 800, "outer notch panel gives its curves lateral room")
}

func testOpenCodePluginWritesSessionState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pluginURL = directory.appendingPathComponent("moonglade.mjs")
    try FileManager.default.copyItem(at: BundledResources.opencodePluginURL, to: pluginURL)
    let driver = directory.appendingPathComponent("driver.mjs")
    try Data(
        """
        import { MoongladePlugin } from "\(pluginURL.absoluteString)";
        const plugin = await MoongladePlugin({
          directory: "/tmp/open-project",
          client: { app: { log: async ({ body }) => console.error(body.message) } }
        });
        await plugin.event({ event: {
          type: "session.created",
          properties: { info: { id: "open-1", directory: "/tmp/open-project" } }
        }});
        """.utf8
    ).write(to: driver)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", driver.path]
    process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "MOONGLADE_HOME": directory.path,
        "TERM_PROGRAM": "ghostty",
    ]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    try expect(process.terminationStatus, equals: 0, "plugin process: \(errorOutput)")
    let stateDirectory = directory.appendingPathComponent("state")
    let stateFiles = (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
    let session = try StateRepository(directoryURL: stateDirectory)
        .loadSessions().first.unwrap(or: "opencode state was not saved; files: \(stateFiles)")
    try expect(session.tool, equals: .opencode, "tool")
    try expect(session.status, equals: .working, "status")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal program")
}

func testOpenCodePluginMapsLifecycleEvents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pluginURL = directory.appendingPathComponent("moonglade.mjs")
    try FileManager.default.copyItem(at: BundledResources.opencodePluginURL, to: pluginURL)
    let driver = directory.appendingPathComponent("lifecycle.mjs")
    try Data(
        """
        import { readFile, writeFile } from "node:fs/promises";
        import { MoongladePlugin } from "\(pluginURL.absoluteString)";
        const plugin = await MoongladePlugin({
          directory: "/tmp/project",
          client: { app: { log: async ({ body }) => console.error(body.message) } }
        });
        const event = async (type, properties) => plugin.event({ event: { type, properties } });
        const statuses = [];
        const stateURL = `${process.env.MOONGLADE_HOME}/state/opencode-b3Blbi0x.json`;
        const capture = async () => statuses.push(JSON.parse(
          await readFile(stateURL, "utf8")
        ));
        await event("session.created", { info: { id: "open-1", directory: "/tmp/project" } });
        const reconciled = JSON.parse(await readFile(stateURL, "utf8"));
        reconciled.process_identity = { pid: reconciled.pid, kernel_start_time_us: 123456 };
        await writeFile(stateURL, JSON.stringify(reconciled));
        await event("permission.asked", { sessionID: "open-1" }); await capture();
        const rebound = JSON.parse(await readFile(stateURL, "utf8"));
        rebound.pid += 1;
        rebound.process_identity = { pid: rebound.pid, kernel_start_time_us: 654321 };
        await writeFile(stateURL, JSON.stringify(rebound));
        await event("permission.replied", { sessionID: "open-1" }); await capture();
        await event("session.idle", { sessionID: "open-1" }); await capture();
        await event("session.deleted", { info: { id: "open-1" } }); await capture();
        console.log(JSON.stringify(statuses));
        """.utf8
    ).write(to: driver)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", driver.path]
    process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "MOONGLADE_HOME": directory.path,
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    try expect(process.terminationStatus, equals: 0, "plugin lifecycle process")
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let states = try decoder.decode([AgentSession].self, from: data)
    try expect(
        states.map(\.status),
        equals: [.needsAttention, .working, .idle, .ended],
        "lifecycle statuses"
    )
    try expect(
        states[0].processIdentity?.kernelStartTimeMicroseconds,
        equals: 123_456,
        "same-process identity survives OpenCode lifecycle update"
    )
    try expect(states[1].processIdentity, equals: nil, "rebound identity is not copied by OpenCode")
}

func testPiExtensionWritesSessionState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let extensionURL = directory.appendingPathComponent("moonglade.mjs")
    try FileManager.default.copyItem(at: BundledResources.piExtensionURL, to: extensionURL)
    let driver = directory.appendingPathComponent("driver.mjs")
    try Data(
        """
        import moonglade from "\(extensionURL.absoluteString)";
        const handlers = new Map();
        moonglade({ on: (event, handler) => handlers.set(event, handler) });
        const ctx = {
          cwd: "/tmp/pi-project",
          sessionManager: { getSessionId: () => "pi-1" },
        };
        await handlers.get("session_start")({ reason: "start" }, ctx);
        """.utf8
    ).write(to: driver)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", driver.path]
    process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "MOONGLADE_HOME": directory.path,
        "TERM_PROGRAM": "ghostty",
    ]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    try expect(process.terminationStatus, equals: 0, "extension process: \(errorOutput)")
    let session = try StateRepository(directoryURL: directory.appendingPathComponent("state"))
        .loadSessions().first.unwrap(or: "pi state was not saved")
    try expect(session.tool, equals: .pi, "tool")
    try expect(session.status, equals: .working, "status")
    try expect(session.cwd, equals: "/tmp/pi-project", "cwd")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal program")
}

func testPiExtensionMapsLifecycleEvents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let extensionURL = directory.appendingPathComponent("moonglade.mjs")
    try FileManager.default.copyItem(at: BundledResources.piExtensionURL, to: extensionURL)
    let driver = directory.appendingPathComponent("lifecycle.mjs")
    try Data(
        """
        import { readFile, writeFile } from "node:fs/promises";
        import moonglade from "\(extensionURL.absoluteString)";
        const handlers = new Map();
        moonglade({ on: (event, handler) => handlers.set(event, handler) });
        const ctx = {
          cwd: "/tmp/pi-project",
          sessionManager: { getSessionId: () => "pi-1" },
        };
        const fire = async (event, payload = {}) => handlers.get(event)(payload, ctx);
        const states = [];
        const stateURL = `${process.env.MOONGLADE_HOME}/state/pi-cGktMQ.json`;
        const capture = async () => states.push(JSON.parse(
          await readFile(stateURL, "utf8")
        ));
        await fire("session_start", { reason: "start" });
        const reconciled = JSON.parse(await readFile(stateURL, "utf8"));
        reconciled.process_identity = { pid: reconciled.pid, kernel_start_time_us: 123456 };
        await writeFile(stateURL, JSON.stringify(reconciled));
        await fire("agent_start"); await capture();
        const rebound = JSON.parse(await readFile(stateURL, "utf8"));
        rebound.pid += 1;
        rebound.process_identity = { pid: rebound.pid, kernel_start_time_us: 654321 };
        await writeFile(stateURL, JSON.stringify(rebound));
        await fire("agent_end", { messages: [] }); await capture();
        await fire("input", { text: "next prompt" }); await capture();
        await fire("session_shutdown", { reason: "exit" }); await capture();
        console.log(JSON.stringify(states));
        """.utf8
    ).write(to: driver)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", driver.path]
    process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "MOONGLADE_HOME": directory.path,
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    try expect(process.terminationStatus, equals: 0, "extension lifecycle process")
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let states = try decoder.decode([AgentSession].self, from: data)
    try expect(
        states.map(\.status),
        equals: [.working, .idle, .working, .ended],
        "lifecycle statuses"
    )
    try expect(
        states.map(\.attentionReason),
        equals: [nil, .turnComplete, nil, nil],
        "attention reasons"
    )
    try expect(
        states[0].processIdentity?.kernelStartTimeMicroseconds,
        equals: 123_456,
        "same-process identity survives Pi lifecycle update"
    )
    try expect(states[1].processIdentity, equals: nil, "rebound identity is not copied by Pi")
}

func testCodexRolloutParserMapsSessionAndTurnEvents() throws {
    var parser = CodexRolloutParser(processID: 321)
    let lines = [
        #"{"timestamp":"2026-07-18T10:00:00Z","type":"session_meta","payload":{"id":"codex-1","cwd":"/tmp/codex-project","timestamp":"2026-07-18T10:00:00Z"}}"#,
        #"{"timestamp":"2026-07-18T10:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2026-07-18T10:00:02Z","type":"event_msg","payload":{"type":"exec_approval_request"}}"#,
        #"{"timestamp":"2026-07-18T10:00:03Z","type":"event_msg","payload":{"type":"exec_command_begin"}}"#,
        #"{"timestamp":"2026-07-18T10:00:04Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ]

    let states = lines.compactMap { parser.consume(line: Data($0.utf8)) }

    try expect(states.map(\.status), equals: [
        .working,
        .working,
        .needsAttention,
        .working,
        .idle,
    ], "Codex states")
    try expect(states.first?.sessionID, equals: "codex-1", "session ID")
    try expect(states.first?.cwd, equals: "/tmp/codex-project", "cwd")
}

func testCodexRolloutParserIgnoresMalformedAndUnknownLines() throws {
    var parser = CodexRolloutParser(processID: 321)

    let malformed = parser.consume(line: Data("not-json".utf8))
    let unknown = parser.consume(
        line: Data(#"{"timestamp":"2026-07-18T10:00:00Z","type":"future_event","payload":{}}"#.utf8)
    )
    let invalidTimestamp = parser.consume(line: Data(
        #"{"timestamp":"not-a-date","type":"session_meta","payload":{"id":"invalid-time","cwd":"/tmp/project"}}"#.utf8
    ))

    try expect(malformed == nil, equals: true, "malformed line")
    try expect(unknown == nil, equals: true, "unknown line")
    try expect(invalidTimestamp == nil, equals: true, "invalid timestamp")
}

func testCodexSessionsWatcherProcessesAppendedLinesIncrementally() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rollout = sessionsDirectory.appendingPathComponent("rollout.jsonl")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let metadata = #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"codex-watch","cwd":"/tmp/watched","timestamp":"\#(timestamp)"}}"#
    try Data("\(metadata)\n".utf8).write(to: rollout)
    let repository = StateRepository(directoryURL: stateDirectory)
    let watcher = CodexSessionsWatcher(
        sessionsDirectoryURL: sessionsDirectory,
        repository: repository,
        processID: Int32(getpid())
    )

    try watcher.scan()
    let approvalTimestamp = ISO8601DateFormatter().string(from: Date())
    let approval = #"{"timestamp":"\#(approvalTimestamp)","type":"event_msg","payload":{"type":"request_permissions"}}"#
    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\(approval)\n".utf8))
    try handle.close()
    try watcher.scan()

    let session = try repository.loadSessions().first.unwrap(or: "Codex state was not saved")
    try expect(session.status, equals: .needsAttention, "appended event status")
    try expect(session.attentionReason, equals: .permission, "appended event reason")
    try expect(
        session.processIdentity,
        equals: SystemProcessScanner.processIdentity(of: Int32(getpid())),
        "live rollout adopts the current process generation"
    )
}

func testCodexSessionsWatcherResavesWhenProcessAppearsLater() throws {
    // A rollout's session_meta can be ingested before the scanner has seen
    // the codex process. Retargeting the resolver must publish the
    // already-parsed session without waiting for new rollout bytes —
    // recreating the watcher (the old behavior) re-read entire files.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let metadata = #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"codex-late","cwd":"/tmp/late-bound","timestamp":"\#(timestamp)"}}"#
    try Data("\(metadata)\n".utf8).write(to: sessionsDirectory.appendingPathComponent("rollout.jsonl"))
    let repository = StateRepository(directoryURL: stateDirectory)
    let watcher = CodexSessionsWatcher(
        sessionsDirectoryURL: sessionsDirectory,
        repository: repository,
        processResolver: { _ in nil }
    )

    try watcher.scan()
    try expect(
        try repository.loadSessions().isEmpty,
        equals: true,
        "unresolved session stays unpublished"
    )

    let processID = Int32(getpid())
    let processIdentity = try SystemProcessScanner.processIdentity(of: processID)
        .unwrap(or: "test process identity was unavailable")
    watcher.processResolver = { session in
        DetectedAgentProcess(
            tool: .codex,
            processID: processID,
            processIdentity: processIdentity,
            cwd: session.cwd,
            terminal: TerminalContext(
                termProgram: "ghostty",
                ghosttyTerminalID: "codex-surface",
                tty: "/dev/ttys045"
            )
        )
    }
    try watcher.scan()

    let session = try repository.loadSessions().first.unwrap(or: "session was not published")
    try expect(session.sessionID, equals: "codex-late", "published session identity")
    try expect(session.pid, equals: Int32(getpid()), "session adopts the resolved pid")
    try expect(session.processIdentity, equals: processIdentity, "session adopts the resolved generation")
    try expect(
        session.terminal,
        equals: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "codex-surface",
            tty: "/dev/ttys045"
        ),
        "session adopts the resolved terminal context"
    )
}

func testCodexSessionsWatcherSkipsDateDirectoriesOutsideWindow() throws {
    // Codex stores rollouts under YYYY/MM/DD directories and the tree grows
    // without bound. Directories whose date period ends before the
    // ingestion window must be skipped without visiting their contents,
    // even when file mtimes are recent (a copied or restored tree).
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    let oldDirectory = sessionsDirectory.appendingPathComponent("2020/01/01", isDirectory: true)
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldMetadata = #"{"timestamp":"2026-07-18T10:00:00Z","type":"session_meta","payload":{"id":"codex-old","cwd":"/tmp/old","timestamp":"2026-07-18T10:00:00Z"}}"#
    try Data("\(oldMetadata)\n".utf8).write(to: oldDirectory.appendingPathComponent("rollout.jsonl"))
    let currentTimestamp = ISO8601DateFormatter().string(from: Date())
    let currentMetadata = #"{"timestamp":"\#(currentTimestamp)","type":"session_meta","payload":{"id":"codex-current","cwd":"/tmp/current","timestamp":"\#(currentTimestamp)"}}"#
    try Data("\(currentMetadata)\n".utf8).write(to: sessionsDirectory.appendingPathComponent("rollout.jsonl"))
    let repository = StateRepository(directoryURL: stateDirectory)
    let watcher = CodexSessionsWatcher(
        sessionsDirectoryURL: sessionsDirectory,
        repository: repository,
        processID: Int32(getpid()),
        ingestionWindow: 3600
    )

    try watcher.scan()

    let sessionIDs = Set(try repository.loadSessions().map(\.sessionID))
    try expect(sessionIDs, equals: ["codex-current"], "only in-window rollouts are ingested")
}

func writeConvoyRunFixture(
    at runsDirectoryURL: URL,
    runID: String,
    serverPid: Int32,
    serverStartedAt: Date,
    updatedAt: Date = Date(),
    targetDir: String = "/tmp/convoy-target",
    phases: [(name: String, status: String, sessionID: String?)],
    humanSteps: Set<String> = [],
    includeServer: Bool = true
) throws {
    let phaseEntries = phases.map { phase in
        let sessionIDField = phase.sessionID.map { "\"sessionID\": \"\($0)\"," } ?? ""
        return """
        "\(phase.name)": {
          "status": "\(phase.status)",
          \(sessionIDField)
          "startedAt": \(Int(serverStartedAt.timeIntervalSince1970 * 1000))
        }
        """
    }.joined(separator: ",\n")
    let steps = phases.map { phase in
        """
        {"type": "\(humanSteps.contains(phase.name) ? "human" : "agent")", "name": "\(phase.name)"}
        """
    }.joined(separator: ",\n")
    let serverField = includeServer ? """
      "server": {
        "url": "http://127.0.0.1:4096",
        "pid": \(serverPid),
        "startedAt": \(Int(serverStartedAt.timeIntervalSince1970 * 1000))
      },
    """ : ""
    let metadata = """
    {
      "schemaVersion": 2,
      "runID": "\(runID)",
      "targetDir": "\(targetDir)",
      "createdAt": \(Int(serverStartedAt.timeIntervalSince1970 * 1000)),
      "updatedAt": \(Int(updatedAt.timeIntervalSince1970 * 1000)),
      \(serverField)
      "phases": { \(phaseEntries) },
      "pipeline": { "name": "test", "steps": [ \(steps) ] }
    }
    """
    let runDirectoryURL = runsDirectoryURL.appendingPathComponent(runID, isDirectory: true)
    try FileManager.default.createDirectory(at: runDirectoryURL, withIntermediateDirectories: true)
    try Data(metadata.utf8).write(to: runDirectoryURL.appendingPathComponent("metadata.json"))
}

func makeConvoyTestDirectories() throws -> (stateDirectoryURL: URL, runsDirectoryURL: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let state = base.appendingPathComponent("state", isDirectory: true)
    let runs = base.appendingPathComponent("runs", isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    return (state, runs)
}

func detectedConvoyProcess(elapsedSeconds: TimeInterval = 600) -> DetectedAgentProcess {
    DetectedAgentProcess(
        tool: .convoy,
        processID: Int32(getpid()),
        cwd: "/tmp/convoy-target",
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys009"),
        elapsedSeconds: elapsedSeconds
    )
}

func testConvoyWatcherPublishesRunningPipelineStep() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-101010-abcd",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [
            ("scope", "completed", "ses_scope"),
            ("security", "running", "ses_security"),
        ]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try watcher.scan(detected: [detectedConvoyProcess()])

    let session = try repository.loadSessions().first.unwrap(or: "no convoy session was published")
    try expect(session.tool, equals: .convoy, "tool")
    try expect(session.sessionID, equals: "20260719-101010-abcd", "session ID")
    try expect(session.pid, equals: Int32(getpid()), "pid")
    try expect(session.status, equals: .working, "status")
    try expect(session.currentStep, equals: "security", "current step")
    try expect(session.cwd, equals: "/tmp/convoy-target", "cwd")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal context adopted")
}

func testConvoyWatcherDoesNotRepublishUnchangedObservation() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let runID = "20260722-101010-stable"
    let process = detectedConvoyProcess()
    let serverStartedAt = Date().addingTimeInterval(-300)
    let runUpdatedAt = Date(timeIntervalSince1970: 2_000_000_000)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: process.processID,
        serverStartedAt: serverStartedAt,
        updatedAt: runUpdatedAt,
        phases: [("implementer", "running", "ses_impl")]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)
    _ = try watcher.observe(detected: [process], isHeartbeat: false)
    let stateFileURL = try FileManager.default.contentsOfDirectory(
        at: stateDirectoryURL,
        includingPropertiesForKeys: nil
    ).first { $0.pathExtension == "json" }.unwrap(or: "Convoy state document missing")
    let unchangedData = try Data(contentsOf: stateFileURL)
    let stableModificationDate = Date(timeIntervalSince1970: 1_000)
    try FileManager.default.setAttributes(
        [.modificationDate: stableModificationDate],
        ofItemAtPath: stateFileURL.path
    )

    let store = StateStore(repository: repository)
    try store.startObserving(pollInterval: nil, layers: .darwinNotification)
    defer { store.stopObserving() }
    try validStateJSON(sessionID: "notification-probe", status: "working")
        .writeAtomically(to: stateDirectoryURL.appendingPathComponent("notification-probe.json"))

    _ = try watcher.observe(detected: [process], isHeartbeat: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    try expect(try Data(contentsOf: stateFileURL), equals: unchangedData, "unchanged document content")
    let observedModificationDate = try FileManager.default
        .attributesOfItem(atPath: stateFileURL.path)[.modificationDate] as? Date
    try expect(observedModificationDate, equals: stableModificationDate, "unchanged document not rewritten")
    try expect(
        store.sessions.map(\.sessionID),
        equals: [runID],
        "unchanged observation emits no state-change notification"
    )
    store.stopObserving()

    let advancedUpdatedAt = runUpdatedAt.addingTimeInterval(5)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: process.processID,
        serverStartedAt: serverStartedAt,
        updatedAt: advancedUpdatedAt,
        phases: [("implementer", "completed", "ses_impl")]
    )
    _ = try watcher.observe(
        detected: [process],
        isHeartbeat: false,
        invalidatedMetadataURLs: [runsDirectoryURL
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("metadata.json")]
    )
    let completed = try repository.loadSessions().first { $0.sessionID == runID }
        .unwrap(or: "meaningful Convoy update missing")
    try expect(completed.status, equals: .idle, "status update persists")
    try expect(completed.updatedAt, equals: advancedUpdatedAt, "timestamp update persists")

    let generation = ProcessIdentity(
        processID: process.processID,
        kernelStartTimeMicroseconds: 123_456
    )
    let identifiedProcess = DetectedAgentProcess(
        tool: .convoy,
        processID: process.processID,
        processIdentity: generation,
        cwd: process.cwd,
        terminal: process.terminal,
        elapsedSeconds: process.elapsedSeconds
    )
    _ = try watcher.observe(detected: [identifiedProcess], isHeartbeat: true)
    let identified = try repository.loadSessions().first { $0.sessionID == runID }
        .unwrap(or: "Convoy process-generation update missing")
    try expect(identified.processIdentity, equals: generation, "process generation update persists")
}

final class ConvoyMetadataParseCounter {
    private var countsByPath: [String: Int] = [:]

    func record(_ url: URL) {
        countsByPath[url.resolvingSymlinksInPath().path, default: 0] += 1
    }

    func count(for url: URL) -> Int {
        countsByPath[url.resolvingSymlinksInPath().path, default: 0]
    }
}

func testConvoyMetadataInvalidationReparsesOnlyDirtyRun() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let process = detectedConvoyProcess()
    let olderRunID = "20260722-181000-unaffected"
    let activeRunID = "20260722-182000-dirty"
    let olderStartedAt = Date().addingTimeInterval(-400)
    let activeStartedAt = Date().addingTimeInterval(-300)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: olderRunID,
        serverPid: process.processID,
        serverStartedAt: olderStartedAt,
        phases: [("scope", "completed", "ses_scope")]
    )
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: activeRunID,
        serverPid: process.processID,
        serverStartedAt: activeStartedAt,
        phases: [("implementer", "running", "ses_impl")]
    )
    let runDirectoryURLs = try FileManager.default.contentsOfDirectory(
        at: runsDirectoryURL,
        includingPropertiesForKeys: nil
    )
    let unaffectedMetadataURL = try runDirectoryURLs
        .first { $0.lastPathComponent == olderRunID }
        .unwrap(or: "unaffected run directory missing")
        .appendingPathComponent("metadata.json")
    let dirtyMetadataURL = try runDirectoryURLs
        .first { $0.lastPathComponent == activeRunID }
        .unwrap(or: "dirty run directory missing")
        .appendingPathComponent("metadata.json")
    let counter = ConvoyMetadataParseCounter()
    let watcher = ConvoyRunsWatcher(
        runsDirectoryURL: runsDirectoryURL,
        repository: StateRepository(directoryURL: stateDirectoryURL),
        metadataParseObserver: { counter.record($0) }
    )

    _ = try watcher.observe(detected: [process], isHeartbeat: false)
    try expect(counter.count(for: unaffectedMetadataURL), equals: 1, "initial unaffected parse")
    try expect(counter.count(for: dirtyMetadataURL), equals: 1, "initial active parse")

    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: activeRunID,
        serverPid: process.processID,
        serverStartedAt: activeStartedAt,
        phases: [("implementer", "completed", "ses_impl")]
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)],
        ofItemAtPath: dirtyMetadataURL.path
    )
    _ = try watcher.observe(detected: [process], isHeartbeat: false)

    try expect(counter.count(for: dirtyMetadataURL), equals: 2, "dirty run reparsed")
    try expect(
        counter.count(for: unaffectedMetadataURL),
        equals: 1,
        "mtime validation preserves unaffected cached run"
    )

    let stableAttributes = try FileManager.default.attributesOfItem(atPath: dirtyMetadataURL.path)
    let stableModificationDate = try (stableAttributes[.modificationDate] as? Date)
        .unwrap(or: "dirty metadata mtime missing")
    let stableSize = try (stableAttributes[.size] as? NSNumber)
        .unwrap(or: "dirty metadata size missing")
    let stableInode = try (stableAttributes[.systemFileNumber] as? NSNumber)
        .unwrap(or: "dirty metadata inode missing")
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: activeRunID,
        serverPid: process.processID,
        serverStartedAt: activeStartedAt,
        phases: [("implementer", "cancelled", "ses_impl")]
    )
    try FileManager.default.setAttributes(
        [.modificationDate: stableModificationDate],
        ofItemAtPath: dirtyMetadataURL.path
    )
    let invalidatedAttributes = try FileManager.default.attributesOfItem(atPath: dirtyMetadataURL.path)
    let invalidatedSize = try (invalidatedAttributes[.size] as? NSNumber)
        .unwrap(or: "invalidated metadata size missing")
    let invalidatedModificationDate = try (invalidatedAttributes[.modificationDate] as? Date)
        .unwrap(or: "invalidated metadata mtime missing")
    let invalidatedInode = try (invalidatedAttributes[.systemFileNumber] as? NSNumber)
        .unwrap(or: "invalidated metadata inode missing")
    try expect(invalidatedSize, equals: stableSize, "targeted rewrite keeps the cached fingerprint")
    try expect(
        invalidatedModificationDate,
        equals: stableModificationDate,
        "targeted rewrite restores the cached mtime"
    )
    try expect(invalidatedInode, equals: stableInode, "targeted rewrite preserves the cached inode")

    _ = try watcher.observe(
        detected: [process],
        isHeartbeat: false,
        invalidatedMetadataURLs: [dirtyMetadataURL]
    )
    try expect(counter.count(for: dirtyMetadataURL), equals: 3, "explicitly dirty run reparsed")
    try expect(
        counter.count(for: unaffectedMetadataURL),
        equals: 1,
        "targeted invalidation preserves unaffected cached run"
    )
}

func testConvoyWatcherFlagsWaitingHumanGate() throws {
    // A human gate reports itself as a running phase, but the pipeline is
    // actually paused waiting for the user — the semaphore must go red,
    // never green (the same trap Claude's SessionStart used to fall into).
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-111111-gate",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [
            ("implementer", "completed", "ses_impl"),
            ("human-review", "running", nil),
        ],
        humanSteps: ["human-review"]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try watcher.scan(detected: [detectedConvoyProcess()])

    let session = try repository.loadSessions().first.unwrap(or: "no convoy session was published")
    try expect(session.status, equals: .needsAttention, "status")
    try expect(session.attentionReason, equals: .permission, "attention reason")
    try expect(session.currentStep, equals: "human-review", "current step")
}

func testConvoyWatcherMapsTerminalPipelineStates() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-121212-fail",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [("implementer", "completed", "ses_impl"), ("tests", "failed", "ses_tests")]
    )
    try watcher.scan(detected: [detectedConvoyProcess()])
    let failed = try repository.loadSessions().first.unwrap(or: "failed run was not published")
    try expect(failed.status, equals: .needsAttention, "failed status")
    try expect(failed.attentionReason, equals: .turnComplete, "failed attention reason")
    try expect(failed.currentStep, equals: "tests failed", "failed step")

    try repository.remove(failed)
    try expect(try repository.loadSessions(), equals: [], "failed run is removed before next run")
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-131313-done",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-200),
        phases: [("implementer", "completed", "ses_impl"), ("tests", "completed", "ses_tests")]
    )
    try watcher.scan(detected: [detectedConvoyProcess()])
    let finished = try repository.loadSessions().first.unwrap(or: "finished run was not published")
    try expect(finished.sessionID, equals: "20260719-131313-done", "newest run wins")
    try expect(finished.status, equals: .idle, "finished status")
    try expect(finished.currentStep, equals: nil, "finished step")
}

func testConvoyWatcherIgnoresRunsNotOwnedByLiveProcess() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    // A historical run whose recorded server pid now belongs to a live
    // convoy process (pid recycling) must not resurrect: its server started
    // long before the process did.
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260601-090909-old",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-86_400),
        phases: [("security", "running", "ses_old")]
    )
    // A run recorded by some other process entirely.
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-141414-othr",
        serverPid: 999_999,
        serverStartedAt: Date().addingTimeInterval(-60),
        phases: [("security", "running", "ses_other")]
    )

    try watcher.scan(detected: [detectedConvoyProcess(elapsedSeconds: 600)])

    try expect(try repository.loadSessions().isEmpty, equals: true, "no session published")
}

func testConvoyWatcherMapsThinkingAndUsesProjectName() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try writeConvoyRunFixture(
        at: runsDirectoryURL, runID: "20260721-thinking",
        serverPid: Int32(getpid()), serverStartedAt: Date().addingTimeInterval(-60),
        targetDir: "/tmp/the-real-project",
        phases: [("implementer", "thinking", "ses_impl")]
    )
    let process = DetectedAgentProcess(
        tool: .convoy, processID: Int32(getpid()), cwd: "/tmp/the-real-project",
        terminal: TerminalContext(termProgram: "ghostty", windowTitleHint: "convoy — implement")
    )

    try ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)
        .scan(detected: [process])

    let session = try repository.loadSessions().first.unwrap(or: "thinking run missing")
    try expect(session.status, equals: .working, "thinking is active work")
    try expect(session.currentStep, equals: "implementer", "thinking step")
    try expect(session.projectName, equals: "the-real-project", "name comes from metadata target")
    try expect(session.terminal.windowTitleHint, equals: nil, "generic Convoy tab title cannot override name")
}

func testConvoyFinalTransitionSurvivesImmediateProcessExitOnce() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let runID = "20260721-final"
    let startedAt = Date().addingTimeInterval(-60)
    let processID: Int32 = 999_999
    try writeConvoyRunFixture(
        at: runsDirectoryURL, runID: runID, serverPid: processID,
        serverStartedAt: startedAt, phases: [("implementer", "running", "ses_impl")]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)
    let process = DetectedAgentProcess(
        tool: .convoy, processID: processID, cwd: "/tmp/convoy-target",
        terminal: TerminalContext(termProgram: "ghostty"), elapsedSeconds: 120
    )
    _ = try watcher.observe(detected: [process], isHeartbeat: false)
    let store = StateStore(repository: repository)
    var completions = 0
    store.onTurnCompleted = { completions += $0.count }
    try store.reload()

    try writeConvoyRunFixture(
        at: runsDirectoryURL, runID: runID, serverPid: processID,
        serverStartedAt: startedAt, phases: [("implementer", "completed", "ses_impl")],
        includeServer: false
    )
    let final = try watcher.observe(
        detected: [],
        isHeartbeat: false,
        invalidatedMetadataURLs: [runsDirectoryURL
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("metadata.json")]
    )
    _ = try ReaperService(repository: repository).reap(
        detected: [], preservingSessionIDs: final.preservingSessionIDs
    )
    try store.reload()
    try store.reload()

    try expect(store.sessions.first?.status, equals: .idle, "final idle remains observable")
    try expect(completions, equals: 1, "completed transition notifies exactly once")

    let firstHeartbeat = try watcher.observe(detected: [], isHeartbeat: true)
    try expect(
        firstHeartbeat.preservingSessionIDs.contains("convoy-\(runID)"),
        equals: true,
        "one-heartbeat grace"
    )
    let secondHeartbeat = try watcher.observe(detected: [], isHeartbeat: true)
    try expect(secondHeartbeat.preservingSessionIDs.isEmpty, equals: true, "grace expires")
}

func testConvoyMetadataObservationDoesNotExtendHeartbeatGrace() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let runID = "20260722-183000-liveness"
    let process = detectedConvoyProcess()
    let startedAt = Date().addingTimeInterval(-60)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: process.processID,
        serverStartedAt: startedAt,
        phases: [("implementer", "running", "ses_impl")]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)
    let initial = try watcher.observe(detected: [process], isHeartbeat: false)
    try expect(initial.preservingSessionIDs, equals: ["convoy-\(runID)"], "initial run tracked")

    let missedHeartbeat = try watcher.observe(detected: [], isHeartbeat: true)
    try expect(
        missedHeartbeat.preservingSessionIDs,
        equals: ["convoy-\(runID)"],
        "first missed heartbeat retains final-state grace"
    )

    let metadataURL = try missedHeartbeat.runDirectoryURLs.first
        .unwrap(or: "tracked run directory missing")
        .appendingPathComponent("metadata.json")
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: process.processID,
        serverStartedAt: startedAt,
        phases: [("implementer", "completed", "ses_impl")]
    )
    var snapshot = try repository.loadSnapshot()
    let metadataOnly = try watcher.observe(
        detected: [process],
        isHeartbeat: false,
        invalidatedMetadataURLs: [metadataURL],
        updatesLiveness: false,
        snapshot: &snapshot
    )
    try expect(
        metadataOnly.preservingSessionIDs,
        equals: ["convoy-\(runID)"],
        "metadata event retains the existing grace count"
    )

    let nextHeartbeat = try watcher.observe(detected: [], isHeartbeat: true)
    try expect(
        nextHeartbeat.preservingSessionIDs.isEmpty,
        equals: true,
        "metadata event does not reset missed-heartbeat liveness"
    )
}

func testConvoyWatcherRetiresSupersededRunForSameProcessGeneration() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)
    let processID: Int32 = 765_432
    let processIdentity = ProcessIdentity(
        processID: processID,
        kernelStartTimeMicroseconds: 123_456_789
    )
    let process = DetectedAgentProcess(
        tool: .convoy,
        processID: processID,
        processIdentity: processIdentity,
        cwd: "/tmp/convoy-target",
        terminal: TerminalContext(termProgram: "ghostty"),
        elapsedSeconds: 120
    )
    let firstRunID = "20260722-101010-first"
    let secondRunID = "20260722-101110-second"
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: firstRunID,
        serverPid: processID,
        serverStartedAt: Date().addingTimeInterval(-60),
        phases: [("implementer", "running", "ses_first")]
    )

    let first = try watcher.observe(detected: [process], isHeartbeat: false)
    try expect(first.preservingSessionIDs, equals: ["convoy-\(firstRunID)"], "first run preserved")
    try expect(
        Set(first.runDirectoryURLs.map(\.lastPathComponent)),
        equals: [firstRunID],
        "first run directory watched"
    )

    let secondStartedAt = Date().addingTimeInterval(-30)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: secondRunID,
        serverPid: processID,
        serverStartedAt: secondStartedAt,
        phases: [("implementer", "running", "ses_second")]
    )

    let replacement = try watcher.observe(
        detected: [process],
        isHeartbeat: false
    )
    try expect(
        replacement.preservingSessionIDs,
        equals: ["convoy-\(secondRunID)"],
        "superseded run is immediately unpreserved"
    )
    try expect(
        Set(replacement.runDirectoryURLs.map(\.lastPathComponent)),
        equals: [secondRunID],
        "only the current run directory remains watched"
    )
    try expect(
        Set(try repository.loadSessions().map(\.sessionID)),
        equals: [secondRunID],
        "replacement is persisted while the superseded run is removed"
    )

    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: secondRunID,
        serverPid: processID,
        serverStartedAt: secondStartedAt,
        phases: [("implementer", "completed", "ses_second")],
        includeServer: false
    )
    let final = try watcher.observe(
        detected: [],
        isHeartbeat: false,
        invalidatedMetadataURLs: [runsDirectoryURL
            .appendingPathComponent(secondRunID, isDirectory: true)
            .appendingPathComponent("metadata.json")]
    )
    try expect(
        final.preservingSessionIDs,
        equals: ["convoy-\(secondRunID)"],
        "current run remains associated after process exit"
    )
    try expect(
        Set(final.runDirectoryURLs.map(\.lastPathComponent)),
        equals: [secondRunID],
        "current final run remains watched"
    )
    let finalSession = try repository.loadSessions().first { $0.sessionID == secondRunID }
        .unwrap(or: "current run final state was not published")
    try expect(finalSession.status, equals: .idle, "current run final state")

    let firstHeartbeat = try watcher.observe(detected: [], isHeartbeat: true)
    try expect(
        firstHeartbeat.preservingSessionIDs,
        equals: ["convoy-\(secondRunID)"],
        "current run receives one-heartbeat final grace"
    )
    let secondHeartbeat = try watcher.observe(detected: [], isHeartbeat: true)
    try expect(secondHeartbeat.preservingSessionIDs.isEmpty, equals: true, "current run grace expires")
    try expect(secondHeartbeat.runDirectoryURLs.isEmpty, equals: true, "final run watcher is retired")
}

func testConvoyWatcherPreservesSupersededRunWhenReplacementCannotPersist() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)
    let processID: Int32 = 765_433
    let processIdentity = ProcessIdentity(
        processID: processID,
        kernelStartTimeMicroseconds: 123_456_790
    )
    let process = DetectedAgentProcess(
        tool: .convoy,
        processID: processID,
        processIdentity: processIdentity,
        cwd: "/tmp/convoy-target",
        terminal: TerminalContext(termProgram: "ghostty"),
        elapsedSeconds: 120
    )
    let firstRunID = "20260722-102010-persisted"
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: firstRunID,
        serverPid: processID,
        serverStartedAt: Date().addingTimeInterval(-60),
        phases: [("implementer", "running", "ses_first")]
    )
    let initial = try watcher.observe(detected: [process], isHeartbeat: false)
    try expect(initial.preservingSessionIDs, equals: ["convoy-\(firstRunID)"], "first run tracked")

    let rejectedRunID = String(repeating: "b", count: 129)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: rejectedRunID,
        serverPid: processID,
        serverStartedAt: Date().addingTimeInterval(-30),
        phases: [("implementer", "running", "ses_rejected")]
    )
    do {
        _ = try watcher.observe(detected: [process], isHeartbeat: false)
        throw TestFailure.expectation("oversized replacement run ID was persisted")
    } catch StateRepositoryError.sessionIdentifierTooLong {
        // Expected: replacement validation must fail without mutating the active run.
    }

    try expect(
        Set(try repository.loadSessions().map(\.sessionID)),
        equals: [firstRunID],
        "failed replacement leaves the previous run persisted"
    )
    try expect(
        try repository.loadSessions().first?.processIdentity,
        equals: processIdentity,
        "failed replacement preserves the verified process generation"
    )
    let retained = try watcher.observe(detected: [], isHeartbeat: false)
    try expect(
        retained.preservingSessionIDs,
        equals: ["convoy-\(firstRunID)"],
        "failed replacement leaves the previous run tracked and preserved"
    )
    try expect(
        Set(retained.runDirectoryURLs.map(\.lastPathComponent)),
        equals: [firstRunID],
        "failed replacement leaves the previous run metadata watched"
    )
    try expect(
        (try repository.loadSessions()).contains { $0.sessionID == rejectedRunID },
        equals: false,
        "failed replacement is not installed"
    )
}

func testConvoyWatcherKeepsFinalReadsInDiscoveredMetadataFile() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let directoryRunID = "actual-run-directory"
    let metadataRunID = "../external-run"
    let serverStartedAt = Date().addingTimeInterval(-60)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: directoryRunID,
        serverPid: Int32(getpid()),
        serverStartedAt: serverStartedAt,
        phases: [("implementer", "completed", "ses_impl")]
    )
    let metadataURL = runsDirectoryURL
        .appendingPathComponent(directoryRunID, isDirectory: true)
        .appendingPathComponent("metadata.json")
    let originalMetadata = try String(contentsOf: metadataURL, encoding: .utf8)
    let metadata = originalMetadata.replacingOccurrences(
        of: #""runID": "actual-run-directory""#,
        with: #""runID": "../external-run""#
    )
    try Data(metadata.utf8).write(to: metadataURL)
    // This is outside the watched runs directory. It must never become the
    // final-state source merely because metadata supplied a traversal ID.
    try writeConvoyRunFixture(
        at: runsDirectoryURL.deletingLastPathComponent(),
        runID: "external-run",
        serverPid: Int32(getpid()),
        serverStartedAt: serverStartedAt,
        phases: [("external", "running", "ses_external")]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)
    let process = detectedConvoyProcess(elapsedSeconds: 120)

    _ = try watcher.observe(detected: [process], isHeartbeat: false)
    _ = try watcher.observe(
        detected: [],
        isHeartbeat: false,
        invalidatedMetadataURLs: [metadataURL]
    )

    let sessions = try repository.loadSessions()
    try expect(
        sessions.contains(where: { $0.sessionID == "external-run" }),
        equals: false,
        "metadata run ID cannot redirect final reads outside its discovered file"
    )
    try expect(
        sessions.first(where: { $0.sessionID == metadataRunID })?.status,
        equals: .idle,
        "final state remains sourced from the discovered metadata file"
    )
}

func testConvoyWatcherRejectsUnsafeMetadataFileTypesAndSizes() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let serverStartedAt = Date().addingTimeInterval(-60)

    // A symlink must not let a run redirect the watcher to arbitrary metadata.
    let externalMetadata = runsDirectoryURL.deletingLastPathComponent()
        .appendingPathComponent("external-metadata.json")
    let validMetadata = """
    {
      "runID": "redirected-run",
      "targetDir": "/tmp/redirected",
      "updatedAt": \(Int(Date().timeIntervalSince1970 * 1000)),
      "server": {
        "pid": \(getpid()),
        "startedAt": \(Int(serverStartedAt.timeIntervalSince1970 * 1000))
      },
      "phases": {
        "implementer": {
          "status": "running",
          "startedAt": \(Int(serverStartedAt.timeIntervalSince1970 * 1000)),
          "sessionID": "ses_unsafe"
        }
      }
    }
    """
    try Data(validMetadata.utf8).write(to: externalMetadata)
    let symlinkedRun = runsDirectoryURL.appendingPathComponent("symlinked", isDirectory: true)
    try FileManager.default.createDirectory(at: symlinkedRun, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: symlinkedRun.appendingPathComponent("metadata.json"),
        withDestinationURL: externalMetadata
    )

    // A directory and an oversized document must also be ignored before JSON
    // decoding, rather than blocking or publishing malformed run state.
    let directoryRun = runsDirectoryURL.appendingPathComponent("directory", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directoryRun.appendingPathComponent("metadata.json", isDirectory: true),
        withIntermediateDirectories: true
    )
    let oversizedRun = runsDirectoryURL.appendingPathComponent("oversized", isDirectory: true)
    try FileManager.default.createDirectory(at: oversizedRun, withIntermediateDirectories: true)
    var oversizedMetadata = Data(validMetadata.utf8)
    oversizedMetadata.append(Data(repeating: 0x20, count: BoundedInput.maximumPayloadSize + 1 - oversizedMetadata.count))
    try oversizedMetadata.write(to: oversizedRun.appendingPathComponent("metadata.json"))
    let fifoRun = runsDirectoryURL.appendingPathComponent("fifo", isDirectory: true)
    try FileManager.default.createDirectory(at: fifoRun, withIntermediateDirectories: true)
    guard Darwin.mkfifo(fifoRun.appendingPathComponent("metadata.json").path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let insecureDirectoryRun = runsDirectoryURL.appendingPathComponent("insecure-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: insecureDirectoryRun, withIntermediateDirectories: true)
    try Data(validMetadata.utf8).write(to: insecureDirectoryRun.appendingPathComponent("metadata.json"))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o777],
        ofItemAtPath: insecureDirectoryRun.path
    )
    let insecureFileRun = runsDirectoryURL.appendingPathComponent("insecure-file", isDirectory: true)
    try FileManager.default.createDirectory(at: insecureFileRun, withIntermediateDirectories: true)
    let insecureMetadataURL = insecureFileRun.appendingPathComponent("metadata.json")
    try Data(validMetadata.utf8).write(to: insecureMetadataURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o666],
        ofItemAtPath: insecureMetadataURL.path
    )
    try repository.save(AgentSession.decode(from: validStateJSON(
        sessionID: "ses_unsafe",
        status: "working",
        pid: Int32(getpid()),
        tool: "opencode"
    )))

    try ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository).scan(
        detected: [detectedConvoyProcess(elapsedSeconds: Date().timeIntervalSince(serverStartedAt) + 60)]
    )

    try expect(
        try repository.loadSessions().map(\.sessionID),
        equals: ["ses_unsafe"],
        "unsafe Convoy metadata cannot publish ownership or a run"
    )
}

func testConvoyWatcherSuppressesPipelineOwnedOpenCodeSessions() throws {
    // Convoy phases run as OpenCode sessions on convoy's embedded server;
    // if that server loads the Moonglade plugin, each phase would also
    // surface as a standalone OpenCode row next to the pipeline it belongs
    // to. The run metadata names those session IDs, so the repository hides
    // them without deleting the plugin-owned lifecycle documents.
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ses_security", status: "working", pid: Int32(getpid()), tool: "opencode")
    ))
    try repository.save(AgentSession.decode(
        from: validStateJSON(
            sessionID: "ses_unrelated", status: "idle", pid: Int32(getpid()),
            tool: "opencode", cwd: "/tmp/convoy-target"
        )
    ))
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-151515-supp",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [("security", "running", "ses_security")]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try watcher.scan(detected: [detectedConvoyProcess()])

    let opencodeSessionIDs = try repository.loadSessions()
        .filter { $0.tool == .opencode }
        .map(\.sessionID)
    try expect(opencodeSessionIDs, equals: ["ses_unrelated"], "same-cwd native session survives")
    try expect(
        Set(try repository.loadLifecycleSessions()
            .filter { $0.tool == .opencode }
            .map(\.sessionID)),
        equals: ["ses_security", "ses_unrelated"],
        "Convoy ownership does not delete native producer state"
    )
}

func testStateRepositoryKeepsConvoyOwnedOpenCodeHiddenAfterProducerRewrite() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let owned = try AgentSession.decode(from: validStateJSON(
        sessionID: "ses_convoy_owned",
        status: "working",
        pid: Int32(getpid()),
        tool: "opencode",
        cwd: "/tmp/shared-target"
    ))
    let independent = try AgentSession.decode(from: validStateJSON(
        sessionID: "ses_independent",
        status: "idle",
        pid: Int32(getpid()),
        tool: "opencode",
        cwd: "/tmp/shared-target"
    ))
    try repository.save(owned)
    try repository.save(independent)
    let ownershipURL = directory.appendingPathComponent("convoy-opencode-ownership.index")
    try Data(
        #"{"schema_version":1,"session_ids":["ses_convoy_owned"]}"#.utf8
    ).write(to: ownershipURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: ownershipURL.path
    )

    try expect(
        try repository.loadSessions().map(\.sessionID),
        equals: ["ses_independent"],
        "ownership projection hides only the exact Convoy session ID"
    )

    try validStateJSON(
        sessionID: "ses_convoy_owned",
        status: "needs_attention",
        pid: Int32(getpid()),
        tool: "opencode",
        cwd: "/tmp/shared-target"
    ).writeAtomically(to: directory.appendingPathComponent("opencode-c2VzX2NvbnZveV9vd25lZA.json"))

    try expect(
        try repository.loadSessions().map(\.sessionID),
        equals: ["ses_independent"],
        "producer rewrite cannot republish a Convoy-owned session"
    )
    try expect(
        Set(try repository.loadLifecycleSessions().map(\.sessionID)),
        equals: ["ses_convoy_owned", "ses_independent"],
        "raw lifecycle documents remain intact"
    )
}

func testConvoyOwnershipIndexRejectsLinksAndFIFOsWithoutBlocking() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = StateRepository(directoryURL: directory)
    let ownershipURL = directory.appendingPathComponent("convoy-opencode-ownership.index")
    let externalURL = root.appendingPathComponent("external.index")
    try Data(#"{"schema_version":1,"session_ids":["ses_external"]}"#.utf8)
        .write(to: externalURL)
    try FileManager.default.createSymbolicLink(
        at: ownershipURL,
        withDestinationURL: externalURL
    )

    do {
        _ = try repository.loadSessions()
        throw TestFailure.expectation("symlinked ownership index was accepted")
    } catch is TestFailure {
        throw TestFailure.expectation("symlinked ownership index was accepted")
    } catch {
        // Expected: app-owned policy is never read through a link.
    }
    do {
        _ = try repository.mergeConvoyOwnedOpenCodeSessionIDs(["ses_safe"])
        throw TestFailure.expectation("symlinked ownership index was replaced")
    } catch is TestFailure {
        throw TestFailure.expectation("symlinked ownership index was replaced")
    } catch {
        // Expected: recovery only replaces an owner-controlled regular file.
    }

    try FileManager.default.removeItem(at: ownershipURL)
    guard Darwin.mkfifo(ownershipURL.path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let startedAt = Date()
    do {
        _ = try repository.loadSessions()
        throw TestFailure.expectation("FIFO ownership index was accepted")
    } catch is TestFailure {
        throw TestFailure.expectation("FIFO ownership index was accepted")
    } catch {
        // Expected: O_NONBLOCK plus file-type validation rejects immediately.
    }
    try expect(
        Date().timeIntervalSince(startedAt) < 1,
        equals: true,
        "FIFO ownership index rejected without blocking"
    )
}

func testCorruptOwnershipIndexWaitsForCompleteMetadataInventory() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try repository.prepareDirectory()
    let ownershipURL = stateDirectoryURL.appendingPathComponent("convoy-opencode-ownership.index")
    let corruptData = Data("truncated".utf8)
    try corruptData.write(to: ownershipURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: ownershipURL.path
    )
    let incompleteRun = runsDirectoryURL.appendingPathComponent("incomplete", isDirectory: true)
    try FileManager.default.createDirectory(at: incompleteRun, withIntermediateDirectories: true)
    guard Darwin.mkfifo(incompleteRun.appendingPathComponent("metadata.json").path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    do {
        try watcher.refreshOpenCodeOwnershipIndex()
        throw TestFailure.expectation("partial metadata inventory rebuilt a corrupt ownership index")
    } catch is TestFailure {
        throw TestFailure.expectation("partial metadata inventory rebuilt a corrupt ownership index")
    } catch {
        // Expected: fail closed until a complete inventory can rebuild it.
    }
    try expect(
        try Data(contentsOf: ownershipURL),
        equals: corruptData,
        "incomplete inventory leaves the previous policy file untouched"
    )
}

func testIncompleteConvoyOwnershipInventoryRetriesWithoutDirectoryChange() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let runDirectory = runsDirectoryURL.appendingPathComponent("pending", isDirectory: true)
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let metadataURL = runDirectory.appendingPathComponent("metadata.json")
    guard Darwin.mkfifo(metadataURL.path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try watcher.refreshOpenCodeOwnershipIndex()
    try FileManager.default.removeItem(at: metadataURL)
    let metadata = """
    {
      "schemaVersion": 2,
      "runID": "pending",
      "targetDir": "/tmp/convoy-target",
      "createdAt": 1784700000000,
      "updatedAt": 1784700001000,
      "phases": {
        "implement": { "status": "completed", "sessionID": "ses_retry" }
      }
    }
    """
    try Data(metadata.utf8).write(to: metadataURL)

    try watcher.refreshOpenCodeOwnershipIndex()
    try expect(
        String(data: try Data(contentsOf: stateDirectoryURL.appendingPathComponent(
            "convoy-opencode-ownership.index"
        )), encoding: .utf8)?.contains("ses_retry"),
        equals: true,
        "incomplete ownership inventories retry after metadata becomes readable"
    )
}

func testConvoyOwnershipWatchersAreBounded() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    for index in 0..<100 {
        try FileManager.default.createDirectory(
            at: runsDirectoryURL.appendingPathComponent(
                String(format: "20260722-%06d-pending", index),
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
    }
    let watcher = ConvoyRunsWatcher(
        runsDirectoryURL: runsDirectoryURL,
        repository: StateRepository(directoryURL: stateDirectoryURL)
    )

    try watcher.refreshOpenCodeOwnershipIndex()

    try expect(
        watcher.ownershipWatchDirectoryURLs.count,
        equals: ConvoyRunsWatcher.maximumOwnershipWatchDirectoryCount,
        "pending Convoy runs cannot exhaust file descriptors"
    )
}

func testInitialReconciliationIndexesServerlessConvoyOwnership() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    for sessionID in ["ses_old_phase", "ses_new_phase", "ses_independent"] {
        try repository.save(AgentSession.decode(from: validStateJSON(
            sessionID: sessionID,
            status: "working",
            pid: Int32(getpid()),
            tool: "opencode",
            cwd: "/tmp/shared-target"
        )))
    }
    for (runID, sessionID) in [
        ("20260720-101010-old", "ses_old_phase"),
        ("20260722-101010-new", "ses_new_phase"),
        ("20260722-101010-invalid", String(repeating: "x", count: 129)),
    ] {
        let runDirectory = runsDirectoryURL.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let metadata = """
        {
          "schemaVersion": 2,
          "runID": "\(runID)",
          "targetDir": "/tmp/shared-target",
          "createdAt": 1784700000000,
          "updatedAt": 1784700001000,
          "phases": {
            "implementer": {
              "status": "completed",
              "sessionID": "\(sessionID)"
            }
          }
        }
        """
        try Data(metadata.utf8).write(to: runDirectory.appendingPathComponent("metadata.json"))
    }
    let ownershipURL = stateDirectoryURL.appendingPathComponent("convoy-opencode-ownership.index")
    try Data("truncated".utf8).write(to: ownershipURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: ownershipURL.path
    )
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: TestProcessScanner([]),
        codexSessionsDirectoryURL: stateDirectoryURL.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: runsDirectoryURL,
        debounceInterval: 0.01
    )
    defer {
        scheduler.stop()
        scheduler.waitUntilIdle()
    }
    let completion = StartupCompletionProbe()

    scheduler.startWithInitialReconciliation { completion.record() }

    let deadline = Date().addingTimeInterval(2)
    while !completion.completionRan, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(completion.completionRan, equals: true, "serverless ownership bootstrap completed")
    try expect(
        try repository.loadSessions().map(\.sessionID),
        equals: ["ses_independent"],
        "cold start indexes every historical Convoy phase without a live server"
    )
    try expect(
        Set(try repository.loadLifecycleSessions().map(\.sessionID)),
        equals: ["ses_old_phase", "ses_new_phase", "ses_independent"],
        "cold-start ownership does not delete producer state"
    )
    let ownershipMode = try FileManager.default.attributesOfItem(
        atPath: ownershipURL.path
    )[.posixPermissions] as? NSNumber
    try expect(ownershipMode?.intValue, equals: 0o600, "ownership index permissions")
}

func testInitialReconciliationWatchesLiveConvoyOwnershipBeforeBaseline() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let opencodeProcessID = Int32(getppid())
    try repository.save(AgentSession.decode(from: validStateJSON(
        sessionID: "ses_late_phase",
        status: "working",
        pid: opencodeProcessID,
        tool: "opencode",
        cwd: "/tmp/convoy-target"
    )))
    let runID = "20260722-202020-watched"
    let serverStartedAt = Date().addingTimeInterval(-60)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: Int32(getpid()),
        serverStartedAt: serverStartedAt,
        phases: [("first", "running", "ses_first_phase")]
    )
    let opencodeProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: opencodeProcessID,
        cwd: "/tmp/convoy-target",
        terminal: TerminalContext()
    )
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: TestProcessScanner([detectedConvoyProcess(), opencodeProcess]),
        codexSessionsDirectoryURL: stateDirectoryURL.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: runsDirectoryURL,
        heartbeatInterval: 60,
        debounceInterval: 0.01
    )
    defer {
        scheduler.stop()
        scheduler.waitUntilIdle()
    }
    let completion = StartupCompletionProbe()
    scheduler.startWithInitialReconciliation { completion.record() }
    var deadline = Date().addingTimeInterval(2)
    while !completion.completionRan, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(completion.completionRan, equals: true, "live ownership baseline completed")
    // Let the normal startup tick drain, then rely only on the per-run vnode
    // source; the heartbeat is deliberately too far away to help this test.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    scheduler.waitUntilIdle()
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: Int32(getpid()),
        serverStartedAt: serverStartedAt,
        phases: [
            ("first", "completed", "ses_first_phase"),
            ("late", "running", "ses_late_phase"),
        ]
    )
    let metadataURL = runsDirectoryURL
        .appendingPathComponent(runID, isDirectory: true)
        .appendingPathComponent("metadata.json")
    try Data(contentsOf: metadataURL).writeAtomically(to: metadataURL)

    deadline = Date().addingTimeInterval(2)
    while (try repository.loadSessions()).contains(where: {
        $0.tool == .opencode && $0.sessionID == "ses_late_phase"
    }), Date() < deadline {
        usleep(10_000)
    }
    try expect(
        (try repository.loadSessions()).contains(where: { $0.sessionID == "ses_late_phase" }),
        equals: false,
        "live run watcher indexes a newly persisted phase before the heartbeat"
    )
}

func testInitialBaselineWaitsForConcurrentConvoyMetadata() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let opencodeProcessID = Int32(getppid())
    try repository.save(AgentSession.decode(from: validStateJSON(
        sessionID: "ses_during_startup",
        status: "working",
        pid: opencodeProcessID,
        tool: "opencode",
        cwd: "/tmp/convoy-target"
    )))
    let runID = "20260722-212121-startup-race"
    let serverStartedAt = Date().addingTimeInterval(-60)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: Int32(getpid()),
        serverStartedAt: serverStartedAt,
        phases: [("first", "running", "ses_first")]
    )
    let scanner = StartupOrderingProcessScanner([
        detectedConvoyProcess(),
        DetectedAgentProcess(
            tool: .opencode,
            processID: opencodeProcessID,
            cwd: "/tmp/convoy-target",
            terminal: TerminalContext()
        ),
    ])
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: scanner,
        codexSessionsDirectoryURL: stateDirectoryURL.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: runsDirectoryURL,
        heartbeatInterval: 60,
        debounceInterval: 0.02
    )
    defer {
        scanner.releaseBaseline.signal()
        scheduler.stop()
        scheduler.waitUntilIdle()
    }
    let completion = StartupCompletionProbe()
    scheduler.startWithInitialReconciliation { completion.record() }
    guard scanner.baselineStarted.wait(timeout: .now() + 2) == .success else {
        throw TestFailure.expectation("startup process scan never blocked")
    }
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: runID,
        serverPid: Int32(getpid()),
        serverStartedAt: serverStartedAt,
        phases: [
            ("first", "completed", "ses_first"),
            ("late", "running", "ses_during_startup"),
        ]
    )
    let metadataURL = runsDirectoryURL
        .appendingPathComponent(runID, isDirectory: true)
        .appendingPathComponent("metadata.json")
    try Data(contentsOf: metadataURL).writeAtomically(to: metadataURL)
    scanner.releaseBaseline.signal()

    let deadline = Date().addingTimeInterval(2)
    while !completion.completionRan, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(completion.completionRan, equals: true, "quiet startup baseline completed")
    try expect(
        (try repository.loadSessions()).contains(where: {
            $0.tool == .opencode && $0.sessionID == "ses_during_startup"
        }),
        equals: false,
        "metadata delivered during reconciliation is indexed before baseline"
    )
}

func testConvoyWatcherSuppressesEmbeddedServerReaperFallbackByDirectory() throws {
    // Live incident 2026-07-20: once the embedded opencode-serve child loses
    // Ghostty's last blank terminal to the convoy process itself, the reaper
    // may create a generic "reaper-<pid>" fallback for it before its own
    // plugin ever writes a document carrying the phase's real session ID.
    // That fallback's session ID never matches a phase's, so sessionID-based
    // suppression alone lets it survive forever as an unlabeled OpenCode row.
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let embeddedServerPid: Int32 = 76_552
    try repository.save(AgentSession.decode(
        from: validStateJSON(
            sessionID: "reaper-\(embeddedServerPid)",
            status: "idle",
            pid: embeddedServerPid,
            tool: "opencode",
            cwd: "/tmp/convoy-target",
            source: "reaper"
        )
    ))
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260720-101044-9zbh",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [("implementer", "running", "ses_impl")]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try watcher.scan(detected: [detectedConvoyProcess()])

    let survivingOpenCodeSessions = try repository.loadSessions().filter { $0.tool == .opencode }
    try expect(survivingOpenCodeSessions.isEmpty, equals: true, "embedded server's reaper fallback is suppressed")
}

func testFocusPlannerPrioritizesTmuxThenTerminal() throws {
    let data = Data(
        #"{"schema_version":1,"tool":"claude","session_id":"focus","pid":1,"status":"working","attention_reason":null,"cwd":"/tmp/project","started_at":"2026-07-18T10:00:00Z","updated_at":"2026-07-18T10:00:00Z","terminal":{"term_program":"ghostty","ghostty_terminal_id":"terminal-123","tmux_pane":"%3","window_title_hint":"project — claude"}}"#.utf8
    )
    let session = try AgentSession.decode(from: data)

    let actions = try FocusPlanner.actions(for: session)

    try expect(
        actions.first,
        equals: .run(executable: "tmux", arguments: ["select-window", "-t", "%3"]),
        "first focus action"
    )
    guard actions.contains(where: { action in
        if case let .appleScript(script) = action {
            return script.contains("Ghostty") && script.contains("terminal-123")
        }
        return false
    }) else {
        throw TestFailure.expectation("Ghostty focus action is missing")
    }
}

func testFocusPlannerRequiresOneExactGhosttyTarget() throws {
    let session = AgentSession(
        tool: .opencode,
        sessionID: "ghostty-exact",
        pid: 42,
        status: .working,
        cwd: "/tmp/project",
        startedAt: Date(),
        updatedAt: Date(),
        terminal: TerminalContext(
            termProgram: "ghostty",
            ghosttyTerminalID: "surface-42",
            tty: "/dev/ttys042",
            windowTitleHint: "project — opencode"
        )
    )

    let actions = try FocusPlanner.actions(for: session)
    guard case let .appleScript(script)? = actions.last else {
        throw TestFailure.expectation("Ghostty focus did not produce AppleScript")
    }
    try expect(
        script.contains("if (count of matches) is not 1 then error"),
        equals: true,
        "Ghostty rejects missing or ambiguous targets"
    )
    try expect(
        script.contains("if (count of matches) > 0 then focus item 1 of matches"),
        equals: false,
        "Ghostty no longer reports activation-only as exact focus"
    )
    try expect(
        script.contains("working directory") || script.contains("whose tty"),
        equals: false,
        "stale strong Ghostty identity never falls back to another tab"
    )
}

func testFocusPlannerTargetsCmuxBySurfaceIdentity() throws {
    // cmux is a Ghostty-derived terminal: it reports TERM_PROGRAM=ghostty but
    // is a distinct application (com.cmuxterm.app). Targeting "Ghostty" would
    // address an app that need not be installed, so a captured surface ID must
    // win over the Ghostty branch and address cmux directly.
    let session = AgentSession(
        tool: .claude,
        sessionID: "cmux-exact",
        pid: 27527,
        status: .working,
        cwd: "/Users/pjjuplo/Documents/codex-projects",
        startedAt: Date(),
        updatedAt: Date(),
        terminal: TerminalContext(
            termProgram: "ghostty",
            cmuxSurfaceID: "1E0A70B7-5FBA-4C4F-83D9-01292C3E957C",
            tty: "/dev/ttys003",
            windowTitleHint: "codex-projects — claude"
        )
    )

    let actions = try FocusPlanner.actions(for: session)
    guard case let .appleScript(script)? = actions.last else {
        throw TestFailure.expectation("cmux focus did not produce AppleScript")
    }
    try expect(
        script.contains("tell application \"cmux\""),
        equals: true,
        "cmux sessions address cmux, never Ghostty"
    )
    try expect(
        script.contains("Ghostty"),
        equals: false,
        "a cmux surface never falls back to an app that may not be installed"
    )
    try expect(
        script.contains("1E0A70B7-5FBA-4C4F-83D9-01292C3E957C"),
        equals: true,
        "the surface ID is strong identity and is used verbatim"
    )
    try expect(
        script.contains("working directory"),
        equals: false,
        "strong cmux identity never guesses by working directory"
    )
    try expect(
        script.contains("if (count of matches) is not 1 then error"),
        equals: true,
        "cmux rejects missing or ambiguous targets like Ghostty does"
    )
}

func testFocusPlannerNormalizesITermIdentityAndSelectsItsWindow() throws {
    let session = AgentSession(
        tool: .claude,
        sessionID: "iterm-exact",
        pid: 43,
        status: .idle,
        cwd: "/tmp/project",
        startedAt: Date(),
        updatedAt: Date(),
        terminal: TerminalContext(
            termProgram: "iTerm.app",
            itermSessionID: "w0t1p2:ABC-123",
            tty: "/dev/ttys043"
        )
    )

    let actions = try FocusPlanner.actions(for: session)
    guard case let .appleScript(script)? = actions.last else {
        throw TestFailure.expectation("iTerm focus did not produce AppleScript")
    }
    try expect(
        script.contains("unique ID of aSession is \"ABC-123\""),
        equals: true,
        "iTerm compares its normalized GUID exactly"
    )
    try expect(script.contains("select targetSession"), equals: true, "iTerm selects the split")
    try expect(script.contains("select targetTab"), equals: true, "iTerm selects the tab")
    try expect(script.contains("select targetWindow"), equals: true, "iTerm raises the window")
    try expect(
        script.contains("if matchCount is not 1 then error"),
        equals: true,
        "iTerm rejects missing or ambiguous targets"
    )
}

func testFocusPlannerRejectsEmptyITermIdentityWithoutTTY() throws {
    let session = AgentSession(
        tool: .claude,
        sessionID: "iterm-missing",
        pid: 45,
        status: .idle,
        cwd: "/tmp/project",
        startedAt: Date(),
        updatedAt: Date(),
        terminal: TerminalContext(
            termProgram: "iTerm.app",
            itermSessionID: "w0t0p0:"
        )
    )

    do {
        _ = try FocusPlanner.actions(for: session)
        throw TestFailure.expectation("empty iTerm identity produced an activation-only plan")
    } catch let error as FocusError {
        try expect(error, equals: .missingTerminalTarget, "empty iTerm target fails closed")
    }
}

func testFocusPlannerMatchesTerminalTTYExactlyAndRaisesItsWindow() throws {
    let session = AgentSession(
        tool: .pi,
        sessionID: "terminal-exact",
        pid: 44,
        status: .idle,
        cwd: "/tmp/project",
        startedAt: Date(),
        updatedAt: Date(),
        terminal: TerminalContext(termProgram: "Apple_Terminal", tty: "/dev/ttys1")
    )

    let actions = try FocusPlanner.actions(for: session)
    guard case let .appleScript(script)? = actions.last else {
        throw TestFailure.expectation("Terminal focus did not produce AppleScript")
    }
    try expect(
        script.contains("if (tty of aTab) is \"/dev/ttys1\""),
        equals: true,
        "Terminal compares normalized TTY exactly"
    )
    try expect(
        script.contains("if matchCount is not 1 then error"),
        equals: true,
        "Terminal rejects missing or ambiguous targets"
    )
    try expect(
        script.contains("set frontmost of targetWindow to true"),
        equals: true,
        "Terminal raises the containing window"
    )
}

func testGhosttyMatcherPrefersProcessAndTTYOverRememberedHeuristics() throws {
    let legacyTerminalData = Data(
        #"[{"id":"legacy","name":"project","cwd":"/tmp/shared"}]"#.utf8
    )
    let legacyTerminal = try JSONDecoder().decode(
        [GhosttyTerminal].self,
        from: legacyTerminalData
    ).first.unwrap(or: "legacy Ghostty terminal did not decode")
    try expect(legacyTerminal.pid, equals: nil, "Ghostty 1.3 terminal has no PID")
    try expect(legacyTerminal.tty, equals: nil, "Ghostty 1.3 terminal has no TTY")

    let first = DetectedAgentProcess(
        tool: .claude,
        processID: 101,
        processIdentity: ProcessIdentity(processID: 101, kernelStartTimeMicroseconds: 1),
        cwd: "/tmp/shared",
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys101")
    )
    let second = DetectedAgentProcess(
        tool: .claude,
        processID: 102,
        processIdentity: ProcessIdentity(processID: 102, kernelStartTimeMicroseconds: 2),
        cwd: "/tmp/shared",
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys102")
    )
    let terminals = [
        GhosttyTerminal(
            id: "surface-second", name: "claude", cwd: "/tmp/shared",
            pid: 102, tty: "/dev/ttys102"
        ),
        GhosttyTerminal(
            id: "surface-first", name: "claude", cwd: "/tmp/shared",
            pid: 101, tty: "/dev/ttys101"
        ),
    ]
    let staleAssignments = [
        GhosttySessionMatcher.assignmentKey(for: first): "surface-second",
        GhosttySessionMatcher.assignmentKey(for: second): "surface-first",
    ]

    let matched = GhosttySessionMatcher.match(
        processes: [first, second],
        terminals: terminals,
        previousAssignments: staleAssignments
    )
    let terminalByPID = Dictionary(uniqueKeysWithValues: matched.map {
        ($0.processID, $0.terminal.ghosttyTerminalID)
    })
    try expect(terminalByPID[101]!, equals: "surface-first", "PID corrects stale first assignment")
    try expect(terminalByPID[102]!, equals: "surface-second", "PID corrects stale second assignment")
}

func testGhosttyMatcherExcludesOrphanedProcessesAndAssignsExactTerminals() throws {
    let processes = [
        detectedProcess(id: 1, cwd: "/stale-one", elapsed: 1_000),
        detectedProcess(id: 2, cwd: "/visible-one", elapsed: 500),
        detectedProcess(id: 3, cwd: "/visible-two", elapsed: 400),
        detectedProcess(id: 4, cwd: "/stale-two", elapsed: 2_000),
        detectedProcess(id: 5, cwd: "/current", elapsed: 10),
    ]
    let terminals = [
        GhosttyTerminal(id: "one", name: "Visible one", cwd: "/visible-one"),
        GhosttyTerminal(id: "two", name: "Visible two", cwd: "/visible-two"),
        GhosttyTerminal(id: "current", name: "Current agent", cwd: ""),
    ]

    let matched = GhosttySessionMatcher.match(processes: processes, terminals: terminals)

    try expect(matched.map(\.processID).sorted(), equals: [2, 3, 5], "visible process IDs")
    try expect(
        matched.first(where: { $0.processID == 5 })?.terminal.ghosttyTerminalID,
        equals: "current",
        "exact terminal ID"
    )
}

func testGhosttyMatcherPrefersSameDirectoryTerminalNamingTheTool() throws {
    // Several tabs often share one project directory (claude and opencode
    // side by side). The tab whose title names the tool must win, so the
    // session row shows — and focus jumps to — the right tab.
    let processes = [
        DetectedAgentProcess(
            tool: .opencode,
            processID: 21,
            cwd: "/tmp/shared-project",
            terminal: TerminalContext(termProgram: "ghostty"),
            elapsedSeconds: 10
        ),
        DetectedAgentProcess(
            tool: .claude,
            processID: 22,
            cwd: "/tmp/shared-project",
            terminal: TerminalContext(termProgram: "ghostty"),
            elapsedSeconds: 20
        ),
    ]
    let terminals = [
        GhosttyTerminal(id: "claude-tab", name: "shared-project — claude", cwd: "/tmp/shared-project"),
        GhosttyTerminal(id: "opencode-tab", name: "shared-project — opencode", cwd: "/tmp/shared-project"),
    ]

    let matched = GhosttySessionMatcher.match(processes: processes, terminals: terminals)

    try expect(
        matched.first(where: { $0.tool == .opencode })?.terminal.ghosttyTerminalID,
        equals: "opencode-tab",
        "opencode terminal"
    )
    try expect(
        matched.first(where: { $0.tool == .claude })?.terminal.ghosttyTerminalID,
        equals: "claude-tab",
        "claude terminal"
    )
}

func testGhosttyMatcherResolvesRetitledTabsBySignatureAndForeignCommands() throws {
    // Live incident 2026-07-19: three tabs shared one project directory —
    // claude's (spinner title), opencode's (emoji-pipe title), and one
    // running `caffeinate -di`. No title named a tool, so assignment fell
    // to enumeration order and opencode adopted the caffeinate tab.
    let processes = [
        DetectedAgentProcess(
            tool: .claude,
            processID: 97,
            cwd: "/tmp/glance",
            terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys001"),
            elapsedSeconds: 100
        ),
        DetectedAgentProcess(
            tool: .opencode,
            processID: 96,
            cwd: "/tmp/glance",
            terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys006"),
            elapsedSeconds: 200
        ),
    ]
    let terminals = [
        GhosttyTerminal(id: "other-project", name: "~/dev/runway", cwd: "/tmp/runway"),
        GhosttyTerminal(id: "claude-tab", name: "⠂ Optimizar rendimiento en Mac", cwd: "/tmp/glance"),
        GhosttyTerminal(id: "caffeinate-tab", name: "caffeinate -di", cwd: "/tmp/glance"),
        GhosttyTerminal(id: "opencode-tab", name: "🟢 | Descripción del repositorio · main", cwd: "/tmp/glance"),
    ]

    let matched = GhosttySessionMatcher.match(processes: processes, terminals: terminals)

    try expect(
        matched.first(where: { $0.tool == .claude })?.terminal.ghosttyTerminalID,
        equals: "claude-tab",
        "spinner signature resolves the claude tab"
    )
    try expect(
        matched.first(where: { $0.tool == .opencode })?.terminal.ghosttyTerminalID,
        equals: "opencode-tab",
        "emoji-pipe signature resolves the opencode tab"
    )
}

func testGhosttyMatcherKeepsPreviousAssignmentsAcrossRetitles() throws {
    // A Ghostty surface never migrates to another process: once a process
    // was matched to a tab, later scans must keep that match even when the
    // titles no longer carry any signal at all.
    let processes = [
        detectedProcess(id: 21, cwd: "/tmp/shared", elapsed: 10),
        DetectedAgentProcess(
            tool: .claude,
            processID: 22,
            cwd: "/tmp/shared",
            terminal: TerminalContext(termProgram: "ghostty"),
            elapsedSeconds: 20
        ),
    ]
    let retitledTerminals = [
        GhosttyTerminal(id: "tab-one", name: "renombrada sin señal", cwd: "/tmp/shared"),
        GhosttyTerminal(id: "tab-two", name: "otra igual de muda", cwd: "/tmp/shared"),
    ]

    let matched = GhosttySessionMatcher.match(
        processes: processes,
        terminals: retitledTerminals,
        previousAssignments: [
            GhosttySessionMatcher.assignmentKey(for: processes[0]): "tab-two",
            GhosttySessionMatcher.assignmentKey(for: processes[1]): "tab-one",
        ]
    )

    try expect(
        matched.first(where: { $0.processID == 21 })?.terminal.ghosttyTerminalID,
        equals: "tab-two",
        "opencode keeps its tab"
    )
    try expect(
        matched.first(where: { $0.processID == 22 })?.terminal.ghosttyTerminalID,
        equals: "tab-one",
        "claude keeps its tab"
    )
}

func testGhosttyMatcherPrefersConvoyOverItsEmbeddedOpenCodeServerForLastTerminal() throws {
    // Live incident 2026-07-20: a convoy pipeline's embedded `opencode serve`
    // child shares the pipeline's exact cwd, and Ghostty's own scripting
    // bridge never enumerates the tab hosting either process. Both land in
    // unmatchedProcesses competing for the one leftover blank terminal — the
    // embedded server must not win it, or ConvoyRunsWatcher never sees the
    // convoy process and the whole pipeline vanishes from the notch.
    let processes = [
        DetectedAgentProcess(
            tool: .opencode,
            processID: 76_552,
            cwd: "/tmp/pipeline-worktree",
            terminal: TerminalContext(termProgram: "ghostty"),
            elapsedSeconds: 5
        ),
        DetectedAgentProcess(
            tool: .convoy,
            processID: 76_544,
            cwd: "/tmp/pipeline-worktree",
            terminal: TerminalContext(termProgram: "ghostty"),
            elapsedSeconds: 15
        ),
    ]
    let terminals = [
        GhosttyTerminal(id: "ghost", name: "👻", cwd: ""),
    ]

    let matched = GhosttySessionMatcher.match(processes: processes, terminals: terminals)

    try expect(
        matched.first(where: { $0.tool == .convoy })?.terminal.ghosttyTerminalID,
        equals: "ghost",
        "convoy claims the last blank terminal"
    )
    try expect(
        matched.contains(where: { $0.tool == .opencode }),
        equals: false,
        "embedded opencode server yields the slot to convoy"
    )
}

func detectedProcess(id: Int32, cwd: String, elapsed: TimeInterval) -> DetectedAgentProcess {
    DetectedAgentProcess(
        tool: .opencode,
        processID: id,
        cwd: cwd,
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys\(id)"),
        elapsedSeconds: elapsed
    )
}

struct SpawnedFakeAgent {
    let rootDirectory: URL
    let process: Process
    let expectedWorkingDirectory: String

    func tearDown() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

/// Launches a real long-running process whose executable basename matches an
/// agent tool, inside a working directory we control, so scanner tests observe
/// genuine system behavior instead of fixtures. When `underFakeTerminalApp`
/// is set (for example "Ghostty.app"), the agent runs as the child of a shell
/// whose argv[0] lives inside that bundle path, emulating a terminal host.
func spawnFakeAgent(
    named executableName: String,
    underFakeTerminalApp terminalAppName: String? = nil
) throws -> SpawnedFakeAgent {
    let fileManager = FileManager.default
    let rootDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("moonglade-scanner-\(UUID().uuidString)", isDirectory: true)
    let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
    let projectDirectory = rootDirectory.appendingPathComponent("project dir", isDirectory: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

    // A symlink keeps /bin/sleep valid as a platform binary (copies get
    // SIGKILLed on Apple Silicon) and mirrors real versioned installs such as
    // ~/.local/bin/claude -> .../versions/2.1.214: the kernel-resolved
    // executable path is "sleep" while argv[0] carries the agent name.
    let executable = binDirectory.appendingPathComponent(executableName)
    try fileManager.createSymbolicLink(
        at: executable,
        withDestinationURL: URL(fileURLWithPath: "/bin/sleep")
    )

    let process = Process()
    if let terminalAppName {
        let hostDirectory = rootDirectory.appendingPathComponent(
            "\(terminalAppName)/Contents/MacOS",
            isDirectory: true
        )
        try fileManager.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        let hostShell = hostDirectory.appendingPathComponent("host-shell")
        try fileManager.createSymbolicLink(
            at: hostShell,
            withDestinationURL: URL(fileURLWithPath: "/bin/zsh")
        )
        process.executableURL = hostShell
        // The trailing builtin keeps zsh alive as the parent instead of
        // exec-replacing itself with the agent.
        process.arguments = ["-c", #""$0" 300; :"#, executable.path]
    } else {
        process.executableURL = executable
        process.arguments = ["300"]
    }
    process.currentDirectoryURL = projectDirectory
    try process.run()

    // realpath(3) instead of URL.resolvingSymlinksInPath(), which strips the
    // /private prefix the kernel reports for temporary directories.
    guard let resolvedPath = realpath(projectDirectory.path, nil) else {
        throw TestFailure.expectation("could not canonicalize fake project directory")
    }
    defer { free(resolvedPath) }
    return SpawnedFakeAgent(
        rootDirectory: rootDirectory,
        process: process,
        expectedWorkingDirectory: String(cString: resolvedPath)
    )
}

func testGhosttyTerminalQueryCacheAvoidsRedundantQueries() throws {
    final class QueryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
    let counter = QueryCounter()
    let terminals = [GhosttyTerminal(id: "1", name: "tab", cwd: "/tmp/project")]
    let cache = GhosttyTerminalQueryCache(timeToLive: 30, failureTimeToLive: 10) {
        counter.increment()
        return terminals
    }
    let start = Date(timeIntervalSince1970: 1_000_000)

    try expect(
        cache.terminals(
            hostingProcessIDs: [100],
            processGenerationKeys: ["100:1"],
            now: start
        ),
        equals: terminals,
        "first query returns terminals"
    )
    try expect(
        cache.terminals(
            hostingProcessIDs: [100],
            processGenerationKeys: ["100:1"],
            now: start.addingTimeInterval(5)
        ),
        equals: terminals,
        "fresh cache returns terminals"
    )
    try expect(counter.count, equals: 1, "fresh same-topology call is served from cache")
    _ = cache.terminals(
        hostingProcessIDs: [100],
        processGenerationKeys: ["100:2"],
        now: start.addingTimeInterval(6)
    )
    try expect(counter.count, equals: 2, "a process generation change refreshes immediately")
    _ = cache.terminals(
        hostingProcessIDs: [100],
        processGenerationKeys: ["100:2"],
        now: start.addingTimeInterval(60)
    )
    try expect(counter.count, equals: 3, "an expired cache refreshes")

    let failureCounter = QueryCounter()
    let failingCache = GhosttyTerminalQueryCache(timeToLive: 30, failureTimeToLive: 10) {
        failureCounter.increment()
        return failureCounter.count == 1 ? nil : terminals
    }
    try expect(
        failingCache.terminals(hostingProcessIDs: [100], now: start),
        equals: nil,
        "first failed query returns no terminal data"
    )
    try expect(
        failingCache.terminals(hostingProcessIDs: [100], now: start.addingTimeInterval(9)),
        equals: nil,
        "failed query is negatively cached during cooldown"
    )
    try expect(failureCounter.count, equals: 1, "negative cache suppresses repeated query")
    try expect(
        failingCache.terminals(hostingProcessIDs: [100], now: start.addingTimeInterval(10)),
        equals: terminals,
        "query retries after failure cooldown"
    )
    try expect(failureCounter.count, equals: 2, "cooldown expiry retries once")
    _ = failingCache.terminals(hostingProcessIDs: [100], now: start.addingTimeInterval(39))
    try expect(failureCounter.count, equals: 2, "successful retry uses the positive TTL")
    _ = failingCache.terminals(hostingProcessIDs: [100], now: start.addingTimeInterval(40))
    try expect(failureCounter.count, equals: 3, "successful retry expires on the positive TTL")

    let generationCounter = QueryCounter()
    let generationCache = GhosttyTerminalQueryCache(timeToLive: 30, failureTimeToLive: 10) {
        generationCounter.increment()
        return nil
    }
    _ = generationCache.terminals(
        hostingProcessIDs: [100],
        processGenerationKeys: ["100:1"],
        now: start
    )
    _ = generationCache.terminals(
        hostingProcessIDs: [100],
        processGenerationKeys: ["100:2"],
        now: start.addingTimeInterval(1)
    )
    try expect(generationCounter.count, equals: 2, "new process generation bypasses negative cache")

    let emptyCounter = QueryCounter()
    let emptyCache = GhosttyTerminalQueryCache(timeToLive: 30, failureTimeToLive: 10) {
        emptyCounter.increment()
        return []
    }
    try expect(
        emptyCache.terminals(hostingProcessIDs: [100], now: start),
        equals: [],
        "successful empty result remains distinct from failure"
    )
    _ = emptyCache.terminals(hostingProcessIDs: [100], now: start.addingTimeInterval(5))
    try expect(emptyCounter.count, equals: 1, "successful empty result uses positive TTL")
}

func testProcessScannerDetectsSpawnedAgentProcessWithinBudget() throws {
    let agent = try spawnFakeAgent(named: "codex")
    defer { agent.tearDown() }

    let scanner = SystemProcessScanner(ghosttyTerminalSource: { nil })
    let scanStart = Date()
    let detected = try scanner.activeProcesses()
    let scanDuration = Date().timeIntervalSince(scanStart)

    guard let match = detected.first(where: { $0.processID == agent.process.processIdentifier }) else {
        throw TestFailure.expectation("spawned codex process was not detected")
    }
    try expect(match.tool, equals: .codex, "detected tool")
    try expect(match.cwd, equals: agent.expectedWorkingDirectory, "detected cwd")
    try expect(
        match.elapsedSeconds >= 0 && match.elapsedSeconds < 60,
        equals: true,
        "elapsed seconds should be a plausible age, got \(match.elapsedSeconds)"
    )
    try expect(
        scanDuration < 0.25,
        equals: true,
        "scan must stay within the 250ms budget, took \(scanDuration)s"
    )
}

func testProcessScannerDetectsScriptRuntimeAgents() throws {
    // Pi installs as an npm CLI: the kernel-resolved executable and argv[0]
    // both name the runtime (node), and the agent name only appears as the
    // script path in argv[1]. Modeled here with a fake "node" that runs a
    // script named "pi".
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("moonglade-runtime-\(UUID().uuidString)", isDirectory: true)
    let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let runtime = binDirectory.appendingPathComponent("node")
    try fileManager.createSymbolicLink(
        at: runtime,
        withDestinationURL: URL(fileURLWithPath: "/bin/zsh")
    )
    let script = binDirectory.appendingPathComponent("pi")
    try Data("/bin/sleep 300\n".utf8).write(to: script)
    let process = Process()
    process.executableURL = runtime
    process.arguments = [script.path]
    try process.run()
    defer {
        process.terminate()
        process.waitUntilExit()
    }

    var match: DetectedAgentProcess?
    let deadline = Date().addingTimeInterval(2)
    repeat {
        match = try SystemProcessScanner(ghosttyTerminalSource: { nil }).activeProcesses()
            .first { $0.processID == process.processIdentifier }
    } while match == nil && Date() < deadline

    try expect(
        match?.tool,
        equals: .pi,
        "a runtime-hosted script named pi must be detected as the pi agent"
    )
}

func testProcessScannerCollapsesRuntimeLauncherOntoNativeChild() throws {
    // npm's codex ships a node launcher (`node .../bin/codex`) that spawns
    // the platform binary (`.../codex-darwin-arm64/.../bin/codex`) as a
    // child. Both carry the tool name, but only the leaf process is the
    // agent — counting both shows two sessions for one Codex.
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("moonglade-launcher-\(UUID().uuidString)", isDirectory: true)
    let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    let vendorDirectory = root.appendingPathComponent("vendor", isDirectory: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: vendorDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let runtime = binDirectory.appendingPathComponent("node")
    try fileManager.createSymbolicLink(
        at: runtime,
        withDestinationURL: URL(fileURLWithPath: "/bin/zsh")
    )
    let nativeAgent = vendorDirectory.appendingPathComponent("codex")
    try fileManager.createSymbolicLink(
        at: nativeAgent,
        withDestinationURL: URL(fileURLWithPath: "/bin/sleep")
    )
    let launcherScript = binDirectory.appendingPathComponent("codex")
    // The trailing builtin keeps the fake node alive as the parent instead
    // of exec-replacing itself with the native agent.
    try Data("\"\(nativeAgent.path)\" 300; :\n".utf8).write(to: launcherScript)
    let launcher = Process()
    launcher.executableURL = runtime
    launcher.arguments = [launcherScript.path]
    try launcher.run()
    var nativeChildPID: pid_t?
    defer {
        launcher.terminate()
        launcher.waitUntilExit()
        if let nativeChildPID { kill(nativeChildPID, SIGTERM) }
    }

    let scanner = SystemProcessScanner(ghosttyTerminalSource: { nil })
    var codexProcesses: [DetectedAgentProcess] = []
    let deadline = Date().addingTimeInterval(2)
    func detectedNativeChild() -> pid_t? {
        codexProcesses.first {
            $0.processID != launcher.processIdentifier
                && SystemProcessScanner.parentProcessID(of: $0.processID) == launcher.processIdentifier
        }?.processID
    }
    repeat {
        codexProcesses = try scanner.activeProcesses().filter {
            $0.processID == launcher.processIdentifier
                || SystemProcessScanner.parentProcessID(of: $0.processID) == launcher.processIdentifier
        }
        if detectedNativeChild() == nil { usleep(50_000) }
    } while detectedNativeChild() == nil && Date() < deadline
    nativeChildPID = detectedNativeChild()

    try expect(
        codexProcesses.map(\.tool),
        equals: [.codex],
        "exactly one codex process must survive for one launcher+child pair"
    )
    try expect(
        codexProcesses.first?.processID != launcher.processIdentifier,
        equals: true,
        "the surviving process must be the native child, not the launcher"
    )
}

func testProcessScannerIgnoresLookalikeProcessNames() throws {
    let agent = try spawnFakeAgent(named: "codexx")
    defer { agent.tearDown() }

    let detected = try SystemProcessScanner(ghosttyTerminalSource: { nil }).activeProcesses()

    try expect(
        detected.contains { $0.processID == agent.process.processIdentifier },
        equals: false,
        "a lookalike executable name must not be detected as an agent"
    )
}

func testProcessScannerResolvesParentOfRootOwnedProcesses() throws {
    // Ghostty spawns shells through /usr/bin/login, which runs as root:
    // proc_pidinfo denies PROC_PIDTBSDINFO on other users' processes, so the
    // ancestor walk must fall back to the kinfo_proc sysctl (what ps uses).
    // launchd (pid 1, root-owned) exercises that path and has parent 0.
    try expect(
        SystemProcessScanner.parentProcessID(of: 1),
        equals: 0,
        "parent of root-owned launchd"
    )
    try expect(
        SystemProcessScanner.parentProcessID(of: getpid()),
        equals: getppid(),
        "parent of this process"
    )
}

func testProcessScannerIdentifiesHostTerminalFromAncestors() throws {
    let agent = try spawnFakeAgent(named: "codex", underFakeTerminalApp: "Ghostty.app")
    defer { agent.tearDown() }

    let scanner = SystemProcessScanner(ghosttyTerminalSource: { nil })
    var match: DetectedAgentProcess?
    let deadline = Date().addingTimeInterval(2)
    repeat {
        match = try scanner.activeProcesses().first {
            $0.tool == .codex && $0.cwd == agent.expectedWorkingDirectory
        }
        if match == nil { usleep(50_000) }
    } while match == nil && Date() < deadline
    guard let match else {
        throw TestFailure.expectation("agent under the fake terminal was not detected")
    }
    // The detected agent is the shell's child, not `agent.process`, so it
    // must be reaped explicitly or it would outlive the test.
    defer { kill(match.processID, SIGTERM) }

    try expect(match.terminal.termProgram, equals: "ghostty", "host terminal program")
}

func testClaudeSettingsMergePreservesHooksAndIsIdempotent() throws {
    let existing = Data(
        #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-hook"}]}]}}"#.utf8
    )

    let once = try ClaudeSettingsMerger.merge(
        settingsData: existing,
        hookCommand: "/Users/me/.moonglade/bin/claude-hook.sh"
    )
    let twice = try ClaudeSettingsMerger.merge(
        settingsData: once,
        hookCommand: "/Users/me/.moonglade/bin/claude-hook.sh"
    )
    let json = try JSONSerialization.jsonObject(with: twice) as? [String: Any]
    let hooks = json?["hooks"] as? [String: [[String: Any]]]
    let stopGroups = hooks?["Stop"] ?? []
    let commands = stopGroups.flatMap { group in
        (group["hooks"] as? [[String: String]] ?? []).compactMap { $0["command"] }
    }

    try expect(json?["theme"] as? String, equals: "dark", "existing setting")
    try expect(commands.filter { $0 == "existing-hook" }.count, equals: 1, "existing hook")
    try expect(
        commands.filter { $0.contains("claude-hook.sh' 'Stop") }.count,
        equals: 1,
        "Moonglade hook"
    )
}

func testClaudeSettingsRemovalPreservesUserHooks() throws {
    let installed = try ClaudeSettingsMerger.merge(
        settingsData: Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#.utf8),
        hookCommand: "/tmp/claude-hook.sh"
    )

    let removed = try ClaudeSettingsMerger.remove(
        settingsData: installed,
        hookCommand: "/tmp/claude-hook.sh"
    )
    let text = String(data: removed, encoding: .utf8) ?? ""
    guard text.contains("mine"), !text.contains("/tmp/claude-hook.sh") else {
        throw TestFailure.expectation("unexpected settings after removal: \(text)")
    }
}

func testClaudeSettingsQuotesHookPathsForTheShell() throws {
    let installed = try ClaudeSettingsMerger.merge(
        settingsData: Data("{}".utf8),
        hookCommand: "/Users/O'Connor/My Tools/claude-hook.sh"
    )
    let root = try JSONSerialization.jsonObject(with: installed) as? [String: Any]
    let hooks = root?["hooks"] as? [String: [[String: Any]]]
    let commands = (hooks?["Stop"] ?? []).flatMap { group in
        (group["hooks"] as? [[String: String]] ?? []).compactMap { $0["command"] }
    }

    try expect(
        commands.first,
        equals: "'/Users/O'\\''Connor/My Tools/claude-hook.sh' 'Stop'",
        "shell-quoted hook command"
    )
}

func testInstallerRejectsSymlinkedPrivateDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    let redirected = root.appendingPathComponent("redirected")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
        at: home.appendingPathComponent(".moonglade"),
        withDestinationURL: redirected
    )

    do {
        try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
        throw TestFailure.expectation("installer followed a symlinked private directory")
    } catch is InstallationError {
        try expect(
            try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty,
            equals: true,
            "redirected directory contents"
        )
    }
}

func testInstallerFollowsUserOwnedSymlinkedIntegrationDirectories() throws {
    // Dotfile setups routinely symlink ~/.config/opencode/plugins (or
    // ~/.claude) into a config repository inside the home directory. The
    // installer must follow those links when they resolve to a user-owned
    // directory under home — only ~/.moonglade is strictly symlink-free.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    let dotfilesPlugins = home.appendingPathComponent("dotfiles/opencode-plugins")
    try FileManager.default.createDirectory(at: dotfilesPlugins, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".config/opencode"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
        at: home.appendingPathComponent(".config/opencode/plugins"),
        withDestinationURL: dotfilesPlugins
    )

    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    try expect(
        FileManager.default.fileExists(
            atPath: dotfilesPlugins.appendingPathComponent("moonglade.js").path
        ),
        equals: true,
        "plugin lands in the symlink's resolved directory"
    )
    try expect(
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/settings.json").path
        ),
        equals: true,
        "claude settings written"
    )
}

func testInstallerReplacesMarkedIntegrationFilesOnReinstall() throws {
    // Upgraded builds ship different plugin content, so exact-match
    // replacement alone would block every reinstall of our own files. The
    // ownership marker in the first line authorizes replacement; unmarked
    // files belong to the user and still refuse the install.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".config/opencode/plugins"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let outdated = "// Moonglade-managed integration; reinstalls replace this file.\nexport const Old = 1;\n"
    let pluginURL = home.appendingPathComponent(".config/opencode/plugins/moonglade.js")
    try Data(outdated.utf8).write(to: pluginURL)

    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    try expect(
        try Data(contentsOf: pluginURL) == Data(contentsOf: BundledResources.opencodePluginURL),
        equals: true,
        "marked plugin is replaced by the bundled one"
    )

    let userExtensionURL = home.appendingPathComponent(".pi/agent/extensions/moonglade.ts")
    try Data("export default function mine() {}\n".utf8).write(to: userExtensionURL)
    do {
        try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
        throw TestFailure.expectation("install must refuse an unmarked integration file")
    } catch let error as InstallationError {
        try expect(
            error,
            equals: .existingIntegrationFile(userExtensionURL.path),
            "unmarked files still refuse"
        )
    }
}

func testInstallerPrependsCodexNotifyBeforeExistingContent() throws {
    // A multi-line TOML value may continue on a line that begins with "[",
    // so inserting before the first such line can land inside a value. The
    // only position that is safe for a root-table key regardless of the
    // existing content is the top of the file.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".codex"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let existingConfig = """
    targets = [
        ["a", "b"],
    ]

    [profiles.fast]
    model = "gpt-5"

    """
    let configURL = home.appendingPathComponent(".codex/config.toml")
    try Data(existingConfig.utf8).write(to: configURL)

    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    let config = try String(contentsOf: configURL, encoding: .utf8)
    try expect(config.hasPrefix("notify = "), equals: true, "notify line leads the file")
    try expect(config.contains(existingConfig), equals: true, "existing content preserved verbatim")
}

func testInstallationDoctorReportsHealthyInstall() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()

    try expect(checks.count, equals: 9, "doctor check count")
    for check in checks {
        try expect(check.passed, equals: true, "check '\(check.title)': \(check.detail)")
    }
    try expect(
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".pi/agent/extensions/moonglade.ts").path
        ),
        equals: true,
        "pi extension installed"
    )
}

func testInstallationDoctorDiagnosesLooseSettingsPermissionsInsteadOfMissingInstall() throws {
    // A group-writable settings file fails the secure read. Reporting that as
    // "missing — run: moonglade install" sends the user to a command that
    // cannot fix it; the check must name the permissions instead.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o666],
        ofItemAtPath: home.appendingPathComponent(".claude/settings.json").path
    )

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()
    let byTitle = Dictionary(uniqueKeysWithValues: checks.map { ($0.title, $0) })
    let claude = try byTitle["Claude Code hooks"].unwrap(or: "missing Claude check")

    try expect(claude.passed, equals: false, "loose permissions must not pass")
    try expect(
        claude.detail.contains("chmod og-w"),
        equals: true,
        "detail prescribes the permission fix, not a reinstall"
    )
}

func testInstallationDoctorRejectsAForeignCodexNotifyHook() throws {
    // A notify entry naming codex-notify.sh but living under a different
    // directory belongs to another installation. Matching the script name alone
    // reported Codex as wired while its events went to that other app, so the
    // check must match the exact path this installation writes.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
    try Data("notify = [\"/Users/someone/.othertool/bin/codex-notify.sh\"]\n".utf8).write(
        to: home.appendingPathComponent(".codex/config.toml")
    )

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()
    let byTitle = Dictionary(uniqueKeysWithValues: checks.map { ($0.title, $0) })
    let codex = try byTitle["Codex notify"].unwrap(or: "missing Codex check")

    try expect(codex.passed, equals: false, "a foreign notify hook must not pass")
    // `moonglade install` only writes the key when no notify exists at all, so
    // prescribing it here sends the user to a command that cannot change
    // anything. The recovery step has to name what actually unblocks them.
    try expect(
        codex.detail.contains("codex-notify.sh"),
        equals: true,
        "detail names the script to add to the foreign chain"
    )
    try expect(
        codex.detail.contains("notify chain"),
        equals: true,
        "detail explains that the foreign hook must forward to ours"
    )
}

func testInstallationDoctorAcceptsAChainedCodexNotifyHook() throws {
    // Codex's notify holds one command, so tools that want it cooperate by
    // taking the key and passing the previous value along as an argument of
    // their own -- escaped, because it travels as a nested JSON string. Our
    // hook still runs, so reporting it as missing is a false alarm, and the
    // remedy it printed was a no-op that left the user with nothing to do.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
    let ours = home.appendingPathComponent(".moonglade/bin/codex-notify.sh")
        .standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "\\\\/")
    try Data("""
        notify = ["/opt/othertool/bin/othertool", "turn-ended", \
        "--previous-notify", "[\\"\(ours)\\"]"]

        model = "gpt-5"
        """.utf8).write(to: home.appendingPathComponent(".codex/config.toml"))

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()
    let byTitle = Dictionary(uniqueKeysWithValues: checks.map { ($0.title, $0) })
    let codex = try byTitle["Codex notify"].unwrap(or: "missing Codex check")

    try expect(codex.passed, equals: true, "a chained notify hook must pass: \(codex.detail)")
    try expect(
        codex.detail.contains("othertool"),
        equals: true,
        "detail names the tool our hook is reached through"
    )
}

func testInstallationDoctorReadsACodexNotifyArraySpanningLines() throws {
    // A TOML array may break across lines, so the value cannot be read as "the
    // rest of the notify line" -- doing that truncated the chain mid-argument
    // and lost our script.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
    let ours = home.appendingPathComponent(".moonglade/bin/codex-notify.sh")
        .standardizedFileURL.path
    try Data("""
        notify = [
          "/opt/othertool/bin/othertool",
          "--previous-notify",
          "\(ours)",
        ]

        model = "gpt-5"
        """.utf8).write(to: home.appendingPathComponent(".codex/config.toml"))

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()
    let byTitle = Dictionary(uniqueKeysWithValues: checks.map { ($0.title, $0) })
    let codex = try byTitle["Codex notify"].unwrap(or: "missing Codex check")

    try expect(codex.passed, equals: true, "a multi-line notify chain must pass: \(codex.detail)")
}

func testInstallationDoctorReportsAnAbsentCodexNotifyKey() throws {
    // A config with no notify at all is the one case install really does fix,
    // so it is the only case that may point at it.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
    try Data("model = \"gpt-5\"\n".utf8).write(
        to: home.appendingPathComponent(".codex/config.toml")
    )

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()
    let byTitle = Dictionary(uniqueKeysWithValues: checks.map { ($0.title, $0) })
    let codex = try byTitle["Codex notify"].unwrap(or: "missing Codex check")

    try expect(codex.passed, equals: false, "an absent notify key must not pass")
    try expect(
        codex.detail.contains("moonglade install"),
        equals: true,
        "detail names the recovery command"
    )
}

func testInstallationDoctorPinpointsBrokenPieces() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
    try FileManager.default.removeItem(
        at: home.appendingPathComponent(".moonglade/bin/claude-hook.sh")
    )
    try Data("tampered".utf8).write(
        to: home.appendingPathComponent(".config/opencode/plugins/moonglade.js")
    )
    try Data("model = \"gpt-5\"\n".utf8).write(
        to: home.appendingPathComponent(".codex/config.toml")
    )
    try FileManager.default.removeItem(
        at: home.appendingPathComponent(".pi/agent/extensions/moonglade.ts")
    )

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()
    let byTitle = Dictionary(uniqueKeysWithValues: checks.map { ($0.title, $0) })
    let binaries = try byTitle["hook binaries"].unwrap(or: "missing binaries check")
    let openCode = try byTitle["OpenCode plugin"].unwrap(or: "missing OpenCode check")
    let codex = try byTitle["Codex notify"].unwrap(or: "missing Codex check")

    try expect(binaries.passed, equals: false, "binaries check must fail")
    try expect(binaries.detail.contains("claude-hook.sh"), equals: true, "binaries detail names the missing script")
    try expect(openCode.passed, equals: false, "OpenCode check must fail")
    try expect(codex.passed, equals: false, "Codex check must fail")
    try expect(
        try byTitle["Pi extension"].unwrap(or: "missing Pi check").passed,
        equals: false,
        "Pi check must fail"
    )
    try expect(
        try byTitle["Claude Code hooks"].unwrap(or: "missing Claude check").passed,
        equals: true,
        "Claude hooks stay healthy"
    )
    try expect(
        try byTitle["state directory"].unwrap(or: "missing state check").passed,
        equals: true,
        "state directory stays healthy"
    )
}

/// SwiftPM's generated `Bundle.module` resolves exactly two locations: the
/// directory holding the running executable, and the absolute build directory
/// of the machine that compiled it. A shipped binary has no bundle beside it,
/// so both installed CLIs loaded their scripts out of the developer's `.build`
/// tree and trapped the moment that directory was renamed. The search must
/// cover the layouts Moonglade actually installs into, and name no build path.
func testResourceBundleSearchCoversEveryInstalledLayout() throws {
    let privateBinary = URL(fileURLWithPath: "/Users/someone/.moonglade/bin/moonglade")
    let privatePaths = BundledResources.bundleSearchPaths(
        executableURL: privateBinary,
        mainResourceURL: nil
    )
    try expect(
        privatePaths.contains("/Users/someone/.moonglade/bin/\(BundledResources.bundleName)"),
        equals: true,
        "the private install directory is searched"
    )
    try expect(
        privatePaths.contains(where: { $0.contains("/.build/") }),
        equals: false,
        "no build directory is baked into the search"
    )

    let appResources = "/Applications/Moonglade.app/Contents/Resources"
    try expect(
        BundledResources.bundleSearchPaths(
            executableURL: URL(fileURLWithPath: "\(appResources)/bin/moonglade"),
            mainResourceURL: nil
        ).contains("\(appResources)/\(BundledResources.bundleName)"),
        equals: true,
        "the CLI in the app bundle searches the Resources directory above it"
    )
    try expect(
        BundledResources.bundleSearchPaths(
            executableURL: URL(fileURLWithPath: "/Applications/Moonglade.app/Contents/MacOS/Moonglade"),
            mainResourceURL: URL(fileURLWithPath: appResources, isDirectory: true)
        ).contains("\(appResources)/\(BundledResources.bundleName)"),
        equals: true,
        "the app binary searches its own Resources directory"
    )
}

/// The Metal shader library ships in the app target's own resource bundle,
/// which `build-app.sh` installs into Contents/Resources. SwiftPM's generated
/// accessor for that target looks only beside `Bundle.main.bundleURL` — the
/// `.app` root — and in the compiling machine's build directory, so an
/// installed app resolved its shader only while that build tree survived and
/// trapped on launch once it was gone. The root is not a candidate: putting
/// anything there leaves the bundle unsealed.
func testAppResourceBundleSearchCoversTheInstalledAppLayout() throws {
    let appResources = "/Applications/Moonglade.app/Contents/Resources"
    let appPaths = BundledResources.bundleSearchPaths(
        named: BundledResources.appBundleName,
        executableURL: URL(fileURLWithPath: "/Applications/Moonglade.app/Contents/MacOS/Moonglade"),
        mainResourceURL: URL(fileURLWithPath: appResources, isDirectory: true)
    )
    try expect(
        appPaths.contains("\(appResources)/\(BundledResources.appBundleName)"),
        equals: true,
        "the app binary searches its own Resources directory for the shader bundle"
    )
    try expect(
        appPaths.contains("/Applications/Moonglade.app/\(BundledResources.appBundleName)"),
        equals: false,
        "the app root is never searched: contents there leave the bundle unsealed"
    )
    try expect(
        appPaths.contains(where: { $0.contains("/.build/") }),
        equals: false,
        "no build directory is baked into the search"
    )

    // `swift run` during development: the bundle sits beside the executable.
    let developmentDirectory = "/Users/someone/Moonglade/.build/x86_64-apple-macosx/debug"
    try expect(
        BundledResources.bundleSearchPaths(
            named: BundledResources.appBundleName,
            executableURL: URL(fileURLWithPath: "\(developmentDirectory)/MoongladeApp"),
            mainResourceURL: nil
        ).contains("\(developmentDirectory)/\(BundledResources.appBundleName)"),
        equals: true,
        "a development build finds the bundle beside its executable"
    )
}

func testInstallerShipsTheResourceBundleBesideTheInstalledBinary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    let installedBundle = home.appendingPathComponent(
        ".moonglade/bin/\(BundledResources.bundleName)"
    )
    try expect(
        FileManager.default.fileExists(atPath: installedBundle.path),
        equals: true,
        "the resource bundle ships beside the installed binary"
    )
    // Existing is not enough: the installed binary reads its hook scripts and
    // agent icons back out of this copy on every install and doctor run.
    try expect(
        FileManager.default.fileExists(
            atPath: installedBundle.appendingPathComponent("Resources/hooks/claude-hook.sh").path
        ),
        equals: true,
        "the installed bundle carries the hook scripts"
    )
}

func testInstallationDoctorFailsWhenTheResourceBundleIsMissing() throws {
    // "hook binaries: all executables present" passed while the installed
    // binary trapped on startup, because presence is not usability.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
    try FileManager.default.removeItem(
        at: home.appendingPathComponent(".moonglade/bin/\(BundledResources.bundleName)")
    )

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()
    let byTitle = Dictionary(uniqueKeysWithValues: checks.map { ($0.title, $0) })
    let resources = try byTitle["resource bundle"].unwrap(or: "missing resource bundle check")

    try expect(resources.passed, equals: false, "a missing resource bundle must fail")
    try expect(
        resources.detail.contains("moonglade install"),
        equals: true,
        "detail names the recovery command"
    )
}

func testFrontTerminalMatcherMatchesByIDAndFallsBackToWorkingDirectory() throws {
    func session(_ sessionID: String, terminalID: String?, cwd: String) -> AgentSession {
        AgentSession(
            tool: .claude,
            sessionID: sessionID,
            pid: 1,
            status: .idle,
            cwd: cwd,
            startedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            terminal: TerminalContext(termProgram: "ghostty", ghosttyTerminalID: terminalID)
        )
    }
    let front = GhosttyFrontTerminal(terminalID: "77", workingDirectory: "/Users/me/project/")
    let exactMatch = session("exact", terminalID: "77", cwd: "/somewhere/else")
    let cwdFallback = session("fallback", terminalID: nil, cwd: "/Users/me/project")
    let otherTab = session("other-tab", terminalID: "12", cwd: "/Users/me/project")
    let otherDirectory = session("other-dir", terminalID: nil, cwd: "/Users/me/elsewhere")

    let focused = FrontTerminalMatcher.sessionsFocused(
        by: front,
        among: [exactMatch, cwdFallback, otherTab, otherDirectory]
    )

    try expect(
        focused.map(\.sessionID),
        equals: ["exact", "fallback"],
        "exact ID wins; missing ID falls back to cwd; a known different tab never matches"
    )
}

func testCLIParsesDoctorCommand() throws {
    try expect(try CLICommand.parse(arguments: ["doctor"]), equals: .doctor, "CLI command")
}

func testHookInputRejectsOversizedPayloads() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x61, count: BoundedInput.maximumPayloadSize + 1).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    do {
        _ = try BoundedInput.read(from: handle)
        throw TestFailure.expectation("oversized hook input was accepted")
    } catch let error as InputError {
        try expect(error, equals: .payloadTooLarge, "hook input error")
    }
}

func testCodexNotifyMarksTurnComplete() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession.decode(
        from: validStateJSON(
            sessionID: "codex-1",
            status: "working",
            pid: Int32(getpid()),
            tool: "codex"
        )
    ))
    let payload = Data(
        #"{"type":"agent-turn-complete","thread-id":"codex-1","cwd":"/tmp/project"}"#.utf8
    )

    try CodexNotifyProcessor(repository: repository).process(
        payload: payload,
        processID: Int32(getpid()),
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let session = try repository.loadSessions().first.unwrap(or: "Codex state was not saved")
    try expect(session.status, equals: .idle, "notify status")
    try expect(session.attentionReason, equals: .turnComplete, "notify reason")
}

func testSessionNameOverridesRenameAndPrune() throws {
    let session = try AgentSession.decode(from: validStateJSON(sessionID: "ses_a", status: "working"))
    var overrides = SessionNameOverrides()
    try expect(overrides.displayName(for: session), equals: nil, "no override yet")

    overrides.rename(session, to: "API refactor")
    try expect(overrides.displayName(for: session), equals: "API refactor", "renamed")

    // A name sticks to the session identity, not to its momentary status.
    let laterActivity = try AgentSession.decode(from: validStateJSON(sessionID: "ses_a", status: "idle"))
    try expect(overrides.displayName(for: laterActivity), equals: "API refactor", "survives status change")

    overrides.rename(session, to: "   ")
    try expect(overrides.displayName(for: session), equals: nil, "blank input clears the override")

    overrides.rename(session, to: "kept")
    let doomed = try AgentSession.decode(from: validStateJSON(sessionID: "ses_b", status: "working"))
    overrides.rename(doomed, to: "gone")
    overrides.prune(keeping: [session])
    try expect(overrides.displayName(for: session), equals: "kept", "prune keeps live session names")
    try expect(overrides.displayName(for: doomed), equals: nil, "prune drops dead session names")
}

func testStateStoreRenamePersistsAcrossRestartsAndPrunesWithSessions() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let stateDirectory = rootDirectory.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let namesFileURL = rootDirectory.appendingPathComponent("session-names.json")
    let repository = StateRepository(directoryURL: stateDirectory)
    let session = try AgentSession.decode(
        from: validStateJSON(sessionID: "ses_named", status: "working", pid: Int32(getpid()))
    )
    try repository.save(session)

    let store = StateStore(repository: repository, nameOverridesFileURL: namesFileURL)
    try store.reload()
    store.rename(session, to: "Mi pipeline")
    try expect(store.nameOverrides.displayName(for: session), equals: "Mi pipeline", "renamed in store")

    // A fresh store — the app restarting — reads the same override back.
    let restartedStore = StateStore(repository: repository, nameOverridesFileURL: namesFileURL)
    try restartedStore.reload()
    try expect(
        restartedStore.nameOverrides.displayName(for: session),
        equals: "Mi pipeline",
        "override survives restart"
    )

    // Once the session document disappears, reload prunes the override and
    // persists the prune, so dead names never accumulate on disk.
    try repository.remove(session)
    try restartedStore.reload()
    let prunedStore = StateStore(repository: repository, nameOverridesFileURL: namesFileURL)
    try prunedStore.reload()
    try expect(
        prunedStore.nameOverrides.displayName(for: session),
        equals: nil,
        "override pruned after session death"
    )
}

func testStateStoreClearsAllSessionNames() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let stateDirectory = rootDirectory.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let namesFileURL = rootDirectory.appendingPathComponent("session-names.json")
    let repository = StateRepository(directoryURL: stateDirectory)
    let session = try AgentSession.decode(
        from: validStateJSON(sessionID: "ses_reset", status: "working", pid: Int32(getpid()))
    )
    try repository.save(session)
    let store = StateStore(repository: repository, nameOverridesFileURL: namesFileURL)
    store.rename(session, to: "Custom name")

    store.clearAllSessionNames()

    try expect(store.nameOverrides.displayName(for: session), equals: nil, "override cleared in memory")
    let restartedStore = StateStore(repository: repository, nameOverridesFileURL: namesFileURL)
    try expect(
        restartedStore.nameOverrides.displayName(for: session),
        equals: nil,
        "cleared state persisted"
    )
}

func testStateStoreRaisesAttentionOnlyOnTransitionsIntoRed() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let store = StateStore(repository: repository)
    var raisedBatches: [[String]] = []
    store.onAttentionRaised = { raisedBatches.append($0.map(\.sessionID)) }

    // The first reload is a baseline: sessions already waiting when the app
    // launches must not chime — a reinstall would beep spuriously.
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "already-red", status: "needs_attention", pid: Int32(getpid()))
    ))
    try store.reload()
    try expect(raisedBatches, equals: [], "baseline reload stays silent")

    // A session transitioning into red raises once, then stays quiet while
    // it remains red.
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "turns-red", status: "working", pid: Int32(getpid()))
    ))
    try store.reload()
    try expect(raisedBatches, equals: [], "green session raises nothing")
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "turns-red", status: "needs_attention", pid: Int32(getpid()))
    ))
    try store.reload()
    try expect(raisedBatches, equals: [["turns-red"]], "transition into red raises once")
    try store.reload()
    try expect(raisedBatches, equals: [["turns-red"]], "still-red session does not re-raise")
}

func testStateStoreDoesNotRepublishUnchangedState() throws {
    /// Observation calls `onChange` from a `@Sendable` closure, so the flag it
    /// raises cannot be a captured `var`.
    final class ObservationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var observed = false

        func recordChange() {
            lock.lock()
            defer { lock.unlock() }
            observed = true
        }

        var sawChange: Bool {
            lock.lock()
            defer { lock.unlock() }
            return observed
        }
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let store = StateStore(repository: repository)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "steady", status: "working", pid: Int32(getpid()))
    ))
    try store.reload()

    // Every hook notification and every directory event reloads, and each
    // reload used to reassign this observable state whether or not the decoded
    // snapshot differed. Reassigning it invalidates the widget's whole view
    // tree and relays the notch window for nothing, which measured as the
    // largest share of the app's idle CPU.
    let unchangedReload = ObservationProbe()
    withObservationTracking {
        _ = store.sessions
        _ = store.acknowledgments
    } onChange: {
        unchangedReload.recordChange()
    }
    try store.reload()
    try expect(
        unchangedReload.sawChange,
        equals: false,
        "a reload that decodes identical state must not invalidate observers"
    )

    // The guard must not make the store go blind: real change still publishes.
    let changedReload = ObservationProbe()
    withObservationTracking {
        _ = store.sessions
    } onChange: {
        changedReload.recordChange()
    }
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "steady", status: "needs_attention", pid: Int32(getpid()))
    ))
    try store.reload()
    try expect(changedReload.sawChange, equals: true, "a status change still reaches observers")
    try expect(
        store.sessions.map(\.status),
        equals: [SessionStatus.needsAttention],
        "the published snapshot carries the new status"
    )
}

func testStateStoreRaisesTurnCompletionOnlyFromWorkingToIdle() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let store = StateStore(repository: repository)
    var completedBatches: [[String]] = []
    store.onTurnCompleted = { completedBatches.append($0.map(\.sessionID)) }

    // A session appearing already idle is not a finished turn — nothing to
    // announce: the agent did not just hand the conversation back.
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "born-idle", status: "idle", pid: Int32(getpid()))
    ))
    try store.reload()
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "finishes", status: "working", pid: Int32(getpid()))
    ))
    try store.reload()
    try expect(completedBatches, equals: [], "no completion before any turn ends")

    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "finishes", status: "idle", pid: Int32(getpid()))
    ))
    try store.reload()
    try expect(completedBatches, equals: [["finishes"]], "working to idle announces the turn")
    try store.reload()
    try expect(completedBatches, equals: [["finishes"]], "still-idle session stays quiet")

    // Red to idle means the user was already interacting — no announcement.
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "finishes", status: "needs_attention", pid: Int32(getpid()))
    ))
    try store.reload()
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "finishes", status: "idle", pid: Int32(getpid()))
    ))
    try store.reload()
    try expect(completedBatches, equals: [["finishes"]], "red to idle stays quiet")
}

func testTerminationPlannerClosesOnlyExactContainers() throws {
    // A tmux session closes its pane and nothing else: the surrounding
    // Ghostty tab may host other panes, so the tab must stay open.
    let tmuxSession = try AgentSession.decode(from: Data(
        #"{"schema_version":1,"tool":"claude","session_id":"kill-tmux","pid":1,"status":"working","attention_reason":null,"cwd":"/tmp/project","started_at":"2026-07-18T10:00:00Z","updated_at":"2026-07-18T10:00:00Z","terminal":{"term_program":"ghostty","ghostty_terminal_id":"terminal-123","tmux_pane":"%3"}}"#.utf8
    ))
    try expect(
        TerminationPlanner.closeActions(for: tmuxSession),
        equals: [.run(executable: "tmux", arguments: ["kill-pane", "-t", "%3"])],
        "tmux close actions"
    )

    // A plain Ghostty tab closes by exact surface id.
    let ghosttySession = try AgentSession.decode(from: Data(
        #"{"schema_version":1,"tool":"opencode","session_id":"kill-ghostty","pid":1,"status":"working","attention_reason":null,"cwd":"/tmp/project","started_at":"2026-07-18T10:00:00Z","updated_at":"2026-07-18T10:00:00Z","terminal":{"term_program":"ghostty","ghostty_terminal_id":"terminal-456"}}"#.utf8
    ))
    let ghosttyActions = try TerminationPlanner.closeActions(for: ghosttySession)
    guard case let .appleScript(script)? = ghosttyActions.first, ghosttyActions.count == 1 else {
        throw TestFailure.expectation("expected a single Ghostty close script, got \(ghosttyActions)")
    }
    try expect(script.contains("close"), equals: true, "script closes")
    try expect(script.contains("terminal-456"), equals: true, "script targets exact id")
    // Closing is destructive: unlike focusing, no cwd or title heuristics.
    try expect(script.contains("working directory"), equals: false, "no cwd fallback")
    try expect(script.contains("name contains"), equals: false, "no title fallback")

    // Without an exact container there is nothing safe to close.
    let anonymousSession = try AgentSession.decode(
        from: validStateJSON(sessionID: "kill-anon", status: "working")
    )
    try expect(TerminationPlanner.closeActions(for: anonymousSession), equals: [], "no container, no close")

    // A malformed pane id must fail fast, never reach tmux.
    let corruptSession = try AgentSession.decode(from: Data(
        #"{"schema_version":1,"tool":"claude","session_id":"kill-bad","pid":1,"status":"working","attention_reason":null,"cwd":"/tmp/project","started_at":"2026-07-18T10:00:00Z","updated_at":"2026-07-18T10:00:00Z","terminal":{"tmux_pane":"%3; rm -rf /"}}"#.utf8
    ))
    do {
        _ = try TerminationPlanner.closeActions(for: corruptSession)
        throw TestFailure.expectation("malformed tmux pane was accepted")
    } catch let error as FocusError {
        try expect(error, equals: .invalidTmuxPane("%3; rm -rf /"), "tmux pane validation")
    }
}

func testTerminationServiceKillsPolitelyAndEscalatesToSigkill() throws {
    func spawn(_ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        try process.run()
        return process
    }
    func sessionForProcessID(_ processID: Int32) throws -> AgentSession {
        let identity = try SystemProcessScanner.processIdentity(of: processID)
            .unwrap(or: "test process has no kernel identity")
        return AgentSession(
            tool: .claude,
            sessionID: "kill-\(processID)",
            pid: processID,
            processIdentity: identity,
            status: .working,
            cwd: "/tmp/kill",
            startedAt: Date(),
            updatedAt: Date()
        )
    }

    // A well-behaved process dies on SIGTERM within the grace period.
    let polite = try spawn(["/bin/sleep", "60"])
    let politeSession = try sessionForProcessID(polite.processIdentifier)
    try TerminationService.terminate(politeSession, gracePeriod: 2)
    polite.waitUntilExit()
    try expect(polite.terminationReason, equals: .uncaughtSignal, "polite process killed by signal")

    // A process ignoring SIGTERM is escalated to SIGKILL after the grace.
    let stubborn = try spawn(["/bin/sh", "-c", "trap '' TERM; sleep 60"])
    // Give the shell a beat to install its trap before signaling.
    usleep(200_000)
    try TerminationService.terminate(try sessionForProcessID(stubborn.processIdentifier), gracePeriod: 0.3)
    stubborn.waitUntilExit()
    try expect(stubborn.terminationReason, equals: .uncaughtSignal, "stubborn process killed by signal")

    // A pid that is already gone is not an error: the goal state holds.
    try TerminationService.terminate(politeSession, gracePeriod: 0.3)
}

func testTerminationServiceRefusesUnverifiedProcess() throws {
    // State documents originate outside the app and can outlive their
    // process. A legacy document without a kernel generation must not turn a
    // stale PID into permission to signal an unrelated process.
    let target = Process()
    target.executableURL = URL(fileURLWithPath: "/bin/sleep")
    target.arguments = ["60"]
    try target.run()
    defer {
        if Darwin.kill(target.processIdentifier, 0) == 0 {
            Darwin.kill(target.processIdentifier, SIGKILL)
        }
        target.waitUntilExit()
    }
    let unverified = AgentSession(
        tool: .claude,
        sessionID: "unverified-\(target.processIdentifier)",
        pid: target.processIdentifier,
        status: .working,
        cwd: "/tmp/unverified",
        startedAt: Date(),
        updatedAt: Date()
    )

    do {
        try TerminationService.terminate(unverified, gracePeriod: 0.1)
        throw TestFailure.expectation("termination accepted an unverified process")
    } catch let error as TerminationError {
        try expect(
            error,
            equals: .signalFailed(pid: target.processIdentifier, underlyingErrno: ESRCH),
            "unverified session is rejected before signaling"
        )
    }
    try expect(Darwin.kill(target.processIdentifier, 0), equals: 0, "unverified process remains alive")
}

func testSessionTitleFormatterCleansTabTitles() throws {
    // Agent status decorations — emoji dots, spinners, separators — and
    // ellipses are stripped; whitespace collapses. Width-aware truncation
    // belongs to the row's single-line Text; the formatter only caps
    // pathological lengths.
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: "🟢 | Ideas de naming... · main", fallback: "repo"),
        equals: "Ideas de naming · main",
        "opencode-style tab title keeps everything the row can fit"
    )
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: "✳ Moonglade — claude", fallback: "repo"),
        equals: "Moonglade — claude",
        "claude-style tab title"
    )
    try expect(
        SessionTitleFormatter.rowTitle(
            tabTitle: String(repeating: "long title ", count: 30),
            fallback: "repo"
        ).count,
        equals: SessionTitleFormatter.maximumTitleLength,
        "a runaway tab string still hits the safety cap"
    )
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: "convoy", fallback: "repo"),
        equals: "convoy",
        "plain short title"
    )
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: "● ● ●", fallback: "repo"),
        equals: "repo",
        "decoration-only title falls back"
    )
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: nil, fallback: "repo"),
        equals: "repo",
        "missing title falls back"
    )
    try expect(
        SessionTitleFormatter.truncate("really-long-directory-name", to: 14),
        equals: "really-long-d…",
        "directory truncation"
    )
    try expect(
        SessionTitleFormatter.truncate("Moonglade", to: 14),
        equals: "Moonglade",
        "short directory untouched"
    )
}

func testStateStoreDisplayNamePrefersOverrideThenTabTitle() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let store = StateStore(repository: repository)
    let titled = try AgentSession.decode(from: Data(
        #"{"schema_version":1,"tool":"claude","session_id":"t1","pid":1,"status":"working","attention_reason":null,"cwd":"/tmp/project","started_at":"2026-07-18T10:00:00Z","updated_at":"2026-07-18T10:00:00Z","terminal":{"window_title_hint":"🟢 | Fixing the reaper"}}"#.utf8
    ))

    try expect(store.displayName(for: titled), equals: "Fixing the reaper", "tab title beats directory")

    store.rename(titled, to: "Mi tarea")
    try expect(store.displayName(for: titled), equals: "Mi tarea", "manual rename beats tab title")

    let untitled = try AgentSession.decode(
        from: validStateJSON(sessionID: "t2", status: "working")
    )
    try expect(store.displayName(for: untitled), equals: "project", "no hint falls back to directory")
}

func testNotchGlassScrimKeepsCollapsedBarSolidAndFadesExpanded() throws {
    // Collapsed bar (32pt) sits entirely inside the 38pt solid band: every
    // stop stays fully opaque, so the compact notch renders flat black.
    let collapsed = NotchGlassStyle.scrimStops(height: 32, solidBandHeight: 38)
    try expect(collapsed.allSatisfy { $0.opacity == 1 }, equals: true, "collapsed bar stays solid black")
    try expect(collapsed.first?.location, equals: 0, "collapsed gradient starts at top")
    try expect(collapsed.last?.location, equals: 1, "collapsed gradient reaches bottom")

    // Fully expanded: pure black through the band, then a smootherstep
    // dissolve down to the smoked floor at the bottom edge.
    let expanded = NotchGlassStyle.scrimStops(
        height: 354,
        solidBandHeight: 38,
        bottomOpacity: 0.15,
        fadeStartFraction: 0
    )
    try expect(expanded.first, equals: NotchGlassStyle.Stop(location: 0, opacity: 1), "expanded starts solid")
    try expect(expanded[1], equals: NotchGlassStyle.Stop(location: 38.0 / 354.0, opacity: 1), "solid band ends at 38pt")
    try expect(expanded.last, equals: NotchGlassStyle.Stop(location: 1, opacity: 0.15), "expanded holds the smoked floor")
    // With the symmetric curve (bias 1), the dissolve crosses exactly half
    // the fade range at the middle of the run.
    let midRun = expanded[expanded.count / 2]
    try expect(
        abs(midRun.opacity - (1 - 0.85 * 0.5)) < 0.000001,
        equals: true,
        "symmetric dissolve crosses half the range at mid-run"
    )

    // Mid-spring height: same smooth run compressed into the shorter drop,
    // still ending at the smoked floor.
    let midSpring = NotchGlassStyle.scrimStops(
        height: 60,
        solidBandHeight: 38,
        bottomOpacity: 0.15,
        fadeStartFraction: 0
    )
    try expect(midSpring.first, equals: NotchGlassStyle.Stop(location: 0, opacity: 1), "mid-spring starts solid")
    try expect(midSpring.last, equals: NotchGlassStyle.Stop(location: 1, opacity: 0.15), "mid-spring keeps the smoked floor")

    // Locations must be non-decreasing and opacities non-increasing at every
    // height or the gradient renders undefined or non-monotonic.
    for height: CGFloat in [1, 32, 38, 60, 98, 150, 158, 354, 720] {
        let stops = NotchGlassStyle.scrimStops(height: height, solidBandHeight: 38)
        let locations = stops.map(\.location)
        try expect(
            locations,
            equals: locations.sorted(),
            "stop locations monotonic at height \(height)"
        )
        let opacities = stops.map(\.opacity)
        try expect(
            opacities,
            equals: opacities.sorted(by: >),
            "stop opacities non-increasing at height \(height)"
        )
    }
}

func testCompactStatusDotRidesEachWingsOuterScreenEdge() throws {
    // The concave notch shoulder (and the pill's capsule end) meets each
    // wing's outer screen-edge: leading on the left, trailing on the right.
    try expect(
        NotchLayout.StatusWingSide.left.outerEdge,
        equals: .leading,
        "left wing outer edge"
    )
    try expect(
        NotchLayout.StatusWingSide.right.outerEdge,
        equals: .trailing,
        "right wing outer edge"
    )
    // The round dot always takes that outer slot so both wings present a
    // round glyph to the shoulder; a flat numeral there looked cramped on
    // the blocked (right) wing.
    try expect(
        StatusIndicatorLayout.forWing(.left).dotEdge,
        equals: .leading,
        "left wing dot rides the leading/outer edge"
    )
    try expect(
        StatusIndicatorLayout.forWing(.right).dotEdge,
        equals: .trailing,
        "right wing dot rides the trailing/outer edge"
    )
}

extension Data {
    func writeAtomically(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write(to: url, options: .atomic)
    }
}

func testBrailleSpinnerCycleCoversEveryFrameExactlyOnce() throws {
    // The layer animation is built from these three values alone: it holds each
    // pre-rendered frame for `stepInterval` and repeats over `cyclePeriod`.
    // Adding or dropping a frame without the period following it stretches or
    // truncates the cycle, so pin that relationship rather than restating 0.8.
    try expect(
        BrailleSpinner.cyclePeriod,
        equals: BrailleSpinner.stepInterval * Double(BrailleSpinner.frames.count),
        "cycle period covers every frame exactly once"
    )
    try expect(
        Set(BrailleSpinner.frames).count,
        equals: BrailleSpinner.frames.count,
        "frames are distinct so the cycle never stutters"
    )
    try expect(BrailleSpinner.frames.first, equals: "⠋", "first frame character")
}

func testBrailleSpinnerFramesAreSingleBraillePatternGlyphs() throws {
    // Frames are rasterized one glyph per image into a fixed 11x11 slot. A
    // multi-scalar or non-braille character would render at a different advance
    // width and make the spinner jitter inside its slot.
    let allBraille = BrailleSpinner.frames.allSatisfy { character in
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(scalar.value)
    }
    try expect(allBraille, equals: true, "every frame is one braille pattern glyph")
}

// A process's executable path and argv are fixed for its lifetime, so the
// scanner reads them once into a ProcessCommand and classifies from that
// snapshot. These cases pin the documented precedence — resolved path first,
// argv[0] second, script path third — because classification is what the
// heartbeat repeats for every process on the machine.

func testAgentToolClassifiesResolvedExecutablePath() throws {
    let classification = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/opt/homebrew/bin/codex",
        leadingArguments: ["codex", "--sandbox"]
    ))
    try expect(classification?.tool, equals: AgentTool.codex, "the executable basename names the tool")
    try expect(
        classification?.viaRuntimeLauncher,
        equals: false,
        "a native binary is not a runtime launcher"
    )
}

func testAgentToolFallsBackToArgumentZeroForVersionedInstalls() throws {
    // ~/.local/bin/claude -> .../claude/versions/2.1.214, where the kernel
    // resolves the symlink and only argv[0] still names the tool.
    let classification = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/Users/someone/.local/share/claude/versions/2.1.214",
        leadingArguments: ["claude"]
    ))
    try expect(classification?.tool, equals: AgentTool.claude, "argv[0] rescues a versioned install")
    try expect(
        classification?.viaRuntimeLauncher,
        equals: false,
        "resolving through argv[0] is not a runtime launch"
    )
}

func testAgentToolClassifiesScriptRuntimeLauncherSkippingFlags() throws {
    let classification = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/opt/homebrew/bin/node",
        leadingArguments: ["node", "--enable-source-maps", "/opt/lib/pi/bin/pi", "chat"]
    ))
    try expect(
        classification?.tool,
        equals: AgentTool.pi,
        "the first non-flag argument after a runtime is the script to classify"
    )
    try expect(
        classification?.viaRuntimeLauncher,
        equals: true,
        "a runtime-launched agent is flagged so its launcher ancestor can be dropped"
    )
}

func testAgentToolRejectsCommandsThatNameNoTool() throws {
    let unrelated = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/bin/zsh",
        leadingArguments: ["-zsh"]
    ))
    try expect(unrelated?.tool, equals: nil, "an ordinary process is not an agent")
    let runtimeWithoutAgentScript = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/opt/homebrew/bin/node",
        leadingArguments: ["node", "/opt/lib/some-other-tool/cli.js"]
    ))
    try expect(
        runtimeWithoutAgentScript?.tool,
        equals: nil,
        "a runtime hosting an unrelated script is not an agent"
    )
    let unreadable = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: nil,
        leadingArguments: []
    ))
    try expect(unreadable?.tool, equals: nil, "a process with no readable command is not an agent")
}

func testAgentToolTakesBasenamesWithoutConsultingTheFilesystem() throws {
    // Basename extraction used to go through URL(fileURLWithPath:), which
    // lstats the path, RFC3986-parses it, and resolves an empty one against
    // the app's working directory. Classification runs over every process on
    // the machine on every heartbeat, so these cases pin the parsing rules
    // that replaced it.
    let bareName = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "codex",
        leadingArguments: []
    ))
    try expect(bareName?.tool, equals: AgentTool.codex, "a bare command name is its own basename")

    let trailingSlash = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/opt/homebrew/bin/claude/",
        leadingArguments: []
    ))
    try expect(
        trailingSlash?.tool,
        equals: AgentTool.claude,
        "a trailing separator does not hide the basename"
    )

    let repeatedSeparators = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/usr//local//bin//pi",
        leadingArguments: []
    ))
    try expect(repeatedSeparators?.tool, equals: AgentTool.pi, "repeated separators collapse")

    let root = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/",
        leadingArguments: []
    ))
    try expect(root?.tool, equals: nil, "the root directory names no tool")

    let empty = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "",
        leadingArguments: []
    ))
    try expect(
        empty?.tool,
        equals: nil,
        "an empty path names no tool rather than resolving against the working directory"
    )

    // The scan walks UTF-8 bytes rather than Characters, so a multi-byte
    // directory name must not be split mid-sequence into a corrupt basename.
    let multiByteAncestor = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/Users/josé/café/bin/codex",
        leadingArguments: []
    ))
    try expect(
        multiByteAncestor?.tool,
        equals: AgentTool.codex,
        "a non-ASCII ancestor directory does not disturb the basename"
    )

    let multiByteName = SystemProcessScanner.agentTool(of: ProcessCommand(
        executablePath: "/opt/bin/códex",
        leadingArguments: []
    ))
    try expect(
        multiByteName?.tool,
        equals: nil,
        "a non-ASCII basename is decoded whole, so it matches no tool instead of a truncation"
    )
}

func testProcessCommandCacheReadsEachProcessGenerationOnce() throws {
    // The heartbeat used to pay four KERN_PROCARGS2 sysctls per process per
    // tick, for every process on the machine. Reading each generation once is
    // the whole point of the cache.
    let cache = ProcessCommandCache()
    let identity = ProcessIdentity(processID: 4242, kernelStartTimeMicroseconds: 1_700_000_000)
    var reads = 0
    func read() -> ProcessCommand {
        reads += 1
        return ProcessCommand(executablePath: "/usr/local/bin/claude", leadingArguments: ["claude"])
    }
    let scan = cache.beginScan()
    let first = cache.command(for: identity, scanToken: scan, read: read)
    let second = cache.command(for: identity, scanToken: scan, read: read)
    try expect(reads, equals: 1, "an immutable command line is read once per process generation")
    try expect(first, equals: second, "the cached snapshot is returned verbatim")
}

func testProcessCommandCacheRereadsRecycledProcessIdentifier() throws {
    let cache = ProcessCommandCache()
    var reads = 0
    func read(path: String) -> ProcessCommand {
        reads += 1
        return ProcessCommand(executablePath: path, leadingArguments: [])
    }
    let scan = cache.beginScan()
    _ = cache.command(
        for: ProcessIdentity(processID: 4242, kernelStartTimeMicroseconds: 1),
        scanToken: scan
    ) {
        read(path: "/bin/zsh")
    }
    let recycled = cache.command(
        for: ProcessIdentity(processID: 4242, kernelStartTimeMicroseconds: 2),
        scanToken: scan
    ) {
        read(path: "/usr/local/bin/claude")
    }
    try expect(reads, equals: 2, "a recycled pid is a different process and must be read again")
    try expect(
        recycled.executablePath,
        equals: "/usr/local/bin/claude",
        "the live generation's command wins over the recycled pid's"
    )
}

func testProcessCommandCacheForgetsProcessesMissingFromLatestScan() throws {
    let cache = ProcessCommandCache()
    let identity = ProcessIdentity(processID: 4242, kernelStartTimeMicroseconds: 1)
    var reads = 0
    func read() -> ProcessCommand {
        reads += 1
        return ProcessCommand(executablePath: "/bin/zsh", leadingArguments: [])
    }
    let seen = cache.beginScan()
    _ = cache.command(for: identity, scanToken: seen, read: read)
    cache.sweep(scanToken: seen) // the scan that saw the process keeps its entry
    cache.sweep(scanToken: cache.beginScan()) // the next scan does not, so the entry goes
    let later = cache.beginScan()
    _ = cache.command(for: identity, scanToken: later, read: read)
    try expect(reads, equals: 2, "entries for vanished processes are dropped instead of accumulating")
}

func testConcurrentStateWritersDoNotInterleave() throws {
    // The write lock exists so a hook process and the app cannot tear each
    // other's directory mutations apart. POSIX record locks are owned per
    // process, so threads inside one process need their own exclusion, and
    // the first descriptor closed drops the file lock for every holder.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let overlap = TestCounter()
    let inFlight = TestCounter()
    // A save materialises its snapshot while holding the lock, so overlapping
    // observer calls are overlapping critical sections.
    let repository = StateRepository(directoryURL: directory) {
        if inFlight.read() != 0 { overlap.increment() }
        inFlight.increment()
        usleep(2_000)
        inFlight.decrement()
    }

    let group = DispatchGroup()
    for index in 0..<8 {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            try? repository.save(AgentSession(
                tool: .claude,
                sessionID: "writer-\(index)",
                pid: Int32(2_000 + index),
                status: .working,
                cwd: "/tmp/writer-\(index)",
                startedAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
    }
    group.wait()

    try expect(overlap.read(), equals: 0, "state writes never overlap inside one process")
    try expect(
        try repository.loadSessions().count,
        equals: 8,
        "every concurrent write landed"
    )
}

func testRemovingASessionTakesTheSameWriteLockAsSaving() throws {
    // save() removes superseded documents while already holding the lock. If
    // remove() re-acquired non-reentrantly it would deadlock; if it closed its
    // own descriptor on the way out it would drop the caller's lock.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let fallback = AgentSession(
        tool: .claude,
        sessionID: "reaper-3100",
        pid: 3_100,
        status: .idle,
        cwd: "/tmp/superseded",
        startedAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 1),
        source: .reaper
    )
    try repository.save(fallback)

    let native = AgentSession(
        tool: .claude,
        sessionID: "native-session",
        pid: 3_100,
        status: .working,
        cwd: "/tmp/superseded",
        startedAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    try repository.save(native)

    try expect(
        try repository.loadSessions().map(\.sessionID),
        equals: ["native-session"],
        "the nested removal ran to completion under one held lock"
    )
}

func testAWedgedForeignLockHolderFailsWritersAtTheDeadline() throws {
    // A holder that is wedged rather than dead would otherwise park every
    // hook process — and with them every agent's turn — behind a blocking
    // lockf. The writer must fail loudly at the deadline instead.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    holder.arguments = [
        "--hold-state-lock",
        root.appendingPathComponent(".moonglade-state-write.lock").path,
        "1200",
    ]
    let holderOutput = Pipe()
    holder.standardOutput = holderOutput
    try holder.run()
    defer {
        holder.terminate()
        holder.waitUntilExit()
    }
    let marker = holderOutput.fileHandleForReading.readData(ofLength: 7)
    try expect(
        String(decoding: marker, as: UTF8.self),
        equals: "locked\n",
        "the foreign process reports the lock as held"
    )

    let defaultTimeout = StateRepository.writeLockAcquisitionTimeout
    StateRepository.writeLockAcquisitionTimeout = 0.3
    defer { StateRepository.writeLockAcquisitionTimeout = defaultTimeout }
    let repository = StateRepository(directoryURL: stateDirectory)
    let session = AgentSession(
        tool: .claude,
        sessionID: "lock-timeout",
        pid: 4_500,
        status: .working,
        cwd: "/tmp/lock-timeout",
        startedAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    let attemptStartedAt = Date()
    var failure: Error?
    do {
        try repository.save(session)
    } catch {
        failure = error
    }

    try expect(
        failure as? StateRepositoryError,
        equals: .writeLockTimeout,
        "a wedged foreign holder surfaces as a timeout, not a hang"
    )
    try expect(
        Date().timeIntervalSince(attemptStartedAt) < 1.0,
        equals: true,
        "the writer gave up at its deadline"
    )

    holder.waitUntilExit()
    try repository.save(session)
    try expect(
        try repository.loadSessions().map(\.sessionID),
        equals: ["lock-timeout"],
        "the same writer succeeds once the holder releases the lock"
    )
}

func testRemovingFromAMissingStateDirectoryIsANoOp() throws {
    // ~/.moonglade may never have existed on this machine. Removal has no
    // documents or overlays to retire, so it must return quietly instead of
    // failing on the lock file's missing parent — or creating anything.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = StateRepository(
        directoryURL: root.appendingPathComponent("state", isDirectory: true)
    )

    try repository.remove(AgentSession(
        tool: .claude,
        sessionID: "never-existed",
        pid: 4_501,
        status: .idle,
        cwd: "/tmp/never-existed",
        startedAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 1)
    ))

    try expect(
        FileManager.default.fileExists(atPath: root.path),
        equals: false,
        "removal creates nothing on the way out"
    )
}

/// Counts descriptors this process currently holds. The directory watchers
/// close theirs from a dispatch source cancel handler, so a watcher that is
/// never cancelled shows up here and nowhere else.
private func openFileDescriptorCount() -> Int {
    var count = 0
    for descriptor in 0..<Int32(getdtablesize()) where Darwin.fcntl(descriptor, F_GETFD) != -1 {
        count += 1
    }
    return count
}

func testReleasingTheSchedulerClosesItsDirectoryWatchers() throws {
    // The scheduler owns O_EVTONLY descriptors on the Codex and Convoy
    // directories. Dropping the last reference has to cancel those sources:
    // a teardown that only schedules work onto the internal queue can never
    // run, because nothing is left to run it for.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stateDirectory = root.appendingPathComponent("state")
    let codexSessions = root.appendingPathComponent("codex-sessions")
    let convoyRuns = root.appendingPathComponent("convoy-runs")
    for directory in [stateDirectory, codexSessions, convoyRuns] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    func runOneSchedulerLifetime() {
        let scheduler = ObservationScheduler(
            repository: StateRepository(directoryURL: stateDirectory),
            processScanner: TestProcessScanner([]),
            codexSessionsDirectoryURL: codexSessions,
            convoyRunsDirectoryURL: convoyRuns,
            heartbeatInterval: 3_600,
            debounceInterval: 0.01
        )
        scheduler.start()
        scheduler.waitUntilIdle()
    }

    // The first lifetime warms every lazily created singleton the scheduler
    // touches, so the baseline measures descriptors and nothing else.
    runOneSchedulerLifetime()
    let baseline = try settledFileDescriptorCount(notExceeding: .max)
    for _ in 0..<5 {
        runOneSchedulerLifetime()
    }

    // A dispatch source closes its descriptor from a cancel handler that runs
    // on the source's own queue, so teardown lands shortly after the release
    // rather than during it. Leaked descriptors never come back.
    try expect(
        try settledFileDescriptorCount(notExceeding: baseline) <= baseline,
        equals: true,
        "a released scheduler leaves no directory watcher descriptor open"
    )
}

/// Samples the descriptor count until it drops to `limit` or a deadline
/// passes, so an asynchronous close is waited for rather than raced.
private func settledFileDescriptorCount(notExceeding limit: Int) throws -> Int {
    let deadline = Date().addingTimeInterval(2)
    var count = openFileDescriptorCount()
    while count > limit, Date() < deadline {
        usleep(20_000)
        count = openFileDescriptorCount()
    }
    return count
}

func testEveryCommandCacheScanEndsWithoutBookkeeping() throws {
    // Per-scan request sets are the cache's only unbounded structure. A scan
    // that ends — swept, superseded, or abandoned — must leave nothing behind,
    // or the bookkeeping outgrows the table it exists to bound.
    let cache = ProcessCommandCache()
    let identity = ProcessIdentity(processID: 4242, kernelStartTimeMicroseconds: 1)
    func read() -> ProcessCommand {
        ProcessCommand(executablePath: "/bin/zsh", leadingArguments: [])
    }
    for _ in 0..<4 {
        let token = cache.beginScan()
        _ = cache.command(for: identity, scanToken: token, read: read)
        cache.sweep(scanToken: token)
    }
    let superseded = cache.beginScan()
    let latest = cache.beginScan()
    cache.sweep(scanToken: superseded)
    cache.sweep(scanToken: latest)
    cache.discardScan(cache.beginScan())

    try expect(cache.trackedScanCount, equals: 0, "no scan bookkeeping outlives its scan")
}

func testAnAbandonedScanDoesNotEvictLiveCommandCacheEntries() throws {
    // A scan that fails before it lists the process table gathered no
    // eviction evidence, so it must defer to the last complete scan rather
    // than dropping entries that scan proved live.
    let cache = ProcessCommandCache()
    let identity = ProcessIdentity(processID: 4242, kernelStartTimeMicroseconds: 1)
    var reads = 0
    func read() -> ProcessCommand {
        reads += 1
        return ProcessCommand(executablePath: "/bin/zsh", leadingArguments: [])
    }
    let complete = cache.beginScan()
    _ = cache.command(for: identity, scanToken: complete, read: read)
    cache.sweep(scanToken: complete)

    cache.discardScan(cache.beginScan())

    let next = cache.beginScan()
    _ = cache.command(for: identity, scanToken: next, read: read)
    try expect(reads, equals: 1, "an abandoned scan evicts nothing")
}

private func orderedTestSession(
    _ sessionID: String,
    updatedAt: TimeInterval = 0
) -> AgentSession {
    AgentSession(
        tool: .claude,
        sessionID: sessionID,
        pid: 1,
        status: .working,
        cwd: "/tmp/\(sessionID)",
        startedAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

func testPinnedSessionOrderPassesThroughBeforeAnythingIsRecorded() throws {
    let order = PinnedSessionOrder()
    let sessions = [orderedTestSession("a"), orderedTestSession("b")]

    try expect(
        order.ordered(sessions).map(\.id),
        equals: ["claude-a", "claude-b"],
        "an empty pin leaves the store's own ordering alone"
    )
}

func testPinnedSessionOrderKeepsRecordedSlotsWhenTheStoreResorts() throws {
    var order = PinnedSessionOrder()
    order.record([orderedTestSession("a"), orderedTestSession("b"), orderedTestSession("c")])

    // The store re-sorts on every hook event: `b` just reported activity and
    // now leads. The open menu must not shuffle underneath the pointer.
    let resorted = [
        orderedTestSession("b", updatedAt: 30),
        orderedTestSession("c", updatedAt: 20),
        orderedTestSession("a", updatedAt: 10),
    ]

    try expect(
        order.ordered(resorted).map(\.id),
        equals: ["claude-a", "claude-b", "claude-c"],
        "recorded slots survive a re-sort of the same sessions"
    )
}

func testPinnedSessionOrderAppendsSessionsItHasNotSeen() throws {
    var order = PinnedSessionOrder()
    order.record([orderedTestSession("a"), orderedTestSession("b")])

    // A brand-new session must still reach the list — appended, so it cannot
    // displace a row the pointer is already resting on.
    let withNewcomer = [
        orderedTestSession("new", updatedAt: 99),
        orderedTestSession("a"),
        orderedTestSession("b"),
    ]

    try expect(
        order.ordered(withNewcomer).map(\.id),
        equals: ["claude-a", "claude-b", "claude-new"],
        "an unrecorded session lands at the end rather than jumping the queue"
    )
}

func testPinnedSessionOrderDropsSessionsThatEnded() throws {
    var order = PinnedSessionOrder()
    order.record([orderedTestSession("a"), orderedTestSession("b"), orderedTestSession("c")])
    order.record([orderedTestSession("a"), orderedTestSession("c")])

    try expect(
        order.ordered([orderedTestSession("a"), orderedTestSession("b"), orderedTestSession("c")])
            .map(\.id),
        equals: ["claude-a", "claude-c", "claude-b"],
        "a session that left the list forfeits its old slot instead of resurrecting into it"
    )
}

func testPinnedSessionOrderRecordingIsAdditiveRatherThanResorting() throws {
    var order = PinnedSessionOrder()
    order.record([orderedTestSession("a"), orderedTestSession("b")])
    // Recording again with a different incoming order must not renumber the
    // slots it already holds; only the newcomer is learned.
    order.record([
        orderedTestSession("c", updatedAt: 40),
        orderedTestSession("b", updatedAt: 30),
        orderedTestSession("a", updatedAt: 20),
    ])

    try expect(
        order.ordered([orderedTestSession("a"), orderedTestSession("b"), orderedTestSession("c")])
            .map(\.id),
        equals: ["claude-a", "claude-b", "claude-c"],
        "learning a new session does not reshuffle the ones already pinned"
    )
}

func testHoverSelectionFollowsThePointerAcrossRows() throws {
    var selection = HoverSelection<String>()
    selection.update("rename", isHovered: true)
    try expect(selection.hovered, equals: "rename", "entering a row selects it")

    selection.update("rename", isHovered: false)
    selection.update("kill", isHovered: true)
    try expect(selection.hovered, equals: "kill", "an orderly hand-off follows the pointer")
}

func testHoverSelectionSurvivesAnExitThatArrivesAfterTheNextEnter() throws {
    // The failure this type exists for. Resizing an animated view replaces its
    // tracking area, so a fast pointer gets the new row's enter before the old
    // row's exit. Independent per-row flags would end up with both rows lit —
    // or, once the late exit lands, with none.
    var selection = HoverSelection<String>()
    selection.update("rename", isHovered: true)
    selection.update("kill", isHovered: true)
    try expect(selection.hovered, equals: "kill", "the newest enter wins")

    selection.update("rename", isHovered: false)
    try expect(
        selection.hovered,
        equals: "kill",
        "a late exit from the row the pointer already left must not clear the highlight"
    )
}

func testHoverSelectionClearsWhenTheSelectedRowExits() throws {
    var selection = HoverSelection<String>()
    selection.update("kill", isHovered: true)
    selection.update("kill", isHovered: false)
    try expect(selection.hovered, equals: nil, "the pointer left the row it was on")
}

func testHoverSelectionDropsEverythingWhenTheListIsReplaced() throws {
    var selection = HoverSelection<String>()
    selection.update("kill", isHovered: true)
    selection.clear()
    try expect(
        selection.hovered,
        equals: nil,
        "swapping the action list out cannot leave a highlight owed to a row that no longer exists"
    )
}

func testActionListHoverGeometryResolvesTheRowUnderThePointer() throws {
    // Enter/exit pairs from animated tracking areas arrive late or out of
    // order; deriving the highlight from the pointer's list-local position on
    // every move cannot lag behind the pointer.
    let width: CGFloat = 200
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 0, listWidth: width, rowCount: 4),
        equals: 0,
        "the list's top edge belongs to the first row"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 31.9, listWidth: width, rowCount: 4),
        equals: 0,
        "the bottom of the first row still highlights it"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 32.5, listWidth: width, rowCount: 4),
        equals: 0,
        "the hairline gap joins the row above it — no dead zones inside the list"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 33, listWidth: width, rowCount: 4),
        equals: 1,
        "crossing the gap hands the highlight to the next row"
    )
    // Four rows of 32 with three 1pt gaps span 131 points.
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 130.9, listWidth: width, rowCount: 4),
        equals: 3,
        "the bottom of the last row still highlights it"
    )
}

func testActionListHoverGeometryRejectsPointsOutsideTheList() throws {
    let width: CGFloat = 200
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: -0.1, listWidth: width, rowCount: 4),
        equals: nil,
        "above the list nothing is highlighted"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 131, listWidth: width, rowCount: 4),
        equals: nil,
        "below the last row nothing is highlighted"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: -1, y: 10, listWidth: width, rowCount: 4),
        equals: nil,
        "left of the list nothing is highlighted"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 200, y: 10, listWidth: width, rowCount: 4),
        equals: nil,
        "the trailing edge is exclusive"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 10, listWidth: width, rowCount: 0),
        equals: nil,
        "an empty list has no rows to highlight"
    )
}

func testInlineActionsClickGateLetsPlainHoverThrough() throws {
    // The whole point: with no button held the catcher must be transparent, or
    // it swallows every hover and click aimed at the row beneath it.
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 0, controlKeyIsDown: false),
        equals: false,
        "a pointer with no button held belongs to the row, not the catcher"
    )
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 0, controlKeyIsDown: true),
        equals: false,
        "holding control without clicking is still just hover"
    )
}

func testInlineActionsClickGateClaimsRightAndControlClicks() throws {
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 1 << 1, controlKeyIsDown: false),
        equals: true,
        "a held right button opens the inline actions"
    )
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 1, controlKeyIsDown: true),
        equals: true,
        "control-click is the trackpad spelling of a right click"
    )
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 1, controlKeyIsDown: false),
        equals: false,
        "a plain left click must reach the focus button underneath"
    )
}

let tests: [(String, () throws -> Void)] = [
    ("notch glass scrim keeps collapsed bar solid and fades expanded", testNotchGlassScrimKeepsCollapsedBarSolidAndFadesExpanded),
    ("compact status dot rides each wing's outer screen edge", testCompactStatusDotRidesEachWingsOuterScreenEdge),
    ("version 1 state document reconstructs session", testVersionOneStateDocumentReconstructsSession),
    ("convoy session decodes current step", testConvoySessionDecodesCurrentStep),
    ("unsupported schema version is rejected", testUnsupportedSchemaVersionIsRejected),
    ("state repository reconstructs sessions from disk", testStateRepositoryReconstructsSessionsFromDisk),
    ("missing state directory loads as empty", testMissingStateDirectoryLoadsAsEmpty),
    ("malformed state does not hide valid sessions", testMalformedStateDoesNotHideValidSessions),
    ("saving session publishes canonical state file", testSavingSessionPublishesCanonicalStateFile),
    ("state files are private and session names do not collide", testStateFilesArePrivateAndSessionNamesDoNotCollide),
    ("state repository ignores symbolic links", testStateRepositoryIgnoresSymbolicLinks),
    ("state repository rejects FIFO without blocking", testStateRepositoryRejectsFIFOWithoutBlocking),
    ("state repository rejects oversized identity document", testStateRepositoryDoesNotPreserveIdentityFromOversizedDocument),
    ("state read tolerates a concurrent atomic replacement", testStateReadToleratesAConcurrentAtomicReplacement),
    ("an unreadable document does not delete a custom session name", testAnUnreadableDocumentDoesNotDeleteACustomSessionName),
    ("an unreadable document does not rearm an acknowledged session", testAnUnreadableDocumentDoesNotRearmAnAcknowledgedSession),
    ("two documents naming the same session produce one row", testTwoDocumentsNamingTheSameSessionProduceOneRow),
    ("merge refuses a hooks value that is not an object", testClaudeSettingsMergeRefusesHooksValueThatIsNotAnObject),
    ("merge refuses an event array containing a non-object", testClaudeSettingsMergeRefusesEventArrayContainingNonObject),
    ("merge preserves unrelated event hooks", testClaudeSettingsMergePreservesUnrelatedEventHooks),
    ("remove refuses malformed shapes and leaves no empty husks", testClaudeSettingsRemoveRefusesMalformedShapesAndLeavesNoEmptyHusks),
    ("first install writes a one-time settings backup", testFirstInstallWritesOneTimeSettingsBackup),
    ("installing through a symlinked settings file writes the target", testInstallingThroughASymlinkedSettingsFileWritesTheTarget),
    ("preparing an already-private directory does not touch its mode", testPreparingAnAlreadyPrivateDirectoryDoesNotTouchItsMode),
    ("Convoy-owned OpenCode documents are not decoded", testConvoyOwnedOpenCodeDocumentsAreNotDecoded),
    ("pruning keeps overlays for Convoy-owned OpenCode sessions", testPruningKeepsOverlaysForConvoyOwnedOpenCodeSessions),
    ("pruning removes overlays with no lifecycle owner", testPruningRemovesOverlaysWithNoLifecycleOwner),
    ("concurrent state writers do not interleave", testConcurrentStateWritersDoNotInterleave),
    ("removing a session takes the same write lock as saving", testRemovingASessionTakesTheSameWriteLockAsSaving),
    ("a wedged foreign lock holder fails writers at the deadline", testAWedgedForeignLockHolderFailsWritersAtTheDeadline),
    ("removing from a missing state directory is a no-op", testRemovingFromAMissingStateDirectoryIsANoOp),
    ("state filename identifier round trips special characters", testStateFilenameIdentifierRoundTripsSpecialCharacters),
    ("a subprocess that never exits is terminated at its deadline", testASubprocessThatNeverExitsIsTerminatedAtItsDeadline),
    ("a subprocess that overfills its pipe still completes", testASubprocessThatOverfillsItsPipeStillCompletes),
    ("an orphan holding the pipe does not turn success into a timeout", testAnOrphanHoldingThePipeDoesNotTurnSuccessIntoATimeout),
    ("the front-terminal query is not repeated within its TTL", testTheFrontTerminalQueryIsNotRepeatedWithinItsTTL),
    ("the heartbeat backs off after a scan finds no agents", testTheHeartbeatBacksOffAfterAScanFindsNoAgents),
    ("the heartbeat returns to five seconds as soon as an agent appears", testTheHeartbeatReturnsToFiveSecondsAsSoonAsAnAgentAppears),
    ("pointer monitors are unnecessary with one display", testPointerMonitorsAreUnnecessaryWithOneDisplay),
    ("the card height budget includes the error row", testTheCardHeightBudgetIncludesTheErrorRow),
    ("a hardware notch with no menu bar still uses notch geometry", testAHardwareNotchWithNoMenuBarStillUsesNotchGeometry),
    ("notch layout supports a secondary display origin", testNotchLayoutSupportsASecondaryDisplayOrigin),
    ("notch layout guards non-finite geometry", testNotchLayoutGuardsNonFiniteGeometry),
    ("AppleScript string escapes every special character", testAppleScriptStringEscapesEverySpecialCharacter),
    ("Claude session start creates idle state", testClaudeSessionStartCreatesIdleState),
    ("Claude session start preserves existing status", testClaudeSessionStartPreservesExistingStatus),
    ("Claude lifecycle update preserves only matching process identity", testClaudeLifecycleUpdatePreservesOnlyMatchingProcessIdentity),
    ("session duration formatter renders compact durations", testSessionDurationFormatterRendersCompactDurations),
    ("Claude permission notification requests attention", testClaudePermissionNotificationRequestsAttention),
    ("Claude PostToolUse clears resolved permission prompt", testClaudePostToolUseClearsResolvedPermissionPrompt),
    ("Claude lifecycle events produce expected states", testClaudeLifecycleEventsProduceExpectedStates),
    ("reaper deletes state for dead process", testReaperDeletesStateForDeadProcess),
    ("reaper drops stale native state when agent is no longer detected", testReaperDropsStaleNativeStateWhenTheAgentIsNoLongerDetected),
    ("reaper rebinds by terminal when several processes share a directory", testReaperRebindsByTerminalWhenSeveralProcessesShareADirectory),
    ("reaper does not rebind across conflicting terminal identities", testReaperDoesNotRebindAcrossConflictingTerminalIdentities),
    ("reaper rejects recycled process identity", testReaperRejectsRecycledProcessIdentity),
    ("reaper treats zombie as dead", testReaperTreatsZombieAsDead),
    ("reaper creates fallback state for untracked process", testReaperCreatesFallbackStateForUntrackedProcess),
    ("reaper skips fallback for process without terminal identity", testReaperSkipsFallbackForProcessWithoutTerminalIdentity),
    ("reaper removes fallback whose process has no terminal identity", testReaperRemovesFallbackWhoseProcessHasNoTerminalIdentity),
    ("reaper creates fallback with terminal host but no tty", testReaperCreatesFallbackWithTerminalHostButNoTTY),
    ("reaper reaps against provided scan", testReaperReapsAgainstProvidedScan),
    ("reaper rebinds daemon-hosted session to visible process", testReaperRebindsDaemonHostedSessionToVisibleProcess),
    ("reaper adopts scanned Ghostty terminal for native session", testReaperAdoptsScannedGhosttyTerminalForNativeSession),
    ("reaper adopts controlling TTY without Ghostty surface", testReaperAdoptsControllingTTYWithoutGhosttySurface),
    ("terminal enrichment preserves concurrent lifecycle write", testTerminalEnrichmentPreservesConcurrentLifecycleWrite),
    ("claude hook captures canonical cmux surface identity", testClaudeHookCapturesCanonicalCmuxSurfaceIdentity),
    ("terminal context persists cmux surface identity under canonical key", testTerminalContextPersistsCmuxSurfaceIdentityUnderCanonicalKey),
    ("terminal enrichment preserves cmux surface identity", testTerminalEnrichmentPreservesCmuxSurfaceIdentity),
    ("terminal enrichment does not replace lifecycle write after reload", testTerminalEnrichmentDoesNotReplaceLifecycleWriteAfterReload),
    ("terminal enrichment rejects concurrent process generation change", testTerminalEnrichmentRejectsConcurrentProcessGenerationChange),
    ("state repository validates and prunes enrichment overlays", testStateRepositoryValidatesAndPrunesEnrichmentOverlays),
    ("terminal enrichment preserves live fallback when Ghostty omits process", testTerminalEnrichmentPreservesLiveFallbackWhenGhosttyOmitsProcess),
    ("agent tool classifies resolved executable path", testAgentToolClassifiesResolvedExecutablePath),
    ("agent tool falls back to argument zero for versioned installs", testAgentToolFallsBackToArgumentZeroForVersionedInstalls),
    ("agent tool classifies script runtime launcher skipping flags", testAgentToolClassifiesScriptRuntimeLauncherSkippingFlags),
    ("agent tool rejects commands that name no tool", testAgentToolRejectsCommandsThatNameNoTool),
    ("agent tool takes basenames without consulting the filesystem", testAgentToolTakesBasenamesWithoutConsultingTheFilesystem),
    ("process command cache reads each process generation once", testProcessCommandCacheReadsEachProcessGenerationOnce),
    ("process command cache rereads recycled process identifier", testProcessCommandCacheRereadsRecycledProcessIdentifier),
    ("process command cache forgets processes missing from latest scan", testProcessCommandCacheForgetsProcessesMissingFromLatestScan),
    ("every command cache scan ends without bookkeeping", testEveryCommandCacheScanEndsWithoutBookkeeping),
    ("an abandoned scan does not evict live command cache entries", testAnAbandonedScanDoesNotEvictLiveCommandCacheEntries),
    ("releasing the scheduler closes its directory watchers", testReleasingTheSchedulerClosesItsDirectoryWatchers),
    ("reaper prunes superseded sessions for same process", testReaperPrunesSupersededSessionsForSameProcess),
    ("reaper prefers native session over newer fallback", testReaperPrefersNativeSessionOverNewerFallback),
    ("observation scheduler tick persists fallback state", testObservationSchedulerTickPersistsFallbackState),
    ("Codex recovery does not authorize historical rollout for replacement process", testCodexRecoveryDoesNotAuthorizeHistoricalRolloutForReplacementProcess),
    ("observation scheduler publishes convoy run on tick", testObservationSchedulerPublishesConvoyRunOnTick),
    ("observation scheduler materializes state once per tick", testObservationSchedulerMaterializesStateOncePerTick),
    ("observation scheduler queues initial reconciliation before recurring work", testObservationSchedulerQueuesInitialReconciliationBeforeRecurringWork),
    ("startup reconciliation completion refreshes store without polling", testStartupReconciliationCompletionRefreshesStoreWithoutPolling),
    ("stopping scheduler suppresses late startup completion", testStoppingSchedulerSuppressesLateStartupCompletion),
    ("observation scheduler reaps immediately when process exits", testObservationSchedulerReapsImmediatelyWhenProcessExits),
    ("observation scheduler coalesces tick bursts", testObservationSchedulerCoalescesTickBursts),
    ("convoy metadata tick reuses last verified process scan", testConvoyMetadataTickReusesLastVerifiedProcessScan),
    ("convoy metadata tick removes superseded run immediately", testConvoyMetadataTickRemovesSupersededRunImmediately),
    ("native state replaces reaper fallback for same process", testNativeStateReplacesReaperFallbackForSameProcess),
    ("debug renderer shows tool counts and session state", testDebugRendererShowsToolCountsAndSessionState),
    ("CLI parses debug command", testCLIParsesDebugCommand),
    ("CLI parses Claude hook command", testCLIParsesClaudeHookCommand),
    ("CLI parses Codex notify command", testCLIParsesCodexNotifyCommand),
    ("capture context emits terminal JSON", testCaptureContextEmitsTerminalJSON),
    ("Claude hook wrapper forwards payload and event", testClaudeHookWrapperForwardsPayloadAndEvent),
    ("state store reload filters ended sessions without writing", testStateStoreReloadFiltersEndedSessionsWithoutWriting),
    ("state store arms notifications before startup baseline mutation", testStateStoreArmsNotificationsBeforeStartupBaselineMutation),
    ("state store polling observes new state files", testStateStorePollingObservesNewStateFiles),
    ("state store file events observe new state files without polling", testStateStoreFileEventsObserveNewStateFilesWithoutPolling),
    ("state store Darwin notification observes new state files", testStateStoreDarwinNotificationObservesNewStateFiles),
    ("state store Darwin notification observes removed state files", testStateStoreDarwinNotificationObservesRemovedStateFiles),
    ("session status summary counts global running waiting and blocked sessions", testSessionStatusSummaryCountsGlobalRunningWaitingAndBlockedSessions),
    ("session status summary visible entries omit zero counts", testSessionStatusSummaryVisibleEntriesOmitsZeroCounts),
    ("session status summary silences acknowledged blocked sessions", testSessionStatusSummarySilencesAcknowledgedBlockedSessions),
    ("idle status indicators use the green dot style", testIdleStatusIndicatorsUseTheGreenDotStyle),
    ("pointer movement gate stays locked until pointer moves", testPointerMovementGateStaysLockedUntilPointerMoves),
    ("pointer samples publish only containment transitions", testPointerSamplesPublishOnlyContainmentTransitions),
    ("hover interaction ignores synthetic exit while pointer remains inside", testHoverInteractionIgnoresSyntheticExitWhilePointerRemainsInside),
    ("hover interaction keeps compact target on visible bar", testHoverInteractionKeepsCompactTargetOnTheVisibleBar),
    ("hover interaction opens whole expanded surface to clicks", testHoverInteractionOpensTheWholeExpandedSurfaceToClicks),
    ("hover interaction uses visible content for hover exit", testHoverInteractionUsesOnlyVisibleContentForHoverExit),
    ("hover interaction does not reexpand from collapsing card", testHoverInteractionDoesNotReexpandFromTheCollapsingCard),
    ("single instance lock excludes bundled and unbundled processes", testSingleInstanceLockExcludesBundledAndUnbundledProcesses),
    ("single instance lock rejects non-regular lock paths", testSingleInstanceLockRejectsNonRegularLockPaths),
    ("notch layout status wing width hides zero count indicators", testNotchLayoutStatusWingWidthHidesZeroCountIndicators),
    ("screen selection follows pointer and falls back to focused display", testScreenSelectionFollowsThePointerAndFallsBackToFocusedDisplay),
    ("focused window frame wins over pointer and default display", testFocusedWindowFrameWinsOverPointerAndDefaultDisplay),
    ("focused window frame uses greatest intersection and stable tie break", testFocusedWindowFrameUsesGreatestIntersectionAndStableTieBreak),
    ("focused window unavailable follows privacy-conscious fallback", testFocusedWindowUnavailableFallsBackWithoutChangingPrivacyPermissions),
    ("screen selection returns every display when configured for all displays", testScreenSelectionReturnsEveryDisplayWhenConfiguredForAllDisplays),
    ("panel synchronization avoids idle polling outside focused mode", testPanelSynchronizationSchedulesNoIdlePollingOutsideFocusedWindowMode),
    ("focused window synchronization uses documented slow fallback", testFocusedWindowSynchronizationUsesOnlyDocumentedSlowFallback),
    ("panel synchronization mode transitions change resources once", testPanelSynchronizationModeTransitionsChangeResourcesExactlyOnce),
    ("attention acknowledgments silence visited sessions", testAttentionAcknowledgmentsSilenceVisitedSessionsUntilNewActivity),
    ("git workspace inspector resolves branch names", testGitWorkspaceInspectorResolvesBranchNames),
    ("Git branch coordinator coalesces and caches working directory", testGitBranchResolutionCoordinatorCoalescesAndCachesWorkingDirectory),
    ("Git branch coordinator bounds concurrent probes", testGitBranchResolutionCoordinatorBoundsConcurrentProbes),
    ("Git branch coordinator evicts least-recent cache entry", testGitBranchResolutionCoordinatorEvictsLeastRecentlyUsedEntry),
    ("notch layout extends from left side of hardware notch", testNotchLayoutExtendsFromLeftSideOfHardwareNotch),
    ("notch layout keeps expanded content close to the side edges", testNotchLayoutKeepsExpandedContentCloseToTheSideEdges),
    ("notch layout pins compact bar to physical notch when panel is clamped", testNotchLayoutPinsCompactBarToPhysicalNotchWhenExpandedPanelIsClamped),
    ("notch layout expanded header wings flank the camera", testNotchLayoutExpandedHeaderWingsFlankTheCamera),
    ("notch layout adds only a minimal fixed right wing", testNotchLayoutAddsOnlyAMinimalFixedRightWing),
    ("notch layout adds only a minimal fixed left wing", testNotchLayoutAddsOnlyAMinimalFixedLeftWing),
    ("notch layout reserves right outer curve clearance for blocked count", testNotchLayoutReservesRightOuterCurveClearanceForBlockedCount),
    ("notch layout uses pill style on notchless screen", testNotchLayoutUsesPillStyleOnNotchlessScreen),
    ("notch layout pill falls back to standard menu bar height", testNotchLayoutPillFallsBackToStandardMenuBarHeight),
    ("notch layout notch keeps screen edge attachment", testNotchLayoutNotchKeepsScreenEdgeAttachment),
    ("hanging notch geometry creates concave shoulders and rounded base", testHangingNotchGeometryCreatesConcaveShouldersAndRoundedBase),
    ("hanging notch geometry keeps expanded sides straight with circular corners", testHangingNotchGeometryKeepsExpandedSidesStraightWithCircularCorners),
    ("bubble geometry rounds every corner and capsules when short", testBubbleGeometryRoundsEveryCornerAndCapsulesWhenShort),
    ("bubble interaction region floats below the top edge", testBubbleInteractionRegionFloatsBelowTheTopEdge),
    ("hover interaction preserves the top gap while expanded", testHoverInteractionPreservesTheTopGapWhileExpanded),
    ("hanging notch metrics share one corner profile across modes", testHangingNotchMetricsShareOneCornerProfileAcrossModes),
    ("session menu layout keeps three expanded sessions out of a scroll view", testSessionMenuLayoutKeepsThreeExpandedSessionsOutOfAScrollView),
    ("hover interaction keeps inline row interactions open during delayed exit", testHoverInteractionKeepsInlineRowInteractionsOpenDuringDelayedExit),
    ("notch layout uses normalized camera clearance", testNotchLayoutUsesNormalizedCameraClearance),
    ("hanging notch interaction region passes transparent corners through", testHangingNotchInteractionRegionPassesTransparentCornersThrough),
    ("notch layout menu card width never cramped in pill mode", testNotchLayoutMenuCardWidthNeverCrampedInPillMode),
    ("opencode plugin writes session state", testOpenCodePluginWritesSessionState),
    ("opencode plugin maps lifecycle events", testOpenCodePluginMapsLifecycleEvents),
    ("pi extension writes session state", testPiExtensionWritesSessionState),
    ("pi extension maps lifecycle events", testPiExtensionMapsLifecycleEvents),
    ("Codex rollout parser maps session and turn events", testCodexRolloutParserMapsSessionAndTurnEvents),
    ("Codex rollout parser ignores malformed and unknown lines", testCodexRolloutParserIgnoresMalformedAndUnknownLines),
    ("Codex sessions watcher processes appended lines incrementally", testCodexSessionsWatcherProcessesAppendedLinesIncrementally),
    ("Codex sessions watcher resaves when process appears later", testCodexSessionsWatcherResavesWhenProcessAppearsLater),
    ("Codex sessions watcher skips date directories outside window", testCodexSessionsWatcherSkipsDateDirectoriesOutsideWindow),
    ("convoy watcher publishes running pipeline step", testConvoyWatcherPublishesRunningPipelineStep),
    ("convoy watcher does not republish unchanged observation", testConvoyWatcherDoesNotRepublishUnchangedObservation),
    ("convoy metadata invalidation reparses only dirty run", testConvoyMetadataInvalidationReparsesOnlyDirtyRun),
    ("convoy watcher flags waiting human gate", testConvoyWatcherFlagsWaitingHumanGate),
    ("convoy watcher maps terminal pipeline states", testConvoyWatcherMapsTerminalPipelineStates),
    ("convoy watcher maps thinking and uses project name", testConvoyWatcherMapsThinkingAndUsesProjectName),
    ("convoy final transition survives immediate process exit once", testConvoyFinalTransitionSurvivesImmediateProcessExitOnce),
    ("convoy metadata observation does not extend heartbeat grace", testConvoyMetadataObservationDoesNotExtendHeartbeatGrace),
    ("convoy watcher retires superseded run for same process generation", testConvoyWatcherRetiresSupersededRunForSameProcessGeneration),
    ("convoy watcher preserves superseded run when replacement cannot persist", testConvoyWatcherPreservesSupersededRunWhenReplacementCannotPersist),
    ("convoy watcher keeps final reads in discovered metadata file", testConvoyWatcherKeepsFinalReadsInDiscoveredMetadataFile),
    ("convoy watcher rejects unsafe metadata file types and sizes", testConvoyWatcherRejectsUnsafeMetadataFileTypesAndSizes),
    ("convoy watcher ignores runs not owned by live process", testConvoyWatcherIgnoresRunsNotOwnedByLiveProcess),
    ("convoy watcher suppresses pipeline-owned opencode sessions", testConvoyWatcherSuppressesPipelineOwnedOpenCodeSessions),
    ("state repository keeps Convoy-owned OpenCode hidden after producer rewrite", testStateRepositoryKeepsConvoyOwnedOpenCodeHiddenAfterProducerRewrite),
    ("Convoy ownership index rejects links and FIFOs without blocking", testConvoyOwnershipIndexRejectsLinksAndFIFOsWithoutBlocking),
    ("corrupt ownership index waits for complete metadata inventory", testCorruptOwnershipIndexWaitsForCompleteMetadataInventory),
    ("incomplete ownership inventory retries without directory change", testIncompleteConvoyOwnershipInventoryRetriesWithoutDirectoryChange),
    ("Convoy ownership watchers are bounded", testConvoyOwnershipWatchersAreBounded),
    ("initial reconciliation indexes serverless Convoy ownership", testInitialReconciliationIndexesServerlessConvoyOwnership),
    ("initial reconciliation watches live Convoy ownership before baseline", testInitialReconciliationWatchesLiveConvoyOwnershipBeforeBaseline),
    ("initial baseline waits for concurrent Convoy metadata", testInitialBaselineWaitsForConcurrentConvoyMetadata),
    ("convoy watcher suppresses embedded server reaper fallback by directory", testConvoyWatcherSuppressesEmbeddedServerReaperFallbackByDirectory),
    ("focus planner prioritizes tmux then terminal", testFocusPlannerPrioritizesTmuxThenTerminal),
    ("focus planner requires one exact Ghostty target", testFocusPlannerRequiresOneExactGhosttyTarget),
    ("focus planner targets cmux by surface identity", testFocusPlannerTargetsCmuxBySurfaceIdentity),
    ("focus planner normalizes iTerm identity and selects its window", testFocusPlannerNormalizesITermIdentityAndSelectsItsWindow),
    ("focus planner rejects empty iTerm identity without TTY", testFocusPlannerRejectsEmptyITermIdentityWithoutTTY),
    ("focus planner matches Terminal TTY exactly and raises its window", testFocusPlannerMatchesTerminalTTYExactlyAndRaisesItsWindow),
    ("Ghostty matcher prefers process and TTY over remembered heuristics", testGhosttyMatcherPrefersProcessAndTTYOverRememberedHeuristics),
    ("Ghostty matcher excludes orphaned processes and assigns exact terminals", testGhosttyMatcherExcludesOrphanedProcessesAndAssignsExactTerminals),
    ("Ghostty matcher prefers same-directory terminal naming the tool", testGhosttyMatcherPrefersSameDirectoryTerminalNamingTheTool),
    ("Ghostty matcher resolves retitled tabs by signature and foreign commands", testGhosttyMatcherResolvesRetitledTabsBySignatureAndForeignCommands),
    ("Ghostty matcher keeps previous assignments across retitles", testGhosttyMatcherKeepsPreviousAssignmentsAcrossRetitles),
    ("Ghostty matcher prefers convoy over its embedded opencode server for last terminal", testGhosttyMatcherPrefersConvoyOverItsEmbeddedOpenCodeServerForLastTerminal),
    ("Ghostty terminal query cache avoids redundant queries", testGhosttyTerminalQueryCacheAvoidsRedundantQueries),
    ("process scanner detects spawned agent process within budget", testProcessScannerDetectsSpawnedAgentProcessWithinBudget),
    ("process scanner ignores lookalike process names", testProcessScannerIgnoresLookalikeProcessNames),
    ("process scanner detects script runtime agents", testProcessScannerDetectsScriptRuntimeAgents),
    ("process scanner collapses runtime launcher onto native child", testProcessScannerCollapsesRuntimeLauncherOntoNativeChild),
    ("process scanner resolves parent of root-owned processes", testProcessScannerResolvesParentOfRootOwnedProcesses),
    ("process scanner identifies host terminal from ancestors", testProcessScannerIdentifiesHostTerminalFromAncestors),
    ("Claude settings merge preserves hooks and is idempotent", testClaudeSettingsMergePreservesHooksAndIsIdempotent),
    ("Claude settings removal preserves user hooks", testClaudeSettingsRemovalPreservesUserHooks),
    ("Claude settings quotes hook paths for the shell", testClaudeSettingsQuotesHookPathsForTheShell),
    ("installer rejects symlinked private directory", testInstallerRejectsSymlinkedPrivateDirectory),
    ("installer follows user-owned symlinked integration directories", testInstallerFollowsUserOwnedSymlinkedIntegrationDirectories),
    ("installer replaces marked integration files on reinstall", testInstallerReplacesMarkedIntegrationFilesOnReinstall),
    ("installer prepends codex notify before existing content", testInstallerPrependsCodexNotifyBeforeExistingContent),
    ("installation doctor reports healthy install", testInstallationDoctorReportsHealthyInstall),
    ("installation doctor diagnoses loose settings permissions", testInstallationDoctorDiagnosesLooseSettingsPermissionsInsteadOfMissingInstall),
    ("installation doctor rejects a foreign codex notify hook", testInstallationDoctorRejectsAForeignCodexNotifyHook),
    ("installation doctor accepts a chained codex notify hook", testInstallationDoctorAcceptsAChainedCodexNotifyHook),
    ("installation doctor reads a codex notify array spanning lines", testInstallationDoctorReadsACodexNotifyArraySpanningLines),
    ("installation doctor reports an absent codex notify key", testInstallationDoctorReportsAnAbsentCodexNotifyKey),
    ("installation doctor pinpoints broken pieces", testInstallationDoctorPinpointsBrokenPieces),
    ("resource bundle search covers every installed layout", testResourceBundleSearchCoversEveryInstalledLayout),
    ("app resource bundle search covers the installed app layout", testAppResourceBundleSearchCoversTheInstalledAppLayout),
    ("installer ships the resource bundle beside the installed binary", testInstallerShipsTheResourceBundleBesideTheInstalledBinary),
    ("installation doctor fails when the resource bundle is missing", testInstallationDoctorFailsWhenTheResourceBundleIsMissing),
    ("CLI parses doctor command", testCLIParsesDoctorCommand),
    ("front terminal matcher matches by ID and falls back to cwd", testFrontTerminalMatcherMatchesByIDAndFallsBackToWorkingDirectory),
    ("hook input rejects oversized payloads", testHookInputRejectsOversizedPayloads),
    ("Codex notify marks turn complete", testCodexNotifyMarksTurnComplete),
    ("session name overrides rename and prune", testSessionNameOverridesRenameAndPrune),
    ("state store rename persists across restarts and prunes", testStateStoreRenamePersistsAcrossRestartsAndPrunesWithSessions),
    ("termination planner closes only exact containers", testTerminationPlannerClosesOnlyExactContainers),
    ("termination service kills politely and escalates to SIGKILL", testTerminationServiceKillsPolitelyAndEscalatesToSigkill),
    ("termination service refuses unverified process", testTerminationServiceRefusesUnverifiedProcess),
    ("braille spinner cycle covers every frame exactly once", testBrailleSpinnerCycleCoversEveryFrameExactlyOnce),
    ("braille spinner frames are single braille pattern glyphs", testBrailleSpinnerFramesAreSingleBraillePatternGlyphs),
    ("session title formatter cleans tab titles", testSessionTitleFormatterCleansTabTitles),
    ("state store display name prefers override then tab title", testStateStoreDisplayNamePrefersOverrideThenTabTitle),
    ("state store clears all session names", testStateStoreClearsAllSessionNames),
    ("state store does not republish unchanged state", testStateStoreDoesNotRepublishUnchangedState),
    ("state store raises attention only on transitions into red", testStateStoreRaisesAttentionOnlyOnTransitionsIntoRed),
    ("state store raises turn completion only from working to idle", testStateStoreRaisesTurnCompletionOnlyFromWorkingToIdle),
    ("pinned session order passes through before anything is recorded", testPinnedSessionOrderPassesThroughBeforeAnythingIsRecorded),
    ("pinned session order keeps recorded slots when the store resorts", testPinnedSessionOrderKeepsRecordedSlotsWhenTheStoreResorts),
    ("pinned session order appends sessions it has not seen", testPinnedSessionOrderAppendsSessionsItHasNotSeen),
    ("pinned session order drops sessions that ended", testPinnedSessionOrderDropsSessionsThatEnded),
    ("pinned session order recording is additive rather than resorting", testPinnedSessionOrderRecordingIsAdditiveRatherThanResorting),
    ("hover selection follows the pointer across rows", testHoverSelectionFollowsThePointerAcrossRows),
    ("hover selection survives an exit that arrives after the next enter", testHoverSelectionSurvivesAnExitThatArrivesAfterTheNextEnter),
    ("hover selection clears when the selected row exits", testHoverSelectionClearsWhenTheSelectedRowExits),
    ("hover selection drops everything when the list is replaced", testHoverSelectionDropsEverythingWhenTheListIsReplaced),
    ("action list hover geometry resolves the row under the pointer", testActionListHoverGeometryResolvesTheRowUnderThePointer),
    ("action list hover geometry rejects points outside the list", testActionListHoverGeometryRejectsPointsOutsideTheList),
    ("inline actions click gate lets plain hover through", testInlineActionsClickGateLetsPlainHoverThrough),
    ("inline actions click gate claims right and control clicks", testInlineActionsClickGateClaimsRightAndControlClicks),
]

if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--load-state-directory" {
    do {
        _ = try StateRepository(
            directoryURL: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        ).loadSessions()
        exit(0)
    } catch {
        exit(1)
    }
} else if CommandLine.arguments.count == 4,
          CommandLine.arguments[1] == "--hold-state-lock" {
    // Child mode for the lock-timeout test: POSIX record locks are held per
    // process, so a wedged foreign holder can only be simulated from outside
    // the test process.
    let descriptor = Darwin.open(
        CommandLine.arguments[2],
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        0o600
    )
    guard descriptor >= 0,
          Darwin.lockf(descriptor, F_LOCK, 0) == 0,
          let holdMilliseconds = UInt32(CommandLine.arguments[3]) else {
        exit(1)
    }
    FileHandle.standardOutput.write(Data("locked\n".utf8))
    usleep(holdMilliseconds * 1_000)
    exit(0)
} else {
    do {
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
    } catch {
        FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
        exit(1)
    }
}
