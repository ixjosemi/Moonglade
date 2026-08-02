import Foundation

public enum InstallationError: Error, Equatable, Sendable {
    case invalidClaudeSettings
    case unsafeInstallationPath(String)
    case existingIntegrationFile(String)
}

public enum ClaudeSettingsMerger {
    private static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("Notification", "permission_prompt|idle_prompt"),
        ("UserPromptSubmit", nil),
        ("PostToolUse", nil),
        ("Stop", nil),
        ("SessionEnd", nil),
    ]

    public static func merge(settingsData: Data, hookCommand: String) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw InstallationError.invalidClaudeSettings
        }
        let (existingHooks, _) = try hooksObject(in: root)
        var allHooks = existingHooks
        for event in events {
            var groups = try eventGroups(event.name, in: allHooks)
            let command = command(hookCommand: hookCommand, eventName: event.name)
            if try !contains(command: command, in: groups) {
                groups.append(group(command: command, matcher: event.matcher))
            }
            allHooks[event.name] = groups
        }
        root["hooks"] = allHooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func remove(settingsData: Data, hookCommand: String) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw InstallationError.invalidClaudeSettings
        }
        let (existingHooks, hooksWerePresent) = try hooksObject(in: root)
        var allHooks = existingHooks
        for event in events {
            let command = command(hookCommand: hookCommand, eventName: event.name)
            let groups = try eventGroups(event.name, in: allHooks)
            let remaining = try groups.filter { try !contains(command: command, in: [$0]) }
            if remaining.isEmpty {
                allHooks.removeValue(forKey: event.name)
            } else {
                allHooks[event.name] = remaining
            }
        }
        if allHooks.isEmpty, !hooksWerePresent {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = allHooks
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// True when every lifecycle event already carries the Moonglade hook —
    /// the read-only counterpart of `merge` used by the installation doctor.
    public static func isInstalled(settingsData: Data, hookCommand: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let (allHooks, _) = try? hooksObject(in: root) else { return false }
        return (try? events.allSatisfy { event in
            try contains(
                command: command(hookCommand: hookCommand, eventName: event.name),
                in: eventGroups(event.name, in: allHooks)
            )
        }) ?? false
    }

    private static func hooksObject(in root: [String: Any]) throws -> ([String: Any], Bool) {
        guard let rawHooks = root["hooks"] else { return ([:], false) }
        guard let hooks = rawHooks as? [String: Any] else {
            throw InstallationError.invalidClaudeSettings
        }
        return (hooks, true)
    }

    private static func eventGroups(
        _ eventName: String,
        in hooks: [String: Any]
    ) throws -> [[String: Any]] {
        guard let rawGroups = hooks[eventName] else { return [] }
        guard let groups = rawGroups as? [[String: Any]] else {
            throw InstallationError.invalidClaudeSettings
        }
        for group in groups {
            guard let rawHooks = group["hooks"], rawHooks is [[String: Any]] else {
                throw InstallationError.invalidClaudeSettings
            }
        }
        return groups
    }

    private static func contains(command: String, in groups: [[String: Any]]) throws -> Bool {
        try groups.contains { group in
            guard let hooks = group["hooks"] as? [[String: Any]] else {
                throw InstallationError.invalidClaudeSettings
            }
            return hooks.contains { $0["command"] as? String == command }
        }
    }

    private static func group(command: String, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": command]],
        ]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    private static func command(hookCommand: String, eventName: String) -> String {
        "\(shellQuote(hookCommand)) \(shellQuote(eventName))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
