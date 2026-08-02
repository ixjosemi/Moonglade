import AppKit
import Foundation

import MoongladeCore

/// Silences the bar semaphore for sessions the user visits on their own —
/// without going through Moonglade's menu. When Ghostty is frontmost and a
/// waiting session exists, the observer asks Ghostty which terminal has
/// focus and acknowledges the matching session. It costs nothing while no
/// session is waiting or another app is frontmost.
@MainActor
final class FocusAcknowledgmentObserver {
    private static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    private static let queryQueue = DispatchQueue(
        label: "com.moonglade.terminal-actions",
        qos: .userInitiated
    )

    private let store: StateStore
    private let frontTerminalQueryCache: FrontTerminalQueryCache
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var queryInFlight = false

    init(store: StateStore) {
        self.store = store
        frontTerminalQueryCache = FrontTerminalQueryCache {
            Self.queryFrontTerminal()
        }
    }

    func start() {
        stop()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrontTerminal(forceRefresh: true) }
        }
        // Tab switches inside Ghostty fire no workspace notification, so a
        // slow poll covers them; the guards below make idle ticks free.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrontTerminal() }
        }
        // Acknowledgment latency is invisible below half a second; tolerance
        // lets the kernel coalesce the wakeup with other timers.
        timer.tolerance = 0.5
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func checkFrontTerminal(forceRefresh: Bool = false) {
        guard !queryInFlight,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                  == Self.ghosttyBundleIdentifier else {
            return
        }
        let waitingSessions = store.sessions.filter { session in
            (session.status == .idle || session.status == .needsAttention)
                && !store.acknowledgments.isAcknowledged(session)
                && session.terminal.termProgram == "ghostty"
        }
        guard !waitingSessions.isEmpty else { return }
        queryInFlight = true
        let cache = frontTerminalQueryCache
        Self.queryQueue.async {
            let frontTerminal = cache.frontTerminal(forceRefresh: forceRefresh)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.queryInFlight = false }
                guard let frontTerminal else { return }
                for session in FrontTerminalMatcher.sessionsFocused(
                    by: frontTerminal,
                    among: waitingSessions
                ) {
                    self.store.acknowledge(session)
                }
            }
        }
    }

    private nonisolated static func queryFrontTerminal() -> GhosttyFrontTerminal? {
        let script = """
        tell application "Ghostty"
            set t to front terminal
            return (id of t as text) & linefeed & (working directory of t)
        end tell
        """
        do {
            let result = try BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeout: 5
            )
            guard result.status == 0 else { return nil }
            let lines = String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            guard let identifier = lines.first, !identifier.isEmpty else { return nil }
            let workingDirectory = lines.dropFirst().first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return GhosttyFrontTerminal(
                terminalID: identifier,
                workingDirectory: (workingDirectory?.isEmpty ?? true) ? nil : workingDirectory
            )
        } catch {
            return nil
        }
    }
}
