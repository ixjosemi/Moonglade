import Darwin
import Foundation

public struct DetectedAgentProcess: Equatable, Sendable {
    public let tool: AgentTool
    public let processID: Int32
    public let processIdentity: ProcessIdentity?
    public let cwd: String
    public let terminal: TerminalContext
    public let elapsedSeconds: TimeInterval

    public init(
        tool: AgentTool,
        processID: Int32,
        processIdentity: ProcessIdentity? = nil,
        cwd: String,
        terminal: TerminalContext,
        elapsedSeconds: TimeInterval = .greatestFiniteMagnitude
    ) {
        self.tool = tool
        self.processID = processID
        self.processIdentity = processIdentity
        self.cwd = cwd
        self.terminal = terminal
        self.elapsedSeconds = elapsedSeconds
    }
}

public protocol ProcessScanning: Sendable {
    func activeProcesses() throws -> [DetectedAgentProcess]
    func basicActiveProcesses() throws -> [DetectedAgentProcess]
    func enrichTerminalContexts(in processes: [DetectedAgentProcess]) -> [DetectedAgentProcess]
}

public extension ProcessScanning {
    func basicActiveProcesses() throws -> [DetectedAgentProcess] { try activeProcesses() }
    func enrichTerminalContexts(in processes: [DetectedAgentProcess]) -> [DetectedAgentProcess] { processes }
}

public struct SystemProcessScanner: ProcessScanning {
    /// Returns the currently visible Ghostty terminals, or nil when Ghostty
    /// cannot be queried. Injectable so behavioral tests stay deterministic.
    public typealias GhosttyTerminalSource = @Sendable () -> [GhosttyTerminal]?

    private let terminalQueryCache: GhosttyTerminalQueryCache
    private let assignmentMemory = GhosttyAssignmentMemory()

    public init() {
        // The 10 s failure cooldown skips at least one 5 s heartbeat after a
        // timeout while allowing a prompt retry; topology changes still refresh.
        self.init(terminalQueryCache: GhosttyTerminalQueryCache(
            timeToLive: 30,
            failureTimeToLive: 10
        ) {
            try? SystemProcessScanner.queryGhosttyTerminals()
        })
    }

    /// Zero TTLs preserve the injected source's call-per-scan semantics.
    public init(ghosttyTerminalSource: @escaping GhosttyTerminalSource) {
        self.init(terminalQueryCache: GhosttyTerminalQueryCache(
            timeToLive: 0,
            failureTimeToLive: 0,
            query: ghosttyTerminalSource
        ))
    }

    private init(terminalQueryCache: GhosttyTerminalQueryCache) {
        self.terminalQueryCache = terminalQueryCache
    }

    public func activeProcesses() throws -> [DetectedAgentProcess] {
        enrichTerminalContexts(in: try basicActiveProcesses())
    }

    public func basicActiveProcesses() throws -> [DetectedAgentProcess] {
        Self.droppingRuntimeLaunchers(
            try Self.allProcessIDs().compactMap(Self.detectAgentProcess)
        )
    }

    public func enrichTerminalContexts(in detected: [DetectedAgentProcess]) -> [DetectedAgentProcess] {
        let ghosttyProcesses = detected.filter { $0.terminal.termProgram == "ghostty" }
        guard !ghosttyProcesses.isEmpty,
               let terminals = terminalQueryCache.terminals(
                   hostingProcessIDs: Set(ghosttyProcesses.map(\.processID)),
                   processGenerationKeys: Set(ghosttyProcesses.map(GhosttySessionMatcher.assignmentKey))
               ) else {
            return detected
        }
        let nonGhosttyProcesses = detected.filter { $0.terminal.termProgram != "ghostty" }
        let matched = GhosttySessionMatcher.match(
            processes: ghosttyProcesses,
            terminals: terminals,
            previousAssignments: assignmentMemory.assignments()
        )
        assignmentMemory.remember(matched)
        let matchedByKey = Dictionary(
            uniqueKeysWithValues: matched.map { (GhosttySessionMatcher.assignmentKey(for: $0), $0) }
        )
        let unresolvedGhosttyProcesses = ghosttyProcesses.filter {
            matchedByKey[GhosttySessionMatcher.assignmentKey(for: $0)] == nil
        }
        return nonGhosttyProcesses + matched + unresolvedGhosttyProcesses
    }

