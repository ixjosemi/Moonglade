import Foundation

/// Decides whether the inline-actions catcher owns a pointer sample.
///
/// The catcher sits on top of a session row to claim right and control clicks
/// for the inline action list, and must let everything else — hover above all
/// — reach the row underneath. It cannot ask which event is being routed:
/// `NSView.hitTest` is not handed one. The last *dispatched* event is the
/// wrong substitute, because AppKit hit-tests outside event dispatch as well
/// (tracking-area maintenance, hover re-resolution after a layout change),
/// and there the last event is stale. A stale right click makes the catcher
/// claim the row and swallow its hover and clicks until the pointer moves
/// again — an intermittently dead row.
///
/// Live button state has no such window: during hover nothing is held.
public enum InlineActionsClickGate {
    private static let leftButtonMask = 1
    private static let rightButtonMask = 1 << 1

    /// `pressedMouseButtons` is `NSEvent.pressedMouseButtons`: a bitmask of the
    /// buttons held at this instant, bit 0 left and bit 1 right.
    public static func claimsPointer(
        pressedMouseButtons: Int,
        controlKeyIsDown: Bool
    ) -> Bool {
        if pressedMouseButtons & rightButtonMask != 0 { return true }
        // Control-click is the trackpad spelling of a right click.
        return controlKeyIsDown && pressedMouseButtons & leftButtonMask != 0
    }
}
