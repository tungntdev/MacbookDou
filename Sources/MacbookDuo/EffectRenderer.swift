import CoreGraphics
import Metal
import QuartzCore
import simd

/// Runtime copy of the settings that shape one rendered frame.
struct EffectTuning {
    var eyeDistanceInScreenHeights: Double = 2.7
    var leanAmount: Double = 1
    var blurEvenness: Double = 0
    var dimReach: Double = 0.5
    var maxBlurRadiusPoints: Double = 135
    var maxDim: Double = 1
}

/// Layout must stay byte-for-byte in sync with `EffectUniforms` in
/// EffectShaders.metal.
private struct EffectUniforms {
    var pictureColumn0: SIMD4<Float>
    var pictureColumn1: SIMD4<Float>
    var pictureColumn2: SIMD4<Float>
    var pointsPerPixel: Float
    var viewHeightPoints: Float
    var pictureWidthPoints: Float
    var pictureHeightPoints: Float
    var paddingPoints: Float
    var maxMipLevel: Float
    var maxBlurRadiusPixels: Float
    var blurStrength: Float
    var blurFloor: Float
    var dimStrength: Float
    var dimFloor: Float
    var dimReach: Float
}

/// Owns the Metal pipeline and the `CAMetalLayer` the overlay window hosts,
/// and draws one warped/blurred/dimmed frame of the captured picture per
/// call to `render`.
final class EffectRenderer {
    /// Black margin around the captured picture, in points. Must exceed the
    /// largest radius `maxBlurRadiusPoints` can reach, so blur always fades
    /// to true black rather than sampling real edge content.
    static let paddingPoints: CGFloat = 120

    let layer = CAMetalLayer()

    private let pipelineState: MTLRenderPipelineState
    private let geometry = HingeProjection()
    private let curve = EffectCurve()

    private var picture: PaddedPictureTexture?
    private var liveScale: CGFloat = 0
    private var liveSizePoints: CGSize = .zero

    /// True once something has actually been drawn into `picture`.
    private(set) var isReady = false

    init?() {
        guard let library = try? MetalContext.device.makeLibrary(source: EffectShaderSource.code, options: nil),
              let vertexFunction = library.makeFunction(name: "depthVertexMain"),
              let fragmentFunction = library.makeFunction(name: "depthFragmentMain") else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        guard let state = try? MetalContext.device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelineState = state

        layer.device = MetalContext.device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        layer.isOpaque = false
        // The shader always writes alpha 1, so this is only to keep the
        // window server from treating the fullscreen layer as occluding
        // everything behind it before the first frame draws.
        //
        // Vsync-blocked `nextDrawable()` waits pair badly with this app
        // being excluded from its own screen capture: the compositor ends
        // up drawing the frame twice per vsync, which halves the effective
        // frame rate. Pacing is done by the caller's own display link
        // instead.
        layer.displaySyncEnabled = false
    }

    // MARK: - Still picture

    func adoptStill(_ built: PaddedPictureTexture, colorSpace: CGColorSpace?) {
        picture = built
        if let colorSpace { layer.colorspace = colorSpace }
        isReady = true
    }

    // MARK: - Live picture

    func beginLive(sizePoints: CGSize, scale: CGFloat, colorSpace: CGColorSpace?) {
        guard picture == nil || liveSizePoints != sizePoints || liveScale != scale else { return }
        picture = PaddedPictureTexture.makeEmpty(unpaddedSizePoints: sizePoints, paddingPoints: Self.paddingPoints, scale: scale)
        liveSizePoints = sizePoints
        liveScale = scale
        if let colorSpace { layer.colorspace = colorSpace }
        isReady = false
    }

    func absorbLive(_ frame: CapturedTextureFrame) {
        guard let picture, let commandBuffer = MetalContext.commandQueue.makeCommandBuffer() else { return }
        picture.absorbLive(frame.texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        isReady = true
    }

    func seedLive(with image: CGImage) {
        guard let picture, let commandBuffer = MetalContext.commandQueue.makeCommandBuffer() else { return }
        picture.seedLive(with: image, commandBuffer: commandBuffer)
        commandBuffer.commit()
        isReady = true
    }

    func release() {
        picture = nil
        isReady = false
        liveSizePoints = .zero
        liveScale = 0
    }

    // MARK: - Drawing

    func render(
        startAngle: Double,
        currentAngle: Double,
        progress: Double,
        tuning: EffectTuning,
        screenSizePoints: CGSize,
        scale: CGFloat
    ) {
        guard isReady, let picture, let drawable = layer.nextDrawable() else { return }

        let corners = geometry.projectedCorners(
            startAngle: startAngle,
            currentAngle: currentAngle,
            eyeDistanceInScreenHeights: tuning.eyeDistanceInScreenHeights,
            leanFactor: tuning.leanAmount,
            screenSize: screenSizePoints
        )
        let forward = Homography.mapping(
            sourceWidth: Double(screenSizePoints.width),
            sourceHeight: Double(screenSizePoints.height),
            toQuad: corners.map { SIMD2(Double($0.x), Double($0.y)) }
        )
        let inverse = forward.inverse

        var uniforms = EffectUniforms(
            pictureColumn0: SIMD4(Float(inverse[0][0]), Float(inverse[0][1]), Float(inverse[0][2]), 0),
            pictureColumn1: SIMD4(Float(inverse[1][0]), Float(inverse[1][1]), Float(inverse[1][2]), 0),
            pictureColumn2: SIMD4(Float(inverse[2][0]), Float(inverse[2][1]), Float(inverse[2][2]), 0),
            pointsPerPixel: Float(1 / scale),
            viewHeightPoints: Float(screenSizePoints.height),
            pictureWidthPoints: Float(picture.unpaddedSizePoints.width),
            pictureHeightPoints: Float(picture.unpaddedSizePoints.height),
            paddingPoints: Float(picture.paddingPoints),
            maxMipLevel: picture.maxMipLevel,
            maxBlurRadiusPixels: Float(tuning.maxBlurRadiusPoints * scale),
            blurStrength: Float(curve.blurStrength(progress: progress)),
            blurFloor: Float(tuning.blurEvenness),
            dimStrength: Float(curve.dimStrength(progress: progress) * tuning.maxDim),
            dimFloor: Float(curve.dimHingeFloor),
            dimReach: Float(tuning.dimReach)
        )

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = MetalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(picture.texture, index: 0)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
