import Foundation

/// Reconciles SwiftUI hover exits with the panel's actual interactive frame.
/// Changing an animated view's size replaces its AppKit tracking area, which
/// can emit `.ended` even while the pointer remains over the new surface.
public enum HoverInteraction {
    /// A delayed hover-exit dismissal must re-check the interaction locks
    /// when it fires: the pointer can click an inline row after the delay was
    /// scheduled but before it expires.
    public static func shouldCollapse(
        isExpanded: Bool,
        isHoveringPanel: Bool,
        openMenuTrackingCount: Int,
        rowInteractionActive: Bool
    ) -> Bool {
        isExpanded
            && !isHoveringPanel
            && openMenuTrackingCount == 0
            && !rowInteractionActive
    }

    /// Resolves the AppKit event gate independently from SwiftUI's animated
    /// presentation geometry. The compact target always follows the visible
    /// bar exactly; once expanded, the whole card width must become clickable
    /// immediately, even before the first expanded measurement arrives.
    public static func interactiveFrame(
        compactFrame: DisplayFrame,
        expandedPanelWidth: CGFloat,
        expandedMaximumHeight: CGFloat,
        measuredContentHeight: CGFloat,
        isExpanded: Bool,
        isHidden: Bool,
        expandedTopInset: CGFloat? = nil
    ) -> DisplayFrame {
        guard !isHidden else {
            return DisplayFrame(minX: 0, minY: 0, width: 0, height: 0)
        }
        guard isExpanded else { return compactFrame }

        let maximumHeight = max(compactFrame.height, expandedMaximumHeight)
        let hasExpandedMeasurement = measuredContentHeight.isFinite
            && measuredContentHeight > compactFrame.height
        let height = hasExpandedMeasurement
            ? min(measuredContentHeight, maximumHeight)
            : maximumHeight
        // The open bubble may float lower than the compact bar (the pill's
        // expanded gap); without its own inset it inherits the bar's top.
        return DisplayFrame(
            minX: 0,
            minY: expandedTopInset ?? compactFrame.minY,
            width: max(0, expandedPanelWidth),
            height: max(0, height)
        )
    }

    /// The hover surface follows what SwiftUI has actually measured, rather
    /// than the larger provisional AppKit click gate. Before the expanded
    /// measurement arrives, it must use that provisional gate as well: the
    /// pointer is allowed to travel from the compact bar into the card while
    /// SwiftUI is still installing its replacement tracking area.
    public static func visibleHoverFrame(
        compactFrame: DisplayFrame,
        expandedPanelWidth: CGFloat,
        expandedMaximumHeight: CGFloat,
        measuredContentHeight: CGFloat,
        isExpanded: Bool,
        isHidden: Bool,
        expandedTopInset: CGFloat? = nil
    ) -> DisplayFrame {
        guard !isHidden else {
            return DisplayFrame(minX: 0, minY: 0, width: 0, height: 0)
        }
        guard isExpanded else { return compactFrame }

        let maximumHeight = max(compactFrame.height, expandedMaximumHeight)
        let hasExpandedMeasurement = measuredContentHeight.isFinite
            && measuredContentHeight > compactFrame.height
        let measuredHeight = hasExpandedMeasurement
            ? measuredContentHeight
            : maximumHeight
        return DisplayFrame(
            minX: 0,
            minY: expandedTopInset ?? compactFrame.minY,
            width: max(0, expandedPanelWidth),
            height: min(max(compactFrame.height, measuredHeight), maximumHeight)
        )
    }

    /// SwiftUI can report an active hover from the disappearing expanded card
    /// while its collapse spring is still running. Only the logical compact
    /// target is allowed to start a new expansion.
    public static func shouldScheduleExpansion(
        pointer: DisplayPoint,
        compactFrame: DisplayFrame,
        panelOriginX: CGFloat,
        panelTopY: CGFloat,
        isExpanded: Bool,
        cornerStyle: HangingNotchCornerStyle = .hangingNotch,
        topShoulderRadius: CGFloat = 0,
        bottomCornerRadius: CGFloat = 0
    ) -> Bool {
        guard !isExpanded else { return false }
        return pointerIsInsideHangingSilhouette(
            pointer,
            localTopLeadingFrame: compactFrame,
            panelOriginX: panelOriginX,
            panelTopY: panelTopY,
            cornerStyle: cornerStyle,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    public static func pointerIsInsideHangingSilhouette(
        _ pointer: DisplayPoint,
        localTopLeadingFrame: DisplayFrame,
        panelOriginX: CGFloat,
        panelTopY: CGFloat,
        cornerStyle: HangingNotchCornerStyle = .hangingNotch,
        topShoulderRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> Bool {
        let localX = pointer.x - panelOriginX - localTopLeadingFrame.minX
        let localY = panelTopY - localTopLeadingFrame.minY - pointer.y
        return HangingNotchGeometry.contains(
            DisplayPoint(x: localX, y: localY),
            width: localTopLeadingFrame.width,
            height: localTopLeadingFrame.height,
            style: cornerStyle,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    public static func pointerIsInside(
        _ pointer: DisplayPoint,
        localTopLeadingFrame: DisplayFrame,
        panelOriginX: CGFloat,
        panelTopY: CGFloat
    ) -> Bool {
        let globalMinX = panelOriginX + localTopLeadingFrame.minX
        let globalMaxX = globalMinX + localTopLeadingFrame.width
        let globalMaxY = panelTopY - localTopLeadingFrame.minY
        let globalMinY = globalMaxY - localTopLeadingFrame.height
        return pointer.x >= globalMinX && pointer.x < globalMaxX
            && pointer.y >= globalMinY && pointer.y < globalMaxY
    }
}
