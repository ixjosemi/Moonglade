/// Platform-neutral status-indicator semantics shared by the compact bar and
/// expanded session rows. The app target translates these styles into SwiftUI
/// views while the behavioral runner can verify the user-facing state mapping.
public enum StatusIndicatorStyle: Equatable, Sendable {
    case spinner
    case mutedDot
    case greenDot
    case redDot
}

public extension SessionStatus {
    var indicatorStyle: StatusIndicatorStyle {
        switch self {
        case .working: .spinner
        case .idle: .greenDot
        case .needsAttention: .redDot
        case .ended: .mutedDot
        }
    }
}

public extension SessionStatusSummary.StatusEntry.Kind {
    var indicatorStyle: StatusIndicatorStyle {
        switch self {
        case .running: .spinner
        case .waiting: .greenDot
        case .blocked: .redDot
        }
    }
}

/// One horizontal edge of a compact status wing.
public enum WingEdge: Equatable, Sendable {
    case leading
    case trailing
}

public extension NotchLayout.StatusWingSide {
    /// The edge that meets the screen's outer edge — the concave notch
    /// shoulder on a hardware notch, the rounded capsule end on a pill. The
    /// left wing hangs off the leading edge, the right wing off the trailing
    /// edge, so their outer edges are mirror opposites.
    var outerEdge: WingEdge {
        switch self {
        case .left: .leading
        case .right: .trailing
        }
    }
}

/// How a compact status indicator arranges its round dot and its count. The
/// dot always takes the wing's outer screen-edge slot so both wings present a
/// round glyph to the notch shoulder; a flat numeral pressed against the
/// concave shoulder read as cramped on the blocked (right) wing.
public struct StatusIndicatorLayout: Equatable, Sendable {
    /// Edge the round dot (or spinner glyph) sits on; the count takes the
    /// opposite edge.
    public let dotEdge: WingEdge

    public init(dotEdge: WingEdge) {
        self.dotEdge = dotEdge
    }

    /// Places the dot on the wing's outer edge, mirroring the two wings into
    /// symmetric bookends around the notch.
    public static func forWing(_ side: NotchLayout.StatusWingSide) -> StatusIndicatorLayout {
        StatusIndicatorLayout(dotEdge: side.outerEdge)
    }
}
