import AppKit
import SwiftUI

import MoongladeCore

final class NotchPanel: NSPanel {
    /// The panel must never steal keyboard focus from the frontmost app —
    /// except while the user edits a session name inline, when the rename
    /// field needs key status to receive typing.
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only accepts events inside the visible notch
/// silhouette. The panel itself always spans the expanded height — resizing
/// the window while SwiftUI animates the shape caused a visible glitch — so
/// pass-through for the transparent strip below the notch is handled here.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// The broad expanded panel reports its visible drop; the compact bar
    /// reports only its attached silhouette. An empty region passes through.
    var interactiveRegion = HangingNotchInteractionRegion.empty {
        didSet {
            guard interactiveRegion != oldValue else { return }
            scheduleContainmentRecheck()
        }
    }
    private var containmentRecheckIsScheduled = false
    /// A single tracking area covers the fixed-size panel. Its callback then
    /// tests the current hanging silhouette, so resizing the SwiftUI card
    /// never replaces the area that owns hover state.
    var onPointerUpdate: ((Bool, DisplayPoint) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    /// The panel never becomes key, so every click arrives as a "first
    /// mouse" while another app is frontmost. Accepting it makes the first
    /// click act immediately instead of being swallowed as activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Unlike UIKit, AppKit supplies this point in the receiver's
        // superview coordinates. The interaction frame is hosting-local.
        let local = superview.map { convert(point, from: $0) } ?? point
        let localX = local.x - bounds.minX
        let distanceFromTop = isFlipped
            ? local.y - bounds.minY
            : bounds.maxY - local.y
        guard interactiveRegion.contains(
            DisplayPoint(x: localX, y: distanceFromTop)
        ) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        report(event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let location = globalLocation(for: event)
        onPointerUpdate?(false, location)
    }

    /// Re-tests containment once the current SwiftUI update has finished.
    ///
    /// The region arrives from that update: `onPreferenceChange` on a
    /// `GeometryReader` measuring the card, so it lands once per frame for as
    /// long as the open or close spring runs. Answering inline would publish
    /// pointer state from inside the very pass that is reading it, which
    /// SwiftUI does not allow. Hopping to the next turn of the run loop also
    /// coalesces the burst: the frames along the way are interpolation, and
    /// only the geometry the pointer actually ends up over decides anything.
    private func scheduleContainmentRecheck() {
        guard !containmentRecheckIsScheduled else { return }
        containmentRecheckIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            containmentRecheckIsScheduled = false
            refreshPointerLocation()
        }
    }

    func refreshPointerLocation() {
        guard let window else { return }
        let global = NSEvent.mouseLocation
        let inWindow = window.convertPoint(fromScreen: NSPoint(x: global.x, y: global.y))
        let local = convert(inWindow, from: nil)
        report(localPoint: local, globalLocation: DisplayPoint(x: global.x, y: global.y))
    }

    private func report(event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        report(localPoint: local, globalLocation: globalLocation(for: event))
    }

    private func report(localPoint: NSPoint, globalLocation: DisplayPoint) {
        let topLeadingY = isFlipped
            ? localPoint.y - bounds.minY
            : bounds.maxY - localPoint.y
        let isInside = interactiveRegion.contains(
            DisplayPoint(x: localPoint.x - bounds.minX, y: topLeadingY)
        )
        onPointerUpdate?(isInside, globalLocation)
    }

    private func globalLocation(for event: NSEvent) -> DisplayPoint {
        guard let window else {
            let location = NSEvent.mouseLocation
            return DisplayPoint(x: location.x, y: location.y)
        }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return DisplayPoint(x: point.x, y: point.y)
    }
}

/// One independent SwiftUI/AppKit surface for a display. Each surface owns
/// hover, expanded-menu, and keyboard-focus state, which lets all-displays
/// mode show the helper on every connected screen at once.
@MainActor
private final class NotchDisplayPanel {
    private let store: StateStore
    private let panel: NotchPanel
    private var layout: NotchLayout
    private var hostingView: NotchHostingView<NotchWidgetView>?
    private var pointerGate = PointerMovementGate()
    private let pointerTracker = NotchPointerTracker()
    private var hoverExpansionIntentSent = false
    private let onMenuVisibilityChanged: () -> Void

