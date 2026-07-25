import Foundation

/// The braille dot-matrix frames and cadence shared by every working spinner
/// (the ora / Convoy progress style). Extracted from the view so the cycle the
/// layer animation is built from has one definition and can be asserted on.
public enum BrailleSpinner {
    /// Seconds each frame is held before advancing.
    public static let stepInterval: TimeInterval = 0.08

    /// The ten-frame braille cycle: several dots lit per frame rather than one
    /// pixel chasing itself.
    public static let frames: [Character] = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// One full pass through `frames`. The keyframe animation repeats over this
    /// duration, and each spinner starts on a multiple of it, so independently
    /// mounted spinners stay in phase.
    public static let cyclePeriod: TimeInterval = stepInterval * Double(frames.count)
}
