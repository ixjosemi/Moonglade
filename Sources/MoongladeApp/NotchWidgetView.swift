import AppKit
import Combine
import SwiftUI

import MoongladeCore

struct NotchPointerSnapshot: Equatable {
    let isInside: Bool
    let revision: UInt
}

/// The AppKit hosting view owns one fixed tracking area for its entire
/// lifetime. SwiftUI observes its normalized result instead of replacing a
/// tracking area every time the hanging card changes height.
@MainActor
final class NotchPointerTracker: ObservableObject {
    @Published private(set) var snapshot = NotchPointerSnapshot(
        isInside: false,
        revision: 0
    )
    let hoverExpansionRequests = PassthroughSubject<DisplayPoint, Never>()
    private var reducer = PointerSampleReducer()

    @discardableResult
    func update(isInside: Bool, location: DisplayPoint) -> DisplayPoint {
        let reduction = reducer.reduce(isInside: isInside, location: location)
        if let containment = reduction.containmentChange {
            snapshot = NotchPointerSnapshot(
                isInside: containment.isInside,
                revision: containment.revision
            )
        }
        return reduction.location
    }

    func requestHoverExpansion(at location: DisplayPoint) {
        hoverExpansionRequests.send(location)
    }
}

struct NotchWidgetView: View {
    @Bindable var store: StateStore
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    @AppStorage("glassFrostRadiusNotch") private var notchFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityNotch") private var notchTintOpacity = NotchGlassStyle.defaultTintOpacity
    @AppStorage("glassFrostRadiusPill") private var pillFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityPill") private var pillTintOpacity = NotchGlassStyle.defaultTintOpacity
    @Environment(\.openSettings) private var openSettings
    let layout: NotchLayout
    @ObservedObject var pointerTracker: NotchPointerTracker
    let requestPointerRefresh: () -> Void
    let onInteractiveRegionChange: (HangingNotchInteractionRegion) -> Void
    let onKeyboardFocusChange: (Bool) -> Void
    let onMenuVisibilityChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var rippleTrigger = 0
    @State private var collapseWorkItem: DispatchWorkItem?
    @State private var hoverExpandWorkItem: DispatchWorkItem?
    @State private var isHoveringPanel = false
    @State private var openMenuTrackingCount = 0
    @State private var rowInteractionActive = false
    @State private var outsideClickMonitor: Any?
    @State private var latestMeasuredContentHeight: CGFloat = 0

