import Foundation

/// The command line of one process generation: the kernel-resolved executable
/// path and the leading argv strings. Both are fixed for the lifetime of a
/// process, which is what makes them safe to remember.
public struct ProcessCommand: Equatable, Sendable {
    public let executablePath: String?
    /// Up to the first few argv entries, empty when argv is unreadable —
    /// KERN_PROCARGS2 only serves the current user's processes.
    public let leadingArguments: [String]

    public init(executablePath: String?, leadingArguments: [String]) {
        self.executablePath = executablePath
        self.leadingArguments = leadingArguments
    }
}

/// Remembers each process generation's command line so the observation
/// heartbeat can classify the process table without re-reading it.
///
/// One read costs a `proc_pidpath` call plus a pair of `KERN_PROCARGS2`
/// sysctls, and the kernel faults in the target's argument region to serve
/// the second. The heartbeat asks about every process on the machine, so
/// paying that on every tick dominated idle CPU; paying it once per process
/// generation makes a steady-state tick nearly free.
///
/// Entries are keyed by `ProcessIdentity`, so a recycled pid misses the cache
/// instead of inheriting the dead process's command line.
/// Every lookup belongs to a scan. `beginScan` opens the bookkeeping, each
/// `command(for:scanToken:read:)` records that the scan still cares about an
/// identity, and exactly one of `sweep(scanToken:)` or `discardScan` closes it.
/// A scan that ends by neither route keeps its request set alive for the
/// lifetime of the process, so callers must always close what they open.
public final class ProcessCommandCache: @unchecked Sendable {
    private let lock = NSLock()
    private var commandsByIdentity: [ProcessIdentity: ProcessCommand] = [:]
    private var requestedIdentitiesByScan: [UUID: Set<ProcessIdentity>] = [:]
    private var generationByScan: [UUID: UInt64] = [:]
    private var latestScanGeneration: UInt64 = 0

    public init() {}

    /// Scans open for testing and diagnostics: this is zero whenever no scan
    /// is in flight, which is the invariant that bounds the bookkeeping.
    package var trackedScanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestedIdentitiesByScan.count
    }

    public func beginScan() -> UUID {
        let token = UUID()
        lock.lock()
        latestScanGeneration &+= 1
        requestedIdentitiesByScan[token] = []
        generationByScan[token] = latestScanGeneration
        lock.unlock()
        return token
    }

    /// Returns the remembered command line for `identity`, reading it once on
    /// first sight. `read` runs outside the lock: it performs syscalls, and a
    /// duplicated read is cheaper than serializing every caller behind one.
    public func command(
        for identity: ProcessIdentity,
        scanToken: UUID,
        read: () -> ProcessCommand
    ) -> ProcessCommand {
        lock.lock()
        requestedIdentitiesByScan[scanToken, default: []].insert(identity)
        let cached = commandsByIdentity[identity]
        lock.unlock()
        if let cached { return cached }
        let command = read()
        lock.lock()
        commandsByIdentity[identity] = command
        lock.unlock()
        return command
    }

    /// Drops every entry the scan did not ask about, bounding the table by the
    /// size of the live process table. An entry survives exactly as long as
    /// scans keep asking about it. Only the newest scan carries a complete
    /// view, so a superseded token releases its bookkeeping without evicting.
    public func sweep(scanToken: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let isLatestScan = generationByScan[scanToken] == latestScanGeneration
        generationByScan.removeValue(forKey: scanToken)
        guard let requestedIdentities = requestedIdentitiesByScan.removeValue(forKey: scanToken),
              isLatestScan else {
            return
        }
        commandsByIdentity = commandsByIdentity.filter { requestedIdentities.contains($0.key) }
    }

    /// Releases a scan's bookkeeping without evicting anything. A scan that
    /// failed partway never gathered the evidence eviction needs, so it defers
    /// to the last scan that completed rather than discarding live entries.
    public func discardScan(_ scanToken: UUID) {
        lock.lock()
        requestedIdentitiesByScan.removeValue(forKey: scanToken)
        generationByScan.removeValue(forKey: scanToken)
        lock.unlock()
    }
}
