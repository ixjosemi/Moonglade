import Foundation

public struct NotchLayout: Equatable, Sendable {
    /// How the bar presents itself, derived from the screen it sits on: a
    /// real camera housing gets the notch-attached bar, every other display
    /// gets a compact notch-style drop attached to the screen edge.
    public enum Presentation: Equatable, Sendable {
        case notch
        case pill
    }

    public enum StatusWingSide: Equatable, Sendable {
        case left
        case right
    }

    public let presentation: Presentation
    public let width: CGFloat
    public let height: CGFloat
    /// Distance between the screen's top edge and the visible surface. Zero
    /// for a hardware notch, which must read as part of the screen edge; the
    /// virtual pill floats slightly detached instead.
    public let topGap: CGFloat
    /// Panel height while the session menu hangs below the notch bar.
    public let expandedHeight: CGFloat
    public let originX: CGFloat
    public let originY: CGFloat
    public let notchWidth: CGFloat
    private let notchLeadingX: CGFloat?

    /// Corner treatment matching the presentation: the notch flares into the
    /// screen edge with concave shoulders, the detached pill rounds every
    /// corner into a capsule/bubble.
    public var cornerStyle: HangingNotchCornerStyle {
        presentation == .pill ? .bubble : .hangingNotch
    }

    /// Extra space the expanded header band gains over the compact bar. Only
    /// the pill needs it; the panel shell already accounts for it in
    /// `expandedHeight`.
    public var expandedHeaderTopPadding: CGFloat {
        presentation == .pill ? Self.pillExpandedHeaderTopPadding : 0
    }

    /// Gap between the screen edge and the open bubble. The notch stays
    /// fused to the edge in both states.
    public var expandedTopGap: CGFloat {
        presentation == .pill ? Self.pillExpandedTopGap : 0
    }

    /// Extra space between the last session row and the expanded surface's
    /// bottom edge, shared by the notch drop and the pill bubble.
    public var expandedBottomPadding: CGFloat { Self.expandedBottomPadding }

    /// Extra horizontal inset for expanded content. The hanging notch's
    /// concave shoulders pull its straight sides `topShoulderRadius` inside
    /// the panel edges, so content must absorb that absolutely to keep the
    /// same visual margin from the visible edge; the bubble's sides are the
    /// panel edges themselves and need nothing extra.
    public var expandedContentSideInset: CGFloat {
        presentation == .notch ? HangingNotchMetrics.topShoulderRadius : 0
    }

    /// The outer expanded shell remains just wider than its content so text
    /// can sit close to the straight sides without entering their corners.
    public static let expandedPanelWidth: CGFloat = 800
    /// Session details use nearly all of the panel width; their own row
    /// padding keeps text clear of the small remaining corner gutter.
    public static let expandedContentWidth: CGFloat = 784
    public static let expandedCurveGutter: CGFloat = 8

    public static func contentWidth(forExpandedPanelWidth panelWidth: CGFloat) -> CGFloat {
        guard panelWidth.isFinite else { return 1 }
        return min(
            expandedContentWidth,
            max(1, panelWidth - 2 * expandedCurveGutter)
        )
    }

    /// The panel has room for three expanded rows without creating a nested
    /// scroll surface. Longer lists retain their own bounded scroll view.
    public static let menuMaxHeight = SessionMenuLayout.maximumCardHeight
    /// Breathing room between the pill and the bottom of the menu-bar strip,
    /// so the capsule floats inside the strip instead of sitting flush on
    /// the boundary with app content.
    public static let pillBottomInset: CGFloat = 4
    /// The detached pill floats this far below the screen's top edge. The
    /// visible height shrinks by gap plus bottom inset, so the capsule stays
    /// inside the menu-bar strip and never overlaps app content.
    public static let pillTopGap: CGFloat = 4
    /// The expanded bubble detaches further than the compact capsule: a
    /// hanging card glued to the screen edge reads as a notch again, so it
    /// slides down to this gap while open.
    public static let pillExpandedTopGap: CGFloat = 8
    /// Extra room above the expanded header in pill mode: the bubble has no
    /// camera band, so without it the title and gear hug the rounded top
    /// edge. The notch keeps zero — its header sits beside the camera.
    public static let pillExpandedHeaderTopPadding: CGFloat = 14
    /// Room under the last session row on every presentation: the expanded
    /// card's lateral margins measure ~18pt from the visible edge, and the
    /// card's own bottom insets alone left barely half that below the list.
    public static let expandedBottomPadding: CGFloat = 8
    /// A screen without a menu bar reports zero height; use the standard.
    public static let fallbackMenuBarHeight: CGFloat = 24

