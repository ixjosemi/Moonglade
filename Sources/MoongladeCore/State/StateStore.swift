import Foundation
import Observation
import Darwin
import CoreFoundation

public struct StateObservationLayers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let darwinNotification = StateObservationLayers(rawValue: 1 << 0)
    public static let fileSystem = StateObservationLayers(rawValue: 1 << 1)
    public static let polling = StateObservationLayers(rawValue: 1 << 2)
    public static let all: StateObservationLayers = [
        .darwinNotification,
        .fileSystem,
        .polling,
    ]
}

private let stateStoreNotificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else { return }
    let store = Unmanaged<StateStore>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { store.scheduleCoalescedReload() }
}

@Observable
public final class StateStore {
    public private(set) var sessions: [AgentSession] = []
    public private(set) var lastErrorDescription: String?
    public private(set) var acknowledgments = AttentionAcknowledgments()
    public private(set) var nameOverrides = SessionNameOverrides()

    /// Invoked from `reload()` with the sessions that just transitioned into
    /// `.needsAttention` — at most once per reload, never on the baseline
    /// load. The app layer hangs the alert chime on it.
    public var onAttentionRaised: (([AgentSession]) -> Void)?

    /// Invoked from `reload()` with the sessions that just went from
    /// `.working` to `.idle` — the agent handed the conversation back. A
    /// session born idle, or leaving `.needsAttention` (the user was already
    /// interacting), announces nothing.
    public var onTurnCompleted: (([AgentSession]) -> Void)?

    private let repository: StateRepository
    private let nameOverridesFileURL: URL?
    // nil until the first reload establishes the baseline.
    private var previousStatusesBySessionID: [String: SessionStatus]?
    private var pollingTimer: Timer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var observesDarwinNotifications = false
    private var isObserving = false
    private var observationGeneration = 0
    private var reloadScheduled = false

    /// The overrides file must live outside the repository's directory: the
    /// store watches that directory for session changes, and the repository
    /// decode-attempts every `.json` in it.
    public init(repository: StateRepository, nameOverridesFileURL: URL? = nil) {
        self.repository = repository
        self.nameOverridesFileURL = nameOverridesFileURL
        if let nameOverridesFileURL,
           let data = try? Data(contentsOf: nameOverridesFileURL),
           let stored = try? JSONDecoder().decode(SessionNameOverrides.self, from: data) {
            nameOverrides = stored
        }
    }

    /// Focus resolves against the latest on-disk lifecycle and enrichment,
    /// rather than the value captured when SwiftUI rendered a row.
    public var stateDirectoryURL: URL { repository.directoryURL }

    /// Reloading is strictly a read: ended sessions are filtered from the UI
    /// but their files stay on disk for the reaper to delete on its own
    /// queue. A reload that writes would re-trigger this store's directory
    /// observation and feed back into itself.
    public func reload() throws {
        let loaded = try repository.loadSessions()
            .filter { $0.status != .ended }
            .sorted(by: Self.precedes)
        publish(loaded, to: \.sessions)
        var prunedAcknowledgments = acknowledgments
        prunedAcknowledgments.prune(keeping: loaded)
        publish(prunedAcknowledgments, to: \.acknowledgments)
        raiseStatusTransitions()
        var prunedOverrides = nameOverrides
        prunedOverrides.prune(keeping: loaded)
        if publish(prunedOverrides, to: \.nameOverrides) {
            persistNameOverrides()
        }
    }