    var body: some View {
        let summary = SessionStatusSummary(
            sessions: store.sessions,
            acknowledgments: store.acknowledgments
        )
        let shouldHide = summary.activeSessionCount == 0 && hideWhenEmpty
        let leftEntries = summary.visibleEntries.filter { $0.kind != .blocked }
        let rightEntries = summary.visibleEntries.filter { $0.kind == .blocked }
        let showsIdleMark = summary.activeSessionCount == 0
        let naturalLeftWidth = layout.statusWingWidth(
            side: .left,
            visibleIndicatorCount: leftEntries.count,
            showsIdleMark: showsIdleMark
        )
        let naturalRightWidth = layout.statusWingWidth(
            side: .right,
            visibleIndicatorCount: rightEntries.count,
            showsIdleMark: false
        )
        let wingWidths = layout.balancedStatusWingWidths(
            leftWidth: naturalLeftWidth,
            rightWidth: naturalRightWidth
        )
        let leftWidth = wingWidths.left
        let rightWidth = wingWidths.right
        let barWidth = leftWidth + layout.notchWidth + rightWidth
        let barLeadingOffset = layout.barLeadingOffset(
            leftWidth: leftWidth,
            rightWidth: rightWidth
        )
        let menuWidth = layout.width
        // The notch's straight sides sit a shoulder radius inside the panel,
        // so its card content narrows by the same amount per side to keep
        // the visual margin the bubble gets from its own edges.
        let menuContentWidth = NotchLayout.contentWidth(forExpandedPanelWidth: menuWidth)
            - 2 * layout.expandedContentSideInset
        let headerWings = layout.expandedHeaderWingWidths()
        let compactInteractiveFrame = DisplayFrame(
            minX: barLeadingOffset,
            minY: layout.topGap,
            width: barWidth,
            height: layout.height
        )

        // One view tree for both presentations: the bar never leaves the
        // hierarchy, so expanding animates the shared silhouette growing out
        // of the notch instead of cross-fading between two layouts. The bar
        // stays pinned to the camera housing the whole time: the outer offset
        // and the row's inner offset always sum to barLeadingOffset.
        ZStack(alignment: .topLeading) {
            if !shouldHide {
                VStack(alignment: .leading, spacing: 0) {
                    // The top row swaps between the compact status bar and the
                    // expanded header living in the wings beside the camera.
                    // Both layers stay resident: each inner offset cancels the
                    // outer animated offset, so every camera cutout remains
                    // pinned over the housing for the whole spring and the
                    // swap reads as a pure cross-fade. Opacity-0 views still
                    // hit-test, hence the explicit gates.
                    ZStack(alignment: .topLeading) {
                        Button(action: openMenu) {
                            barRow(
                                leftEntries: leftEntries,
                                rightEntries: rightEntries,
                                showsIdleMark: showsIdleMark,
                                leftWidth: leftWidth,
                                rightWidth: rightWidth
                            )
                            .contentShape(silhouette)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show active sessions")
                        .frame(width: barWidth, height: layout.height)
                        .offset(x: isExpanded ? barLeadingOffset : 0)
                        .opacity(isExpanded ? 0 : 1)
                        .allowsHitTesting(!isExpanded)

                        expandedHeaderRow(
                            sessionCount: store.sessions.count,
                            wings: headerWings
                        )
                        .frame(width: menuWidth, height: layout.height)
                        .offset(x: isExpanded ? 0 : -barLeadingOffset)
                        .opacity(isExpanded ? 1 : 0)
                        .allowsHitTesting(isExpanded)
                    }
                    if isExpanded {
                        SessionMenuCard(
                            sessions: store.sessions,
                            stateDirectoryURL: store.stateDirectoryURL,
                            dismiss: collapseMenu,
                            acknowledge: { store.acknowledge($0) },
                            sessionTitle: { store.displayName(for: $0) },
                            overrideName: { store.nameOverrides.displayName(for: $0) },
                            rename: { store.rename($0, to: $1) },
                            setKeyboardFocus: onKeyboardFocusChange,
                            onRowInteractionChange: { isActive in
                                rowInteractionActive = isActive
                                if isActive {
                                    cancelPendingCollapse()
                                } else {
                                    settleAfterDetachedInteraction()
                                }
                            }
                        )
                        .frame(width: menuContentWidth)
                        .frame(width: menuWidth, alignment: .center)
                        .transition(.opacity)
                    }
                }
                .frame(width: isExpanded ? menuWidth : barWidth, alignment: .topLeading)
                // The pill's expanded bubble has no camera band above the
                // header, so it gains breathing room between its rounded top
                // edge and the title, plus matching room under the last row;
                // collapsed keeps the tight capsule.
                .padding(.top, isExpanded ? layout.expandedHeaderTopPadding : 0)
                .padding(.bottom, isExpanded ? layout.expandedBottomPadding : 0)
                .background(
                    // The band beside the camera stays explicit pure black so
                    // the drop reads as part of the screen edge; below it the
                    // scrim fades into behind-window glass. Pill mode has no
                    // camera to hide and keeps a flat tint over the glass.
                    //
                    // The ripple warps only the scrim: it is pure vector, so
                    // it always rasterizes. The content above holds AppKit-
                    // backed views (the session list's scroll view) that a
                    // layer effect would render blank, and the glass below is
                    // window-server fed and must stay out of any effect.
                    NotchGlassScrim(
                        silhouette: silhouette,
                        barBandHeight: layout.height,
                        presentation: layout.presentation,
                        tintOpacity: layout.presentation == .pill
                            ? pillTintOpacity : notchTintOpacity
                    )
                    .modifier(ExpansionRippleEffect(trigger: rippleTrigger))
                )
                .background(
                    NotchGlassBackdrop(
                        presentation: layout.presentation,
                        frostRadius: layout.presentation == .pill
                            ? pillFrostRadius : notchFrostRadius
                    )
                )
                // Do not clip the compact counters to the curved silhouette:
                // the physical camera already owns the central cutout, while
                // clipping here shaves off the leading spinner before it can
                // reach the safe area beside that cutout.
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: InteractiveHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                // Gestures live on the silhouette, not the outer frame: the
                // panel is always expanded-height, so the outer frame covers
                // transparent dead space below the visible shape.
                .contentShape(silhouette)
                .contextMenu {
                    SettingsLink {
                        Label("Moonglade Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit Moonglade", systemImage: "power")
                    }
                }
                // A session row's context menu is an NSMenu window outside
                // this view: opening it fires a hover exit that would
                // collapse the panel — and the menu with it — mid-read.
                .onReceive(
                    NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
                ) { _ in
                    openMenuTrackingCount += 1
                    cancelPendingCollapse()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
                ) { _ in
                    openMenuTrackingCount = max(0, openMenuTrackingCount - 1)
                    settleAfterDetachedInteraction()
                }
                // Offset the rendered surface *after* attaching its shape and
                // hover tracking. Applying offset first leaves those later
                // modifiers at the unshifted 720-point panel origin: pill
                // hover then misses entirely and notch hover lands in empty
                // space to the left of the visible bar. The vertical offset
                // floats the pill below the screen edge — further while the
                // bubble is open; the notch keeps zero gap in both states.
                .offset(
                    x: isExpanded ? 0 : barLeadingOffset,
                    y: isExpanded ? layout.expandedTopGap : layout.topGap
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86),
            value: isExpanded
        )
        .onChange(of: pointerTracker.snapshot) { _, snapshot in
            handlePointerContainmentChange(snapshot)
        }
        .onReceive(pointerTracker.hoverExpansionRequests) { location in
            handleHoverExpansionRequest(location, compactFrame: compactInteractiveFrame)
        }
        .onAppear {
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
            requestPointerRefresh()
            onMenuVisibilityChange(isExpanded)
        }
        .onPreferenceChange(InteractiveHeightPreferenceKey.self) { measuredHeight in
            latestMeasuredContentHeight = measuredHeight
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: measuredHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
        }
        .onChange(of: isExpanded) { _, isVisible in
            if isVisible, !reduceMotion {
                rippleTrigger += 1
            }
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isVisible,
                isHidden: shouldHide
            )
            updateOutsideClickMonitor(menuIsVisible: isVisible)
            onMenuVisibilityChange(isVisible)
        }
        .onChange(of: compactInteractiveFrame) { _, newFrame in
            publishInteractiveRegion(
                compactFrame: newFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
            requestPointerRefresh()
        }
        .onChange(of: shouldHide) { _, isHidden in
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: isHidden
            )
        }
        .onDisappear {
            updateOutsideClickMonitor(menuIsVisible: false)
            onMenuVisibilityChange(false)
        }
        .onChange(of: store.sessions.isEmpty) { _, isNowEmpty in
            if isNowEmpty { collapseMenu() }
        }
    }

    // MARK: Bar

    private func barRow(
        leftEntries: [SessionStatusSummary.StatusEntry],
        rightEntries: [SessionStatusSummary.StatusEntry],
        showsIdleMark: Bool,
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> some View {
        // Wings span the full bar height so the click targets reach the top
        // edge of the screen — the natural place to slam the pointer. Only
        // states with a nonzero count take up a slot. Every indicator is a
        // fixed slot and wing widths add up exactly, so padding stays
        // symmetric on both pill and notch — no slack parked at either end.
        HStack(spacing: 0) {
            Group {
                if leftEntries.isEmpty {
                    if showsIdleMark {
                        // Quiet empty state: the app is awake but no agent
                        // is running.
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.32))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("No active agents")
                    }
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: layout.leftStatusWingLeadingPadding)
                        HStack(spacing: NotchLayout.statusIndicatorSpacing) {
                            ForEach(leftEntries) { entry in
                                StatusSummaryIndicator(
                                    kind: entry.kind,
                                    count: entry.count,
                                    indicatorLayout: .forWing(.left)
                                )
                            }
                        }
                        Spacer(minLength: layout.leftStatusWingTrailingPadding)
                    }
                    .frame(width: leftWidth, height: layout.height, alignment: .leading)
                }
            }
            .frame(width: leftWidth, height: layout.height, alignment: .leading)
            Color.clear
                .frame(width: layout.notchWidth, height: layout.height)
            Group {
                if !rightEntries.isEmpty {
                    HStack(spacing: 0) {
                        Spacer(minLength: layout.rightStatusWingLeadingPadding)
                        HStack(spacing: NotchLayout.statusIndicatorSpacing) {
                            ForEach(rightEntries) { entry in
                                StatusSummaryIndicator(
                                    kind: entry.kind,
                                    count: entry.count,
                                    indicatorLayout: .forWing(.right)
                                )
                            }
                        }
                        Spacer(minLength: layout.rightStatusWingTrailingPadding)
                    }
                    .frame(width: rightWidth, height: layout.height, alignment: .trailing)
                }
            }
            .frame(width: rightWidth, height: layout.height, alignment: .trailing)
        }
    }

    /// Expanded replacement for the compact bar row: the menu header claims
    /// the wings beside the camera cutout instead of a row below it, so the
    /// space flanking the housing carries information rather than padding.
    /// Fixed-height frames center the content vertically in both bar heights.
    private func expandedHeaderRow(
        sessionCount: Int,
        wings: (left: CGFloat, right: CGFloat)
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Active sessions")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
            .padding(
                .leading,
                SessionMenuLayout.expandedHeaderLeadingInset + layout.expandedContentSideInset
            )
            .frame(width: wings.left, height: layout.height, alignment: .leading)
            Color.clear
                .frame(width: layout.notchWidth, height: layout.height)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(sessionCount, format: .number)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
                SettingsGearButton {
                    // The settings window is a normal app window: activate
                    // first so it opens frontmost and key — the notch panel
                    // itself never takes that role.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                    collapseMenu()
                }
            }
            .padding(
                .trailing,
                SessionMenuLayout.expandedHeaderTrailingInset + layout.expandedContentSideInset
            )
            .frame(width: wings.right, height: layout.height, alignment: .trailing)
        }
        .lineLimit(1)
    }

    /// Bar and menu share one silhouette. On a notched display the top
    /// shoulders curve inward from the screen edge while the lower corners
    /// remain circular; the detached pill instead rounds every corner — a
    /// capsule collapsed, a bubble expanded. Compact and expanded use
    /// identical radii; expansion only adds the straight sides between them.
    private var silhouette: HangingNotchShape {
        HangingNotchShape(
            style: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
    }

    // MARK: Menu visibility

    private static let hoverExpandDelay: TimeInterval = 0.15

    private func scheduleExpansion() {
        guard !isExpanded, hoverExpandWorkItem == nil else { return }
        let workItem = DispatchWorkItem {
            isExpanded = true
            hoverExpandWorkItem = nil
        }
        hoverExpandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExpandDelay, execute: workItem)
    }

    private func openMenu() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        cancelPendingCollapse()
        isExpanded = true
    }

    private func publishInteractiveRegion(
        compactFrame: DisplayFrame,
        measuredContentHeight: CGFloat,
        isExpanded: Bool,
        isHidden: Bool
    ) {
        let frame = HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: layout.width,
            expandedMaximumHeight: layout.expandedHeight,
            measuredContentHeight: measuredContentHeight,
            isExpanded: isExpanded,
            isHidden: isHidden,
            expandedTopInset: layout.expandedTopGap
        )
        let region = HangingNotchInteractionRegion(
            frame: frame,
            cornerStyle: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
        onInteractiveRegionChange(region)
    }

    private func collapseMenu() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        cancelPendingCollapse()
        isExpanded = false
    }

    private func cancelPendingCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    /// Collapse shortly after the pointer leaves the panel, mirroring how
    /// notch utilities dismiss. Inline row interactions keep it open.
    private func scheduleCollapseOnHoverExit() {
        cancelPendingCollapse()
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        guard HoverInteraction.shouldCollapse(
            isExpanded: isExpanded,
            isHoveringPanel: isHoveringPanel,
            openMenuTrackingCount: openMenuTrackingCount,
            rowInteractionActive: rowInteractionActive
        ) else { return }
        let workItem = DispatchWorkItem {
            guard HoverInteraction.shouldCollapse(
                isExpanded: isExpanded,
                isHoveringPanel: isHoveringPanel,
                openMenuTrackingCount: openMenuTrackingCount,
                rowInteractionActive: rowInteractionActive
            ) else { return }
            collapseWorkItem = nil
            isExpanded = false
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func handlePointerContainmentChange(_ snapshot: NotchPointerSnapshot) {
        if snapshot.isInside {
            isHoveringPanel = true
            cancelPendingCollapse()
        } else {
            isHoveringPanel = false
            hoverExpandWorkItem?.cancel()
            hoverExpandWorkItem = nil
            scheduleCollapseOnHoverExit()
        }
    }

    private func handleHoverExpansionRequest(
        _ location: DisplayPoint,
        compactFrame: DisplayFrame
    ) {
        guard HoverInteraction.shouldScheduleExpansion(
            pointer: location,
            compactFrame: compactFrame,
            panelOriginX: layout.originX,
            panelTopY: layout.originY + layout.height,
            isExpanded: isExpanded,
            cornerStyle: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ) else { return }
        scheduleExpansion()
    }

    private func settleAfterDetachedInteraction() {
        guard !rowInteractionActive else { return }
        requestPointerRefresh()
        DispatchQueue.main.async {
            if isHoveringPanel {
                cancelPendingCollapse()
            } else {
                scheduleCollapseOnHoverExit()
            }
        }
    }

    private func updateOutsideClickMonitor(menuIsVisible: Bool) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        guard menuIsVisible else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            collapseMenu()
        }
    }

}

