import Foundation

/// Shared expanded-menu spacing. Keeping these values outside the SwiftUI
/// tree makes the compact horizontal layout explicit and testable.
public enum SessionMenuLayout {
    public enum ActionMode: Equatable, Sendable {
        case menu
        case renaming
        case confirmingKill
    }

    public static let errorRowHeight: CGFloat = 25
    public static let contentHorizontalInset: CGFloat = 4
    /// Gap between the notch bar — whose wings now hold the header — and the
    /// first session row.
    public static let listTopPadding: CGFloat = 6
    /// Leading inset for the session rows' own content, shared with the
    /// header math below so both columns stay aligned.
    public static let sessionRowLeadingInset: CGFloat = 12
    /// Outer insets for header content living in the expanded bar wings,
    /// chosen so the header columns line up with the session rows below:
    /// leading matches the row's agent icon (8pt centering gutter + 4pt card
    /// inset + 12pt row leading), trailing matches the row's chevron button
    /// (8 + 4 + 12pt chevron trailing).
    public static let expandedHeaderLeadingInset: CGFloat = 24
    public static let expandedHeaderTrailingInset: CGFloat = 24
    public static let cardStackSpacing: CGFloat = 2
    public static let cardBottomPadding: CGFloat = 6
    public static let sessionListBottomPadding: CGFloat = 4
    public static let sessionRowHeight: CGFloat = 52
    /// Three full rows plus the inline actions fit without shifting the row
    /// that received the click out from under the pointer. Longer lists still
    /// scroll inside the card.
    public static let maximumSessionListHeight: CGFloat = 300
    public static func expandedActionsHeight(for mode: ActionMode) -> CGFloat {
        switch mode {
        case .menu:
            let actionRowsHeight: CGFloat = 4 * 32
            let separatorHeight: CGFloat = 3
            let verticalInsets: CGFloat = 4 + 9
            return actionRowsHeight + separatorHeight + verticalInsets
        case .renaming:
            return 34
        case .confirmingKill:
            return 44
        }
    }

    /// The largest card the panel must accommodate: a fitting three-row
    /// expanded list and every vertical inset rendered by `SessionMenuCard`.
    /// The header lives in the bar wings, so it adds no card height.
    public static func maximumCardHeight(hasError: Bool = false) -> CGFloat {
        listTopPadding
            + maximumSessionListHeight
            + sessionListBottomPadding
            + cardBottomPadding
            + (hasError ? errorRowHeight : 0)
    }

    public static func sessionListHeight(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> CGFloat {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight(for: .menu) : 0
        return min(rowsHeight + actionsHeight, maximumSessionListHeight)
    }

    public static func sessionListHeight(
        sessionCount: Int,
        actionMode: ActionMode?
    ) -> CGFloat {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = actionMode.map(expandedActionsHeight(for:)) ?? 0
        return min(rowsHeight + actionsHeight, maximumSessionListHeight)
    }

    /// A scroll affordance belongs only to a list whose expanded content
    /// cannot fit in its assigned viewport. Showing it for a fitting row
    /// makes the pointer target move unnecessarily while the row opens.
    public static func requiresScrolling(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> Bool {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight(for: .menu) : 0
        return rowsHeight + actionsHeight > maximumSessionListHeight
    }
}
