import CoreGraphics
import Foundation

/// Tunables and pure math for the notch's black-to-glass vertical scrim: the
/// band beside the camera stays pure black so the hardware cutout never shows,
/// and the drop fades into a translucent glass backdrop going down.
public enum NotchGlassStyle {
    /// Extra solid black below the bar band so the wing content and the top
    /// shoulder curves never sit over translucent glass.
    public static let solidBandOverlap: CGFloat = 6
    /// Unit-space Y of the scrim gradient's elliptical center: negative sits
    /// above the notch (flatter bands), values near zero hug the top edge
    /// (strong curvature). Must stay well below the solid band's end so the
    /// mirrored region above the center never reaches visible glass.
    public static let scrimCenterY: Double = -0.70
    /// Warp applied to the dissolve's progress: below 1 pulls the transition
    /// upward, so the black recedes early and tapers through a long gentle
    /// tail; 1 is the symmetric curve. Both curve ends stay seamless.
    public static let scrimDissolveBias: Double = 1.0
    /// Offset of the dissolve's virtual start relative to the camera band,
    /// as a fraction of the container height. Zero starts the fade right at
    /// the band; positive pushes it down; negative lifts it above the band —
    /// even above the top edge — so the visible top is already partway into
    /// the curve and barely any pure black remains.
    public static let scrimFadeStartFraction: Double = -0.24
    /// Residual black over the glass at the bottom: the glass never fully
    /// clears — a subtle smoked tint that keeps white content readable.
    public static let bottomScrimOpacity: Double = 0.25
    /// User-tunable tint over the glass — the black wash's opacity. On the
    /// pill it covers the whole silhouette flat; on a notched display it is
    /// the floor the camera band's black dissolves down to, so the band
    /// itself always stays pure black. Exposed in Settings as "Tint"; this
    /// default is the hand-picked baseline.
    public static let defaultTintOpacity: Double = 0.22
    public static let tintOpacityRange: ClosedRange<Double> = 0...0.7
    /// User-tunable frost — the glass filter's blur radius. Zero is clear
    /// lensing with no diffusion; the stock system clear style ships 10.
    /// Exposed in Settings as "Frosted"; this default is the hand-picked
    /// whisper of frost.
    public static let defaultFrostRadius: Double = 1
    public static let frostRadiusRange: ClosedRange<Double> = 0...30
    /// Absolute values forced onto the private glassBackground filter's
    /// inputs, applied over the recovered system baseline: no face wash and
    /// lensing boosted past the stock clear style (-60 over 20pt). The blur
    /// radius rides separately on the user's frost setting. Hand-tuned live
    /// on hardware.
    public static let glassFilterOverrides: [String: Double] = [
        "inputFaceOpacity": 0,
        "inputInnerRefractionAmount": -80,
        "inputInnerRefractionHeight": 26,
    ]

    public struct Stop: Equatable {
        public let location: Double
        public let opacity: Double

        public init(location: Double, opacity: Double) {
            self.location = location
            self.opacity = opacity
        }
    }

    /// Unit-space gradient stops for a silhouette of the given height: pure
    /// black through the camera band, then a smootherstep dissolve spanning
    /// the rest of the live container down to the residual smoked tint. The
    /// curve has zero slope leaving the black and arriving at the tint, so
    /// there is no visible seam at either end; it passes ~0.57 opacity at
    /// mid-height. Shapes no taller than the solid band come out fully
    /// opaque (the collapsed bar renders exactly as flat black).
    public static func scrimStops(
        height: CGFloat,
        solidBandHeight: CGFloat,
        bottomOpacity: Double = bottomScrimOpacity,
        dissolveBias: Double = scrimDissolveBias,
        fadeStartFraction: Double = scrimFadeStartFraction
    ) -> [Stop] {
        let h = max(height, 1)
        let solid = max(solidBandHeight, 0)
        guard solid < h else {
            return [Stop(location: 0, opacity: 1), Stop(location: 1, opacity: 1)]
        }
        // The dissolve's virtual start is the camera band offset by the
        // tunable fraction: negative lifts it above the band (even above the
        // top edge), so the visible top is already partway into the curve.
        let clampedOffset = min(max(fadeStartFraction, -1), 0.9)
        let startY = min(solid + h * CGFloat(clampedOffset), h - 1)
        let fadeTopY = max(startY, 0)
        var stops: [Stop] = []
        if fadeTopY > 0 {
            stops.append(Stop(location: 0, opacity: 1))
            stops.append(Stop(location: Double(fadeTopY / h), opacity: 1))
        }
        let sampleCount = 12
        let firstSample = fadeTopY > 0 ? 1 : 0
        for sample in firstSample...sampleCount {
            let frac = Double(sample) / Double(sampleCount)
            let y = fadeTopY + CGFloat(frac) * (h - fadeTopY)
            // Progress along the virtual curve, which may begin off-screen.
            let t = Double((y - startY) / (h - startY))
            // Smootherstep (6t⁵ − 15t⁴ + 10t³) over bias-warped progress:
            // the warp advances the transition without breaking the seamless
            // ends. The final sample lands on the floor value exactly rather
            // than through the (inexact) formula.
            let warped = pow(t, max(dissolveBias, 0.05))
            let smooth = warped * warped * warped * (warped * (warped * 6 - 15) + 10)
            stops.append(Stop(
                location: Double(y / h),
                opacity: sample == sampleCount
                    ? bottomOpacity
                    : 1 - (1 - bottomOpacity) * smooth
            ))
        }
        return stops
    }
}
