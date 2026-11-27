import CoreFoundation

/// A Darwin notification channel. The Darwin notify center is machine-wide,
/// so every process on the machine shares a channel by name; `standard` is
/// the one the app, the CLI and the bundled plugins agree on.
public struct StateChangeNotifier: Sendable {
    public static let standard = StateChangeNotifier(notificationName: "com.moonglade.stateChanged")

    public let notificationName: String

    /// `package` so tests can scope a repository and its store to a channel
    /// no other process posts to; production always uses `standard`.
    package init(notificationName: String) {
        self.notificationName = notificationName
    }

    public func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}
