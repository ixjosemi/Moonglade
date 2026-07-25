import Foundation

/// When the widget jumps to the display the pointer is on, AppKit reports the
/// bar as hovered even though the pointer never moved — an immediate
/// hover-expansion would pop the menu open for no user intent. The gate stays
/// locked after a screen jump until the pointer actually travels, so only a
/// deliberate approach opens the menu. Pure value type: the app layer feeds it
/// global screen coordinates.
public struct PointerMovementGate: Equatable, Sendable {
    /// Manhattan distance that reads as a real approach rather than tracking
    /// noise from the window server.
    public static let unlockThreshold: CGFloat = 6

    private var lockedAt: DisplayPoint?
    public private(set) var isUnlocked: Bool

    public init() {
        lockedAt = nil
        isUnlocked = true
    }

    public mutating func lock(at point: DisplayPoint) {
        lockedAt = point
        isUnlocked = false
    }

    @discardableResult
    public mutating func update(pointerLocation: DisplayPoint) -> Bool {
        guard !isUnlocked else { return true }
        guard let lockedAt else {
            isUnlocked = true
            return true
        }
        let travel = abs(pointerLocation.x - lockedAt.x) + abs(pointerLocation.y - lockedAt.y)
        guard travel >= Self.unlockThreshold else { return false }
        isUnlocked = true
        self.lockedAt = nil
        return true
    }
}
