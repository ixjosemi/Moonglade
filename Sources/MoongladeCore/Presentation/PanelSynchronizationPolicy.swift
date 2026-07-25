import Foundation

public enum PanelSynchronizationResource: Hashable, Sendable {
    case pointerEventMonitor
    case focusedWindowFallbackTimer
}

public struct PanelSynchronizationSchedule: Equatable, Sendable {
    public let resources: Set<PanelSynchronizationResource>
    public let idlePollInterval: TimeInterval?

    public init(
        resources: Set<PanelSynchronizationResource>,
        idlePollInterval: TimeInterval?
    ) {
        self.resources = resources
        self.idlePollInterval = idlePollInterval
    }
}

public struct PanelSynchronizationResourceTransition: Equatable, Sendable {
    public let installed: Set<PanelSynchronizationResource>
    public let removed: Set<PanelSynchronizationResource>
}

/// Describes the mode-owned resources used by the AppKit panel controller.
/// Focus changes are delivered immediately by workspace notifications; the
/// slow fallback only covers moving a focused window within one application.
public struct PanelSynchronizationPolicy: Sendable {
    public static let focusedWindowFallbackInterval: TimeInterval = 2

    private var resources: Set<PanelSynchronizationResource> = []

    public init() {}

    public static func schedule(for mode: ScreenSelectionMode) -> PanelSynchronizationSchedule {
        switch mode {
        case .pointer:
            return PanelSynchronizationSchedule(
                resources: [.pointerEventMonitor],
                idlePollInterval: nil
            )
        case .focusedWindow:
            return PanelSynchronizationSchedule(
                resources: [.focusedWindowFallbackTimer],
                idlePollInterval: focusedWindowFallbackInterval
            )
        case .allDisplays:
            return PanelSynchronizationSchedule(resources: [], idlePollInterval: nil)
        }
    }

    public mutating func transition(
        to mode: ScreenSelectionMode
    ) -> PanelSynchronizationResourceTransition {
        let nextResources = Self.schedule(for: mode).resources
        let transition = PanelSynchronizationResourceTransition(
            installed: nextResources.subtracting(resources),
            removed: resources.subtracting(nextResources)
        )
        resources = nextResources
        return transition
    }
}

/// Converts high-frequency pointer samples into display-boundary transitions.
public struct PointerDisplayChangeReducer: Equatable, Sendable {
    public private(set) var displayID: UInt32?

    public init(initialDisplayID: UInt32?) {
        displayID = initialDisplayID
    }

    public mutating func update(displayID: UInt32?) -> Bool {
        guard displayID != self.displayID else { return false }
        self.displayID = displayID
        return true
    }
}