    /// Lists every process ID visible to this user via libproc, without
    /// spawning helper processes. Retries with headroom because the process
    /// table can grow between the sizing call and the fetch.
    private static func allProcessIDs() throws -> [pid_t] {
        for _ in 0..<3 {
            let sizeInBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard sizeInBytes > 0 else { throw POSIXError(.EIO) }
            let capacity = Int(sizeInBytes) / MemoryLayout<pid_t>.stride + 64
            var buffer = [pid_t](repeating: 0, count: capacity)
            let filledBytes = buffer.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
            }
            guard filledBytes > 0 else { throw POSIXError(.EIO) }
            let filledCount = Int(filledBytes) / MemoryLayout<pid_t>.stride
            guard filledCount < capacity else { continue }
            return buffer.prefix(filledCount).filter { $0 > 0 }
        }
        throw POSIXError(.EAGAIN)
    }

    private struct ClassifiedAgentProcess {
        let process: DetectedAgentProcess
        let viaRuntimeLauncher: Bool
    }

    /// Classifies one process, returning nil unless it is a running agent
    /// whose metadata is fully readable. Processes that exit mid-scan simply
    /// disappear from the result instead of failing the whole scan.
    private static func detectAgentProcess(_ processID: pid_t) -> ClassifiedAgentProcess? {
        guard let initialInfo = bsdInfo(processID: processID),
              initialInfo.pbi_status != UInt32(SZOMB),
              let classification = agentTool(processID: processID),
              let cwd = workingDirectory(processID: processID),
              let bsdInfo = bsdInfo(processID: processID),
              bsdInfo.pbi_status != UInt32(SZOMB),
              processIdentity(from: initialInfo, processID: processID)
                == processIdentity(from: bsdInfo, processID: processID) else {
            return nil
        }
        let identity = processIdentity(from: bsdInfo, processID: processID)
        let startedAt = TimeInterval(identity.kernelStartTimeMicroseconds) / 1_000_000
        return ClassifiedAgentProcess(
            process: DetectedAgentProcess(
                tool: classification.tool,
                processID: processID,
                processIdentity: identity,
                cwd: cwd,
                terminal: TerminalContext(
                    termProgram: hostTerminalProgram(descendant: bsdInfo),
                    tty: controllingTTY(bsdInfo)
                ),
                elapsedSeconds: max(0, Date().timeIntervalSince1970 - startedAt)
            ),
            viaRuntimeLauncher: classification.viaRuntimeLauncher
        )
    }

    /// npm-style CLIs often pair a runtime launcher (`node .../bin/codex`)
    /// with the platform binary it spawns; both processes carry the tool
    /// name, but only the leaf is the agent. Launcher ancestors of a
    /// detected same-tool process are dropped. Native ancestors are kept:
    /// an agent started from inside another agent's shell is a real session.
    private static func droppingRuntimeLaunchers(
        _ classified: [ClassifiedAgentProcess]
    ) -> [DetectedAgentProcess] {
        let launcherProcessIDsByTool: [AgentTool: Set<pid_t>] = classified
            .filter(\.viaRuntimeLauncher)
            .reduce(into: [:]) { result, entry in
                result[entry.process.tool, default: []].insert(entry.process.processID)
            }
        guard !launcherProcessIDsByTool.isEmpty else { return classified.map(\.process) }
        var droppedProcessIDs: Set<pid_t> = []
        for entry in classified {
            guard let launcherProcessIDs = launcherProcessIDsByTool[entry.process.tool] else {
                continue
            }
            var ancestorProcessID = parentProcessID(of: entry.process.processID)
            for _ in 0..<8 {
                guard let current = ancestorProcessID, current > 1 else { break }
                if launcherProcessIDs.contains(current) {
                    droppedProcessIDs.insert(current)
                }
                ancestorProcessID = parentProcessID(of: current)
            }
        }
        return classified.map(\.process).filter {
            !droppedProcessIDs.contains($0.processID)
        }
    }

    private static let terminalAppMarkers: [(pathMarker: String, termProgram: String)] = [
        ("/Ghostty.app/", "ghostty"),
        ("/iTerm.app/", "iTerm.app"),
        ("/Terminal.app/", "Apple_Terminal"),
    ]

    /// Walks up the parent chain looking for a known terminal application.
    /// Both the kernel-resolved executable path and argv[0] are checked, for
    /// the same reason as agent matching: either side may hide behind a
    /// symlink. The walk is bounded and stops at launchd.
    private static func hostTerminalProgram(descendant: proc_bsdinfo) -> String? {
        var ancestorProcessID = pid_t(descendant.pbi_ppid)
        for _ in 0..<8 {
            guard ancestorProcessID > 1 else { return nil }
            if let program = terminalProgram(ofProcess: ancestorProcessID) {
                return program
            }
            guard let parent = parentProcessID(of: ancestorProcessID) else { return nil }
            ancestorProcessID = parent
        }
        return nil
    }

    /// Parent resolution that survives root-owned intermediaries: Ghostty and
    /// Terminal spawn shells through /usr/bin/login (root), where
    /// proc_pidinfo returns EPERM for unprivileged callers and would abort
    /// the ancestor walk one hop before the terminal app. The kinfo_proc
    /// sysctl — the same interface ps uses — remains readable there.
    public static func parentProcessID(of processID: pid_t) -> pid_t? {
        if let info = bsdInfo(processID: processID) {
            return pid_t(info.pbi_ppid)
        }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == processID else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }

    private static func terminalProgram(ofProcess processID: pid_t) -> String? {
        classifyByCommandIdentifier(processID: processID) { identifier in
            terminalAppMarkers.first { identifier.contains($0.pathMarker) }?.termProgram
        }
    }

    /// A process is an agent when the basename of its kernel-resolved
    /// executable path or of its argv[0] names a supported tool. The argv[0]
    /// fallback covers versioned installs behind symlinks, such as
    /// ~/.local/bin/claude -> .../claude/versions/2.1.214. Script-runtime
    /// CLIs (Pi installs via npm) name only the runtime in both places, so
    /// when the command is a known runtime the script path in the leading
    /// arguments is classified instead.
    private static func agentTool(
        processID: pid_t
    ) -> (tool: AgentTool, viaRuntimeLauncher: Bool)? {
        if let tool = classifyByCommandIdentifier(processID: processID, classifyToolName) {
            return (tool, false)
        }
        guard classifyByCommandIdentifier(processID: processID, isScriptRuntime) == true else {
            return nil
        }
        return firstArguments(processID: processID, count: 4)
            .dropFirst()
            .first { !$0.hasPrefix("-") }
            .flatMap(classifyToolName)
            .map { ($0, true) }
    }

    private static let scriptRuntimeNames: Set<String> = ["node", "bun", "deno"]

    private static func classifyToolName(_ identifier: String) -> AgentTool? {
        AgentTool(rawValue: URL(fileURLWithPath: identifier).lastPathComponent)
    }

    private static func isScriptRuntime(_ identifier: String) -> Bool? {
        scriptRuntimeNames.contains(URL(fileURLWithPath: identifier).lastPathComponent)
            ? true
            : nil
    }

    /// Applies a classifier to the kernel-resolved executable path first and
    /// argv[0] second, reading argv only when the path was not conclusive.
    /// Either side may hide behind a symlink, so both must be considered.
    private static func classifyByCommandIdentifier<Classification>(
        processID: pid_t,
        _ classify: (String) -> Classification?
    ) -> Classification? {
        if let path = executablePath(processID: processID), let match = classify(path) {
            return match
        }
        guard let argumentZero = argumentZero(processID: processID) else { return nil }
        return classify(argumentZero)
    }

    private static func executablePath(processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func workingDirectory(processID: pid_t) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size) == size else {
            return nil
        }
        return withUnsafeBytes(of: vnodeInfo.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Maps the controlling terminal device to its /dev path. NODEV
    /// (all bits set) means the process has no controlling terminal.
    private static func controllingTTY(_ info: proc_bsdinfo) -> String? {
        guard info.e_tdev != UInt32.max,
              let deviceName = devname(dev_t(bitPattern: info.e_tdev), mode_t(S_IFCHR)) else {
            return nil
        }
        return "/dev/" + String(cString: deviceName)
    }

    private static func bsdInfo(processID: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return info
    }

    public static func processIdentity(of processID: pid_t) -> ProcessIdentity? {
        guard let info = bsdInfo(processID: processID), info.pbi_status != UInt32(SZOMB) else {
            return nil
        }
        return processIdentity(from: info, processID: processID)
    }

    private static func processIdentity(from info: proc_bsdinfo, processID: pid_t) -> ProcessIdentity {
        ProcessIdentity(
            processID: processID,
            kernelStartTimeMicroseconds: UInt64(info.pbi_start_tvsec) * 1_000_000
                + UInt64(info.pbi_start_tvusec)
        )
    }

    private static func argumentZero(processID: pid_t) -> String? {
        firstArguments(processID: processID, count: 1).first.flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    /// Reads the leading argv strings through KERN_PROCARGS2. The buffer
    /// layout is: argc, then the executable path, NUL padding, then the argv
    /// strings separated by NULs. Only readable for the current user's
    /// processes; anything else yields an empty array.
    private static func firstArguments(processID: pid_t, count: Int) -> [String] {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, UInt32(name.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let argumentCountWidth = MemoryLayout<Int32>.size
        guard size > argumentCountWidth else { return [] }
        let argumentCount = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let content = buffer[argumentCountWidth..<size]
        guard let executablePathEnd = content.firstIndex(of: 0) else { return [] }
        var cursor = content[executablePathEnd...].prefix(while: { $0 == 0 }).endIndex
        var arguments: [String] = []
        while arguments.count < min(count, Int(argumentCount)), cursor < content.endIndex {
            let argumentBytes = content[cursor...].prefix(while: { $0 != 0 })
            arguments.append(String(decoding: argumentBytes, as: UTF8.self))
            cursor = argumentBytes.endIndex + 1
        }
        return arguments
    }

    static func queryGhosttyTerminals() throws -> [GhosttyTerminal] {
        let script = """
        const app = Application("Ghostty");
        function optionalProperty(terminal, name) {
          try {
            if (typeof terminal[name] !== "function") return null;
            return terminal[name]();
          } catch (_) {
            return null;
          }
        }
        JSON.stringify(app.terminals().map(t => ({
          id: t.id(), name: t.name(), cwd: t.workingDirectory(),
          pid: optionalProperty(t, "pid"), tty: optionalProperty(t, "tty")
        })))
        """
        let result = try Self.run(
            "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", script],
            timeout: 2
        )
        guard result.status == 0 else { throw POSIXError(.EIO) }
        return try JSONDecoder().decode([GhosttyTerminal].self, from: Data(result.output.utf8))
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 0.25) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.25)
            }
            throw POSIXError(.ETIMEDOUT)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
