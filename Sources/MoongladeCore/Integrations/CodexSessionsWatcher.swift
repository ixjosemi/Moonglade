import Foundation

/// Tails Codex rollout files and publishes the sessions they describe.
/// The watcher is long-lived: read offsets persist across scans, so each
/// scan only consumes newly appended bytes.
public final class CodexSessionsWatcher {
    private static let readChunkSize = 65_536
    private static let maximumLineSize = 1_048_576
    private static let futureTimestampTolerance: TimeInterval = 5
    private let sessionsDirectoryURL: URL
    private let repository: StateRepository
    /// Offers the sole visible process that may own a parsed session. The
    /// watcher still verifies that rollout activity occurred during that
    /// process generation before granting the session its kernel identity.
    public var processResolver: @Sendable (AgentSession) -> DetectedAgentProcess?
    private let ingestionWindow: TimeInterval?
    private var offsets: [URL: UInt64] = [:]
    private var buffers: [URL: Data] = [:]
    private var parsers: [URL: CodexRolloutParser] = [:]
    private var pendingSessions: [URL: AgentSession] = [:]

    public init(
        sessionsDirectoryURL: URL,
        repository: StateRepository,
        processID: Int32,
        ingestionWindow: TimeInterval? = nil
    ) {
        self.sessionsDirectoryURL = sessionsDirectoryURL
        self.repository = repository
        processResolver = { session in
            guard let identity = SystemProcessScanner.processIdentity(of: processID) else {
                return nil
            }
            return DetectedAgentProcess(
                tool: .codex,
                processID: processID,
                processIdentity: identity,
                cwd: session.cwd,
                terminal: TerminalContext()
            )
        }
        self.ingestionWindow = ingestionWindow
    }

    public init(
        sessionsDirectoryURL: URL,
        repository: StateRepository,
        ingestionWindow: TimeInterval? = nil,
        processResolver: @escaping @Sendable (AgentSession) -> DetectedAgentProcess?
    ) {
        self.sessionsDirectoryURL = sessionsDirectoryURL
        self.repository = repository
        self.processResolver = processResolver
        self.ingestionWindow = ingestionWindow
    }

    public func scan() throws {
        try scan { try repository.save($0) }
    }

    package func scan(snapshot: inout StateSnapshot) throws {
        try scan { try repository.save($0, updating: &snapshot) }
    }

    private func scan(saveSession: (AgentSession) throws -> Void) throws {
        let cutoff = ingestionWindow.map { Date().addingTimeInterval(-$0) }
        let fileURLs = try rolloutFileURLs(cutoff: cutoff)
        for fileURL in fileURLs {
            try consumeNewData(from: fileURL, saveSession: saveSession)
        }
        try publishPendingSessions(saveSession: saveSession)
        pruneFileState(keeping: Set(fileURLs))
    }

    /// Rollout files age out of the ingestion window and normally never
    /// return; their read state would otherwise accumulate for the lifetime
    /// of the app. The rare file that does come back — a session resumed
    /// after a long pause — is re-ingested from the start.
    private func pruneFileState(keeping fileURLs: Set<URL>) {
        offsets = offsets.filter { fileURLs.contains($0.key) }
        buffers = buffers.filter { fileURLs.contains($0.key) }
        parsers = parsers.filter { fileURLs.contains($0.key) }
        pendingSessions = pendingSessions.filter { fileURLs.contains($0.key) }
    }

    /// Sessions parsed while their process was not yet visible are retried
    /// on every scan: the resolver may have been retargeted since, and the
    /// rollout bytes that described them were already consumed.
    private func publishPendingSessions(
        saveSession: (AgentSession) throws -> Void
    ) throws {
        for (fileURL, session) in pendingSessions {
            guard let process = verifiedProcess(for: session, rolloutURL: fileURL) else { continue }
            try saveSession(session.replacingProcess(process))
            pendingSessions[fileURL] = nil
        }
    }