struct HangingNotchShape: Shape {
    var style: HangingNotchCornerStyle = .hangingNotch
    var topShoulderRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topShoulderRadius, bottomCornerRadius) }
        set {
            topShoulderRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(HangingNotchGeometry.path(
            in: rect,
            style: style,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        ))
    }
}

private struct InteractiveHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Status indicators

private extension SessionStatusSummary.StatusEntry.Kind {
    var accessibilityName: String {
        switch self {
        case .running: "running"
        case .waiting: "waiting"
        case .blocked: "blocked"
        }
    }
}

/// User-facing status vocabulary shared by the bar and the session rows.
/// Mirrors the README "Session states" table so VoiceOver reads the same
/// words the compact indicators announce, instead of the snake-case rawValue.
private extension SessionStatus {
    var accessibilityName: String {
        switch self {
        case .working: "running"
        case .idle: "waiting"
        case .needsAttention: "blocked"
        case .ended: "ended"
        }
    }
}

/// One compact status counter. Zero-count states never reach this view —
/// the summary filters them out — so every glyph on the bar earns its
/// space. Waiting and blocked share the same dot size: green marks an idle
/// session ready for input, while red remains reserved for attention.
private struct StatusSummaryIndicator: View {
    let kind: SessionStatusSummary.StatusEntry.Kind
    let count: Int
    /// Which edge the dot rides. The right wing mirrors the pair so the round
    /// dot — not the flat numeral — meets the notch shoulder, matching the
    /// left wing and reading as symmetric bookends.
    var indicatorLayout: StatusIndicatorLayout = .forWing(.left)