    public init(
        screenMinX: CGFloat,
        screenWidth: CGFloat,
        screenMaxY: CGFloat,
        safeAreaTop: CGFloat,
        leftNotchEdgeX: CGFloat?,
        rightNotchEdgeX: CGFloat?,
        menuBarHeight: CGFloat = 0
    ) {
        let centerX = screenMinX + screenWidth / 2
        // A display narrower than the ideal menu still gets a fully visible
        // panel. Normal macOS displays are comfortably wider than 720 pt.
        let expandedWidth = min(Self.expandedPanelWidth, max(1, screenWidth))
        if safeAreaTop > 0, let leftNotchEdgeX, let rightNotchEdgeX {
            presentation = .notch
            notchLeadingX = leftNotchEdgeX
            topGap = 0
            height = safeAreaTop
            notchWidth = max(rightNotchEdgeX - leftNotchEdgeX, 168)
            width = expandedWidth
            // Centre the broad expanded card on the physical camera housing,
            // then keep it inside this display. The bar itself remains pinned
            // to the actual notch through `barLeadingOffset`.
            let notchCenterX = (leftNotchEdgeX + rightNotchEdgeX) / 2
            originX = min(
                max(notchCenterX - width / 2, screenMinX),
                screenMinX + screenWidth - width
            )
            originY = screenMaxY - height
        } else {
            presentation = .pill
            notchLeadingX = nil
            // The gap plus the pill must stay entirely within the menu-bar
            // strip so neither ever overlaps the app content below it.
            let menuBar = menuBarHeight > 0 ? menuBarHeight : Self.fallbackMenuBarHeight
            topGap = Self.pillTopGap
            height = max(1, menuBar - Self.pillTopGap - Self.pillBottomInset)
            notchWidth = 0
            width = expandedWidth
            originX = centerX - width / 2
            originY = screenMaxY - height
        }
        // The panel keeps its top on the screen edge; the bottom padding,
        // the expanded gap, and the pill's header padding all live inside
        // it, so the expanded shell grows by each to keep the tallest card
        // fully inside the window.
        expandedHeight = height + Self.menuMaxHeight
            + Self.expandedBottomPadding
            + (presentation == .pill
                ? Self.pillExpandedTopGap + Self.pillExpandedHeaderTopPadding
                : 0)
    }

    /// Width one status indicator occupies in the compact bar: glyph, a
    /// tight gap, and up to two digits. The slot is fixed and the wing
    /// widths below add up to exactly the rendered content, so no invisible
    /// slack ends up parked at one end of the bar.
    public static let statusIndicatorSlotWidth: CGFloat = 30
    /// Gap between adjacent indicators; shared by the width formula and the
    /// view so both always agree.
    public static let statusIndicatorSpacing: CGFloat = 6
    /// Breathing room at each end of a virtual-pill status wing. The slot
    /// centering already leaves ~4-5pt of slack beside the outermost glyph,
    /// so the explicit inset stays slim to keep the capsule snug.
    public static let statusWingEdgePadding: CGFloat = 6
    /// Breathing room the outermost glyph keeps *past* the shoulder radius, so
    /// it clears the curve's tangent instead of hugging the exact point where
    /// the flare begins. Landing flush on the straight side reads covered but
    /// cramped; a few points more lets the glyph sit clearly inside the black.
    public static let hardwareNotchOuterWingBreathingRoom: CGFloat = 4
    /// Outer inset of a hardware-notch wing, identical on both ends. The
    /// concave shoulder is a quarter-circle of radius
    /// `HangingNotchMetrics.topShoulderRadius`, so below that band the black
    /// silhouette's straight side sits exactly one shoulder radius inside the
    /// bar's outer edge. Any glyph closer to the edge than that lands where
    /// the curve has already peeled away and gets bisected onto the wallpaper
    /// — the "cramped red dot" bug. Pinning the outer inset to the shoulder
    /// radius plus a little breathing room keeps the outermost glyph clearly
    /// inside the straight side, and keeps the clearance in lockstep with the
    /// curve if the radius changes. Applied symmetrically so both wings read
    /// balanced.
    public static let hardwareNotchOuterWingPadding: CGFloat =
        HangingNotchMetrics.topShoulderRadius + hardwareNotchOuterWingBreathingRoom
    public static let hardwareNotchRightOuterWingPadding = hardwareNotchOuterWingPadding
    /// The camera-facing edge of a hardware-notch wing reserves enough room
    /// to keep the counter cluster fully clear of the physical camera cutout.
    public static let hardwareNotchInnerWingPadding: CGFloat = 12
    /// A small empty continuation after a physical notch, just enough to
    /// finish the hanging silhouette without mirroring a status wing.
    public static let hardwareNotchFakeRightWingWidth: CGFloat = 28

    /// The left outer-edge padding for a compact status wing. See the
    /// side-specific properties for the wider right counter clearance.
    public var statusWingEdgePadding: CGFloat {
        switch presentation {
        case .notch: Self.hardwareNotchOuterWingPadding
        case .pill: Self.statusWingEdgePadding
        }
    }

