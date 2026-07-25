import AppKit
import CoreGraphics

import MoongladeCore

/// Reads only geometry and process metadata from the ordered Quartz window
/// list. This API does not prompt for Accessibility or Screen Recording; if
/// macOS withholds external windows, the caller receives no observation.
@MainActor
final class ExternalFocusedWindowProvider {
    private struct CacheEntry {
        let processID: pid_t
        let sampledAt: TimeInterval
        let frame: DisplayFrame?
    }

    private let refreshInterval: TimeInterval
    private var cacheEntry: CacheEntry?

    init(refreshInterval: TimeInterval = 0.5) {
        self.refreshInterval = refreshInterval
    }

    func focusedWindowFrame(on displays: [DisplaySnapshot]) -> DisplayFrame? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let processID = frontmostApplication.processIdentifier
        guard processID != getpid() else { return nil }

        let now = ProcessInfo.processInfo.systemUptime
        if let cacheEntry,
           cacheEntry.processID == processID,
           now - cacheEntry.sampledAt < refreshInterval {
            return cacheEntry.frame
        }

        let frame = Self.topmostWindowFrame(processID: processID, displays: displays)
        cacheEntry = CacheEntry(processID: processID, sampledAt: now, frame: frame)
        return frame
    }

    func invalidate() {
        cacheEntry = nil
    }

    private static func topmostWindowFrame(
        processID: pid_t,
        displays: [DisplaySnapshot]
    ) -> DisplayFrame? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return nil
        }

        // Quartz returns this list front-to-back. Restricting it to the
        // frontmost external PID makes the first usable normal-level window
        // that application's focused/topmost window.
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == processID,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.int32Value == CGWindowLevelForKey(.normalWindow),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rectangle = CGRect(dictionaryRepresentation: bounds),
                  rectangle.width.isFinite,
                  rectangle.height.isFinite,
                  rectangle.minX.isFinite,
                  rectangle.minY.isFinite,
                  rectangle.width > 1,
                  rectangle.height > 1 else {
                continue
            }
            if let alpha = window[kCGWindowAlpha as String] as? NSNumber,
               alpha.doubleValue <= 0 {
                continue
            }
            if let isOnscreen = window[kCGWindowIsOnscreen as String] as? NSNumber,
               !isOnscreen.boolValue {
                continue
            }

            let frame = DisplayFrame(
                minX: rectangle.minX,
                minY: rectangle.minY,
                width: rectangle.width,
                height: rectangle.height
            )
            guard ScreenSelection.displayID(containingMostOf: frame, displays: displays) != nil else {
                continue
            }
            return frame
        }

        return nil
    }
}
