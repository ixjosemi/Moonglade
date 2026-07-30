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
            resourceBundleCheck(),
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

    /// The binaries check reports presence, which is not usability: the
    /// installed `moonglade` reads its hook scripts and agent icons from the
    /// resource bundle beside it, so without that bundle every install and
    /// doctor run dies before printing anything.
    private func resourceBundleCheck() -> DoctorCheck {
        let bundleURL = binDirectory.appendingPathComponent(BundledResources.bundleName)
        let usable = FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("Resources/hooks/claude-hook.sh").path
        )
        return DoctorCheck(
            title: "resource bundle",
            passed: usable,
            detail: usable
                ? "\(display(bundleURL)) sits beside the installed binary"
                : "\(display(bundleURL)) is missing or incomplete — run: moonglade install"
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
            bundled: try BundledResources.opencodePluginURL
        )
    }

    private func piExtensionCheck() -> DoctorCheck {
        integrationFileCheck(
            title: "Pi extension",
            relativePath: ".pi/agent/extensions/moonglade.ts",
            bundled: try BundledResources.piExtensionURL
        )
    }

    private func integrationFileCheck(
        title: String,
        relativePath: String,
        bundled bundledResource: @autoclosure () throws -> URL
    ) -> DoctorCheck {
        let destination = homeDirectoryURL.appendingPathComponent(relativePath)
        guard let bundled = try? bundledResource() else {
            return DoctorCheck(
                title: title,
                passed: false,
                detail: "cannot read the bundled file — see the resource bundle check"
            )
        }
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
        guard let notify = Self.notifyValue(in: config) else {
            return DoctorCheck(
                title: "Codex notify",
                passed: false,
                detail: "no notify hook in \(display(configURL)) — run: moonglade install"
            )
        }
        return codexNotifyCheck(notify: notify, configURL: configURL)
    }

    /// Codex's `notify` holds a single command, so tools that want it cooperate
    /// by taking the key and carrying the previous value forward as one of their
    /// own arguments. Our hook still runs in that arrangement, so it counts as
    /// wired whether it owns the key or merely appears inside it — and because a
    /// forwarded value travels as a nested string, the escapes have to come off
    /// before the path can be compared.
    ///
    /// The exact path matters, not just the script name: another installation
    /// can ship its own codex-notify.sh, and reporting that as ours would claim
    /// Codex is wired here while its events go somewhere else entirely.
    private func codexNotifyCheck(notify: String, configURL: URL) -> DoctorCheck {
        let ownScript = homeDirectoryURL
            .appendingPathComponent(".moonglade/bin/codex-notify.sh")
            .standardizedFileURL.path
        let owner = Self.notifyOwner(in: notify)
        guard notify.replacingOccurrences(of: "\\", with: "").contains(ownScript) else {
            // Installation deliberately refuses to overwrite a notify key it did
            // not write, so `moonglade install` cannot resolve this and must not
            // be offered as the way out.
            return DoctorCheck(
                title: "Codex notify",
                passed: false,
                detail: """
                    \(display(configURL)) points notify at \(owner), which does not forward to \
                    ours — add \(display(URL(fileURLWithPath: ownScript))) to that tool's notify \
                    chain, or clear the notify line and run: moonglade install
                    """
            )
        }
        let ours = URL(fileURLWithPath: ownScript).lastPathComponent
        return DoctorCheck(
            title: "Codex notify",
            passed: true,
            detail: owner == ours
                ? "notify hook registered in \(display(configURL))"
                : "notify hook reached through \(owner)'s notify chain in \(display(configURL))"
        )
    }

    /// The value of the root table's `notify` key.
    private static func notifyValue(in config: String) -> String? {
        guard let assignment = config.range(
            of: #"(?m)^[ \t]*notify[ \t]*=[ \t]*"#,
            options: .regularExpression
        ) else { return nil }
        let tail = config[assignment.upperBound...]
        guard tail.first == "[" else { return String(tail.prefix { !$0.isNewline }) }
        return String(bracketedPrefix(of: tail))
    }

    /// Consumes a TOML array, closing on bracket depth rather than at the first
    /// newline because the value may span lines, and ignoring brackets that sit
    /// inside strings — a forwarded chain carries whole quoted arrays as
    /// arguments.
    private static func bracketedPrefix(of tail: Substring) -> Substring {
        var depth = 0
        var inString = false
        var escaped = false
        for index in tail.indices {
            if escaped {
                escaped = false
                continue
            }
            switch tail[index] {
            case "\\": escaped = true
            case "\"": inString.toggle()
            case "[" where !inString: depth += 1
            case "]" where !inString:
                depth -= 1
                if depth == 0 { return tail[...index] }
            default: break
            }
        }
        return tail
    }

    /// The command `notify` actually invokes, named by its last path component.
    private static func notifyOwner(in notify: String) -> String {
        guard let quoted = notify.range(of: #""[^"]+""#, options: .regularExpression) else {
            return "another command"
        }
        let path = notify[quoted].dropFirst().dropLast()
        return URL(fileURLWithPath: String(path)).lastPathComponent
    }

    private func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = homeDirectoryURL.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
