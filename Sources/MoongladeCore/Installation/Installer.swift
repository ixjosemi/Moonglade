import Foundation
import Darwin

public struct Installer {
    private let homeDirectoryURL: URL
    private let executableURL: URL

    public init(homeDirectoryURL: URL, executableURL: URL) {
        self.homeDirectoryURL = homeDirectoryURL
        self.executableURL = executableURL
    }

    public func install() throws {
        let moongladeDirectory = homeDirectoryURL.appendingPathComponent(".moonglade")
        let binaryDirectory = moongladeDirectory.appendingPathComponent("bin")
        try validatePrivateDirectory(moongladeDirectory)
        try validateIntegrationDirectories(Self.integrationDirectories(under: homeDirectoryURL))
        try preflightInstallation()
        try FileManager.default.createDirectory(
            at: moongladeDirectory.appendingPathComponent("state"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        for directory in [moongladeDirectory, binaryDirectory, moongladeDirectory.appendingPathComponent("state")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try copy(executableURL, to: binaryDirectory.appendingPathComponent("moonglade"), executable: true)
        try copy(BundledResources.claudeHookScriptURL, to: binaryDirectory.appendingPathComponent("claude-hook.sh"), executable: true)
        try copy(BundledResources.codexNotifyScriptURL, to: binaryDirectory.appendingPathComponent("codex-notify.sh"), executable: true)
        try copy(BundledResources.captureContextScriptURL, to: binaryDirectory.appendingPathComponent("capture-context.sh"), executable: true)
        try installClaudeSettings(hookDirectory: binaryDirectory)
        try installOpenCodePlugin()
        try installCodexNotify(hookDirectory: binaryDirectory)
        try installPiExtension()
    }

    static func integrationDirectories(under homeDirectoryURL: URL) -> [URL] {
        [
            homeDirectoryURL.appendingPathComponent(".claude"),
            homeDirectoryURL.appendingPathComponent(".config/opencode/plugins"),
            homeDirectoryURL.appendingPathComponent(".codex"),
            homeDirectoryURL.appendingPathComponent(".pi/agent/extensions"),
        ]
    }

    public func uninstall() throws {
        let moongladeDirectory = homeDirectoryURL.appendingPathComponent(".moonglade")
        try validatePrivateDirectory(moongladeDirectory)
        try validateIntegrationDirectories(Self.integrationDirectories(under: homeDirectoryURL))
        try uninstallClaudeSettings(
            hookDirectory: moongladeDirectory.appendingPathComponent("bin")
        )
        try uninstallCodexNotify(
            hookDirectory: moongladeDirectory.appendingPathComponent("bin")
        )
        try removeOwnedIntegrationFile(
            at: homeDirectoryURL.appendingPathComponent(".config/opencode/plugins/moonglade.js"),
            matching: BundledResources.opencodePluginURL
        )
        try removeOwnedIntegrationFile(
            at: homeDirectoryURL.appendingPathComponent(".pi/agent/extensions/moonglade.ts"),
            matching: BundledResources.piExtensionURL
        )
        try removeIfPresent(moongladeDirectory)
    }

    /// First-line marker that identifies an installed integration file as
    /// ours: bundled integrations carry it, user files do not. Without it,
    /// exact-match comparison alone would block every reinstall that ships
    /// changed plugin content.
    static let integrationOwnershipMarker = "Moonglade-managed integration"

    private static func isMoongladeOwned(_ contents: Data) -> Bool {
        // Only the first line counts, so a user file that merely mentions
        // the marker somewhere inside is never claimed.
        let firstLine = String(decoding: contents.prefix(200), as: UTF8.self)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? ""
        return firstLine.contains(integrationOwnershipMarker)
    }

    /// An integration file may be replaced (or removed on uninstall) when it
    /// does not exist, matches this build's bundled content, or carries the
    /// ownership marker; anything else belongs to the user.
    private func mayReplaceIntegrationFile(at destination: URL, bundled: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return true }
        let existing = try Data(contentsOf: destination)
        return existing == (try Data(contentsOf: bundled)) || Self.isMoongladeOwned(existing)
    }

    private func removeOwnedIntegrationFile(at destination: URL, matching bundled: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path),
           try mayReplaceIntegrationFile(at: destination, bundled: bundled) {
            try removeIfPresent(destination)
        }
    }

    private func uninstallClaudeSettings(hookDirectory: URL) throws {
        let settingsURL = homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let updated = try ClaudeSettingsMerger.remove(
            settingsData: Data(contentsOf: settingsURL),
            hookCommand: hookDirectory.appendingPathComponent("claude-hook.sh").path
        )
        try updated.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    private func uninstallCodexNotify(hookDirectory: URL) throws {
        let configURL = homeDirectoryURL.appendingPathComponent(".codex/config.toml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        var config = try String(contentsOf: configURL, encoding: .utf8)
        let path = hookDirectory.appendingPathComponent("codex-notify.sh").path
        config = config.replacingOccurrences(
            of: "notify = [\"\(path)\"]\n",
            with: ""
        )
        try Data(config.utf8).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func installClaudeSettings(hookDirectory: URL) throws {
        let directory = homeDirectoryURL.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let existing = FileManager.default.fileExists(atPath: settingsURL.path)
            ? try Data(contentsOf: settingsURL)
            : Data("{}".utf8)
        let merged = try ClaudeSettingsMerger.merge(
            settingsData: existing,
            hookCommand: hookDirectory.appendingPathComponent("claude-hook.sh").path
        )
        try merged.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    private func installOpenCodePlugin() throws {
        try installIntegrationFile(
            bundled: BundledResources.opencodePluginURL,
            intoDirectory: ".config/opencode/plugins",
            named: "moonglade.js"
        )
    }

    private func installPiExtension() throws {
        try installIntegrationFile(
            bundled: BundledResources.piExtensionURL,
            intoDirectory: ".pi/agent/extensions",
            named: "moonglade.ts"
        )
    }

    /// Copies a bundled integration file, refusing to replace an existing
    /// file with unknown content — that file belongs to the user.
    private func installIntegrationFile(
        bundled: URL,
        intoDirectory relativeDirectory: String,
        named fileName: String
    ) throws {
        let directory = homeDirectoryURL.appendingPathComponent(relativeDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        guard try mayReplaceIntegrationFile(at: destination, bundled: bundled) else {
            throw InstallationError.existingIntegrationFile(destination.path)
        }
        try copy(bundled, to: destination, executable: false)
    }

    private func installCodexNotify(hookDirectory: URL) throws {
        let directory = homeDirectoryURL.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.toml")
        var config = FileManager.default.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8)
            : ""
        if config.range(of: #"(?m)^\s*notify\s*="#, options: .regularExpression) == nil {
            let script = hookDirectory.appendingPathComponent("codex-notify.sh").path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            // `notify` must live in the root table, which ends at the first
            // table header. A multi-line value may continue on a line that
            // begins with "[", so the top of the file is the only insertion
            // point that is safe regardless of the existing content.
            config = "notify = [\"\(script)\"]\n\n" + config
            try Data(config.utf8).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
    }

    private func copy(_ source: URL, to destination: URL, executable: Bool) throws {
        if source.standardizedFileURL.resolvingSymlinksInPath()
            == destination.standardizedFileURL.resolvingSymlinksInPath() {
            return
        }
        try removeIfPresent(destination)
        try FileManager.default.copyItem(at: source, to: destination)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// The private directory holds executables run by hooks; any symlink in
    /// its path could redirect them, so every existing component must be a
    /// real directory.
    private func validatePrivateDirectory(_ directory: URL) throws {
        try walkComponents(of: directory) { componentURL, metadata in
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw InstallationError.unsafeInstallationPath(componentURL.path)
            }
        }
    }

    /// Integration directories live in tool configs that dotfile setups
    /// routinely symlink into a config repository. A symlink component is
    /// acceptable when it resolves to a directory the user owns inside their
    /// home; anything else is rejected.
    private func validateIntegrationDirectories(_ directories: [URL]) throws {
        for directory in directories {
            try walkComponents(of: directory) { componentURL, metadata in
                switch metadata.st_mode & S_IFMT {
                case S_IFDIR:
                    return
                case S_IFLNK:
                    try validateResolvedSymlink(componentURL)
                default:
                    throw InstallationError.unsafeInstallationPath(componentURL.path)
                }
            }
        }
    }

    private func validateResolvedSymlink(_ componentURL: URL) throws {
        guard let resolvedPath = realpathString(componentURL.path),
              let resolvedHome = realpathString(homeDirectoryURL.path),
              resolvedPath == resolvedHome || resolvedPath.hasPrefix(resolvedHome + "/") else {
            throw InstallationError.unsafeInstallationPath(componentURL.path)
        }
        // realpath already resolved every link, so lstat inspects the target
        // itself (the C stat() function is shadowed by the struct in Swift).
        var resolvedMetadata = stat()
        guard Darwin.lstat(resolvedPath, &resolvedMetadata) == 0,
              resolvedMetadata.st_mode & S_IFMT == S_IFDIR,
              resolvedMetadata.st_uid == getuid() else {
            throw InstallationError.unsafeInstallationPath(componentURL.path)
        }
    }

    private func walkComponents(
        of directory: URL,
        validateExisting: (URL, stat) throws -> Void
    ) throws {
        let homePath = homeDirectoryURL.standardizedFileURL.path
        let path = directory.standardizedFileURL.path
        guard path == homePath || path.hasPrefix(homePath + "/") else {
            throw InstallationError.unsafeInstallationPath(path)
        }
        var current = homeDirectoryURL.standardizedFileURL
        let relativeComponents = directory.standardizedFileURL.pathComponents
            .dropFirst(homeDirectoryURL.standardizedFileURL.pathComponents.count)
        for component in relativeComponents {
            current.appendPathComponent(component)
            var metadata = stat()
            if Darwin.lstat(current.path, &metadata) == 0 {
                try validateExisting(current, metadata)
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func realpathString(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func preflightInstallation() throws {
        var executableMetadata = stat()
        guard Darwin.lstat(executableURL.path, &executableMetadata) == 0,
              executableMetadata.st_mode & S_IFMT == S_IFREG else {
            throw InstallationError.unsafeInstallationPath(executableURL.path)
        }

        let claudeSettings = homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: claudeSettings.path) {
            _ = try ClaudeSettingsMerger.merge(
                settingsData: Data(contentsOf: claudeSettings),
                hookCommand: homeDirectoryURL.appendingPathComponent(".moonglade/bin/claude-hook.sh").path
            )
        }

        let codexConfig = homeDirectoryURL.appendingPathComponent(".codex/config.toml")
        if FileManager.default.fileExists(atPath: codexConfig.path) {
            _ = try String(contentsOf: codexConfig, encoding: .utf8)
        }

        let integrationFiles: [(destination: String, bundled: URL)] = [
            (".config/opencode/plugins/moonglade.js", BundledResources.opencodePluginURL),
            (".pi/agent/extensions/moonglade.ts", BundledResources.piExtensionURL),
        ]
        for file in integrationFiles {
            let destination = homeDirectoryURL.appendingPathComponent(file.destination)
            guard try mayReplaceIntegrationFile(at: destination, bundled: file.bundled) else {
                throw InstallationError.existingIntegrationFile(destination.path)
            }
        }
    }
}