    /// Assigns only when the value actually differs, reporting whether it did.
    ///
    /// Observation invalidates observers on assignment, not on change, and
    /// every hook notification and directory event triggers a reload — most of
    /// which decode state that has not moved. Writing unconditionally rebuilt
    /// the widget's view tree and relaid the notch window for nothing, which
    /// measured as the largest single share of the app's idle CPU.
    @discardableResult
    private func publish<Value: Equatable>(
        _ value: Value,
        to keyPath: ReferenceWritableKeyPath<StateStore, Value>
    ) -> Bool {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    public func sessions(for tool: AgentTool) -> [AgentSession] {
        sessions.filter { $0.tool == tool }
    }

    /// Marks a waiting session as visited so the bar semaphore goes quiet
    /// until the session shows new activity.
    public func acknowledge(_ session: AgentSession) {
        acknowledgments.acknowledge(session)
    }

    /// Renames a session for display; a blank name restores the project name.
    public func rename(_ session: AgentSession, to name: String) {
        nameOverrides.rename(session, to: name)
        persistNameOverrides()
    }

    /// Row title precedence: a manual rename always wins, then the cleaned
    /// live tab title (the reaper refreshes `windowTitleHint` from the
    /// Ghostty scan each tick), then the directory name.
    private func raiseStatusTransitions() {
        let statusesBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0.status) }
        )
        defer { previousStatusesBySessionID = statusesBySessionID }
        guard let previousStatusesBySessionID else { return }
        let newlyRaised = sessions.filter {
            $0.status == .needsAttention
                && previousStatusesBySessionID[$0.id] != .needsAttention
        }
        if !newlyRaised.isEmpty {
            onAttentionRaised?(newlyRaised)
        }
        let newlyCompleted = sessions.filter {
            $0.status == .idle && previousStatusesBySessionID[$0.id] == .working
        }
        if !newlyCompleted.isEmpty {
            onTurnCompleted?(newlyCompleted)
        }
    }

    /// Drops every custom session name, in memory and on disk — the reset
    /// offered from Settings.
    public func clearAllSessionNames() {
        nameOverrides = SessionNameOverrides()
        persistNameOverrides()
    }

    public func displayName(for session: AgentSession) -> String {
        nameOverrides.displayName(for: session)
            ?? SessionTitleFormatter.rowTitle(
                tabTitle: session.terminal.windowTitleHint,
                fallback: session.projectName
            )
    }

    /// Persistence failures only cost the custom names on the next launch;
    /// they must never take down reload or rename, so they are logged and
    /// swallowed here.
    private func persistNameOverrides() {
        guard let nameOverridesFileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(nameOverrides).write(to: nameOverridesFileURL, options: .atomic)
        } catch {
            NSLog(
                "Moonglade could not persist session names: %@",
                String(describing: error)
            )
        }
    }

    public func startObserving(
        pollInterval: TimeInterval? = 5,
        layers: StateObservationLayers = .all
    ) throws {
        stopObserving()
        try repository.prepareDirectory()
        isObserving = true
        do {
            // Arm event capture before reading the baseline. A write during
            // that read is then either present in the snapshot or schedules a
            // follow-up reload; there is no unobserved gap between the two.
            if layers.contains(.darwinNotification) {
                startDarwinObservation()
            }
            if layers.contains(.fileSystem) {
                try startDirectoryObservation()
            }
            try reload()
            if layers.contains(.polling), let pollInterval {
                let pollingGeneration = observationGeneration
                let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
                    [weak self] _ in
                    guard let self,
                          self.isObserving,
                          self.observationGeneration == pollingGeneration else { return }
                    self.reloadRecordingError()
                }
                // Polling is only a safety net behind the event-driven layers;
                // tolerance lets the kernel coalesce the wakeup with other timers.
                timer.tolerance = pollInterval / 5
                pollingTimer = timer
            }
        } catch {
            stopObserving()
            throw error
        }
    }

    public func stopObserving() {
        observationGeneration += 1
        isObserving = false
        reloadScheduled = false
        pollingTimer?.invalidate()
        pollingTimer = nil
        directorySource?.cancel()
        directorySource = nil
        if observesDarwinNotifications {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(StateChangeNotifier.notificationName as CFString),
                nil
            )
            observesDarwinNotifications = false
        }
    }

    private func startDarwinObservation() {
        guard !observesDarwinNotifications else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            stateStoreNotificationCallback,
            StateChangeNotifier.notificationName as CFString,
            nil,
            .deliverImmediately
        )
        observesDarwinNotifications = true
    }

    private func startDirectoryObservation() throws {
        guard directorySource == nil else { return }
        let descriptor = Darwin.open(repository.directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleCoalescedReload() }
        source.setCancelHandler { Darwin.close(descriptor) }
        directorySource = source
        source.resume()
    }

    /// Coalesces bursts of directory events into one reload per 150ms window
    /// so that an aggressive writer — another process, or a misbehaving
    /// integration — can never storm the main thread with reloads.
    fileprivate func scheduleCoalescedReload() {
        guard isObserving, !reloadScheduled else { return }
        reloadScheduled = true
        let scheduledGeneration = observationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.isObserving,
                  self.observationGeneration == scheduledGeneration else { return }
            self.reloadScheduled = false
            self.reloadRecordingError()
        }
    }

    package func reloadRecordingError() {
        do {
            try reload()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = String(describing: error)
        }
    }

    private static func precedes(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        let rank: [SessionStatus: Int] = [.needsAttention: 0, .working: 1, .idle: 2, .ended: 3]
        let leftRank = rank[lhs.status, default: 3]
        let rightRank = rank[rhs.status, default: 3]
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}
