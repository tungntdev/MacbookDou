import AppKit
import CoreMedia
import ScreenCaptureKit

/// Continuously streams the built-in display via `SCStream` so the overlay
/// can show live content (video keeps playing, the cursor blinks, etc.)
/// while the depth effect is up.
@MainActor
final class ScreenLiveCapture {
    private var stream: SCStream?
    private var output: StreamOutput?
    private var cachedFilter: SCContentFilter?
    private var cachedFilterDisplayID: CGDirectDisplayID?
    private var startTask: Task<Void, Never>?

    /// No more than this often, so a burst of frames right after the stream
    /// starts doesn't outrun the render loop's own pacing.
    private let minimumHandOverInterval: CFTimeInterval = 1.0 / 32
    private var lastHandedOverAt: CFTimeInterval = 0
    private var lastHandedOverID: UInt64 = 0

    func warmFilter() async {
        _ = try? await filter()
    }

    func invalidateFilter() {
        cachedFilter = nil
        cachedFilterDisplayID = nil
    }

    /// Starts asynchronously. `SCStream.startCapture()` can take a while, so
    /// this should be kicked off as soon as the lid is seen closing, not at
    /// the exact moment the effect trigger angle is crossed, or the live
    /// picture will visibly lag the geometry animation.
    func start() {
        guard stream == nil, startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.startAndWait()
            self?.startTask = nil
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        guard let stream else { return }
        self.stream = nil
        output = nil
        Task { try? await stream.stopCapture() }
    }

    /// The newest frame not yet handed out, or `nil` if there's nothing new
    /// (or it's too soon since the last hand-over).
    func newFrame() -> CapturedTextureFrame? {
        guard let output else { return nil }
        let now = CACurrentMediaTime()
        guard now - lastHandedOverAt >= minimumHandOverInterval else { return nil }
        guard let (frame, id) = output.latest(), id != lastHandedOverID else { return nil }
        lastHandedOverAt = now
        lastHandedOverID = id
        return frame
    }

    private func startAndWait() async {
        guard let screen = NSScreen.builtIn, let filter = try? await filter() else { return }

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.displayP3
        config.showsCursor = false
        config.queueDepth = 5
        config.scalesToFit = false

        let output = StreamOutput()
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .liveCaptureQueue)
            try await stream.startCapture()
            guard !Task.isCancelled else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            self.output = output
        } catch {
            Log.capture.error("live capture failed to start: \(error, privacy: .public)")
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

    /// Receives sample buffers off the main thread, wraps each as a
    /// zero-copy Metal texture, and keeps only the newest one — an
    /// undelivered older frame is simply dropped rather than queued.
    private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
        private let lock = NSLock()
        private var textureCache: CVMetalTextureCache?
        private var nextID: UInt64 = 1
        private var stored: (frame: CapturedTextureFrame, id: UInt64)?

        override init() {
            super.init()
            CVMetalTextureCacheCreate(nil, nil, MetalContext.device, nil, &textureCache)
        }

        func latest() -> (CapturedTextureFrame, UInt64)? {
            lock.lock()
            defer { lock.unlock() }
            guard let stored else { return nil }
            return (stored.frame, stored.id)
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid,
                  let pixelBuffer = sampleBuffer.imageBuffer,
                  let textureCache else { return }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, .bgra8Unorm_srgb, width, height, 0, &cvTexture
            )
            // Let go of any recycled surfaces from prior frames now that a
            // fresh one has landed.
            CVMetalTextureCacheFlush(textureCache, 0)

            guard status == kCVReturnSuccess, let cvTexture else { return }
            let frame = CapturedTextureFrame(backing: cvTexture)

            lock.lock()
            stored = (frame, nextID)
            nextID += 1
            lock.unlock()
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            Log.capture.error("live capture stopped: \(error, privacy: .public)")
        }
    }
}

private extension DispatchQueue {
    static let liveCaptureQueue = DispatchQueue(label: "com.local.MacbookDuo.live-capture", qos: .userInteractive)
}