    /// Padding on the outer and camera-facing edges of the left wing.
    public var leftStatusWingLeadingPadding: CGFloat {
        presentation == .notch ? Self.hardwareNotchOuterWingPadding : Self.statusWingEdgePadding
    }

    public var leftStatusWingTrailingPadding: CGFloat {
        presentation == .notch ? Self.hardwareNotchInnerWingPadding : Self.statusWingEdgePadding
    }

    /// Padding on the camera-facing and outer edges of the right wing.
    public var rightStatusWingLeadingPadding: CGFloat {
        presentation == .notch ? Self.hardwareNotchInnerWingPadding : Self.statusWingEdgePadding
    }

    public var rightStatusWingTrailingPadding: CGFloat {
        presentation == .notch ? Self.hardwareNotchRightOuterWingPadding : Self.statusWingEdgePadding
    }

    /// Compact status-bar wing sizing: one slot per *visible* indicator —
    /// zero-count kinds claim nothing — plus the requested edge padding.
    /// A completely quiet bar keeps the same minimum outer clearance as a
    /// populated wing. The optional padding lets the physical notch stay
    /// compact while the virtual pill remains comfortably spaced.
    public static func statusWingWidth(
        visibleIndicatorCount: Int,
        showsIdleMark: Bool,
        edgePadding: CGFloat = NotchLayout.statusWingEdgePadding
    ) -> CGFloat {
        statusWingWidth(
            visibleIndicatorCount: visibleIndicatorCount,
            showsIdleMark: showsIdleMark,
            leadingPadding: edgePadding,
            trailingPadding: edgePadding
        )
    }

    /// Compact status-wing width with independently controllable leading and
    /// trailing insets. Hardware-notch wings use side-specific values so the
    /// camera gap and each outer glyph both receive the required clearance.
    public static func statusWingWidth(
        visibleIndicatorCount: Int,
        showsIdleMark: Bool,
        leadingPadding: CGFloat,
        trailingPadding: CGFloat
    ) -> CGFloat {
        let leading = leadingPadding.isFinite ? max(0, leadingPadding) : 0
        let trailing = trailingPadding.isFinite ? max(0, trailingPadding) : 0
        guard visibleIndicatorCount > 0 else {
            return showsIdleMark ? max(46, 28 + leading + trailing) : 0
        }
        return CGFloat(visibleIndicatorCount) * statusIndicatorSlotWidth
            + CGFloat(max(visibleIndicatorCount - 1, 0)) * statusIndicatorSpacing
            + leading + trailing
    }

    /// Side-aware status-wing width. Keeping the side explicit prevents the
    /// mirrored right wing from accidentally reusing the left wing's insets.
    public func statusWingWidth(
        side: StatusWingSide,
        visibleIndicatorCount: Int,
        showsIdleMark: Bool
    ) -> CGFloat {
        let leadingPadding: CGFloat
        let trailingPadding: CGFloat
        switch side {
        case .left:
            leadingPadding = leftStatusWingLeadingPadding
            trailingPadding = leftStatusWingTrailingPadding
        case .right:
            leadingPadding = rightStatusWingLeadingPadding
            trailingPadding = rightStatusWingTrailingPadding
        }
        return Self.statusWingWidth(
            visibleIndicatorCount: visibleIndicatorCount,
            showsIdleMark: showsIdleMark,
            leadingPadding: leadingPadding,
            trailingPadding: trailingPadding
        )
    }

    /// Horizontal origin of the compact bar inside the broad panel. On a
    /// notched display this preserves the hardware-notch attachment even
    /// though the expanded card is far wider than the collapsed wings.
    public func barLeadingOffset(leftWidth: CGFloat, rightWidth: CGFloat) -> CGFloat {
        switch presentation {
        case .notch:
            return (notchLeadingX ?? originX) - leftWidth - originX
        case .pill:
            return (width - (leftWidth + notchWidth + rightWidth)) / 2
        }
    }

    /// Widths of the expanded header wings flanking the camera cutout,
    /// measured inside the expanded panel. Pill mode has no cutout
    /// (notchWidth == 0), so the wings simply split the panel.
    public func expandedHeaderWingWidths() -> (left: CGFloat, right: CGFloat) {
        switch presentation {
        case .notch:
            let left = max(0, (notchLeadingX ?? originX) - originX)
            return (left, max(0, width - left - notchWidth))
        case .pill:
            return (width / 2, width / 2)
        }
    }

    /// When statuses exist only to the left of the camera, add a simple empty
    /// right wing for a finished silhouette. The real left wing stays intact;
    /// no width is mirrored back into it, and a real right status takes over
    /// as soon as one exists.
    public func balancedStatusWingWidths(
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        guard presentation == .notch, leftWidth > 0, rightWidth == 0 else {
            return (leftWidth, rightWidth)
        }
        return (leftWidth, Self.hardwareNotchFakeRightWingWidth)
    }
}
