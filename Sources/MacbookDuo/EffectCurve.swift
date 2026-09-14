import Foundation

/// Shapes a linear 0...1 "how far the lid has closed past the threshold"
/// progress into independent blur and dim intensity curves.
struct EffectCurve {
    /// >1 makes blur ramp in slowly at first, then accelerate.
    var blurExponent: Double = 1.6
    /// <1 makes dimming ramp in quickly, then level off.
    var dimExponent: Double = 0.7
    /// Dimming never drops fully to zero at the hinge edge, even when the
    /// per-pixel height-based spread (see the shader) would otherwise send
    /// it there.
    var dimHingeFloor: Double = 0.2

    func blurStrength(progress: Double) -> Double {
        pow(progress.clamped(to: 0...1), blurExponent)
    }

    func dimStrength(progress: Double) -> Double {
        pow(progress.clamped(to: 0...1), dimExponent)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
