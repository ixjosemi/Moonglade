import Foundation

/// The screen-selection policy is deliberately independent from AppKit so the
/// priority rules remain behaviorally testable. The app layer supplies stable
/// `NSScreenNumber` identifiers and the current pointer/focus facts.
public enum ScreenSelectionMode: String, CaseIterable, Sendable {
    case pointer
    case focusedWindow
    case allDisplays
}

public struct DisplayPoint: Equatable, Sendable {
    public let x: CGFloat
    public let y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

public struct DisplayFrame: Equatable, Sendable {
    public let minX: CGFloat
    public let minY: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(minX: CGFloat, minY: CGFloat, width: CGFloat, height: CGFloat) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    public func contains(_ point: DisplayPoint) -> Bool {
        point.x >= minX && point.x < minX + width
            && point.y >= minY && point.y < minY + height
    }
}

public struct DisplaySnapshot: Equatable, Sendable {
    public let id: UInt32
    public let frame: DisplayFrame

    public init(id: UInt32, frame: DisplayFrame) {
        self.id = id
        self.frame = frame
    }
}

public enum ScreenSelection {
    /// Maps a window to the display containing the greatest portion of it.
    /// Display IDs break exact area ties so the result does not depend on the
    /// order in which the platform reports displays.
    public static func displayID(
        containingMostOf windowFrame: DisplayFrame,
        displays: [DisplaySnapshot]
    ) -> UInt32? {
        var bestMatch: (id: UInt32, area: CGFloat)?

        for display in displays {
            let area = intersectionArea(windowFrame, display.frame)
            guard area > 0 else { continue }
            if let bestMatch {
                guard area > bestMatch.area
                    || (area == bestMatch.area && display.id < bestMatch.id) else {
                    continue
                }
            }
            bestMatch = (display.id, area)
        }

        return bestMatch?.id
    }

    /// Resolves every display that should host a notch. Pointer and focused
    /// modes return one display; all-displays mode retains every connected
    /// display in the AppKit-provided order.
    public static func selectDisplayIDs(
        mode: ScreenSelectionMode,
        pointerLocation: DisplayPoint?,
        focusedDisplayID: UInt32?,
        lastSelectedDisplayID: UInt32?,
        displays: [DisplaySnapshot]
    ) -> [UInt32] {
        guard !displays.isEmpty else { return [] }
        if mode == .allDisplays {
            return displays.map(\.id)
        }
        return selectDisplayID(
            mode: mode,
            pointerLocation: pointerLocation,
            focusedDisplayID: focusedDisplayID,
            lastSelectedDisplayID: lastSelectedDisplayID,
            displays: displays
        ).map { [$0] } ?? []
    }

    public static func selectDisplayID(
        mode: ScreenSelectionMode,
        pointerLocation: DisplayPoint?,
        focusedWindowFrame: DisplayFrame?,
        lastSelectedDisplayID: UInt32?,
        displays: [DisplaySnapshot]
    ) -> UInt32? {
        // A missing/restricted/offscreen observation deliberately enters the
        // normal focused-mode fallback: pointer, previous display, then the
        // first connected display. Resolving geometry never requests access.
        selectDisplayID(
            mode: mode,
            pointerLocation: pointerLocation,
            focusedDisplayID: focusedWindowFrame.flatMap {
                displayID(containingMostOf: $0, displays: displays)
            },
            lastSelectedDisplayID: lastSelectedDisplayID,
            displays: displays
        )
    }

    public static func selectDisplayID(
        mode: ScreenSelectionMode,
        pointerLocation: DisplayPoint?,
        focusedDisplayID: UInt32?,
        lastSelectedDisplayID: UInt32?,
        displays: [DisplaySnapshot]
    ) -> UInt32? {
        guard !displays.isEmpty else { return nil }
        let availableIDs = Set(displays.map(\.id))
        let pointerDisplayID = pointerLocation.flatMap { location in
            displays.first(where: { $0.frame.contains(location) })?.id
        }
        let focusedID = focusedDisplayID.flatMap { availableIDs.contains($0) ? $0 : nil }
        let lastID = lastSelectedDisplayID.flatMap { availableIDs.contains($0) ? $0 : nil }

        switch mode {
        case .pointer:
            return pointerDisplayID ?? focusedID ?? lastID ?? displays.first?.id
        case .focusedWindow:
            return focusedID ?? pointerDisplayID ?? lastID ?? displays.first?.id
        case .allDisplays:
            return displays.first?.id
        }
    }

    private static func intersectionArea(_ first: DisplayFrame, _ second: DisplayFrame) -> CGFloat {
        guard isValid(first), isValid(second) else { return 0 }
        let width = min(first.minX + first.width, second.minX + second.width)
            - max(first.minX, second.minX)
        let height = min(first.minY + first.height, second.minY + second.height)
            - max(first.minY, second.minY)
        guard width > 0, height > 0 else { return 0 }
        let area = width * height
        return area.isFinite ? area : 0
    }

    private static func isValid(_ frame: DisplayFrame) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
            && (frame.minX + frame.width).isFinite
            && (frame.minY + frame.height).isFinite
    }
}
