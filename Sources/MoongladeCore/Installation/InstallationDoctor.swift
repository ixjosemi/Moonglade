import Foundation
import Darwin

public struct DoctorCheck: Equatable, Sendable {
    public let title: String
    public let passed: Bool
    public let detail: String

    public init(title: String, passed: Bool, detail: String) {
        self.title = title
        self.passed = passed
        self.detail = detail
    }
}

/// Read-only diagnosis of an Moonglade installation. Every check inspects
/// the same files the Installer writes — binaries, Claude hooks, OpenCode
/// plugin, Codex notify — without mutating anything, so it is safe to run
/// at any time.
public struct InstallationDoctor {
    private static let hookBinaryNames = [
        "moonglade",
        "claude-hook.sh",
        "codex-notify.sh",
        "capture-context.sh",
    ]

    private let homeDirectoryURL: URL

    public init(homeDirectoryURL: URL) {
        self.homeDirectoryURL = homeDirectoryURL
    }

    public func diagnose() -> [DoctorCheck] {
        [
            hookBinariesCheck(),
            stateDirectoryCheck(),
            claudeHooksCheck(),
            openCodePluginCheck(),
            codexNotifyCheck(),
            piExtensionCheck(),
        ]
    }

    private var binDirectory: URL {
        homeDirectoryURL.appendingPathComponent(".moonglade/bin")
    }

    private func hookBinariesCheck() -> DoctorCheck {
        let missing = Self.hookBinaryNames.filter { name in
            Darwin.access(binDirectory.appendingPathComponent(name).path, X_OK) != 0
        }
        return DoctorCheck(
            title: "hook binaries",
            passed: missing.isEmpty,
            detail: missing.isEmpty
                ? "all executables present in \(display(binDirectory))"
                : "missing or not executable: \(missing.joined(separator: ", "))"
        )
    }

    private func stateDirectoryCheck() -> DoctorCheck {
        let stateDirectory = homeDirectoryURL.appendingPathComponent(".moonglade/state")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: stateDirectory.path,
            isDirectory: &isDirectory
        )
        return DoctorCheck(
            title: "state directory",
            passed: exists && isDirectory.boolValue,
            detail: exists && isDirectory.boolValue
                ? "\(display(stateDirectory)) exists"
                : "\(display(stateDirectory)) is missing — run: moonglade install"
        )
    }

    private func claudeHooksCheck() -> DoctorCheck {
        let settingsURL = homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        guard let settingsData = try? Data(contentsOf: settingsURL) else {
            return DoctorCheck(
                title: "Claude Code hooks",
                passed: false,
                detail: "\(display(settingsURL)) is missing — run: moonglade install"
            )
        }
        let installed = ClaudeSettingsMerger.isInstalled(
            settingsData: settingsData,
            hookCommand: binDirectory.appendingPathComponent("claude-hook.sh").path
        )
        return DoctorCheck(
            title: "Claude Code hooks",
            passed: installed,
            detail: installed
                ? "all lifecycle hooks registered in \(display(settingsURL))"
                : "hooks missing from \(display(settingsURL)) — run: moonglade install"
        )
    }

    private func openCodePluginCheck() -> DoctorCheck {
        integrationFileCheck(
            title: "OpenCode plugin",
            relativePath: ".config/opencode/plugins/moonglade.js",
            bundled: BundledResources.opencodePluginURL
        )
    }

    private func piExtensionCheck() -> DoctorCheck {
        integrationFileCheck(
            title: "Pi extension",
            relativePath: ".pi/agent/extensions/moonglade.ts",
            bundled: BundledResources.piExtensionURL
        )
    }

    private func integrationFileCheck(
        title: String,
        relativePath: String,
        bundled: URL
    ) -> DoctorCheck {
        let destination = homeDirectoryURL.appendingPathComponent(relativePath)
        guard let installed = try? Data(contentsOf: destination) else {
            return DoctorCheck(
                title: title,
                passed: false,
                detail: "\(display(destination)) is missing — run: moonglade install"
            )
        }
        let matchesBundled = (try? Data(contentsOf: bundled)) == installed
        return DoctorCheck(
            title: title,
            passed: matchesBundled,
            detail: matchesBundled
                ? "\(display(destination)) matches the bundled file"
                : "\(display(destination)) differs from the bundled file — reinstall to update"
        )
    }

    private func codexNotifyCheck() -> DoctorCheck {
        let configURL = homeDirectoryURL.appendingPathComponent(".codex/config.toml")
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return DoctorCheck(
                title: "Codex notify",
                passed: false,
                detail: "\(display(configURL)) is missing — run: moonglade install"
            )
        }
        // Match the exact script this installation writes, not just its name:
        // another app's notify hook can ship a file called codex-notify.sh, and
        // reporting that as ours would claim Codex is wired here while its
        // events go somewhere else entirely.
        let ownScript = homeDirectoryURL
            .appendingPathComponent(".moonglade/bin/codex-notify.sh")
            .standardizedFileURL.path
        let configured = config.range(
            of: #"(?m)^\s*notify\s*=.*"# + NSRegularExpression.escapedPattern(for: ownScript),
            options: .regularExpression
        ) != nil
        return DoctorCheck(
            title: "Codex notify",
            passed: configured,
            detail: configured
                ? "notify hook registered in \(display(configURL))"
                : "notify hook missing from \(display(configURL)) — run: moonglade install"
        )
    }

    private func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = homeDirectoryURL.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