    var body: some View {
        HStack(spacing: 3) {
            if indicatorLayout.dotEdge == .leading {
                glyph
                countText
            } else {
                countText
                glyph
            }
        }
        .foregroundStyle(.white.opacity(0.94))
        // Fixed slot: the wing-width formula in NotchLayout adds up to
        // exactly the rendered bar, preserving each side's intended padding.
        .frame(width: NotchLayout.statusIndicatorSlotWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(kind.accessibilityName) sessions")
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind.indicatorStyle {
        case .spinner:
            WorkingPixelSpinner()
        case .greenDot, .redDot, .mutedDot:
            Circle()
                .fill(indicatorColor(for: kind.indicatorStyle))
                .frame(width: 8, height: 8)
        }
    }

    private var countText: some View {
        Text(count, format: .number)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
    }
}

/// The classic braille dot-matrix spinner used across CLI tools (ora,
/// Convoy's own progress indicator) — several dots lit per frame rather
/// than one pixel chasing itself. Monochrome by design so the green and red
/// dots remain easy to distinguish from active work.
private struct WorkingPixelSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BrailleSpinnerView(animated: !reduceMotion)
            .frame(width: BrailleSpinnerHostView.side, height: BrailleSpinnerHostView.side)
    }
}

/// Bridges the Core Animation spinner into SwiftUI. The glyph cycle runs on
/// the render server rather than through a `TimelineView`: a periodic
/// TimelineView commits a CoreAnimation transaction every frame, and each
/// commit forces `NSHostingView` to re-lay-out the entire notch tree — ~12.5
/// full relayouts per second, which profiling showed to be the app's dominant
/// idle CPU (and battery) cost. A discrete `CAKeyframeAnimation` steps the
/// pre-rendered frames on the compositor with no SwiftUI graph update at all,
/// so the animation looks and steps identically while the main thread sleeps.
private struct BrailleSpinnerView: NSViewRepresentable {
    let animated: Bool

