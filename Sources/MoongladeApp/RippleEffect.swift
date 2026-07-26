import MoongladeCore
import SwiftUI

/// The compiled Metal library, resolved the same way every other bundled
/// resource is.
///
/// SwiftPM's generated `Bundle.module` for this target resolves only the
/// `.app` root and the absolute build directory of the machine that compiled
/// it, and `build-app.sh` installs into Contents/Resources — neither. An
/// installed app therefore read its shader out of the developer's `.build`
/// tree and trapped on launch the moment that tree moved. Nothing may be
/// placed at the `.app` root to satisfy the generated accessor: contents
/// there leave the bundle unsealed and fail `codesign --verify`.
///
/// A missing library disables the ripple rather than taking the panel down —
/// the expansion is decoration, and the notch is not.
private enum RippleShaderLibrary {
    static let resolved: ShaderLibrary? = {
        let searched = BundledResources.bundleSearchPaths(
            named: BundledResources.appBundleName,
            executableURL: Bundle.main.executableURL,
            mainResourceURL: Bundle.main.resourceURL
        )
        for path in searched {
            if let bundle = Bundle(path: path) { return ShaderLibrary.bundle(bundle) }
        }
        return nil
    }()
}

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
        guard let library = RippleShaderLibrary.resolved else { return AnyView(content) }
        return AnyView(content.visualEffect { view, proxy in
            view.layerEffect(
                library.expansionRipple(
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
        })
    }
}
