import AppKit
import SwiftUI

import MoongladeCore

@main
struct MoongladeApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MoongladeSettingsView(store: appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private(set) var store: StateStore?
    private var observationScheduler: ObservationScheduler?
    private var instanceLock: SingleInstanceLock?
    private var demoRootURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if DemoWorkspace.isEnabled(in: ProcessInfo.processInfo.environment) {
            launchDemo()
            return
        }
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moonglade/state", isDirectory: true)
        let repository = StateRepository(directoryURL: stateDirectory)
        // Two live instances fight over state and stack duplicate panels.
        // The file lock is atomic across bundled and `swift run` launches;
        // unlike an NSRunningApplication preflight, simultaneous starts
        // cannot both decide that the other process should exit.
        do {
            try repository.prepareDirectory()
            guard let lock = try SingleInstanceLock.acquire(
                at: stateDirectory.appendingPathComponent(".app.lock")
            ) else {
                NSLog("Moonglade: another instance owns the application lock; exiting.")
                NSApp.terminate(nil)
                return
            }
            instanceLock = lock
        } catch {
            NSLog("Moonglade failed to acquire its application lock: %@", String(describing: error))
            NSApp.terminate(nil)
            return
        }
        // Session names live next to — never inside — the state directory:
        // the store watches that directory and decode-attempts every .json.
        let store = StateStore(
            repository: repository,
            nameOverridesFileURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".moonglade/session-names.json")
        )
        self.store = store
        // Two-sound language: the system alert (user-configured sound and
        // volume) means "a session needs you"; the soft Tink means "the
        // agent finished its turn — the conversation is yours".
        UserDefaults.standard.register(defaults: [
            "attentionSoundEnabled": true,
            "turnCompleteSoundEnabled": true,
            "screenSelectionMode": ScreenSelectionMode.pointer.rawValue,
        ])
        store.onAttentionRaised = { _ in
            guard UserDefaults.standard.bool(forKey: "attentionSoundEnabled") else { return }
            NSSound.beep()
        }
        store.onTurnCompleted = { _ in
            guard UserDefaults.standard.bool(forKey: "turnCompleteSoundEnabled") else { return }
            NSSound(named: "Tink")?.play()
        }
        // Capture scheduler sources first, then build Convoy ownership and
        // reconcile persisted state off the main thread. The panel stays
        // hidden until that baseline is ready, so internal OpenCode phases
        // cannot flash as global sessions during cold start.
        let scheduler = ObservationScheduler(repository: repository)
        observationScheduler = scheduler
        scheduler.startWithInitialReconciliation { [weak self, weak scheduler, weak store] in
            guard let self,
                  self.observationScheduler === scheduler,
                  self.store === store else { return }
            guard let store else { return }
            do {
                // Arm event capture before reading the post-reconciliation
                // baseline. Polling is only a 30-second safety heartbeat.
                try store.startObserving(pollInterval: 30)
            } catch {
                store.stopObserving()
                store.reloadRecordingError()
                NSLog("Moonglade failed to start state observation: %@", String(describing: error))
            }
            self.panelController = NotchPanelController(store: store)
            self.panelController?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        observationScheduler?.stop()
        store?.stopObserving()
        if let demoRootURL {
            try? FileManager.default.removeItem(at: demoRootURL)
        }
    }

    /// `MOONGLADE_DEMO=1`: the real panel over fixed sessions in a throwaway
    /// root, for screenshots. No observation scheduler, so nothing reaps the
    /// demo sessions, and no sounds; the user's own state is never opened.
    /// Quit any running Moonglade first, or the two panels stack.
    private func launchDemo() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonglade-demo-\(UUID().uuidString)", isDirectory: true)
        demoRootURL = root
        let workspace = DemoWorkspace(rootURL: root)
        do {
            try workspace.seed(now: Date())
            let store = StateStore(
                repository: StateRepository(directoryURL: workspace.stateDirectoryURL),
                nameOverridesFileURL: workspace.nameOverridesFileURL
            )
            try store.startObserving(pollInterval: 30)
            self.store = store
            panelController = NotchPanelController(store: store)
            panelController?.show()
        } catch {
            NSLog("Moonglade failed to start demo mode: %@", String(describing: error))
            NSApp.terminate(nil)
        }
    }

}