    func makeNSView(context: Context) -> BrailleSpinnerHostView {
        BrailleSpinnerHostView()
    }

    func updateNSView(_ view: BrailleSpinnerHostView, context: Context) {
        view.animated = animated
    }
}

/// An `NSView` whose backing layer cycles the braille frames via Core
/// Animation. Frames are rendered once per backing scale and reused across
/// every spinner on screen.
private final class BrailleSpinnerHostView: NSView {
    static let side: CGFloat = 11

    var animated = true {
        didSet {
            guard animated != oldValue else { return }
            reinstallAnimation()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .center
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reinstallAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reinstallAnimation()
    }

    private static let animationKey = "brailleSpinner"

    /// (Re)renders the frames at the current scale and drives them with a
    /// discrete keyframe animation. `beginTime` is aligned to the shared media
    /// clock so independently mounted spinners step in lockstep, matching the
    /// previous absolute-clock TimelineView behavior.
    private func reinstallAnimation() {
        guard let layer, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        let frames = Self.frames(scale: scale)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.contents = frames.first

        guard animated else { return }
        let period = BrailleSpinner.cyclePeriod
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        let now = CACurrentMediaTime()
        animation.beginTime = layer.convertTime(
            now - now.truncatingRemainder(dividingBy: period), from: nil
        )
        layer.add(animation, forKey: Self.animationKey)
    }

    private static let framesLock = NSLock()
    private static var framesByScale: [CGFloat: [CGImage]] = [:]

    private static func frames(scale: CGFloat) -> [CGImage] {
        framesLock.lock()
        defer { framesLock.unlock() }
        if let cached = framesByScale[scale] { return cached }
        let rendered = BrailleSpinner.frames.map { render($0, scale: scale) }
        framesByScale[scale] = rendered
        return rendered
    }

    /// Draws one glyph white-on-clear, matching the former SwiftUI text:
    /// `.system(size: 14, weight: .medium, design: .monospaced)`, centered in
    /// the 11×11 slot.
    private static func render(_ character: Character, scale: CGFloat) -> CGImage {
        let pixels = Int((side * scale).rounded())
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let glyph = NSAttributedString(string: String(character), attributes: attributes)
        let bounds = glyph.size()
        glyph.draw(at: CGPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
}

/// Shared colors for compact and per-session status dots.
private func indicatorColor(for style: StatusIndicatorStyle) -> Color {
    switch style {
    case .spinner: .white
    case .mutedDot: .gray
    case .greenDot: .green
    case .redDot: .red
    }
}

// MARK: - Brand icons

/// SVG brand marks bundled in MoongladeCore; NSImage renders SVG natively
/// on macOS 11+ so no rasterized assets are needed.
private enum AgentIcons {
    static let byTool: [AgentTool: NSImage] = Dictionary(
        AgentTool.allCases.compactMap { tool in
            // A brand mark is decoration: AgentIconView already draws a
            // monogram for any tool without an image, so an unreadable
            // resource bundle must degrade the row rather than take the panel
            // down. `moonglade doctor` is where that failure gets reported,
            // because that is where it can be acted on.
            guard let iconURL = try? BundledResources.iconURL(for: tool),
                  let image = NSImage(contentsOf: iconURL) else { return nil }
            return (tool, image)
        },
        uniquingKeysWith: { $1 }
    )
}

private struct AgentIconView: View {
    let tool: AgentTool

    var body: some View {
        if let image = AgentIcons.byTool[tool] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Text(String(tool.rawValue.prefix(1)).uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Session menu

private struct SessionMenuCard: View {
    private static let terminalActionQueue = DispatchQueue(
        label: "com.moonglade.session-actions",
        qos: .userInitiated
    )
    let sessions: [AgentSession]
    let stateDirectoryURL: URL
    let dismiss: () -> Void
    let acknowledge: (AgentSession) -> Void
    let sessionTitle: (AgentSession) -> String
    let overrideName: (AgentSession) -> String?
    let rename: (AgentSession, String) -> Void
    let setKeyboardFocus: (Bool) -> Void
    let onRowInteractionChange: (Bool) -> Void
    @State private var errorMessage: String?
    // At most one row shows its inline actions; opening another closes it.
    @State private var actionsSessionID: String?
    @State private var branchCoordinator = GitBranchResolutionCoordinator()
    /// The row order this menu opened with, held for as long as it is on
    /// screen so no row can slide out from under the pointer mid-reach.
    @State private var pinnedOrder = PinnedSessionOrder()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SessionMenuLayout.cardStackSpacing) {
            if sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                // The list owns the extra height from inline actions. Once
                // several sessions are visible it scrolls instead of growing
                // past the panel and clipping the lower controls.
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(pinnedOrder.ordered(sessions)) { session in
                                row(for: session)
                                    .id(session.id)
                            }
                        }
                    }
                    .frame(height: SessionMenuLayout.sessionListHeight(
                        sessionCount: sessions.count,
                        hasExpandedActions: actionsSessionID != nil
                    ))
                    .onChange(of: actionsSessionID) { _, sessionID in
                        guard let sessionID else { return }
                        DispatchQueue.main.async {
                            withAnimation(
                                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)
                            ) {
                                proxy.scrollTo(sessionID, anchor: .bottom)
                            }
                        }
                    }
                }
                .padding(.bottom, SessionMenuLayout.sessionListBottomPadding)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, SessionMenuLayout.contentHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SessionMenuLayout.listTopPadding)
        .padding(.bottom, SessionMenuLayout.cardBottomPadding)
        // The whole panel can collapse while a row interaction is open;
        // the interaction lock must not outlive the card.
        .onDisappear { onRowInteractionChange(false) }
        .onAppear { pinnedOrder.record(sessions) }
        // Only appearances and departures need learning; a status or timestamp
        // change redraws a row in place, and the pin absorbs the reordering.
        .onChange(of: sessions.map(\.id)) { _, _ in pinnedOrder.record(sessions) }
    }