    private(set) var menuIsVisible = false

    init(
        store: StateStore,
        layout: NotchLayout,
        onMenuVisibilityChanged: @escaping () -> Void
    ) {
        self.store = store
        self.layout = layout
        self.onMenuVisibilityChanged = onMenuVisibilityChanged
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: layout.width, height: layout.expandedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        applyLayout()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func update(layout: NotchLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        applyLayout()
    }

    func lockHoverExpansion(at point: DisplayPoint) {
        pointerGate.lock(at: point)
        hoverExpansionIntentSent = false
    }

    private func applyLayout() {
        if let hostingView {
            hostingView.rootView = makeRootView()
        } else {
            let hostingView = NotchHostingView(rootView: makeRootView())
            hostingView.onPointerUpdate = { [weak self] isInside, location in
                self?.handlePointerUpdate(isInside: isInside, location: location)
            }
            self.hostingView = hostingView
            panel.contentView = hostingView
        }
        panel.setFrame(
            NSRect(
                x: layout.originX,
                y: layout.originY + layout.height - layout.expandedHeight,
                width: layout.width,
                height: layout.expandedHeight
            ),
            display: true
        )
    }

    private func handlePointerUpdate(isInside: Bool, location: DisplayPoint) {
        let location = pointerTracker.update(isInside: isInside, location: location)
        guard isInside else {
            hoverExpansionIntentSent = false
            return
        }
        guard !hoverExpansionIntentSent,
              pointerGate.update(pointerLocation: location) else { return }
        hoverExpansionIntentSent = true
        pointerTracker.requestHoverExpansion(at: location)
    }

    private func makeRootView() -> NotchWidgetView {
        NotchWidgetView(
            store: store,
            layout: layout,
            pointerTracker: pointerTracker,
            requestPointerRefresh: { [weak self] in
                self?.hostingView?.refreshPointerLocation()
            },
            onInteractiveRegionChange: { [weak self] region in
                self?.hostingView?.interactiveRegion = region
            },
            onKeyboardFocusChange: { [weak self] wantsKeyboard in
                self?.setKeyboardFocus(wantsKeyboard)
            },
            onMenuVisibilityChange: { [weak self] isVisible in
                guard let self else { return }
                menuIsVisible = isVisible
                onMenuVisibilityChanged()
            }
        )
    }

    private func setKeyboardFocus(_ wantsKeyboard: Bool) {
        panel.allowsKeyboardFocus = wantsKeyboard
        if wantsKeyboard {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }
}

@MainActor
final class NotchPanelController {
    private let store: StateStore
    private let focusedWindowProvider = ExternalFocusedWindowProvider()
    private var displayPanels: [UInt32: NotchDisplayPanel] = [:]
    private var selectedDisplayID: UInt32?
    private var selectionMode: ScreenSelectionMode
    private var displaySnapshots: [DisplaySnapshot] = []
    private var pointerDisplayChanges = PointerDisplayChangeReducer(initialDisplayID: nil)
    private var synchronizationPolicy = PanelSynchronizationPolicy()
    private var panelsAreVisible = false
    /// A pointer/focus move waits for the current menu to close. All-displays
    /// mode has no selected display and therefore never needs this deferral.
    private var hasPendingSelectedDisplay = false
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var focusedWindowFallbackTimer: Timer?

    init(store: StateStore) {
        self.store = store
        selectionMode = Self.configuredSelectionMode
        synchronizePanels()
        // Display changes — docking, resolution switches, lid state —
        // invalidate every notch metric, so every panel re-derives its layout
        // from the current screen instead of keeping launch-time values.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusedWindowProvider.invalidate()
                self?.updatePointerEventMonitorPolicy()
                self?.synchronizePanels()
            }
        }
        // The widget follows the screen the user is working on when a
        // single-display policy is active. All-displays mode deliberately
        // keeps every panel visible regardless of activation.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async {
                    self?.handleWorkspaceContextChange()
                }
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWorkspaceContextChange()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDefaultsChange()
            }
        }
        transitionSynchronizationResources(to: selectionMode)
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
        }
        focusedWindowFallbackTimer?.invalidate()
    }

    func show() {
        panelsAreVisible = true
        displayPanels.values.forEach { $0.show() }
    }

    private func synchronizePanels() {
        let screens = NSScreen.screens
        let screensByID = screens.reduce(into: [UInt32: NSScreen]()) { result, screen in
            guard let displayID = Self.displayID(for: screen) else { return }
            result[displayID] = screen
        }
        let displays = screens.compactMap { screen -> DisplaySnapshot? in
            guard let displayID = Self.displayID(for: screen) else { return nil }
            return DisplaySnapshot(
                id: displayID,
                frame: DisplayFrame(
                    minX: screen.frame.minX,
                    minY: screen.frame.minY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
            )
        }
        displaySnapshots = displays
        let mouseLocation = NSEvent.mouseLocation
        let pointerLocation = DisplayPoint(x: mouseLocation.x, y: mouseLocation.y)
        _ = pointerDisplayChanges.update(
            displayID: Self.displayID(containing: pointerLocation, displays: displays)
        )
        let pointerIsOnDisplay = displays.contains { $0.frame.contains(pointerLocation) }
        let needsFocusedWindow = selectionMode == .focusedWindow
            || (selectionMode == .pointer && !pointerIsOnDisplay)
        let focusedDisplayID: UInt32?
        if needsFocusedWindow {
            // CGWindow bounds and CGDisplayBounds share Quartz's top-left
            // coordinate space, avoiding a fragile AppKit Y-axis conversion.
            let quartzDisplays = displays.map(Self.quartzDisplaySnapshot)
            focusedDisplayID = focusedWindowProvider
                .focusedWindowFrame(on: quartzDisplays)
                .flatMap {
                    ScreenSelection.displayID(containingMostOf: $0, displays: quartzDisplays)
                }
        } else {
            focusedDisplayID = nil
        }
        let desiredIDs = ScreenSelection.selectDisplayIDs(
            mode: selectionMode,
            pointerLocation: pointerLocation,
            focusedDisplayID: focusedDisplayID,
            lastSelectedDisplayID: selectedDisplayID,
            displays: displays
        )
        let desiredIDSet = Set(desiredIDs)

        if selectionMode != .allDisplays,
           let desiredID = desiredIDs.first,
           let currentID = selectedDisplayID,
            PanelSynchronizationPolicy.shouldDeferSelection(
                current: currentID,
                desired: desiredID,
                available: Set(screensByID.keys),
                menuIsVisible: displayPanels[currentID]?.menuIsVisible == true
            ) {
            hasPendingSelectedDisplay = true
            return
        }

        let previousSelectedDisplayID = selectedDisplayID
        selectedDisplayID = selectionMode == .allDisplays ? nil : desiredIDs.first
        hasPendingSelectedDisplay = false

        for displayID in desiredIDs {
            guard let screen = screensByID[displayID] else { continue }
            let layout = Self.layout(for: screen)
            if let displayPanel = displayPanels[displayID] {
                displayPanel.update(layout: layout)
            } else {
                let displayPanel = NotchDisplayPanel(
                    store: store,
                    layout: layout,
                    onMenuVisibilityChanged: { [weak self] in
                        self?.handleMenuVisibilityChange()
                    }
                )
                displayPanels[displayID] = displayPanel
                if panelsAreVisible {
                    displayPanel.show()
                }
                if selectionMode != .allDisplays,
                   let previousSelectedDisplayID,
                   previousSelectedDisplayID != displayID {
                    let mouse = NSEvent.mouseLocation
                    displayPanel.lockHoverExpansion(at: DisplayPoint(x: mouse.x, y: mouse.y))
                }
            }
        }

        let removedDisplayIDs = displayPanels.keys.filter { !desiredIDSet.contains($0) }
        for displayID in removedDisplayIDs {
            displayPanels[displayID]?.hide()
            displayPanels.removeValue(forKey: displayID)
        }
    }

    private func handleDefaultsChange() {
        let mode = Self.configuredSelectionMode
        guard mode != selectionMode else { return }
        selectionMode = mode
        focusedWindowProvider.invalidate()
        transitionSynchronizationResources(to: mode)
        synchronizePanels()
    }

    private func handleWorkspaceContextChange() {
        switch selectionMode {
        case .focusedWindow:
            break
        case .pointer:
            let pointer = NSEvent.mouseLocation
            guard Self.displayID(
                containing: DisplayPoint(x: pointer.x, y: pointer.y),
                displays: displaySnapshots
            ) == nil else { return }
        case .allDisplays:
            return
        }
        focusedWindowProvider.invalidate()
        synchronizePanels()
    }

    private func transitionSynchronizationResources(to mode: ScreenSelectionMode) {
        let transition = synchronizationPolicy.transition(to: mode)
        for resource in transition.removed {
            switch resource {
            case .pointerEventMonitor:
                removePointerEventMonitors()
            case .focusedWindowFallbackTimer:
                stopFocusedWindowFallbackTimer()
            }
        }
        for resource in transition.installed {
            switch resource {
            case .pointerEventMonitor:
                installPointerEventMonitors()
            case .focusedWindowFallbackTimer:
                startFocusedWindowFallbackTimer()
            }
        }
    }

    private func installPointerEventMonitors() {
        guard PanelSynchronizationPolicy.needsPointerMonitors(displayCount: NSScreen.screens.count) else {
            return
        }
        guard localPointerMonitor == nil, globalPointerMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handlePointerMovement()
            }
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePointerMovement()
            }
        }
    }

    private func removePointerEventMonitors() {
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
    }

    private func updatePointerEventMonitorPolicy() {
        guard selectionMode == .pointer else { return }
        if PanelSynchronizationPolicy.needsPointerMonitors(displayCount: NSScreen.screens.count) {
            installPointerEventMonitors()
        } else {
            removePointerEventMonitors()
        }
    }

    private func handlePointerMovement() {
        let location = NSEvent.mouseLocation
        let displayID = Self.displayID(
            containing: DisplayPoint(x: location.x, y: location.y),
            displays: displaySnapshots
        )
        guard pointerDisplayChanges.update(displayID: displayID) else { return }
        synchronizePanels()
    }

    private func startFocusedWindowFallbackTimer() {
        guard focusedWindowFallbackTimer == nil else { return }
        let interval = PanelSynchronizationPolicy.focusedWindowFallbackInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusedWindowProvider.invalidate()
                self?.synchronizePanels()
            }
        }
        timer.tolerance = interval * 0.25
        focusedWindowFallbackTimer = timer
    }

    private func stopFocusedWindowFallbackTimer() {
        focusedWindowFallbackTimer?.invalidate()
        focusedWindowFallbackTimer = nil
    }

    private func handleMenuVisibilityChange() {
        guard hasPendingSelectedDisplay,
              !displayPanels.values.contains(where: \.menuIsVisible) else { return }
        synchronizePanels()
    }

    private static func layout(for screen: NSScreen?) -> NotchLayout {
        // frame minus visible frame isolates the menu bar strip: the Dock
        // can eat into the sides or bottom of a screen, never into the top
        // edge, so the difference is the real menu bar height.
        let menuBarHeight = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return NotchLayout(
            screenMinX: screen?.frame.minX ?? 0,
            screenWidth: screen?.frame.width ?? 1_512,
            screenMaxY: screen?.frame.maxY ?? 982,
            safeAreaTop: screen?.safeAreaInsets.top ?? 0,
            leftNotchEdgeX: screen?.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen?.auxiliaryTopRightArea?.minX,
            menuBarHeight: menuBarHeight
        )
    }

    private static func displayID(for screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { $0.uint32Value }
    }

    private static func displayID(
        containing point: DisplayPoint,
        displays: [DisplaySnapshot]
    ) -> UInt32? {
        displays.first { $0.frame.contains(point) }?.id
    }

    private static var configuredSelectionMode: ScreenSelectionMode {
        ScreenSelectionMode(
            rawValue: UserDefaults.standard.string(forKey: "screenSelectionMode") ?? ""
        ) ?? .pointer
    }

    private static func quartzDisplaySnapshot(_ display: DisplaySnapshot) -> DisplaySnapshot {
        let bounds = CGDisplayBounds(CGDirectDisplayID(display.id))
        return DisplaySnapshot(
            id: display.id,
            frame: DisplayFrame(
                minX: bounds.minX,
                minY: bounds.minY,
                width: bounds.width,
                height: bounds.height
            )
        )
    }
}
