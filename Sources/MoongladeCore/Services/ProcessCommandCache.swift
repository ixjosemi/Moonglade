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
public final class ProcessCommandCache: @unchecked Sendable {
    private let lock = NSLock()
    private var commandsByIdentity: [ProcessIdentity: ProcessCommand] = [:]
    private var requestedIdentities: Set<ProcessIdentity> = []

    public init() {}

    /// Returns the remembered command line for `identity`, reading it once on
    /// first sight. `read` runs outside the lock: it performs syscalls, and a
    /// duplicated read is cheaper than serializing every caller behind one.
    public func command(
        for identity: ProcessIdentity,
        read: () -> ProcessCommand
    ) -> ProcessCommand {
        lock.lock()
        requestedIdentities.insert(identity)
        let cached = commandsByIdentity[identity]
        lock.unlock()
        if let cached { return cached }
        let command = read()
        lock.lock()
        commandsByIdentity[identity] = command
        lock.unlock()
        return command
    }

    /// Drops every entry not requested since the previous sweep, bounding the
    /// table by the size of the live process table. Callers sweep once per
    /// completed scan, so an entry survives exactly as long as scans keep
    /// asking about it. A scan that fails partway defers eviction to the next
    /// successful one rather than discarding still-live entries.
    public func sweep() {
        lock.lock()
        commandsByIdentity = commandsByIdentity.filter { requestedIdentities.contains($0.key) }
        requestedIdentities.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
