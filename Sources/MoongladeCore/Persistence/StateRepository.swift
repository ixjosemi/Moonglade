import Foundation
import Darwin

public enum StateRepositoryError: Error, Equatable, Sendable {
    case insecureDirectory
    case concurrentlyReplaced
    case enrichmentTooLarge
    case ownershipIndexTooLarge
    case invalidOwnershipIndex
    case sessionIdentifierTooLong
}

package struct StateSnapshot: Sendable {
    package fileprivate(set) var sessions: [AgentSession]
    package fileprivate(set) var skippedDocumentCount: Int
    fileprivate var lifecycleSessions: [AgentSession]
    fileprivate let convoyOwnedOpenCodeSessionIDs: Set<String>

    fileprivate mutating func upsert(lifecycle: AgentSession, merged: AgentSession) {
        upsert(lifecycle, in: &lifecycleSessions)
        if merged.tool == .opencode,
           convoyOwnedOpenCodeSessionIDs.contains(merged.sessionID) {
            sessions.removeAll { $0.id == merged.id }
        } else {
            upsert(merged, in: &sessions)
        }
    }

    private func upsert(_ session: AgentSession, in sessions: inout [AgentSession]) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
            return
        }
        sessions.append(session)
    }

    fileprivate mutating func remove(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
        lifecycleSessions.removeAll { $0.id == session.id }
    }
}

private struct ConvoyOpenCodeOwnershipDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionIDs = "session_ids"
    }
}

private struct SessionEnrichmentDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let tool: AgentTool
    let sessionID: String
    let lifecyclePID: Int32
    let lifecycleProcessIdentity: ProcessIdentity?
    let lifecycleStartedAt: Date
    let processIdentity: ProcessIdentity
    let terminal: TerminalEnrichmentDocument?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tool
        case sessionID = "session_id"
        case lifecyclePID = "lifecycle_pid"
        case lifecycleProcessIdentity = "lifecycle_process_identity"
        case lifecycleStartedAt = "lifecycle_started_at"
        case processIdentity = "process_identity"
        case terminal
    }
}

private struct TerminalEnrichmentDocument: Codable, Equatable {
    let termProgram: String?
    let ghosttyTerminalID: String?
    let tmuxPane: String?
    let tty: String?
    let windowTitleHint: String?

    enum CodingKeys: String, CodingKey {
        case termProgram = "term_program"
        case ghosttyTerminalID = "ghostty_terminal_id"
        case tmuxPane = "tmux_pane"
        case tty
        case windowTitleHint = "window_title_hint"
    }
}

