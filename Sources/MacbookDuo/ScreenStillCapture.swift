import AppKit
import ScreenCaptureKit

/// Grabs single still frames of the built-in display via
/// `SCScreenshotManager`, either on demand or on a repeating timer while
/// "prewarming" so a frame is instantly ready the moment the effect starts.
@MainActor
final class ScreenStillCapture {
    private(set) var latestImage: CGImage?
    private(set) var latestScreen: NSScreen?

    private var cachedFilter: SCContentFilter?
    private var cachedFilterDisplayID: CGDirectDisplayID?
    private var prewarmTimer: Timer?
    private var inFlight: Task<Void, Never>?

    /// Builds the content filter ahead of time so the first real capture
    /// isn't slowed down by `SCShareableContent` enumeration.
    func warmFilter() async {
        _ = try? await filter()
    }

    func invalidateFilter() {
        cachedFilter = nil
        cachedFilterDisplayID = nil
    }

    func beginPrewarm(interval: TimeInterval) {
        guard prewarmTimer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureNowIfIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        prewarmTimer = timer
        captureNowIfIdle()
    }

    func endPrewarm() {
        prewarmTimer?.invalidate()
        prewarmTimer = nil
    }

    func discard() {
        endPrewarm()
        inFlight?.cancel()
        inFlight = nil
        latestImage = nil
        latestScreen = nil
    }

    func stop() { discard() }

    /// Captures once and waits for the result, coalescing with any capture
    /// already in flight so overlapping calls don't double-fire the API.
    func captureOnce() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.captureNowAndWait() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func captureNowIfIdle() {
        guard inFlight == nil else { return }
        let task = Task { await self.captureNowAndWait() }
        inFlight = task
        Task { await task.value; self.inFlight = nil }
    }

    private func captureNowAndWait() async {
        guard let screen = NSScreen.builtIn else { return }
        do {
            guard let filter = try await filter() else { return }
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            config.scalesToFit = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            latestImage = image
            latestScreen = screen
        } catch {
            Log.capture.error("still capture failed: \(error, privacy: .public)")
            invalidateFilter()
        }
    }

    private func filter() async throws -> SCContentFilter? {
        if let cachedFilter, cachedFilterDisplayID == BuiltInDisplay.directDisplayID() {
            return cachedFilter
        }
        let filter = try await BuiltInDisplay.makeFilter()
        cachedFilter = filter
        cachedFilterDisplayID = BuiltInDisplay.directDisplayID()
        return filter
    }
}