    private func row(for session: AgentSession) -> some View {
        SessionRow(
            session: session,
            title: sessionTitle(session),
            renamePrefill: overrideName(session) ?? "",
            isActionsExpanded: actionsSessionID == session.id,
            toggleActions: { toggleActions(for: session) },
            focus: focusSession,
            rename: rename,
            kill: killSession,
            setKeyboardFocus: setKeyboardFocus,
            branchCoordinator: branchCoordinator
        )
    }

    private func toggleActions(for session: AgentSession) {
        withAnimation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)
        ) {
            actionsSessionID = actionsSessionID == session.id ? nil : session.id
        }
        onRowInteractionChange(actionsSessionID != nil)
    }

    /// The kill waits up to two grace periods; keep it off the main thread.
    /// The state document needs no cleanup here: the scheduler's exit
    /// watcher sees the death and the reaper removes it on its tick.
    private func killSession(_ session: AgentSession) {
        Self.terminalActionQueue.async {
            do {
                try TerminationService.terminate(session)
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Could not kill this session."
                }
            }
        }
    }

    private func focusSession(_ session: AgentSession) {
        // FocusService shells out to osascript/tmux, which can take
        // hundreds of milliseconds; keep it off the main thread so the
        // menu stays responsive.
        Self.terminalActionQueue.async {
            do {
                let latest = try StateRepository(directoryURL: stateDirectoryURL)
                    .loadSessions()
                    .first { $0.id == session.id }
                guard let latest else { throw FocusError.sessionUnavailable }
                try FocusService.focus(latest)
                DispatchQueue.main.async {
                    acknowledge(latest)
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Could not focus this terminal session."
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let title: String
    let renamePrefill: String
    let isActionsExpanded: Bool
    let toggleActions: () -> Void
    let focus: (AgentSession) -> Void
    let rename: (AgentSession, String) -> Void
    let kill: (AgentSession) -> Void
    let setKeyboardFocus: (Bool) -> Void
    let branchCoordinator: GitBranchResolutionCoordinator

    /// Sub-modes of the inline action area: the button strip, the rename
    /// field, or the kill confirmation. All live inside the row itself so
    /// nothing ever floats outside the notch silhouette.
    private enum ActionMode { case menu, renaming, confirmingKill }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var branchName: String?
    @State private var mode: ActionMode = .menu
    @State private var renameDraft = ""
    /// Which action entry the pointer is on, keyed by label. One selection for
    /// the whole list, so an exit that arrives late cannot unlight the entry
    /// the pointer actually reached.
    @State private var hoveredAction = HoverSelection<String>()
    /// Measured width of the inline menu list, fed to the geometric hover
    /// resolver. Zero until the first layout pass; the per-row fallback
    /// covers that window.
    @State private var actionListWidth: CGFloat = 0
    @FocusState private var renameFieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    focus(session)
                } label: {
                    mainRow.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The chevron sits beside — not inside — the focus button,
                // so each click has exactly one unambiguous target.
                chevronButton
                    .padding(.trailing, 12)
            }
            // A right (or control) click also expands the actions inline;
            // the catcher passes every other event through.
            .overlay(RightClickCatcher(onRightClick: toggleActions))
            if isActionsExpanded {
                actionArea
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .background(
            // Hover reads on both extremes of the background — near-solid
            // black at the top, translucent glass below — via a hairline
            // border plus a whisper of light fill; a heavy wash in either
            // direction fails on one of the two. The opened state gets the
            // dark smoke instead, where the grown row needs separation.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isActionsExpanded
                        ? Color.black.opacity(0.55)
                        : Color.white.opacity(isHovered ? 0.05 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            .white.opacity(isHovered || isActionsExpanded ? 0.12 : 0),
                            lineWidth: 0.5
                        )
                )
                .padding(.horizontal, 6)
        )
        .onHover { isHovered = $0 }
        .onChange(of: isActionsExpanded) { _, _ in
            endRenameKeyboard()
            mode = .menu
        }
        // Each mode shows a different set of entries. The ones leaving cannot
        // be relied on to report their exit, so the selection starts empty and
        // the entry under the pointer re-announces itself as it appears.
        .onChange(of: mode) { _, _ in hoveredAction.clear() }
        .onDisappear { endRenameKeyboard() }
        // Lazy rows request branch data only while visible. Disappearance
        // cancels queued work through the coordinator; the menu-scoped cache
        // is discarded on close so a later open sees branch switches.
        .task(id: session.currentStep == nil ? session.cwd : nil) { [cwd = session.cwd] in
            branchName = nil
            guard session.currentStep == nil else { return }
            let resolved = await branchCoordinator.branchName(forWorkingDirectory: cwd)
            guard !Task.isCancelled else { return }
            branchName = resolved
        }
        .accessibilityLabel("\(title), \(session.status.accessibilityName)")
    }

    private var mainRow: some View {
        HStack(spacing: 12) {
            AgentIconView(tool: session.tool)
            if session.status.indicatorStyle == .spinner {
                WorkingPixelSpinner()
            } else {
                Circle()
                    .fill(indicatorColor(for: session.status.indicatorStyle))
                    .frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                // The title belongs to the tab now, so the directory keeps
                // the project context here, followed by the pipeline step —
                // which outranks the branch: convoy targets worktrees whose
                // directory name already carries it — or the git branch.
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .semibold))
                    Text(SessionTitleFormatter.truncate(session.projectName, to: 30))
                        .font(.system(size: 11, design: .monospaced))
                    if let currentStep = session.currentStep {
                        Text("·")
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 9, weight: .semibold))
                        Text(currentStep)
                            .font(.system(size: 11, design: .monospaced))
                    } else if let branch = branchName {
                        Text("·")
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .semibold))
                        Text(branch)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            // The system wakes this view on minute boundaries while the
            // row is on screen — no timers, no polling while collapsed.
            TimelineView(.everyMinute) { context in
                Text(SessionDurationFormatter.string(from: session.startedAt, to: context.date))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.leading, SessionMenuLayout.sessionRowLeadingInset)
        .padding(.trailing, 10)
        .frame(height: SessionMenuLayout.sessionRowHeight)
    }

    private var chevronButton: some View {
        Button(action: toggleActions) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered || isActionsExpanded ? 0.65 : 0.3))
                .rotationEffect(.degrees(isActionsExpanded ? 180 : 0))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(isActionsExpanded ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Session actions")
    }

    /// Binds one action entry to the row's single hover selection. Every entry
    /// goes through here so the binding is written once.
    private func actionRow(
        _ label: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> ActionListRow {
        ActionListRow(
            label: label,
            systemImage: systemImage,
            isDestructive: isDestructive,
            isHovered: hoveredAction.hovered == label,
            setHovered: { hoveredAction.update(label, isHovered: $0) },
            action: action
        )
    }

    /// One source of order for the inline menu: the rows render from this
    /// array and the continuous-hover resolver indexes back into it, so the
    /// highlight can never disagree with the visible order.
    private var menuActions: [InlineMenuAction] {
        [
            InlineMenuAction(label: "Rename Session", systemImage: "pencil", perform: beginRename),
            InlineMenuAction(label: "Copy Project Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
                toggleActions()
            },
            InlineMenuAction(label: "Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: session.cwd)]
                )
                toggleActions()
            },
            InlineMenuAction(label: "Kill Session", systemImage: "xmark.octagon", isDestructive: true) {
                switchMode(to: .confirmingKill)
            },
        ]
    }

    @ViewBuilder
    private var actionArea: some View {
        switch mode {
        case .menu:
            menuActionList
                .transition(.opacity)
        case .renaming:
            // The field wears the same glass as the action rows — hairline
            // border over a whisper of light — and answers focus by waking
            // the hairline rather than growing chrome.
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    ZStack(alignment: .leading) {
                        // macOS does not honour styling on a TextField
                        // prompt, and the system placeholder colour sinks
                        // into the glass, so the prompt is drawn by hand
                        // and the field's own prompt is suppressed.
                        if renameDraft.isEmpty {
                            Text(session.projectName)
                                .foregroundStyle(.white.opacity(0.45))
                                .allowsHitTesting(false)
                        }
                        TextField(
                            "Session name",
                            text: $renameDraft,
                            prompt: Text(verbatim: "")
                        )
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white.opacity(0.94))
                        .focused($renameFieldIsFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: SessionMenuLayout.actionRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(renameFieldIsFocused ? 0.08 : 0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    .white.opacity(renameFieldIsFocused ? 0.22 : 0.1),
                                    lineWidth: 0.5
                                )
                        )
                )
                iconButton("checkmark", accessibilityLabel: "Save name", action: commitRename)
                iconButton("xmark", accessibilityLabel: "Cancel rename", action: cancelRename)
            }
            .padding(.horizontal, 2)
            .transition(.opacity)
        case .confirmingKill:
            // One calm line: the question breathes at the leading edge and
            // the verdict waits at the trailing one — capsules echoing the
            // pill silhouette, with the destructive one in red glass.
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.85))
                Text("Kill the process and close its pane?")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 8)
                confirmCapsule("Cancel", isDestructive: false) {
                    switchMode(to: .menu)
                }
                confirmCapsule("Kill", isDestructive: true) {
                    kill(session)
                    toggleActions()
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: SessionMenuLayout.actionRowHeight)
            .transition(.opacity)
        }
    }

    /// The list resolves its highlight geometrically on every pointer sample:
    /// per-row `.onHover` still runs as the fallback for a pointer that is
    /// already resting where a row appears, but any movement recomputes the
    /// selection from the pointer's position, so the highlight can never trail
    /// the pointer while the expansion spring is replacing tracking areas.
    private var menuActionList: some View {
        let actions = menuActions
        return VStack(spacing: SessionMenuLayout.actionRowSpacing) {
            ForEach(actions) { entry in
                actionRow(
                    entry.label,
                    systemImage: entry.systemImage,
                    isDestructive: entry.isDestructive,
                    action: entry.perform
                )
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { actionListWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in
                        actionListWidth = width
                    }
            }
        )
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                guard let index = SessionMenuLayout.actionRowIndex(
                    x: location.x,
                    y: location.y,
                    listWidth: actionListWidth,
                    rowCount: actions.count
                ) else { return }
                // Samples arrive at pointer frequency; only a change in the
                // resolved entry may invalidate the view.
                let label = actions[index].label
                guard hoveredAction.hovered != label else { return }
                hoveredAction.update(label, isHovered: true)
            case .ended:
                guard hoveredAction.hovered != nil else { return }
                hoveredAction.clear()
            }
        }
    }

    /// Rename's confirm/cancel: circles cut from the same glass as the rows,
    /// sized against the field so the trio reads as one control.
    private func iconButton(
        _ systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredAction.hovered == accessibilityLabel
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.7))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(.white.opacity(isHovered ? 0.13 : 0.06))
                        .overlay(
                            Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredAction.update(accessibilityLabel, isHovered: $0) }
        .accessibilityLabel(accessibilityLabel)
    }

    /// Kill confirmation verdicts: capsules matching the app's pill
    /// silhouette. The destructive one wears red glass; the neutral one the
    /// standard hairline treatment.
    private func confirmCapsule(
        _ label: String,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredAction.hovered == label
        return Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(
                    isDestructive
                        ? Color.red.opacity(isHovered ? 1 : 0.9)
                        : Color.white.opacity(isHovered ? 0.95 : 0.8)
                )
                .padding(.horizontal, 13)
                .frame(height: 26)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isDestructive
                                ? Color.red.opacity(isHovered ? 0.28 : 0.16)
                                : Color.white.opacity(isHovered ? 0.13 : 0.06)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    isDestructive
                                        ? Color.red.opacity(0.35)
                                        : Color.white.opacity(0.1),
                                    lineWidth: 0.5
                                )
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveredAction.update(label, isHovered: $0) }
        .accessibilityLabel(label)
    }

    /// Sub-mode swaps cross-fade with the same spring the row opened with,
    /// so the area reads as one surface changing its mind rather than a
    /// hard cut between unrelated panels.
    private func switchMode(to newMode: ActionMode) {
        withAnimation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)
        ) {
            mode = newMode
        }
    }

    private func beginRename() {
        renameDraft = renamePrefill
        switchMode(to: .renaming)
        // The panel refuses key status except during this edit; grant it
        // first, then focus the field once the window can accept it.
        setKeyboardFocus(true)
        DispatchQueue.main.async { renameFieldIsFocused = true }
    }

    private func commitRename() {
        rename(session, renameDraft)
        endRenameKeyboard()
        toggleActions()
    }

    private func cancelRename() {
        endRenameKeyboard()
        switchMode(to: .menu)
    }

    private func endRenameKeyboard() {
        guard mode == .renaming else { return }
        renameFieldIsFocused = false
        setKeyboardFocus(false)
    }
}

