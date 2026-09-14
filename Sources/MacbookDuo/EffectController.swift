import AppKit
import Combine
import HingeSensorKit
import QuartzCore

/// Watches the hinge angle and drives the overlay: decides when the effect
/// should be on screen, keeps a smoothed angle animating at display refresh
/// rate between sensor samples, and manages prewarming the screen capture so
/// the picture appears the instant the lid crosses the trigger angle.
@MainActor
final class EffectController: ObservableObject {

    @Published private(set) var currentAngleDegrees: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var isEffectActive = false

    private let settings: Settings
    private let sensor = HingeAngleSensor()
    private let overlay = EffectOverlayWindow()
    private let liveCapture = ScreenLiveCapture()
    let stillCapture = ScreenStillCapture()

    private var settingsSubscription: AnyCancellable?
    private var seedTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    private var rawAngle: Double = 0
    private var angularVelocityDegPerSec: Double = 0
    private var lastAngleForVelocity: Double?
    private var lastVelocitySampleTime: CFTimeInterval = 0
    private var lastClosingMovementTime: CFTimeInterval = -.greatestFiniteMagnitude
    private var smoothedAngle = Spring(frequency: 16)
    private var consecutiveFailedReads = 0
    private var activeSince: CFTimeInterval = 0
    private var preview: PreviewSweep?
    private var isSuspended = false
    private var timeoutReferenceAngle: Double?
    private var timeoutReferenceTime: CFTimeInterval = 0
    private var timeoutAwaitingRelease = false
    private var isEasingClosed = false
    private var easeStartedAt: CFTimeInterval = 0
    private var builtInDisplayID: CGDirectDisplayID?

    private static let idlePollInterval: TimeInterval = 1.0 / 8
    private static let activePollInterval: TimeInterval = 1.0 / 30
    private static let fadeInDuration: TimeInterval = 0.07
    /// Degrees above the prewarm ceiling at which polling speeds back up.
    private static let fastPollMargin: Double = 20
    /// Closing speed, in degrees/second, that counts as deliberate.
    private static let deliberateClosingSpeed: Double = 2
    /// How long after the lid last moved down the effect may still start.
    private static let closingMemory: TimeInterval = 1.5
    private static let predictionSpeedFloor: Double = 40
    private static let predictionLatency: TimeInterval = 0.04
    private static let minimumEffectDuration: TimeInterval = 0.35
    private static let holdStillThreshold: Double = 2
    private static let holdStillDuration: TimeInterval = 2
    private static let easeSettleEpsilon: Double = 0.05
    private static let easeMaxDuration: TimeInterval = 1.2

    /// A scripted angle sweep so Settings can preview the effect without
    /// physically moving the lid.
    private struct PreviewSweep {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        let closingDuration: CFTimeInterval = 1.4
        let holdDuration: CFTimeInterval = 0.8
        let openingDuration: CFTimeInterval = 0.6

        func angle(at now: CFTimeInterval) -> Double? {
            let elapsed = now - startedAt
            if elapsed < closingDuration { return open + (shut - open) * (elapsed / closingDuration) }
            if elapsed < closingDuration + holdDuration { return shut }
            if elapsed < closingDuration + holdDuration + openingDuration {
                return shut + (open - shut) * ((elapsed - closingDuration - holdDuration) / openingDuration)
            }
            return nil
        }
    }

