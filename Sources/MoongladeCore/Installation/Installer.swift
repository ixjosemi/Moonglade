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
        // The installed binary resolves its scripts and icons relative to
        // itself, so the resource bundle has to travel with it. Without this
        // copy it fell back to the build directory of the machine that
        // compiled it and trapped once that path was gone.
        try copy(
            BundledResources.bundleURL,
            to: binaryDirectory.appendingPathComponent(BundledResources.bundleName),
            executable: false
        )
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
        let resolvedDestination = try writableFileURL(at: destination)
        guard FileManager.default.fileExists(atPath: resolvedDestination.path) else { return true }
        let existing = try SecureFileReader.read(at: resolvedDestination)
        return existing == (try SecureFileReader.read(at: bundled))
            || Self.isMoongladeOwned(existing)
    }

    private func removeOwnedIntegrationFile(at destination: URL, matching bundled: URL) throws {
        let resolvedDestination = try writableFileURL(at: destination)
        if FileManager.default.fileExists(atPath: resolvedDestination.path),
           try mayReplaceIntegrationFile(at: destination, bundled: bundled) {
            try removeIfPresent(resolvedDestination)
        }
    }

    private func uninstallClaudeSettings(hookDirectory: URL) throws {
        let settingsURL = try writableFileURL(
            at: homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        )
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let updated = try ClaudeSettingsMerger.remove(
            settingsData: try SecureFileReader.read(at: settingsURL),
            hookCommand: hookDirectory.appendingPathComponent("claude-hook.sh").path
        )
        try SecureFileWriter.writeAtomically(updated, to: settingsURL)
    }

    private func uninstallCodexNotify(hookDirectory: URL) throws {
        let configURL = try writableFileURL(
            at: homeDirectoryURL.appendingPathComponent(".codex/config.toml")
        )
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        guard var config = String(
            data: try SecureFileReader.read(at: configURL),
            encoding: .utf8
        ) else { throw InstallationError.invalidClaudeSettings }
        let path = escapedTomlString(hookDirectory.appendingPathComponent("codex-notify.sh").path)
        config = config.replacingOccurrences(
            of: "notify = [\"\(path)\"]\n",
            with: ""
        )
        try SecureFileWriter.writeAtomically(Data(config.utf8), to: configURL)
    }

    private func installClaudeSettings(hookDirectory: URL) throws {
        let directory = homeDirectoryURL.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsDestination = directory.appendingPathComponent("settings.json")
        let settingsURL = try writableFileURL(at: settingsDestination)
        let existing = FileManager.default.fileExists(atPath: settingsURL.path)
            ? try SecureFileReader.read(at: settingsURL)
            : Data("{}".utf8)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            try createSettingsBackup(for: settingsDestination, original: existing)
        }
        let merged = try ClaudeSettingsMerger.merge(
            settingsData: existing,
            hookCommand: hookDirectory.appendingPathComponent("claude-hook.sh").path
        )
        try SecureFileWriter.writeAtomically(merged, to: settingsURL)
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
        let writableDestination = try writableFileURL(at: destination)
        guard try mayReplaceIntegrationFile(at: destination, bundled: bundled) else {
            throw InstallationError.existingIntegrationFile(destination.path)
        }
        try copy(bundled, to: writableDestination, executable: false)
    }

    private func installCodexNotify(hookDirectory: URL) throws {
        let directory = homeDirectoryURL.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configDestination = directory.appendingPathComponent("config.toml")
        let configURL = try writableFileURL(at: configDestination)
        var config = ""
        if FileManager.default.fileExists(atPath: configURL.path) {
            guard let decoded = String(
                data: try SecureFileReader.read(at: configURL),
                encoding: .utf8
            ) else { throw InstallationError.invalidClaudeSettings }
            config = decoded
        }
        if config.range(of: #"(?m)^\s*notify\s*="#, options: .regularExpression) == nil {
            let script = escapedTomlString(hookDirectory.appendingPathComponent("codex-notify.sh").path)
            // `notify` must live in the root table, which ends at the first
            // table header. A multi-line value may continue on a line that
            // begins with "[", so the top of the file is the only insertion
            // point that is safe regardless of the existing content.
            config = "notify = [\"\(script)\"]\n\n" + config
            try SecureFileWriter.writeAtomically(Data(config.utf8), to: configURL)
        }
    }

    private func escapedTomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func createSettingsBackup(for destination: URL, original: Data) throws {
        let backupURL = destination.appendingPathExtension("moonglade-backup")
        var metadata = stat()
        if Darwin.lstat(backupURL.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid() else {
                throw InstallationError.unsafeInstallationPath(backupURL.path)
            }
            return
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try SecureFileWriter.writeIfAbsent(original, to: backupURL)
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

    private func writableFileURL(at destination: URL) throws -> URL {
        var metadata = stat()
        guard Darwin.lstat(destination.path, &metadata) == 0 else {
            guard errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return destination
        }
        guard metadata.st_mode & S_IFMT == S_IFLNK else {
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid() else {
                throw InstallationError.unsafeInstallationPath(destination.path)
            }
            return destination
        }
        guard let resolvedPath = realpathString(destination.path),
              let resolvedHome = realpathString(homeDirectoryURL.path),
              resolvedPath == resolvedHome || resolvedPath.hasPrefix(resolvedHome + "/") else {
            throw InstallationError.unsafeInstallationPath(destination.path)
        }
        var resolvedMetadata = stat()
        guard Darwin.lstat(resolvedPath, &resolvedMetadata) == 0,
              resolvedMetadata.st_mode & S_IFMT == S_IFREG,
              resolvedMetadata.st_uid == getuid() else {
            throw InstallationError.unsafeInstallationPath(destination.path)
        }
        return URL(fileURLWithPath: resolvedPath)
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
                settingsData: try SecureFileReader.read(at: writableFileURL(at: claudeSettings)),
                hookCommand: homeDirectoryURL.appendingPathComponent(".moonglade/bin/claude-hook.sh").path
            )
        }

        let codexConfig = homeDirectoryURL.appendingPathComponent(".codex/config.toml")
        if FileManager.default.fileExists(atPath: codexConfig.path) {
            _ = try SecureFileReader.read(at: writableFileURL(at: codexConfig))
        }

        let integrationFiles: [(destination: String, bundled: URL)] = [
            (".config/opencode/plugins/moonglade.js", try BundledResources.opencodePluginURL),
            (".pi/agent/extensions/moonglade.ts", try BundledResources.piExtensionURL),
        ]
        for file in integrationFiles {
            let destination = homeDirectoryURL.appendingPathComponent(file.destination)
            _ = try writableFileURL(at: destination)
            guard try mayReplaceIntegrationFile(at: destination, bundled: file.bundled) else {
                throw InstallationError.existingIntegrationFile(destination.path)
            }
        }
    }
}
