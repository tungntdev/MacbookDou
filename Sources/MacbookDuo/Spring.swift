import Foundation

/// A critically-damped spring: the fastest possible approach to a moving
/// target with zero overshoot and no ringing.
///
/// Integrated with semi-implicit (symplectic) Euler, which stays stable as
/// long as `frequency * dt < 2` — callers should clamp `dt` before calling
/// `advance(toward:dt:)`.
struct Spring {
    /// How quickly the value catches up to its target. Higher tracks faster
    /// but smooths less of the input's own jitter.
    var frequency: Double

    private(set) var value: Double = 0
    private(set) var velocity: Double = 0

    init(frequency: Double = 16, startingAt value: Double = 0) {
        self.frequency = frequency
        self.value = value
    }

    /// Snaps to `value` with zero velocity, so a sudden retarget doesn't
    /// leave a visible velocity spike behind.
    mutating func reset(to value: Double) {
        self.value = value
        velocity = 0
    }

    @discardableResult
    mutating func advance(toward target: Double, dt: Double) -> Double {
        // Critical damping (ζ = 1) falls out of choosing the damping
        // coefficient as 2·ω with unit mass and stiffness ω²: the classic
        // "no oscillation, no overshoot" solution.
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
        return value
    }
}
