import Foundation

/// Chooses the polling cadence from observed evidence rather than UI state.
/// Integrated sessions still arrive through event notifications; the longer
/// interval only affects cold-start discovery when no agent is visible.
public enum ObservationCadence {
    public static let activeInterval: TimeInterval = 5
    public static let idleInterval: TimeInterval = 30

    public static func interval(afterAgentCount count: Int) -> TimeInterval {
        count > 0 ? activeInterval : idleInterval
    }

    public static func staleSessionInterval(afterAgentCount count: Int) -> TimeInterval {
        interval(afterAgentCount: count)
    }
}
