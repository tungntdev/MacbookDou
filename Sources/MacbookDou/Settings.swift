import Combine
import Foundation

/// All user-tunable knobs, persisted to `UserDefaults` and observable so
/// SwiftUI controls and the effect controller stay in sync automatically.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let isEnabled = "isEnabled"
        static let isLiveEnabled = "isLiveEnabled"
        static let isHoldTimeoutEnabled = "isHoldTimeoutEnabled"
        static let triggerAngle = "triggerAngle"
        static let rampSpan = "rampSpan"
        static let maxBlurRadius = "maxBlurRadius"
        static let maxDim = "maxDim"
        static let perspectiveAmount = "perspectiveAmount"
        static let leanAmount = "leanAmount"
        static let blurEvenness = "blurEvenness"
        static let dimReach = "dimReach"
        static let showsAngleInMenuBar = "showsAngleInMenuBar"
        static let launchAtLogin = "launchAtLogin"
    }

    private static let defaults: [String: Any] = [
        Key.isEnabled: true,
        Key.isLiveEnabled: true,
        Key.isHoldTimeoutEnabled: false,
        Key.triggerAngle: 90.0,
        Key.rampSpan: 60.0,
        Key.maxBlurRadius: 135.0,
        Key.maxDim: 1.0,
        Key.perspectiveAmount: 1.0,
        Key.leanAmount: 1.0,
        Key.blurEvenness: 0.0,
        Key.dimReach: 0.5,
        Key.showsAngleInMenuBar: false,
        Key.launchAtLogin: false,
    ]

    /// Bounds for the "Perspective" slider, expressed as eye distance in
    /// multiples of screen height. Larger distance reads as flatter/less
    /// dramatic perspective.
    static let nearestEyeDistance: Double = 1
    static let farthestEyeDistance: Double = 6

    private let store = UserDefaults.standard

    @Published var isEnabled: Bool { didSet { store.set(isEnabled, forKey: Key.isEnabled) } }
    @Published var isLiveEnabled: Bool { didSet { store.set(isLiveEnabled, forKey: Key.isLiveEnabled) } }
    @Published var isHoldTimeoutEnabled: Bool { didSet { store.set(isHoldTimeoutEnabled, forKey: Key.isHoldTimeoutEnabled) } }
    @Published var triggerAngle: Double { didSet { store.set(triggerAngle, forKey: Key.triggerAngle) } }
    @Published var rampSpan: Double { didSet { store.set(rampSpan, forKey: Key.rampSpan) } }
    @Published var maxBlurRadius: Double { didSet { store.set(maxBlurRadius, forKey: Key.maxBlurRadius) } }
    @Published var maxDim: Double { didSet { store.set(maxDim, forKey: Key.maxDim) } }
    /// 0...1, where 1 is the most dramatic (nearest eye) perspective.
    @Published var perspectiveAmount: Double { didSet { store.set(perspectiveAmount, forKey: Key.perspectiveAmount) } }
    @Published var leanAmount: Double { didSet { store.set(leanAmount, forKey: Key.leanAmount) } }
    @Published var blurEvenness: Double { didSet { store.set(blurEvenness, forKey: Key.blurEvenness) } }
    @Published var dimReach: Double { didSet { store.set(dimReach, forKey: Key.dimReach) } }
    @Published var showsAngleInMenuBar: Bool { didSet { store.set(showsAngleInMenuBar, forKey: Key.showsAngleInMenuBar) } }
    @Published var launchAtLogin: Bool {
        didSet {
            store.set(launchAtLogin, forKey: Key.launchAtLogin)
            LoginItem.setEnabled(launchAtLogin)
        }
    }

    /// Eye distance derived from the 0...1 `perspectiveAmount` slider.
    var eyeDistanceInScreenHeights: Double {
        Self.farthestEyeDistance - perspectiveAmount * (Self.farthestEyeDistance - Self.nearestEyeDistance)
    }

    // MARK: - Fixed tuning (not exposed as sliders)

    /// Highest angle above the trigger at which prewarming may run.
    let prewarmCeilingAboveTrigger: Double = 70
    /// Closing speed, in degrees/second, that counts as deliberate and starts prewarming.
    let prewarmTriggerSpeed: Double = 8
    /// How long prewarming keeps running after the lid stops moving.
    let prewarmLinger: TimeInterval = 2
    /// Snapshot cadence while prewarming.
    let prewarmInterval: TimeInterval = 0.25
    /// Degrees the lid must reopen past the trigger before the overlay dismisses.
    let releaseHysteresis: Double = 4

    private init() {
        store.register(defaults: Self.defaults)
        isEnabled = store.bool(forKey: Key.isEnabled)
        isLiveEnabled = store.bool(forKey: Key.isLiveEnabled)
        isHoldTimeoutEnabled = store.bool(forKey: Key.isHoldTimeoutEnabled)
        triggerAngle = store.double(forKey: Key.triggerAngle)
        rampSpan = store.double(forKey: Key.rampSpan)
        maxBlurRadius = store.double(forKey: Key.maxBlurRadius)
        maxDim = store.double(forKey: Key.maxDim)
        perspectiveAmount = store.double(forKey: Key.perspectiveAmount)
        leanAmount = store.double(forKey: Key.leanAmount)
        blurEvenness = store.double(forKey: Key.blurEvenness)
        dimReach = store.double(forKey: Key.dimReach)
        showsAngleInMenuBar = store.bool(forKey: Key.showsAngleInMenuBar)
        launchAtLogin = store.bool(forKey: Key.launchAtLogin)
    }

    func resetToDefaults() {
        for (key, value) in Self.defaults { store.set(value, forKey: key) }
        isEnabled = store.bool(forKey: Key.isEnabled)
        isLiveEnabled = store.bool(forKey: Key.isLiveEnabled)
        isHoldTimeoutEnabled = store.bool(forKey: Key.isHoldTimeoutEnabled)
        triggerAngle = store.double(forKey: Key.triggerAngle)
        rampSpan = store.double(forKey: Key.rampSpan)
        maxBlurRadius = store.double(forKey: Key.maxBlurRadius)
        maxDim = store.double(forKey: Key.maxDim)
        perspectiveAmount = store.double(forKey: Key.perspectiveAmount)
        leanAmount = store.double(forKey: Key.leanAmount)
        blurEvenness = store.double(forKey: Key.blurEvenness)
        dimReach = store.double(forKey: Key.dimReach)
        showsAngleInMenuBar = store.bool(forKey: Key.showsAngleInMenuBar)
    }
}
