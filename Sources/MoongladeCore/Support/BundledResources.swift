import Foundation
import Darwin

public enum ResourceError: Error, Equatable, Sendable, CustomStringConvertible {
    case bundleMissing(searched: [String])
    case resourceMissing(name: String, bundlePath: String)

    public var description: String {
        switch self {
        case let .bundleMissing(searched):
            """
            Moonglade resource bundle \(BundledResources.bundleName) not found. \
            Searched: \(searched.joined(separator: ", ")). Reinstall with: moonglade install
            """
        case let .resourceMissing(name, bundlePath):
            "Moonglade resource \(name) is missing from \(bundlePath) — reinstall with: moonglade install"
        }
    }
}

public enum BundledResources {
    /// The name SwiftPM gives MoongladeCore's resource bundle: `<package>_<target>.bundle`.
    public static let bundleName = "Moonglade_MoongladeCore.bundle"

    /// MoongladeApp's own resource bundle, which carries the compiled Metal
    /// shader library. It is installed into Contents/Resources like the core
    /// bundle, so it is found by the same search.
    public static let appBundleName = "Moonglade_MoongladeApp.bundle"

    public static var claudeHookScriptURL: URL {
        get throws { try resourceURL(named: "claude-hook", extension: "sh", subdirectory: "Resources/hooks") }
    }
    public static var codexNotifyScriptURL: URL {
        get throws { try resourceURL(named: "codex-notify", extension: "sh", subdirectory: "Resources/hooks") }
    }
    public static var captureContextScriptURL: URL {
        get throws { try resourceURL(named: "capture-context", extension: "sh", subdirectory: "Resources/hooks") }
    }
    public static var opencodePluginURL: URL {
        get throws { try resourceURL(named: "moonglade", extension: "js", subdirectory: "Resources/opencode") }
    }
    public static var piExtensionURL: URL {
        get throws { try resourceURL(named: "moonglade", extension: "ts", subdirectory: "Resources/pi") }
    }

    /// Official brand marks (Anthropic's Claude spark, sst/opencode's glyph,
    /// OpenAI's knot for Codex) — see NOTICE for trademark attribution.
    public static func iconURL(for tool: AgentTool) throws -> URL {
        try resourceURL(named: tool.rawValue, extension: "svg", subdirectory: "Resources/icons")
    }

    /// The resolved bundle itself, so `Installer` can ship a copy of it beside
    /// the binary it installs.
    public static var bundleURL: URL {
        get throws { try locatedBundle.get().bundleURL }
    }

    public static func containsResource(
        named name: String,
        withExtension fileExtension: String,
        inBundleAt path: String
    ) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              let bundle = Bundle(path: path),
              let resourceURL = bundle.url(forResource: name, withExtension: fileExtension),
              Darwin.lstat(resourceURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { return false }
        return true
    }

    /// Locations that may hold the resource bundle, in priority order.
    ///
    /// SwiftPM's generated `Bundle.module` resolves only the directory holding
    /// the running executable and the absolute build directory of the machine
    /// that compiled it. A shipped binary has no bundle beside it, so both
    /// installed CLIs read their scripts out of the developer's `.build` tree
    /// and trapped the moment that directory was renamed. These are the
    /// layouts Moonglade actually installs into, and none is a build path.
    public static func bundleSearchPaths(
        named bundleName: String = bundleName,
        executableURL: URL?,
        mainResourceURL: URL?
    ) -> [String] {
        var directories: [URL] = []
        if let executableDirectory = executableURL?.deletingLastPathComponent() {
            // ~/.moonglade/bin/moonglade, and .build/<config>/ during development.
            directories.append(executableDirectory)
            // Moonglade.app/Contents/Resources/bin/moonglade — the bundle sits
            // in Resources/, one level above the CLI.
            directories.append(executableDirectory.deletingLastPathComponent())
        }
        if let mainResourceURL {
            // Moonglade.app/Contents/MacOS/Moonglade — the app binary reaches
            // Resources/ only through its own bundle.
            directories.append(mainResourceURL)
        }
        var paths: [String] = []
        for directory in directories {
            let path = directory.standardizedFileURL.appendingPathComponent(bundleName).path
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    private static let locatedBundle: Result<Bundle, ResourceError> = {
        let searched = bundleSearchPaths(
            executableURL: Bundle.main.executableURL,
            mainResourceURL: Bundle.main.resourceURL
        )
        for path in searched {
            if let bundle = Bundle(path: path) { return .success(bundle) }
        }
        return .failure(.bundleMissing(searched: searched))
    }()

    private static func resourceURL(
        named name: String,
        extension fileExtension: String,
        subdirectory: String
    ) throws -> URL {
        let bundle = try locatedBundle.get()
        guard let url = bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            throw ResourceError.resourceMissing(
                name: "\(name).\(fileExtension)",
                bundlePath: bundle.bundleURL.path
            )
        }
        return url
    }
}