public struct StateRepository: Sendable {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private static let maximumStateFileSize = 1_048_576
    private static let maximumEnrichmentFileSize = 16_384
    private static let maximumOwnershipIndexFileSize = 16 * 1_048_576
    private static let maximumOwnershipEntryCount = 65_536
    private static let maximumSessionIdentifierBytes = 128
    private static let enrichmentFilePrefix = "enrichment-"
    private static let enrichmentFileExtension = "overlay"
    private static let convoyOwnershipFileName = "convoy-opencode-ownership.index"
    private static let decodedDocumentCounter = LockedCounter()
    package static var documentsDecodedForTesting: Int {
        get { decodedDocumentCounter.value }
        set { decodedDocumentCounter.value = newValue }
    }
    public let directoryURL: URL
    private let materializationObserver: (@Sendable () -> Void)?
    private let reloadObserver: (@Sendable () throws -> Void)?
    package var didReadDocumentForTesting: (@Sendable () -> Void)?

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        materializationObserver = nil
        reloadObserver = nil
        didReadDocumentForTesting = nil
    }

    package init(
        directoryURL: URL,
        materializationObserver: @escaping @Sendable () -> Void
    ) {
        self.directoryURL = directoryURL
        self.materializationObserver = materializationObserver
        reloadObserver = nil
        didReadDocumentForTesting = nil
    }

    package init(
        directoryURL: URL,
        reloadObserver: @escaping @Sendable () throws -> Void
    ) {
        self.directoryURL = directoryURL
        materializationObserver = nil
        self.reloadObserver = reloadObserver
        didReadDocumentForTesting = nil
    }

    public func prepareDirectory() throws {
        try ensurePrivateDirectory()
    }

    public func loadSessions() throws -> [AgentSession] {
        try loadSnapshot().sessions
    }

    package func loadLifecycleSessions() throws -> [AgentSession] {
        try materializeSnapshot(mergingEnrichments: false).lifecycleSessions
    }

    package func loadSnapshot() throws -> StateSnapshot {
        try materializeSnapshot(mergingEnrichments: true)
    }

    private func materializeSnapshot(mergingEnrichments: Bool) throws -> StateSnapshot {
        defer { materializationObserver?() }
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try ensurePrivateDirectory()
        }
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        } catch CocoaError.fileReadNoSuchFile {
            return StateSnapshot(
                sessions: [],
                skippedDocumentCount: 0,
                lifecycleSessions: [],
                convoyOwnedOpenCodeSessionIDs: []
            )
        }
        let convoyOwnedOpenCodeSessionIDs = mergingEnrichments
            ? try loadConvoyOwnedOpenCodeSessionIDs()
            : []
        var decodedSessions: [(session: AgentSession, fileName: String)] = []
        var skippedDocumentCount = 0
        for fileURL in fileURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where fileURL.pathExtension == "json" {
            if mergingEnrichments,
               let encodedID = Self.encodedIdentifierComponent(from: fileURL.lastPathComponent),
               let sessionID = Self.decodedIdentifier(encodedID),
               convoyOwnedOpenCodeSessionIDs.contains(sessionID) {
                continue
            }
            do {
                Self.decodedDocumentCounter.increment()
                decodedSessions.append(
                    (
                        try AgentSession.decode(from: secureDataWithRetry(at: fileURL)),
                        fileURL.lastPathComponent
                    )
                )
                Self.decodeFailureLog.reportSuccess(fileURL.lastPathComponent)
            } catch {
                skippedDocumentCount += 1
                Self.decodeFailureLog.reportOnce(fileURL.lastPathComponent, error: error)
                continue
            }
        }
        var sessionsByID: [String: (session: AgentSession, fileName: String)] = [:]
        for decoded in decodedSessions {
            guard let existing = sessionsByID[decoded.session.id] else {
                sessionsByID[decoded.session.id] = decoded
                continue
            }
            let decodedWins = decoded.session.updatedAt > existing.session.updatedAt
                || (decoded.session.updatedAt == existing.session.updatedAt
                    && decoded.fileName < existing.fileName)
            if decodedWins {
                sessionsByID[decoded.session.id] = decoded
            }
            Self.decodeFailureLog.reportDuplicate(
                decodedWins ? existing.fileName : decoded.fileName
            )
        }
        let lifecycleSessions = sessionsByID.values
            .sorted { $0.fileName > $1.fileName }
            .map(\.session)
        guard mergingEnrichments else {
            return StateSnapshot(
                sessions: lifecycleSessions,
                skippedDocumentCount: skippedDocumentCount,
                lifecycleSessions: lifecycleSessions,
                convoyOwnedOpenCodeSessionIDs: convoyOwnedOpenCodeSessionIDs
            )
        }

        let enrichmentFileNames = Set(
            fileURLs.lazy
                .filter(isRecognizedEnrichmentFile)
                .map(\.lastPathComponent)
        )
        var retainedEnrichmentFileNames: Set<String> = []
        let sessions = lifecycleSessions.map { lifecycle in
            let fileURL: URL
            do {
                fileURL = directoryURL.appendingPathComponent(try enrichmentFileName(for: lifecycle))
            } catch {
                return lifecycle
            }
            guard enrichmentFileNames.contains(fileURL.lastPathComponent) else {
                return lifecycle
            }
            guard let enrichment = loadEnrichment(for: lifecycle, at: fileURL) else {
                return lifecycle
            }
            retainedEnrichmentFileNames.insert(fileURL.lastPathComponent)
            return merging(enrichment, into: lifecycle)
        }
        return StateSnapshot(
            sessions: sessions.filter {
                $0.tool != .opencode
                || !convoyOwnedOpenCodeSessionIDs.contains($0.sessionID)
            },
            skippedDocumentCount: skippedDocumentCount,
            lifecycleSessions: lifecycleSessions,
            convoyOwnedOpenCodeSessionIDs: convoyOwnedOpenCodeSessionIDs
        )
    }

    package func pruneOrphanedEnrichments(against snapshot: StateSnapshot) throws {
        var ownedFileNames = Set(try snapshot.lifecycleSessions.map(enrichmentFileName(for:)))
        // A Convoy-owned OpenCode document is deliberately never decoded, so it
        // cannot appear in the lifecycle list. Its owner is alive all the same:
        // ownership suppresses a phase session from the UI, it does not retire
        // the plugin's document or the overlay bound to it.
        for sessionID in snapshot.convoyOwnedOpenCodeSessionIDs {
            ownedFileNames.insert(
                try enrichmentFileName(tool: .opencode, sessionID: sessionID)
            )
        }
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        } catch CocoaError.fileReadNoSuchFile {
            return
        }
        try withWriteLock {
            for fileURL in fileURLs
                where isRecognizedEnrichmentFile(fileURL)
                    && !ownedFileNames.contains(fileURL.lastPathComponent) {
                var metadata = stat()
                guard Darwin.lstat(fileURL.path, &metadata) == 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard metadata.st_uid == getuid() else {
                    throw StateRepositoryError.insecureDirectory
                }
                if Darwin.unlink(fileURL.path) != 0, errno != ENOENT {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    package func reload(
        _ session: AgentSession,
        updating snapshot: inout StateSnapshot
    ) throws -> AgentSession? {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            snapshot.remove(session)
            return nil
        }
        try ensurePrivateDirectory()
        let fileURL = directoryURL.appendingPathComponent(try fileName(for: session))
        do {
            let lifecycle = try AgentSession.decode(from: secureData(at: fileURL))
            guard lifecycle.id == session.id else {
                snapshot.remove(session)
                return nil
            }
            let enrichmentURL = directoryURL.appendingPathComponent(
                try enrichmentFileName(for: lifecycle)
            )
            let current = loadEnrichment(for: lifecycle, at: enrichmentURL)
                .map { merging($0, into: lifecycle) } ?? lifecycle
            snapshot.upsert(lifecycle: lifecycle, merged: current)
            try reloadObserver?()
            return current
        } catch let error as POSIXError where error.code == .ENOENT {
            snapshot.remove(session)
            return nil
        } catch {
            Self.decodeFailureLog.reportOnce(fileURL.lastPathComponent, error: error)
            snapshot.remove(session)
            return nil
        }
    }

    /// Unreadable documents are skipped so one bad integration cannot blank
    /// the whole UI, but each is reported once per process so the failure
    /// stays diagnosable — reloads run too often to log unconditionally.
    private final class DecodeFailureLog: @unchecked Sendable {
        private static let maximumEntries = 256
        private let lock = NSLock()
        private var reportedFileNames: Set<String> = []

        func reportOnce(_ fileName: String, error: Error) {
            lock.lock()
            defer { lock.unlock() }
            guard reportedFileNames.insert(fileName).inserted else { return }
            if reportedFileNames.count > Self.maximumEntries {
                reportedFileNames.removeFirst()
            }
            NSLog(
                "MOONGLADE_STATE_READ_FAILED: %@ (%@)",
                Self.redactedFileName(fileName),
                String(describing: type(of: error))
            )
        }

        func reportDuplicate(_ fileName: String) {
            NSLog("MOONGLADE_DUPLICATE_STATE: %@", Self.redactedFileName(fileName))
        }

        func reportSuccess(_ fileName: String) {
            lock.lock()
            reportedFileNames.remove(fileName)
            lock.unlock()
        }

        private static func redactedFileName(_ fileName: String) -> String {
            let extensionName = (fileName as NSString).pathExtension
            let prefix = fileName.split(separator: "-", maxSplits: 1).first.map(String.init)
                ?? "state"
            return "\(prefix)-<redacted>.\(extensionName)"
        }
    }

    private static let decodeFailureLog = DecodeFailureLog()

    public func save(_ session: AgentSession) throws {
        try prepareDirectory()
        try withWriteLock {
            var snapshot = try snapshotForSave(of: session)
            try saveLocked(session, updating: &snapshot)
        }
    }

    /// Convoy owns every OpenCode phase session named in its run metadata.
    /// Keep that ownership as an app-owned projection instead of deleting the
    /// plugin's lifecycle document: the plugin can rewrite its file at any
    /// time, while an exact session ID remains owned for its whole lifetime.
    @discardableResult
    package func mergeConvoyOwnedOpenCodeSessionIDs(
        _ sessionIDs: Set<String>,
        allowingInvalidIndexRepair: Bool = false,
        inventoryIsComplete: Bool = false
    ) throws -> Bool {
        try validateOwnershipSessionIDs(sessionIDs)
        try prepareDirectory()
        // Read-modify-write of a single index file: without the lock a
        // concurrent merge reads the same baseline and the later rename wins,
        // silently dropping the other writer's IDs.
        return try withWriteLock {
            try mergeConvoyOwnedOpenCodeSessionIDsLocked(
                sessionIDs,
                allowingInvalidIndexRepair: allowingInvalidIndexRepair,
                inventoryIsComplete: inventoryIsComplete
            )
        }
    }

    private func mergeConvoyOwnedOpenCodeSessionIDsLocked(
        _ sessionIDs: Set<String>,
        allowingInvalidIndexRepair: Bool,
        inventoryIsComplete: Bool
    ) throws -> Bool {
        let existing: Set<String>
        let repairsInvalidIndex: Bool
        do {
            existing = try loadConvoyOwnedOpenCodeSessionIDs()
            repairsInvalidIndex = false
        } catch StateRepositoryError.invalidOwnershipIndex {
            guard allowingInvalidIndexRepair, ownershipIndexCanBeReplaced() else {
                throw StateRepositoryError.invalidOwnershipIndex
            }
            // The inventory is a complete scan of durable Convoy metadata, so
            // an invalid app-owned regular file can be rebuilt safely. Never
            // replace a link, directory, FIFO, or file owned by another user.
            existing = []
            repairsInvalidIndex = true
        }
        let combined = inventoryIsComplete ? sessionIDs : existing.union(sessionIDs)
        guard repairsInvalidIndex || combined != existing else { return false }
        guard combined.count <= Self.maximumOwnershipEntryCount else {
            throw StateRepositoryError.ownershipIndexTooLarge
        }
        let document = ConvoyOpenCodeOwnershipDocument(
            schemaVersion: ConvoyOpenCodeOwnershipDocument.currentSchemaVersion,
            sessionIDs: combined.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumOwnershipIndexFileSize else {
            throw StateRepositoryError.ownershipIndexTooLarge
        }
        let destinationURL = directoryURL.appendingPathComponent(Self.convoyOwnershipFileName)
        try SecureFileWriter.writeAtomically(data, to: destinationURL)
        StateChangeNotifier.post()
        return true
    }

    private func ownershipIndexCanBeReplaced() -> Bool {
        let fileURL = directoryURL.appendingPathComponent(Self.convoyOwnershipFileName)
        var metadata = stat()
        guard Darwin.lstat(fileURL.path, &metadata) == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == getuid()
    }

    private func loadConvoyOwnedOpenCodeSessionIDs() throws -> Set<String> {
        let fileURL = directoryURL.appendingPathComponent(Self.convoyOwnershipFileName)
        let data: Data
        do {
            data = try secureData(
                at: fileURL,
                maximumSize: Self.maximumOwnershipIndexFileSize,
                requiredPermissions: 0o600
            )
        } catch let error as POSIXError where error.code == .ENOENT {
            return []
        } catch StateRepositoryError.insecureDirectory {
            // Wrong mode/size on an owner-controlled regular app file is
            // explicit corruption and can be rebuilt from a complete Convoy
            // inventory. A stable-looking file that merely changed while it
            // was read remains a transient I/O failure and is never replaced.
            var metadata = stat()
            guard Darwin.lstat(fileURL.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == getuid() else {
                throw StateRepositoryError.insecureDirectory
            }
            if metadata.st_mode & 0o7777 != 0o600
                || metadata.st_size < 0
                || metadata.st_size > Self.maximumOwnershipIndexFileSize {
                throw StateRepositoryError.invalidOwnershipIndex
            }
            throw StateRepositoryError.insecureDirectory
        }
        let document: ConvoyOpenCodeOwnershipDocument
        do {
            document = try JSONDecoder().decode(ConvoyOpenCodeOwnershipDocument.self, from: data)
        } catch {
            throw StateRepositoryError.invalidOwnershipIndex
        }
        guard document.schemaVersion == ConvoyOpenCodeOwnershipDocument.currentSchemaVersion,
              document.sessionIDs.count <= Self.maximumOwnershipEntryCount else {
            throw StateRepositoryError.invalidOwnershipIndex
        }
        let sessionIDs = Set(document.sessionIDs)
        guard sessionIDs.count == document.sessionIDs.count else {
            throw StateRepositoryError.invalidOwnershipIndex
        }
        try validateOwnershipSessionIDs(sessionIDs)
        return sessionIDs
    }

    private func validateOwnershipSessionIDs(_ sessionIDs: Set<String>) throws {
        guard sessionIDs.count <= Self.maximumOwnershipEntryCount,
              sessionIDs.allSatisfy({
                  let count = $0.utf8.count
                  return count > 0 && count <= Self.maximumSessionIdentifierBytes
              }) else {
            throw StateRepositoryError.invalidOwnershipIndex
        }
    }

    package func save(_ session: AgentSession, updating snapshot: inout StateSnapshot) throws {
        try prepareDirectory()
        try withWriteLock {
            try saveLocked(session, updating: &snapshot)
        }
    }

    private func snapshotForSave(of session: AgentSession) throws -> StateSnapshot {
        if session.source == .reaper {
            return StateSnapshot(
                sessions: [],
                skippedDocumentCount: 0,
                lifecycleSessions: [],
                convoyOwnedOpenCodeSessionIDs: try loadConvoyOwnedOpenCodeSessionIDs()
            )
        }
        return try loadSnapshot()
    }

    private func saveLocked(_ session: AgentSession, updating snapshot: inout StateSnapshot) throws {
        try prepareDirectory()
        let existingSessions = session.source == .reaper ? [] : snapshot.lifecycleSessions
        let session = preservingProcessIdentity(in: session, from: existingSessions)
        if session.source != .reaper {
            let supersededSessions = existingSessions.filter {
                let isFallback = $0.source == .reaper
                    && $0.tool == session.tool
                    && $0.pid == session.pid
                let isOlderCodexCorrelation = session.tool == .codex
                    && $0.tool == .codex
                    && $0.pid == session.pid
                    && $0.sessionID != session.sessionID
                return isFallback || isOlderCodexCorrelation
            }
            for supersededSession in supersededSessions {
                try remove(supersededSession, updating: &snapshot)
            }
        }
        let destinationURL = directoryURL.appendingPathComponent(try fileName(for: session))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        if let existingData = try? secureData(at: destinationURL), existingData == data {
            snapshot.upsert(lifecycle: session, merged: mergedSession(for: session))
            return
        }
        if session.source != .reaper,
           let existingData = try? secureDataWithRetry(at: destinationURL),
           let existing = try? AgentSession.decode(from: existingData),
           existing.updatedAt > session.updatedAt {
            snapshot.upsert(lifecycle: existing, merged: mergedSession(for: existing))
            return
        }
        try SecureFileWriter.writeAtomically(data, to: destinationURL)
        snapshot.upsert(lifecycle: session, merged: mergedSession(for: session))
        StateChangeNotifier.post()
    }

    private func withWriteLock<Value>(_ body: () throws -> Value) throws -> Value {
        try StateDirectoryWriteLock.forDirectory(directoryURL).withLock(
            at: directoryURL.deletingLastPathComponent()
                .appendingPathComponent(".moonglade-state-write.lock"),
            body
        )
    }

    /// Publishes app-owned process and terminal metadata without replacing the
    /// integration-owned lifecycle document. The sidecar is rebound to the
    /// latest lifecycle bytes immediately before its own independent rename.
    package func saveEnrichment(
        for session: AgentSession,
        process: DetectedAgentProcess,
        terminal: TerminalContext?,
        updating snapshot: inout StateSnapshot
    ) throws -> AgentSession? {
        guard session.source != .reaper,
              process.tool == session.tool,
              process.processID > 0,
              let processIdentity = validatedIdentity(for: process) else {
            return nil
        }
        try prepareDirectory()
        return try withWriteLock {
            try saveEnrichmentLocked(
                for: session,
                processIdentity: processIdentity,
                process: process,
                terminal: terminal,
                updating: &snapshot
            )
        }
    }

    private func saveEnrichmentLocked(
        for session: AgentSession,
        processIdentity: ProcessIdentity,
        process: DetectedAgentProcess,
        terminal: TerminalContext?,
        updating snapshot: inout StateSnapshot
    ) throws -> AgentSession? {
        guard let lifecycle = try loadLifecycleDocument(matching: session) else {
            _ = try removeEnrichment(for: session)
            snapshot.remove(session)
            return nil
        }

        let enrichmentURL = directoryURL.appendingPathComponent(
            try enrichmentFileName(for: lifecycle)
        )
        let existingEnrichment = loadEnrichment(for: lifecycle, at: enrichmentURL)
        let latest = existingEnrichment.map { merging($0, into: lifecycle) } ?? lifecycle
        guard request(session, stillTargets: lifecycle, merged: latest, existingEnrichment) else {
            snapshot.upsert(lifecycle: lifecycle, merged: latest)
            return nil
        }

        let terminalEnrichment: TerminalEnrichmentDocument?
        if let terminal {
            terminalEnrichment = TerminalEnrichmentDocument(
                termProgram: terminal.termProgram,
                ghosttyTerminalID: terminal.ghosttyTerminalID,
                tmuxPane: lifecycle.terminal.tmuxPane == nil ? terminal.tmuxPane : nil,
                tty: lifecycle.terminal.tty == nil ? terminal.tty : nil,
                windowTitleHint: terminal.windowTitleHint
            )
        } else if existingEnrichment?.processIdentity == processIdentity {
            terminalEnrichment = existingEnrichment?.terminal
        } else {
            terminalEnrichment = nil
        }
        let enrichment = SessionEnrichmentDocument(
            schemaVersion: SessionEnrichmentDocument.currentSchemaVersion,
            tool: lifecycle.tool,
            sessionID: lifecycle.sessionID,
            lifecyclePID: lifecycle.pid,
            lifecycleProcessIdentity: lifecycle.processIdentity,
            lifecycleStartedAt: lifecycle.startedAt,
            processIdentity: processIdentity,
            terminal: terminalEnrichment
        )
        let data = try encode(enrichment)
        guard data.count <= Self.maximumEnrichmentFileSize else {
            throw StateRepositoryError.enrichmentTooLarge
        }
        let merged = merging(enrichment, into: lifecycle)
        if let existingData = try? secureData(
            at: enrichmentURL,
            maximumSize: Self.maximumEnrichmentFileSize,
            requiredPermissions: 0o600
        ), existingData == data {
            snapshot.upsert(lifecycle: lifecycle, merged: merged)
            return merged
        }

        try SecureFileWriter.writeAtomically(data, to: enrichmentURL)
        snapshot.upsert(lifecycle: lifecycle, merged: merged)
        StateChangeNotifier.post()
        return merged
    }

    private func preservingProcessIdentity(
        in session: AgentSession,
        from existingSessions: [AgentSession]
    ) -> AgentSession {
        guard session.processIdentity == nil,
              let identity = existingSessions.first(where: {
                  $0.tool == session.tool
                      && $0.sessionID == session.sessionID
                      && $0.pid == session.pid
              })?.processIdentity,
              SystemProcessScanner.processIdentity(of: session.pid) == identity else {
            return session
        }
        return session.replacingProcessIdentity(identity)
    }

    public func remove(_ session: AgentSession) throws {
        let fileURL = directoryURL.appendingPathComponent(try fileName(for: session))
        try withWriteLock {
            var removed = false
            do {
                try FileManager.default.removeItem(at: fileURL)
                removed = true
            } catch CocoaError.fileNoSuchFile {
                // The lifecycle writer may already have removed its document;
                // its app-owned overlay must still be retired.
            }
            if try removeEnrichment(for: session) {
                removed = true
            }
            if removed {
                StateChangeNotifier.post()
            }
        }
    }

    package func remove(_ session: AgentSession, updating snapshot: inout StateSnapshot) throws {
        try remove(session)
        snapshot.remove(session)
    }

    private func loadLifecycleDocument(matching session: AgentSession) throws -> AgentSession? {
        let fileURL = directoryURL.appendingPathComponent(try fileName(for: session))
        do {
            let lifecycle = try AgentSession.decode(from: secureData(at: fileURL))
            return lifecycle.id == session.id ? lifecycle : nil
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        } catch {
            Self.decodeFailureLog.reportOnce(fileURL.lastPathComponent, error: error)
            return nil
        }
    }

    private func mergedSession(for lifecycle: AgentSession) -> AgentSession {
        guard lifecycle.source != .reaper,
              let fileName = try? enrichmentFileName(for: lifecycle) else {
            return lifecycle
        }
        let fileURL = directoryURL.appendingPathComponent(fileName)
        return loadEnrichment(for: lifecycle, at: fileURL)
            .map { merging($0, into: lifecycle) } ?? lifecycle
    }

    private func loadEnrichment(
        for lifecycle: AgentSession,
        at fileURL: URL
    ) -> SessionEnrichmentDocument? {
        do {
            let data = try secureData(
                at: fileURL,
                maximumSize: Self.maximumEnrichmentFileSize,
                requiredPermissions: 0o600
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let enrichment = try decoder.decode(SessionEnrichmentDocument.self, from: data)
            guard enrichmentIsValid(enrichment, for: lifecycle) else {
                return nil
            }
            return enrichment
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        } catch {
            Self.decodeFailureLog.reportOnce(fileURL.lastPathComponent, error: error)
            return nil
        }
    }

    private func enrichmentIsValid(
        _ enrichment: SessionEnrichmentDocument,
        for lifecycle: AgentSession
    ) -> Bool {
        guard enrichment.schemaVersion == SessionEnrichmentDocument.currentSchemaVersion,
              lifecycle.source != .reaper,
              enrichment.tool == lifecycle.tool,
              enrichment.sessionID == lifecycle.sessionID,
              enrichment.lifecyclePID == lifecycle.pid,
              enrichment.lifecycleProcessIdentity == lifecycle.processIdentity,
              enrichment.lifecycleStartedAt == lifecycle.startedAt,
              enrichment.processIdentity.processID > 0 else {
            return false
        }
        if let currentIdentity = SystemProcessScanner.processIdentity(
            of: enrichment.processIdentity.processID
        ) {
            return currentIdentity == enrichment.processIdentity
        }
        return true
    }

    private func merging(
        _ enrichment: SessionEnrichmentDocument,
        into lifecycle: AgentSession
    ) -> AgentSession {
        let terminal: TerminalContext
        if let enriched = enrichment.terminal {
            terminal = TerminalContext(
                termProgram: enriched.termProgram ?? lifecycle.terminal.termProgram,
                ghosttyTerminalID: enriched.ghosttyTerminalID
                    ?? lifecycle.terminal.ghosttyTerminalID,
                // Only the hook observes CMUX_SURFACE_ID; the scanner reads
                // proc_pidinfo and can never recover it, so enrichment must
                // carry the lifecycle value forward rather than drop it.
                cmuxSurfaceID: lifecycle.terminal.cmuxSurfaceID,
                itermSessionID: lifecycle.terminal.itermSessionID,
                tmuxPane: lifecycle.terminal.tmuxPane ?? enriched.tmuxPane,
                tty: lifecycle.terminal.tty ?? enriched.tty,
                windowTitleHint: lifecycle.tool == .convoy
                    ? nil
                    : enriched.windowTitleHint ?? lifecycle.terminal.windowTitleHint
            )
        } else {
            terminal = lifecycle.terminal
        }
        return AgentSession(
            schemaVersion: lifecycle.schemaVersion,
            tool: lifecycle.tool,
            sessionID: lifecycle.sessionID,
            pid: enrichment.processIdentity.processID,
            processIdentity: enrichment.processIdentity,
            status: lifecycle.status,
            attentionReason: lifecycle.attentionReason,
            cwd: lifecycle.cwd,
            startedAt: lifecycle.startedAt,
            updatedAt: lifecycle.updatedAt,
            terminal: terminal,
            source: lifecycle.source,
            currentStep: lifecycle.currentStep
        )
    }

    private func validatedIdentity(for process: DetectedAgentProcess) -> ProcessIdentity? {
        guard let identity = process.processIdentity
                ?? SystemProcessScanner.processIdentity(of: process.processID),
              identity.processID == process.processID else {
            return nil
        }
        if let currentIdentity = SystemProcessScanner.processIdentity(of: process.processID),
           currentIdentity != identity {
            return nil
        }
        return identity
    }

    private func request(
        _ requested: AgentSession,
        stillTargets lifecycle: AgentSession,
        merged latest: AgentSession,
        _ existingEnrichment: SessionEnrichmentDocument?
    ) -> Bool {
        guard requested.id == lifecycle.id,
              requested.startedAt == lifecycle.startedAt else {
            return false
        }
        if requested.pid != lifecycle.pid {
            guard existingEnrichment != nil, requested.pid == latest.pid else {
                return false
            }
        }
        if requested.pid == latest.pid,
           let requestedIdentity = requested.processIdentity,
           let latestIdentity = latest.processIdentity,
           requestedIdentity != latestIdentity {
            return false
        }
        return true
    }

    private func encode(_ enrichment: SessionEnrichmentDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(enrichment)
    }

    private func removeEnrichment(for session: AgentSession) throws -> Bool {
        let fileURL = directoryURL.appendingPathComponent(try enrichmentFileName(for: session))
        var metadata = stat()
        guard Darwin.lstat(fileURL.path, &metadata) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_uid == getuid() else {
            throw StateRepositoryError.insecureDirectory
        }
        guard Darwin.unlink(fileURL.path) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    private func isRecognizedEnrichmentFile(_ fileURL: URL) -> Bool {
        fileURL.pathExtension == Self.enrichmentFileExtension
            && fileURL.lastPathComponent.hasPrefix(Self.enrichmentFilePrefix)
    }

    private func fileName(for session: AgentSession) throws -> String {
        "\(session.tool.rawValue)-\(try encodedIdentifier(for: session)).json"
    }

    private func enrichmentFileName(for session: AgentSession) throws -> String {
        try enrichmentFileName(tool: session.tool, sessionID: session.sessionID)
    }

    private func enrichmentFileName(tool: AgentTool, sessionID: String) throws -> String {
        "\(Self.enrichmentFilePrefix)\(tool.rawValue)-\(try encodedIdentifier(sessionID)).\(Self.enrichmentFileExtension)"
    }

    private func encodedIdentifier(for session: AgentSession) throws -> String {
        try encodedIdentifier(session.sessionID)
    }

    package func encodedIdentifierForTesting(_ sessionID: String) throws -> String {
        try encodedIdentifier(sessionID)
    }

    package func decodedIdentifierForTesting(_ encoded: String) -> String? {
        Self.decodedIdentifier(encoded)
    }

    private func encodedIdentifier(_ sessionID: String) throws -> String {
        let identifierData = Data(sessionID.utf8)
        guard identifierData.count <= Self.maximumSessionIdentifierBytes else {
            throw StateRepositoryError.sessionIdentifierTooLong
        }
        return identifierData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func encodedIdentifierComponent(from fileName: String) -> String? {
        guard fileName.hasPrefix("opencode-"), fileName.hasSuffix(".json") else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: "opencode-".count)
        let end = fileName.index(fileName.endIndex, offsetBy: -".json".count)
        return String(fileName[start..<end])
    }

    private static func decodedIdentifier(_ encoded: String) -> String? {
        guard !encoded.isEmpty,
              encoded.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        let base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64 + padding),
              data.count <= maximumSessionIdentifierBytes,
              let identifier = String(data: data, encoding: .utf8),
              !identifier.isEmpty else { return nil }
        return identifier
    }

    private func ensurePrivateDirectory() throws {
        var metadata = stat()
        if Darwin.lstat(directoryURL.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid() else {
                throw StateRepositoryError.insecureDirectory
            }
        } else if errno == ENOENT {
            var newlyCreated: [URL] = []
            var ancestor = directoryURL
            while Darwin.access(ancestor.path, F_OK) != 0 {
                newlyCreated.append(ancestor)
                ancestor.deleteLastPathComponent()
            }
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            for createdURL in newlyCreated {
                guard Darwin.chmod(createdURL.path, 0o700) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & 0o777 != 0o700 else { return }
        guard Darwin.chmod(directoryURL.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func secureData(
        at fileURL: URL,
        maximumSize: Int = Self.maximumStateFileSize,
        requiredPermissions: mode_t? = nil
    ) throws -> Data {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var initialMetadata = stat()
        guard Darwin.fstat(descriptor, &initialMetadata) == 0,
              isSecureFile(
                  initialMetadata,
                  maximumSize: maximumSize,
                  requiredPermissions: requiredPermissions
              ) else {
            throw StateRepositoryError.insecureDirectory
        }

        var data = Data()
        while data.count <= maximumSize {
            let remaining = maximumSize + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }

        var finalMetadata = stat()
        didReadDocumentForTesting?()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              isSecureFile(
                  finalMetadata,
                  maximumSize: maximumSize,
                  requiredPermissions: requiredPermissions
              ) else {
            throw StateRepositoryError.insecureDirectory
        }
        guard hasSameFingerprint(initialMetadata, finalMetadata),
              data.count <= maximumSize,
              finalMetadata.st_size == data.count else {
            throw StateRepositoryError.concurrentlyReplaced
        }
        return data
    }

    private func secureDataWithRetry(
        at fileURL: URL,
        maximumSize: Int = Self.maximumStateFileSize,
        requiredPermissions: mode_t? = nil
    ) throws -> Data {
        do {
            return try secureData(
                at: fileURL,
                maximumSize: maximumSize,
                requiredPermissions: requiredPermissions
            )
        } catch StateRepositoryError.concurrentlyReplaced {
            return try secureData(
                at: fileURL,
                maximumSize: maximumSize,
                requiredPermissions: requiredPermissions
            )
        }
    }

    private func isSecureFile(
        _ metadata: stat,
        maximumSize: Int,
        requiredPermissions: mode_t?
    ) -> Bool {
        let permissionsAreValid = requiredPermissions.map {
            metadata.st_mode & 0o7777 == $0
        } ?? (metadata.st_mode & 0o022 == 0)
        return metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == getuid()
            && permissionsAreValid
            && metadata.st_size >= 0
            && metadata.st_size <= maximumSize
    }

    private func hasSameFingerprint(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

/// Serialises every mutation of one state directory.
///
/// Two layers are needed because they solve different halves of the problem.
/// The advisory file lock excludes *other* processes: integration hooks run as
/// short-lived CLI invocations while the app is writing. It cannot exclude
/// this process from itself — POSIX record locks are held per process, so
/// every thread acquires immediately, and the first descriptor closed releases
/// the lock for all of them. The recursive mutex covers that half, and its
/// depth count keeps the descriptor open until the outermost caller returns,
/// so a nested write (a save that retires superseded documents) neither
/// deadlocks nor drops the lock its caller is standing on.
///
/// One instance exists per state directory for the lifetime of the process.
/// A process writes to a single directory in production; the registry only
/// grows across the many temporary directories a test run creates.
private final class StateDirectoryWriteLock: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var locksByDirectoryPath: [String: StateDirectoryWriteLock] = [:]

    static func forDirectory(_ directoryURL: URL) -> StateDirectoryWriteLock {
        let key = directoryURL.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locksByDirectoryPath[key] { return existing }
        let created = StateDirectoryWriteLock()
        locksByDirectoryPath[key] = created
        return created
    }

    private let mutex = NSRecursiveLock()
    private var depth = 0
    private var descriptor: Int32 = -1

    func withLock<Value>(at lockURL: URL, _ body: () throws -> Value) throws -> Value {
        mutex.lock()
        defer { mutex.unlock() }
        if depth == 0 {
            try acquireFileLock(at: lockURL)
        }
        depth += 1
        defer {
            depth -= 1
            if depth == 0 { releaseFileLock() }
        }
        return try body()
    }

    private func acquireFileLock(at lockURL: URL) throws {
        let opened = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard opened >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.lockf(opened, F_LOCK, 0) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = Darwin.close(opened)
            throw failure
        }
        descriptor = opened
    }

    private func releaseFileLock() {
        guard descriptor >= 0 else { return }
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }
}
