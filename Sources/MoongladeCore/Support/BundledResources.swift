import Foundation

public enum BundledResources {
    public static let captureContextScriptURL = resourceURL(
        named: "capture-context",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let claudeHookScriptURL = resourceURL(
        named: "claude-hook",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let codexNotifyScriptURL = resourceURL(
        named: "codex-notify",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let opencodePluginURL = resourceURL(
        named: "moonglade",
        extension: "js",
        subdirectory: "Resources/opencode"
    )
    public static let piExtensionURL = resourceURL(
        named: "moonglade",
        extension: "ts",
        subdirectory: "Resources/pi"
    )

    /// Official brand marks (Anthropic's Claude spark, sst/opencode's glyph,
    /// OpenAI's knot for Codex) — see NOTICE for trademark attribution.
    public static func iconURL(for tool: AgentTool) -> URL {
        resourceURL(named: tool.rawValue, extension: "svg", subdirectory: "Resources/icons")
    }

    private static func resourceURL(
        named name: String,
        extension fileExtension: String,
        subdirectory: String
    ) -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            fatalError("Moonglade resource is missing: \(name).\(fileExtension)")
        }
        return url
    }
}
