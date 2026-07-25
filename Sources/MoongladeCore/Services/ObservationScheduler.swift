import Darwin
import Foundation

/// Drives all background observation from a single serial queue: one process
/// scan per liveness tick feeds both the reaper and the Codex sessions watcher,
/// while Convoy-only metadata ticks reuse that verified snapshot. No consumer
/// ever triggers its own process-table scan.
///
/// `start()` and `stop()` must be called on the main thread; every scan and
/// state write runs on the internal serial queue, which also confines the
/// Codex watcher state.
public final class ObservationScheduler {
    private let repository: StateRepository
    private let processScanner: any ProcessScanning
    private let codexSessionsDirectoryURL: URL
    private let convoyRunsDirectoryURL: URL
    private let heartbeatInterval: TimeInterval
    private let debounceInterval: TimeInterval
    private let reaper: ReaperService
    private let workQueue = DispatchQueue(
        label: "com.moonglade.observation",
        qos: .utility
    )
    private var heartbeatTimer: DispatchSourceTimer?

    // Only touched by the documented main-thread lifecycle APIs and by
    // reconciliation completions delivered on main.
    private var lifecycleGeneration = 0

    // Only touched on workQueue.
    private var codexWatcher: CodexSessionsWatcher?
    private var convoyWatcher: ConvoyRunsWatcher?
    private var codexDirectorySource: DispatchSourceFileSystemObject?
    private var convoyRunsDirectorySource: DispatchSourceFileSystemObject?
    private var convoyRunDirectorySources: [URL: DispatchSourceFileSystemObject] = [:]
    private var exitWatchers: [String: DispatchSourceProcess] = [:]
    private var tickScheduled = false
    private var pendingReasons: TickReasons = []
    private var pendingConvoyMetadataURLs: Set<URL> = []
    private var lastVerifiedProcesses: [DetectedAgentProcess]?
    private var generation = 0
    private var convoyMetadataRevision: UInt64 = 0

    private struct TickReasons: OptionSet {
        let rawValue: Int
        static let explicit = TickReasons(rawValue: 1 << 0)
        static let heartbeat = TickReasons(rawValue: 1 << 1)
        static let codexMetadata = TickReasons(rawValue: 1 << 2)
        static let convoyMetadata = TickReasons(rawValue: 1 << 3)
        static let processExit = TickReasons(rawValue: 1 << 4)
    }

