import Foundation

/// Which row of a list the pointer is on, held in one place.
///
/// The obvious spelling — a `@State` flag per row, each set from its own
/// `.onHover` — assumes the two callbacks of a hand-off arrive in order. They
/// do not always: resizing an animated view replaces its AppKit tracking area,
/// which can emit an exit for a row the pointer has already left *after* the
/// next row reported its enter (see `HoverInteraction`). Independent flags then
/// disagree — two rows lit, or the late exit clearing the row the pointer is
/// actually on and leaving none.
///
/// One selection cannot disagree with itself. An enter always wins, and an exit
/// only counts when it comes from the row currently held, so a stale one is
/// discarded instead of clearing a live highlight.
public struct HoverSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var hovered: ID?

    public init() {}

    public mutating func update(_ id: ID, isHovered: Bool) {
        if isHovered {
            hovered = id
        } else if hovered == id {
            hovered = nil
        }
    }

    /// Forgets the current row. For when the list itself is swapped out and the
    /// rows that owed an exit no longer exist to send one.
    public mutating func clear() {
        hovered = nil
    }
}