    /// A rollout path and its contents are untrusted. CWD narrows candidates,
    /// but only activity written during the scanned kernel generation is
    /// enough to bind a session and make it actionable.
    private func verifiedProcess(
        for session: AgentSession,
        rolloutURL: URL
    ) -> DetectedAgentProcess? {
        guard let process = processResolver(session),
              process.tool == .codex,
              process.cwd == session.cwd,
              process.processID > 0,
              let identity = process.processIdentity,
              identity.processID == process.processID,
              let modificationDate = try? rolloutURL.resourceValues(
                  forKeys: [.contentModificationDateKey]
              ).contentModificationDate else {
            return nil
        }
        let processStartedAt = Date(
            timeIntervalSince1970: TimeInterval(identity.kernelStartTimeMicroseconds) / 1_000_000
        )
        guard session.updatedAt >= processStartedAt,
              session.updatedAt <= Date().addingTimeInterval(Self.futureTimestampTolerance),
              modificationDate >= processStartedAt else {
            return nil
        }
        return process
    }

    private func rolloutFileURLs(cutoff: Date?) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ]
        ) else {
            return []
        }
        var fileURLs: [URL] = []
        while let element = enumerator.nextObject() {
            guard let url = element as? URL,
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .isDirectoryKey,
                      .isSymbolicLinkKey,
                      .contentModificationDateKey,
                  ]) else {
                continue
            }
            if values.isDirectory == true {
                if let cutoff,
                   Self.datePeriodEndsBeforeCutoff(url, root: sessionsDirectoryURL, cutoff: cutoff) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == "jsonl",
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            if let cutoff,
               let modificationDate = values.contentModificationDate,
               modificationDate < cutoff {
                continue
            }
            fileURLs.append(url)
        }
        return fileURLs.sorted { $0.path < $1.path }
    }

    /// Codex stores rollouts under date-named directories (YYYY/MM/DD). A
    /// directory whose date period ends before the cutoff cannot contain
    /// in-window rollouts, so its whole subtree is skipped without visiting
    /// it — the tree grows without bound and file mtimes alone would still
    /// cost one stat per file. Names that do not parse as date components
    /// are always traversed.
    private static func datePeriodEndsBeforeCutoff(
        _ directoryURL: URL,
        root: URL,
        cutoff: Date
    ) -> Bool {
        let components = directoryURL.pathComponents.dropFirst(root.pathComponents.count)
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count, (1...3).contains(numbers.count) else {
            return false
        }
        var dateComponents = DateComponents()
        dateComponents.year = numbers[0]
        dateComponents.month = numbers.count >= 2 ? numbers[1] : 1
        dateComponents.day = numbers.count >= 3 ? numbers[2] : 1
        let calendar = Calendar.current
        let period: Calendar.Component = switch numbers.count {
        case 1: .year
        case 2: .month
        default: .day
        }
        guard let periodStart = calendar.date(from: dateComponents),
              let periodEnd = calendar.date(byAdding: period, value: 1, to: periodStart) else {
            return false
        }
        return periodEnd < cutoff
    }

    private func consumeNewData(
        from fileURL: URL,
        saveSession: (AgentSession) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let previousOffset = offsets[fileURL, default: 0]
        if size < previousOffset {
            reset(fileURL)
        }
        let offset = offsets[fileURL, default: 0]
        try handle.seek(toOffset: offset)
        while let data = try handle.read(upToCount: Self.readChunkSize), !data.isEmpty {
            offsets[fileURL, default: offset] += UInt64(data.count)
            buffers[fileURL, default: Data()].append(data)
            try consumeCompleteLines(for: fileURL, saveSession: saveSession)
            if buffers[fileURL, default: Data()].count > Self.maximumLineSize {
                buffers[fileURL] = Data()
            }
        }
    }

    private func consumeCompleteLines(
        for fileURL: URL,
        saveSession: (AgentSession) throws -> Void
    ) throws {
        var buffer = buffers[fileURL, default: Data()]
        var parser = parsers[fileURL] ?? CodexRolloutParser(processID: 0)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            if line.count <= Self.maximumLineSize,
               let session = parser.consume(line: Data(line)) {
                if let process = verifiedProcess(for: session, rolloutURL: fileURL) {
                    try saveSession(session.replacingProcess(process))
                    pendingSessions[fileURL] = nil
                } else {
                    pendingSessions[fileURL] = session
                }
            }
        }
        buffers[fileURL] = buffer
        parsers[fileURL] = parser
    }

    private func reset(_ fileURL: URL) {
        offsets[fileURL] = 0
        buffers[fileURL] = Data()
        parsers[fileURL] = CodexRolloutParser(processID: 0)
        pendingSessions[fileURL] = nil
    }
}