    init(settings: Settings) {
        self.settings = settings
        settingsSubscription = settings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard !enabled else { return }
                self?.disableEffect()
            }
    }

    // MARK: - Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        Log.effect.notice("hinge sensor available: \(self.isSensorAvailable), angle: \(self.sensor.readAngleDegrees() ?? -1)")
        guard isSensorAvailable else { return }

        if let angle = sensor.readAngleDegrees() {
            rawAngle = angle
            currentAngleDegrees = angle
            smoothedAngle.reset(to: angle)
        }
        setPollInterval(Self.idlePollInterval)
        builtInDisplayID = BuiltInDisplay.directDisplayID()
        observeSystemEvents()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.local.MacbookDuo.preview"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPreview() }
        }
        overlay.warmUp()
        Task {
            await stillCapture.warmFilter()
            try? await Task.sleep(nanoseconds: 500_000_000)
            await liveCapture.warmFilter()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        stopEffectAndCapture()
    }

    func runPreview() {
        guard settings.isEnabled, !isSuspended, preview == nil, !isEffectActive else { return }
        preview = PreviewSweep(
            startedAt: CACurrentMediaTime(),
            open: min(settings.triggerAngle + 35, 130),
            shut: max(settings.triggerAngle - settings.rampSpan * 1.15, 5)
        )
        setPollInterval(Self.activePollInterval)
    }

    private func stopEffectAndCapture() {
        seedTask?.cancel()
        seedTask = nil
        isEasingClosed = false
        stopDisplayLink()
        overlay.dismiss(animated: false)
        stillCapture.stop()
        liveCapture.stop()
        overlay.discardLiveTexture()
        preview = nil
        isEffectActive = false
    }

    private func disableEffect() {
        stopEffectAndCapture()
        lastAngleForVelocity = nil
        angularVelocityDegPerSec = 0
        lastClosingMovementTime = -.greatestFiniteMagnitude
        if pollTimer != nil { setPollInterval(Self.idlePollInterval) }
    }

    // MARK: - Polling

    private func setPollInterval(_ interval: TimeInterval) {
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !isSuspended else { return }

        let angle: Double
        if let run = preview {
            guard let scripted = run.angle(at: CACurrentMediaTime()) else {
                preview = nil
                return
            }
            angle = scripted
        } else {
            guard let read = sensor.readAngleDegrees() else {
                consecutiveFailedReads += 1
                if consecutiveFailedReads > 30, isEffectActive {
                    Log.effect.notice("sensor read failed repeatedly, ending effect")
                    setActive(false)
                }
                return
            }
            consecutiveFailedReads = 0
            angle = read
        }

        rawAngle = angle
        currentAngleDegrees = angle

        if settings.isEnabled {
            updateVelocity(with: angle)
            reconcile(angle: angle)
        }

        let prewarmZone = settings.triggerAngle + settings.prewarmCeilingAboveTrigger
        let wantsFastPolling = settings.isEnabled
            && (preview != nil || isEffectActive || angle <= prewarmZone + Self.fastPollMargin)
        setPollInterval(wantsFastPolling ? Self.activePollInterval : Self.idlePollInterval)
    }

    private func wantsEffect(angle: Double) -> Bool {
        guard settings.isEnabled else { return false }
        let threshold = settings.triggerAngle

        if isEffectActive {
            guard CACurrentMediaTime() - activeSince > Self.minimumEffectDuration else { return true }
            if angle >= threshold + settings.releaseHysteresis { return false }
            if settings.isHoldTimeoutEnabled, isPastHoldTimeout(angle: angle) {
                timeoutAwaitingRelease = true
                return false
            }
            return true
        }

        if settings.isHoldTimeoutEnabled, timeoutAwaitingRelease {
            guard angle >= threshold else { return false }
            timeoutAwaitingRelease = false
        }

        let closingRecently = CACurrentMediaTime() - lastClosingMovementTime < Self.closingMemory
        return closingRecently && predictedAngle() <= threshold
    }

    private func isPastHoldTimeout(angle: Double) -> Bool {
        let now = CACurrentMediaTime()
        if let reference = timeoutReferenceAngle, abs(angle - reference) <= Self.holdStillThreshold {
            return now - timeoutReferenceTime >= Self.holdStillDuration
        }
        timeoutReferenceAngle = angle
        timeoutReferenceTime = now
        return false
    }

    private func reconcile(angle: Double) {
        guard settings.isEnabled, !isSuspended else { return }
        let wanted = wantsEffect(angle: angle)
        if wanted != isEffectActive {
            setActive(wanted)
            return
        }
        if isEffectActive {
            if !overlay.isVisible { presentPicture() }
            if overlay.isVisible, displayLink == nil { startDisplayLink() }
        } else if !isEasingClosed {
            updatePrewarm(angle: angle, ceiling: settings.triggerAngle + settings.prewarmCeilingAboveTrigger)
        }
    }

    private func updateVelocity(with angle: Double) {
        let now = CACurrentMediaTime()
        guard let last = lastAngleForVelocity else {
            lastAngleForVelocity = angle
            lastVelocitySampleTime = now
            return
        }
        if angle != last {
            let dt = now - lastVelocitySampleTime
            if dt > 0.001 {
                let instant = (angle - last) / dt
                angularVelocityDegPerSec = 0.5 * instant + 0.5 * angularVelocityDegPerSec
            }
            lastAngleForVelocity = angle
            lastVelocitySampleTime = now
        } else if now - lastVelocitySampleTime > 0.4 {
            angularVelocityDegPerSec = 0
        }
        if angularVelocityDegPerSec <= -Self.deliberateClosingSpeed {
            lastClosingMovementTime = now
        }
    }

    private func updatePrewarm(angle: Double, ceiling: Double) {
        let closingRecently = CACurrentMediaTime() - lastClosingMovementTime < settings.prewarmLinger
        guard angle <= ceiling, closingRecently else {
            stillCapture.endPrewarm()
            liveCapture.stop()
            overlay.discardLiveTexture()
            return
        }
        guard settings.isLiveEnabled else {
            liveCapture.stop()
            overlay.discardLiveTexture()
            stillCapture.beginPrewarm(interval: settings.prewarmInterval)
            return
        }
        stillCapture.endPrewarm()
        liveCapture.start()
    }

    private func predictedAngle() -> Double {
        guard angularVelocityDegPerSec < -Self.predictionSpeedFloor else { return rawAngle }
        let staleness = min(CACurrentMediaTime() - lastVelocitySampleTime, 0.12)
        return rawAngle + angularVelocityDegPerSec * (staleness + Self.predictionLatency)
    }

    // MARK: - Depth effect

    private func setActive(_ active: Bool) {
        isEffectActive = active
        if active {
            isEasingClosed = false
            activeSince = CACurrentMediaTime()
            if settings.isHoldTimeoutEnabled {
                timeoutReferenceAngle = rawAngle
                timeoutReferenceTime = activeSince
            }
            smoothedAngle.reset(to: rawAngle)
            stillCapture.endPrewarm()
            setPollInterval(Self.activePollInterval)
            presentPicture()
        } else {
            stillCapture.discard()
            timeoutReferenceAngle = nil
            beginEasingClosed()
        }
    }

    private func beginEasingClosed() {
        guard overlay.isVisible, displayLink != nil else {
            stopDisplayLink()
            overlay.dismiss(animated: true)
            return
        }
        isEasingClosed = true
        easeStartedAt = CACurrentMediaTime()
    }

    private func finishEasingClosed() {
        isEasingClosed = false
        stopDisplayLink()
        overlay.dismiss(animated: true)
    }

    private func presentPicture() {
        guard settings.isEnabled, !isSuspended, isEffectActive else { return }

        if settings.isLiveEnabled, let screen = NSScreen.builtIn,
           overlay.showLive(on: screen, startAngle: settings.triggerAngle, tuning: tuning, fadeIn: Self.fadeInDuration) {
            startDisplayLink()
            if let frame = liveCapture.newFrame() {
                overlay.absorb(frame)
                return
            }
            if let image = stillCapture.latestImage {
                overlay.seed(image: image)
                return
            }
            requestSeed()
            return
        }

        if let image = stillCapture.latestImage, let screen = stillCapture.latestScreen {
            show(image: image, on: screen)
            return
        }

        seedTask?.cancel()
        seedTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.stillCapture.captureOnce()
            guard !Task.isCancelled else { return }
            self.seedTask = nil
            guard self.isEffectActive, !self.overlay.isVisible,
                  let image = self.stillCapture.latestImage,
                  let screen = self.stillCapture.latestScreen else { return }
            self.show(image: image, on: screen)
        }
    }

    private func requestSeed() {
        seedTask?.cancel()
        seedTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.stillCapture.captureOnce()
            guard !Task.isCancelled else { return }
            self.seedTask = nil
            guard self.isEffectActive, !self.overlay.isPictureReady,
                  let image = self.stillCapture.latestImage else { return }
            self.overlay.seed(image: image)
        }
    }

    private func show(image: CGImage, on screen: NSScreen) {
        overlay.show(image: image, on: screen, startAngle: settings.triggerAngle, tuning: tuning, fadeIn: Self.fadeInDuration)
        startDisplayLink()
    }

    private func progress(for angle: Double) -> Double {
        let span = max(settings.rampSpan, 1)
        return ((settings.triggerAngle - angle) / span).clamped(to: 0...1)
    }

    // MARK: - Animation

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = overlay.hostWindow else { return }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrameTime, 1.0 / 240), 1.0 / 20)
        lastFrameTime = now

        if let frame = liveCapture.newFrame() {
            overlay.absorb(frame)
        }

        let target = isEasingClosed ? settings.triggerAngle : rawAngle
        smoothedAngle.advance(toward: target, dt: dt)

        guard isEasingClosed else {
            applyVisual(angle: smoothedAngle.value)
            return
        }

        let settled = smoothedAngle.value >= target - Self.easeSettleEpsilon
        let timedOut = now - easeStartedAt > Self.easeMaxDuration
        guard settled || timedOut else {
            applyVisual(angle: smoothedAngle.value)
            return
        }
        smoothedAngle.reset(to: target)
        applyVisual(angle: target)
        finishEasingClosed()
    }

    private func applyVisual(angle: Double) {
        overlay.update(progress: progress(for: angle), currentAngle: angle, tuning: tuning)
    }

    private var tuning: EffectTuning {
        EffectTuning(
            eyeDistanceInScreenHeights: settings.eyeDistanceInScreenHeights,
            leanAmount: settings.leanAmount,
            blurEvenness: settings.blurEvenness,
            dimReach: settings.dimReach,
            maxBlurRadiusPoints: settings.maxBlurRadius,
            maxDim: settings.maxDim
        )
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newID = BuiltInDisplay.directDisplayID()
                guard newID != self.builtInDisplayID else { return }
                self.builtInDisplayID = newID
                if self.isEffectActive { self.setActive(false) }
                self.liveCapture.stop()
                self.liveCapture.invalidateFilter()
                Task { await self.liveCapture.warmFilter() }
                self.overlay.discardLiveTexture()
                self.stillCapture.discard()
                Task { await self.stillCapture.warmFilter() }
            }
        }
    }

    private func suspend() {
        isSuspended = true
        stopEffectAndCapture()
    }

    private func resume() {
        isSuspended = false
        lastAngleForVelocity = nil
        angularVelocityDegPerSec = 0
        lastClosingMovementTime = -.greatestFiniteMagnitude
        timeoutReferenceAngle = nil
        timeoutAwaitingRelease = false
        isEasingClosed = false
        if let angle = sensor.readAngleDegrees() {
            rawAngle = angle
            smoothedAngle.reset(to: angle)
        }
        setPollInterval(Self.idlePollInterval)
    }
}
