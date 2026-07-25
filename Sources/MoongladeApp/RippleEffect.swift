import SwiftUI

/// Water-drop ripple riding on the expand spring, done entirely with public
/// API: a `layerEffect` Metal shader (`Ripple.metal`) displaces the SwiftUI
/// layer radially with a damped traveling wave and brightens its crests.
/// Driven by `keyframeAnimator` so the shader clock advances only while the
/// wave is alive; outside that window `isEnabled` keeps the effect free.
///
/// Apply it to SwiftUI-rendered content only. The glass backdrop is
/// composited by the window server: rasterizing it through a shader (or a
/// CATransition) renders it blank for the duration of the animation.
struct ExpansionRippleEffect: ViewModifier {
    /// Bump to fire one ripple; the animator triggers on change.
    let trigger: Int

    private nonisolated static let duration: TimeInterval = 0.9

    func body(content: Content) -> some View {
        content.keyframeAnimator(
            initialValue: 0,
            trigger: trigger
        ) { view, elapsedTime in
            view.modifier(RippleShaderModifier(elapsedTime: elapsedTime))
        } keyframes: { _ in
            MoveKeyframe(0)
            LinearKeyframe(Self.duration, duration: Self.duration)
        }
    }
}

private struct RippleShaderModifier: ViewModifier {
    var elapsedTime: TimeInterval

    /// Hand-tuned for the notch surface: one subtle pulse, not a train of
    /// rings — the decay eats the sine before its second cycle, so a single
    /// wavefront crosses the surface and dies with the expand spring.
    /// `nonisolated` because the shader closure inside `visualEffect` is
    /// Sendable and off the main actor.
    private nonisolated static let amplitude: Double = 8
    private nonisolated static let frequency: Double = 6
    private nonisolated static let decay: Double = 5
    private nonisolated static let speed: Double = 1_300
    private nonisolated static let duration: TimeInterval = 0.9

    func body(content: Content) -> some View {
        let elapsedTime = elapsedTime
        content.visualEffect { view, proxy in
            view.layerEffect(
                ShaderLibrary.bundle(.module).expansionRipple(
                    // The wave sets out from the bar band's center — the
                    // camera housing or the collapsed capsule — regardless
                    // of how far the card has grown.
                    .float2(CGPoint(x: proxy.size.width / 2, y: 0)),
                    .float(elapsedTime),
                    .float(Self.amplitude),
                    .float(Self.frequency),
                    .float(Self.decay),
                    .float(Self.speed)
                ),
                maxSampleOffset: CGSize(width: Self.amplitude, height: Self.amplitude),
                isEnabled: elapsedTime > 0 && elapsedTime < Self.duration
            )
        }
    }
}
