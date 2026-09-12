import AppKit
import QuartzCore

/// A window that never takes keyboard focus, so a click-through overlay
/// never steals focus from whatever app is underneath.
private final class NonActivatingWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the renderer's `CAMetalLayer` and lets the Metal render loop, not
/// AppKit, own the redraw cadence.
private final class MetalHostView: NSView {
    init(metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        wantsLayer = true
        layer = metalLayer
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

/// The full-screen, click-through window that shows the tilted/blurred
/// picture, plus a tiny always-present decoy window that makes this app
/// excludable from its own `ScreenCaptureKit` capture — the API can only
/// exclude an application that owns at least one on-screen window, and
/// without the decoy the real overlay window would have to exist first
/// (which is exactly the window that must never appear in its own capture).
@MainActor
final class EffectOverlayWindow {
    private var renderer: EffectRenderer?
    private var rendererBuildAttempted = false
    private var window: NSWindow?
    private var fadingWindow: NSWindow?
    private var decoyWindow: NSWindow?
    private var hasRevealed = false
    private var buildGeneration = 0

    var isVisible: Bool { window != nil }
    var isPictureReady: Bool { renderer?.isReady ?? false }
    var hostWindow: NSWindow? { window }

    @discardableResult
    func warmUp() -> Bool {
        if !rendererBuildAttempted {
            rendererBuildAttempted = true
            renderer = EffectRenderer()
        }
        keepDecoyWindow()
        return renderer != nil
    }

    func discardLiveTexture() {
        renderer?.release()
    }

    // MARK: - Still picture

    func show(image: CGImage, on screen: NSScreen, startAngle: Double, tuning: EffectTuning, fadeIn: TimeInterval) {
        guard let renderer else { return }
        makeWindow(on: screen)
        renderer.release()
        startAngleForCurrentRun = startAngle

        buildGeneration += 1
        let generation = buildGeneration
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        let colorSpace = image.colorSpace
        Task.detached(priority: .userInitiated) {
            let built = PaddedPictureTexture.build(
                fromStill: image, unpaddedSizePoints: size, paddingPoints: EffectRenderer.paddingPoints, scale: scale
            )
            await MainActor.run { [weak self] in
                guard let self, self.buildGeneration == generation, let built else { return }
                renderer.adoptStill(built, colorSpace: colorSpace)
                self.reveal(fadeIn: fadeIn)
            }
        }
    }

    // MARK: - Live picture

    @discardableResult
    func showLive(on screen: NSScreen, startAngle: Double, tuning: EffectTuning, fadeIn: TimeInterval) -> Bool {
        guard let renderer else { return false }
        makeWindow(on: screen)
        startAngleForCurrentRun = startAngle
        buildGeneration += 1
        renderer.beginLive(
            sizePoints: screen.frame.size, scale: screen.backingScaleFactor,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
        )
        currentFadeIn = fadeIn
        return true
    }

    func absorb(_ frame: CapturedTextureFrame) {
        renderer?.absorbLive(frame)
        reveal(fadeIn: currentFadeIn)
    }

    func seed(image: CGImage) {
        renderer?.seedLive(with: image)
        reveal(fadeIn: currentFadeIn)
    }

    // MARK: - Per-frame update

    func update(progress: Double, currentAngle: Double, tuning: EffectTuning) {
        guard let renderer, let window else { return }
        let screen = window.screen ?? NSScreen.builtIn
        guard let screen else { return }
        renderer.render(
            startAngle: startAngleForCurrentRun,
            currentAngle: currentAngle,
            progress: progress,
            tuning: tuning,
            screenSizePoints: screen.frame.size,
            scale: screen.backingScaleFactor
        )
    }

    // MARK: - Dismissal

    func dismiss(animated: Bool, duration: TimeInterval = 0.22) {
        buildGeneration += 1
        renderer?.release()
        guard let window else { return }
        self.window = nil
        hasRevealed = false

        guard animated else {
            window.orderOut(nil)
            window.close()
            return
        }

        closeFadingWindow()
        fadingWindow = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.close()
                if self?.fadingWindow === window { self?.fadingWindow = nil }
            }
        }
    }

    // MARK: - Private

    private var startAngleForCurrentRun: Double = 0
    private var currentFadeIn: TimeInterval = 0.07

    private func makeWindow(on screen: NSScreen) {
        closeFadingWindow()
        window?.orderOut(nil)
        window?.close()

        let scale = screen.backingScaleFactor
        let newWindow = NonActivatingWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = false
        newWindow.ignoresMouseEvents = true
        newWindow.isReleasedWhenClosed = false
        newWindow.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        newWindow.alphaValue = 0
        newWindow.setFrame(screen.frame, display: false)

        guard let renderer else { return }
        let hostView = MetalHostView(metalLayer: renderer.layer, scale: scale)
        newWindow.contentView = hostView
        newWindow.orderFrontRegardless()

        window = newWindow
        hasRevealed = false
    }

    private func reveal(fadeIn: TimeInterval) {
        guard let window, !hasRevealed, renderer?.isReady == true else { return }
        hasRevealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func closeFadingWindow() {
        guard let fadingWindow else { return }
        fadingWindow.orderOut(nil)
        fadingWindow.close()
        self.fadingWindow = nil
    }

    /// A one-point, nearly-invisible ordinary window kept alive for the
    /// lifetime of the app so this process always owns at least one
    /// on-screen window and can therefore be excluded, by application, from
    /// its own screen capture.
    private func keepDecoyWindow() {
        guard decoyWindow == nil else { return }
        let decoy = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        decoy.isOpaque = false
        decoy.backgroundColor = .clear
        decoy.hasShadow = false
        decoy.ignoresMouseEvents = true
        decoy.isReleasedWhenClosed = false
        decoy.alphaValue = 0.004
        decoy.level = .normal
        decoy.orderFrontRegardless()
        decoyWindow = decoy
    }
}