/// The visible route into the native Settings window, living in the expanded
/// bar's right wing; the silhouette's right-click menu stays as the fallback
/// for when no sessions exist and no menu can open.
private struct SettingsGearButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.75 : 0.35))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Moonglade settings")
    }
}

/// A menu entry of the inline action list, held as data so the rendered
/// order and the geometric hover resolver share one definition.
private struct InlineMenuAction: Identifiable {
    let label: String
    let systemImage: String
    var isDestructive = false
    let perform: () -> Void
    var id: String { label }
}

/// One entry of the inline action list: icon, label, hover highlight — the
/// look of a menu item, rendered inside the row instead of a floating menu.
/// The metrics line up optically with the roomier session row above while
/// preserving a broad click target and rounded hover treatment.
private struct ActionListRow: View {
    let label: String
    let systemImage: String
    var isDestructive = false
    /// Hover is owned by the enclosing row's `HoverSelection`, not by a flag
    /// per entry: sibling flags disagree when a fast pointer makes AppKit
    /// deliver the hand-off out of order. `SessionRow.actionRow` binds these,
    /// and the list-level continuous hover overwrites them from geometry.
    let isHovered: Bool
    let setHovered: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                isDestructive
                    ? Color.red.opacity(isHovered ? 1 : 0.85)
                    : Color.white.opacity(isHovered ? 0.95 : 0.8)
            )
            .padding(.horizontal, 10)
            // The height feeds `SessionMenuLayout.actionRowIndex`; a literal
            // here would silently desynchronize the hover resolver.
            .frame(height: SessionMenuLayout.actionRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover(perform: setHovered)
    }

    private var backgroundFill: Color {
        if isDestructive && isHovered {
            return .red.opacity(0.18)
        }
        return .white.opacity(isHovered ? 0.1 : 0)
    }
}

/// Claims right and control clicks for the inline action toggle and lets
/// every other event — left clicks, hover, scroll — fall through to the
/// SwiftUI row underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickForwardingView {
        let view = RightClickForwardingView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: RightClickForwardingView, context: Context) {
        view.onRightClick = onRightClick
    }
}

private final class RightClickForwardingView: NSView {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is the trackpad spelling of a right click.
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)),
              InlineActionsClickGate.claimsPointer(
                  pressedMouseButtons: NSEvent.pressedMouseButtons,
                  controlKeyIsDown: NSEvent.modifierFlags.contains(.control)
              ) else {
            return nil
        }
        return self
    }
}