    public init(
        repository: StateRepository,
        processScanner: any ProcessScanning = SystemProcessScanner(),
        codexSessionsDirectoryURL: URL? = nil,
        convoyRunsDirectoryURL: URL? = nil,
        heartbeatInterval: TimeInterval = 5,
        debounceInterval: TimeInterval = 0.3
    ) {
        self.repository = repository
        self.processScanner = processScanner
        self.codexSessionsDirectoryURL = codexSessionsDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.convoyRunsDirectoryURL = convoyRunsDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".convoy/runs", isDirectory: true)
        self.heartbeatInterval = heartbeatInterval
        self.debounceInterval = debounceInterval
        reaper = ReaperService(repository: repository, processScanner: processScanner)
    }

    public func start() {
        stop()
        lifecycleGeneration += 1
        requestTick()
        workQueue.async { [weak self] in
            self?.startObservationSources()
        }
    }

    /// Establishes event capture immediately, then reconciles persisted state
    /// before any normal startup or event tick can run on the serial queue.
    public func startWithInitialReconciliation(
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        stop()
        lifecycleGeneration += 1
        let startupGeneration = lifecycleGeneration
        workQueue.async { [weak self] in
            guard let self else { return }
            self.startObservationSources()
            self.refreshConvoyOwnershipIndex()
            do {
                _ = try self.reaper.reap(
                    detected: self.processScanner.basicActiveProcesses()
                )
            } catch {
                NSLog(
                    "Moonglade initial process reconciliation failed: %@",
                    String(describing: error)
                )
            }
            self.finishInitialReconciliationWhenConvoyMetadataIsQuiet(
                startupGeneration: startupGeneration,
                completion: completion
            )
        }
    }

    private func finishInitialReconciliationWhenConvoyMetadataIsQuiet(
        startupGeneration: Int,
        completion: (@MainActor @Sendable () -> Void)?
    ) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let finalizationGeneration = generation
        let inventoryRevision = convoyMetadataRevision
        refreshConvoyOwnershipIndex()
        workQueue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            guard let self, self.generation == finalizationGeneration else { return }
            guard self.convoyMetadataRevision == inventoryRevision else {
                self.finishInitialReconciliationWhenConvoyMetadataIsQuiet(
                    startupGeneration: startupGeneration,
                    completion: completion
                )
                return
            }
            if let completion {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.lifecycleGeneration == startupGeneration else { return }
                    completion()
                }
            }
            self.scheduleCoalescedTick(reason: .explicit)
        }
    }

    public func stop() {
        lifecycleGeneration += 1
        workQueue.async { [self] in
            self.generation += 1
            self.tickScheduled = false
            self.pendingReasons = []
            self.pendingConvoyMetadataURLs = []
            self.lastVerifiedProcesses = nil
            self.codexDirectorySource?.cancel()
            self.codexDirectorySource = nil
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
            self.convoyRunsDirectorySource?.cancel()
            self.convoyRunsDirectorySource = nil
            self.convoyRunDirectorySources.values.forEach { $0.cancel() }
            self.convoyRunDirectorySources.removeAll()
            self.exitWatchers.values.forEach { $0.cancel() }
            self.exitWatchers.removeAll()
        }
    }

    public func requestTick() {
        workQueue.async { [weak self] in self?.scheduleCoalescedTick(reason: .explicit) }
    }

    package func requestConvoyMetadataTick() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.convoyMetadataRevision &+= 1
            self.scheduleCoalescedTick(reason: .convoyMetadata)
        }
    }

    package func requestHeartbeatTick() {
        workQueue.async { [weak self] in self?.scheduleCoalescedTick(reason: .heartbeat) }
    }

    package func waitUntilIdle() {
        workQueue.sync {}
    }

    private func startObservationSources() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        startCodexDirectorySource()
        startConvoyRunsDirectorySource()
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + heartbeatInterval,
            repeating: heartbeatInterval,
            leeway: .milliseconds(Int(heartbeatInterval * 200))
        )
        timer.setEventHandler { [weak self] in self?.scheduleCoalescedTick(reason: .heartbeat) }
        heartbeatTimer = timer
        timer.resume()
    }

    /// Coalesces bursts of tick requests (Codex rollout files receive a write
    /// event per token flush) into one observation per debounce window.
    private func scheduleCoalescedTick(
        reason: TickReasons,
        invalidatedConvoyMetadataURL: URL? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        pendingReasons.formUnion(reason)
        if let invalidatedConvoyMetadataURL {
            pendingConvoyMetadataURLs.insert(invalidatedConvoyMetadataURL)
        }
        guard !tickScheduled else { return }
        tickScheduled = true
        let scheduledGeneration = generation
        workQueue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.tickScheduled = false
            let reasons = self.pendingReasons
            let invalidatedConvoyMetadataURLs = self.pendingConvoyMetadataURLs
            self.pendingReasons = []
            self.pendingConvoyMetadataURLs = []
            self.tick(
                reasons: reasons,
                invalidatedConvoyMetadataURLs: invalidatedConvoyMetadataURLs
            )
        }
    }

    private func tick(
        reasons: TickReasons,
        invalidatedConvoyMetadataURLs: Set<URL>
    ) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        refreshConvoyOwnershipIndex()
        if reasons == .convoyMetadata, let detected = lastVerifiedProcesses {
            tickConvoyMetadata(
                detected: detected,
                invalidatedMetadataURLs: invalidatedConvoyMetadataURLs
            )
            return
        }
        let detected: [DetectedAgentProcess]
        do {
            detected = try processScanner.basicActiveProcesses()
        } catch {
            NSLog("Moonglade process scan failed: %@", String(describing: error))
            return
        }
        lastVerifiedProcesses = detected
        var snapshot: StateSnapshot
        do {
            snapshot = try repository.loadSnapshot()
        } catch {
            NSLog("Moonglade state snapshot failed: %@", String(describing: error))
            return
        }
        let convoyResult = scanConvoyRuns(
            detected: detected,
            isHeartbeat: reasons.contains(.heartbeat),
            invalidatedMetadataURLs: invalidatedConvoyMetadataURLs,
            updatesLiveness: true,
            snapshot: &snapshot
        )
        do {
            _ = try reaper.reap(
                detected: detected,
                preservingSessionIDs: convoyResult?.preservingSessionIDs ?? [],
                snapshot: &snapshot
            )
        } catch {
            NSLog("Moonglade reaper failed: %@", String(describing: error))
        }
        let enriched = processScanner.enrichTerminalContexts(in: detected)
        do {
            try reaper.applyTerminalEnrichment(
                basic: detected,
                enriched: enriched,
                snapshot: &snapshot
            )
        } catch {
            NSLog("Moonglade terminal enrichment failed: %@", String(describing: error))
        }
        refreshCodexWatcher(detected: enriched, snapshot: &snapshot)
            if let convoyResult {
            do {
                try convoyWatcher?.suppressOpenCodeSessions(
                    for: convoyResult,
                    snapshot: &snapshot
                )
            } catch {
                NSLog("Moonglade convoy suppression failed: %@", String(describing: error))
            }
            refreshConvoyRunDirectorySources(
                convoyResult.runDirectoryURLs.union(
                    convoyWatcher?.ownershipWatchDirectoryURLs ?? []
                )
            )
        }
        refreshExitWatchers(detected: detected)
    }

    /// A Convoy vnode event carries metadata, not liveness evidence. Reuse the
    /// most recent generation-aware process scan to map the run, but leave
    /// reaping and heartbeat grace to ticks that perform a fresh scan.
    private func tickConvoyMetadata(
        detected: [DetectedAgentProcess],
        invalidatedMetadataURLs: Set<URL>
    ) {
        var snapshot: StateSnapshot
        do {
            snapshot = try repository.loadSnapshot()
        } catch {
            NSLog("Moonglade state snapshot failed: %@", String(describing: error))
            return
        }
        guard let convoyResult = scanConvoyRuns(
            detected: detected,
            isHeartbeat: false,
            invalidatedMetadataURLs: invalidatedMetadataURLs,
            updatesLiveness: false,
            snapshot: &snapshot
        ) else { return }
        do {
            try convoyWatcher?.suppressOpenCodeSessions(
                for: convoyResult,
                snapshot: &snapshot
            )
        } catch {
            NSLog("Moonglade convoy suppression failed: %@", String(describing: error))
        }
        refreshConvoyRunDirectorySources(
            convoyResult.runDirectoryURLs.union(
                convoyWatcher?.ownershipWatchDirectoryURLs ?? []
            )
        )
    }

    /// Convoy metadata events are primary; the heartbeat remains a backstop
    /// for missed vnode events and drives final-state grace expiration.
    private func scanConvoyRuns(
        detected: [DetectedAgentProcess],
        isHeartbeat: Bool,
        invalidatedMetadataURLs: Set<URL>,
        updatesLiveness: Bool,
        snapshot: inout StateSnapshot
    ) -> ConvoyRunsWatcher.ScanResult? {
        let watcher = convoyWatcher ?? ConvoyRunsWatcher(
            runsDirectoryURL: convoyRunsDirectoryURL,
            repository: repository
        )
        convoyWatcher = watcher
        do {
            return try watcher.observe(
                detected: detected,
                isHeartbeat: isHeartbeat,
                invalidatedMetadataURLs: invalidatedMetadataURLs,
                updatesLiveness: updatesLiveness,
                snapshot: &snapshot
            )
        } catch {
            NSLog("Moonglade convoy watcher failed: %@", String(describing: error))
        }
        return nil
    }

    /// Ownership inventory is independent from process detection: completed
    /// runs clear their server metadata, and an app restart must still know
    /// that their OpenCode phase documents are internal implementation state.
    /// Run this before every state materialization so a plugin rewrite can
    /// never race a snapshot back into the UI.
    private func refreshConvoyOwnershipIndex() {
        let watcher = convoyWatcher ?? ConvoyRunsWatcher(
            runsDirectoryURL: convoyRunsDirectoryURL,
            repository: repository
        )
        convoyWatcher = watcher
        do {
            try watcher.refreshOpenCodeOwnershipIndex()
        } catch {
            NSLog("Moonglade Convoy ownership indexing failed: %@", String(describing: error))
        }
        refreshConvoyRunDirectorySources(watcher.ownershipWatchDirectoryURLs)
    }

    /// Registers a kernel exit notification (EVFILT_PROC) per tracked agent
    /// so a closed terminal disappears on the next debounce window instead of
    /// waiting for the heartbeat. Costs nothing between events. A process
    /// that dies before registration is caught by the heartbeat backstop.
    private func refreshExitWatchers(detected: [DetectedAgentProcess]) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let processesByKey = Dictionary(uniqueKeysWithValues: detected.map {
            (processGenerationKey($0), $0)
        })
        for (key, watcher) in exitWatchers where processesByKey[key] == nil {
            watcher.cancel()
            exitWatchers[key] = nil
        }
        for (key, process) in processesByKey where exitWatchers[key] == nil {
            let watcher = DispatchSource.makeProcessSource(
                identifier: process.processID,
                eventMask: .exit,
                queue: workQueue
            )
            watcher.setEventHandler { [weak self] in self?.scheduleCoalescedTick(reason: .processExit) }
            watcher.resume()
            exitWatchers[key] = watcher
        }
    }

    private func processGenerationKey(_ process: DetectedAgentProcess) -> String {
        if let identity = process.processIdentity {
            return "\(identity.processID)-\(identity.kernelStartTimeMicroseconds)"
        }
        return String(process.processID)
    }

    /// Keeps one long-lived Codex watcher and retargets its process resolver
    /// whenever the set of visible Codex processes changes, then lets it
    /// ingest new rollout lines. Retargeting in place preserves the read
    /// offsets, so a process-table change never re-ingests already-consumed
    /// rollout bytes.
    private func refreshCodexWatcher(
        detected: [DetectedAgentProcess],
        snapshot: inout StateSnapshot
    ) {
        let processesByCWD = Dictionary(grouping: detected.filter { $0.tool == .codex }, by: \.cwd)
        let currentProcesses = processesByCWD.compactMapValues {
            $0.count == 1 ? $0[0] : nil
        }
        let capturedProcesses = currentProcesses
        let resolver: @Sendable (AgentSession) -> DetectedAgentProcess? = {
            capturedProcesses[$0.cwd]
        }
        if let codexWatcher {
            codexWatcher.processResolver = resolver
        } else {
            codexWatcher = CodexSessionsWatcher(
                sessionsDirectoryURL: codexSessionsDirectoryURL,
                repository: repository,
                ingestionWindow: 3600,
                processResolver: resolver
            )
        }
        do {
            try codexWatcher?.scan(snapshot: &snapshot)
        } catch {
            NSLog("Moonglade Codex watcher failed: %@", String(describing: error))
        }
    }

    private func startCodexDirectorySource() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard codexDirectorySource == nil,
              FileManager.default.fileExists(atPath: codexSessionsDirectoryURL.path) else {
            return
        }
        let descriptor = Darwin.open(codexSessionsDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: workQueue
        )
        source.setEventHandler { [weak self] in self?.scheduleCoalescedTick(reason: .codexMetadata) }
        source.setCancelHandler { Darwin.close(descriptor) }
        codexDirectorySource = source
        source.resume()
    }

    private func startConvoyRunsDirectorySource() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard convoyRunsDirectorySource == nil,
              FileManager.default.fileExists(atPath: convoyRunsDirectoryURL.path) else { return }
        let descriptor = Darwin.open(convoyRunsDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: workQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.convoyMetadataRevision &+= 1
            if !source.data.intersection([.rename, .delete]).isEmpty {
                source.cancel()
                self.convoyRunsDirectorySource = nil
            }
            self.scheduleCoalescedTick(reason: .convoyMetadata)
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        convoyRunsDirectorySource = source
        source.resume()
    }

    private func refreshConvoyRunDirectorySources(_ directoryURLs: Set<URL>) {
        for (url, source) in convoyRunDirectorySources where !directoryURLs.contains(url) {
            source.cancel()
            convoyRunDirectorySources[url] = nil
        }
        for url in directoryURLs where convoyRunDirectorySources[url] == nil {
            let descriptor = Darwin.open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: workQueue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.convoyMetadataRevision &+= 1
                if !source.data.intersection([.rename, .delete]).isEmpty {
                    source.cancel()
                    self.convoyRunDirectorySources[url] = nil
                }
                self.scheduleCoalescedTick(
                    reason: .convoyMetadata,
                    invalidatedConvoyMetadataURL: url.appendingPathComponent("metadata.json")
                )
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            convoyRunDirectorySources[url] = source
            source.resume()
        }
        if convoyRunsDirectorySource == nil { startConvoyRunsDirectorySource() }
    }
}
