import CoreGraphics
import Metal
import MetalPerformanceShaders

/// A GPU texture holding one captured frame, composited onto a black canvas
/// with a fixed margin around every edge and a Gaussian mip pyramid built on
/// top. The margin must exceed the largest radius the shader will ever blur
/// with, so blur always fades into true black instead of sampling real
/// picture content past the edge.
final class PaddedPictureTexture {
    let texture: MTLTexture
    /// Size of the real (unpadded) captured picture, in points.
    let unpaddedSizePoints: CGSize
    let paddingPoints: CGFloat
    let scale: CGFloat
    let maxMipLevel: Float

    private let pyramid: MPSImageGaussianPyramid

    private init(texture: MTLTexture, unpaddedSizePoints: CGSize, paddingPoints: CGFloat, scale: CGFloat) {
        self.texture = texture
        self.unpaddedSizePoints = unpaddedSizePoints
        self.paddingPoints = paddingPoints
        self.scale = scale
        let longestSide = max(texture.width, texture.height)
        maxMipLevel = Float(max(Int(log2(Double(longestSide))), 0))
        pyramid = MPSImageGaussianPyramid(device: MetalContext.device, centerWeight: 0.375)
    }

    var paddedPixelSize: (width: Int, height: Int) { (texture.width, texture.height) }

    /// Pixel offset of the unpadded content's top-left corner within the
    /// padded texture (padding is symmetric, so this is the same on the
    /// bottom/right by construction).
    var interiorOriginPixels: MTLOrigin {
        MTLOrigin(x: Int(paddingPoints * scale), y: Int(paddingPoints * scale), z: 0)
    }

    var interiorSizePixels: MTLSize {
        MTLSize(width: Int(unpaddedSizePoints.width * scale), height: Int(unpaddedSizePoints.height * scale), depth: 1)
    }

    // MARK: - Construction

    /// Builds a fully-composited, fully-mipped texture from a still image.
    /// Safe to call off the main thread; blocks until the GPU work is done.
    static func build(fromStill image: CGImage, unpaddedSizePoints: CGSize, paddingPoints: CGFloat, scale: CGFloat) -> PaddedPictureTexture? {
        let paddedWidthPx = Int((unpaddedSizePoints.width + 2 * paddingPoints) * scale)
        let paddedHeightPx = Int((unpaddedSizePoints.height + 2 * paddingPoints) * scale)
        guard paddedWidthPx > 0, paddedHeightPx > 0 else { return nil }

        let bytesPerRow = paddedWidthPx * 4
        guard let stagingBuffer = MetalContext.device.makeBuffer(
            length: bytesPerRow * paddedHeightPx, options: .storageModeShared
        ) else { return nil }

        let colorSpace = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: stagingBuffer.contents(),
            width: paddedWidthPx, height: paddedHeightPx,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: paddedWidthPx, height: paddedHeightPx))

        let padPx = CGFloat(Int(paddingPoints * scale))
        context.draw(image, in: CGRect(
            x: padPx, y: padPx,
            width: CGFloat(image.width), height: CGFloat(image.height)
        ))

        guard let texture = makeMippedTexture(width: paddedWidthPx, height: paddedHeightPx) else { return nil }
        let picture = PaddedPictureTexture(
            texture: texture, unpaddedSizePoints: unpaddedSizePoints, paddingPoints: paddingPoints, scale: scale
        )

        guard let commandBuffer = MetalContext.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: stagingBuffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * paddedHeightPx,
            sourceSize: MTLSize(width: paddedWidthPx, height: paddedHeightPx, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        var mutableTexture: MTLTexture = texture
        _ = picture.pyramid.encode(commandBuffer: commandBuffer, inPlaceTexture: &mutableTexture, fallbackCopyAllocator: nil)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return picture
    }

    /// Allocates an empty (black) persistent texture for the live path, sized
    /// once per screen/scale combination and reused across frames.
    static func makeEmpty(unpaddedSizePoints: CGSize, paddingPoints: CGFloat, scale: CGFloat) -> PaddedPictureTexture? {
        let paddedWidthPx = Int((unpaddedSizePoints.width + 2 * paddingPoints) * scale)
        let paddedHeightPx = Int((unpaddedSizePoints.height + 2 * paddingPoints) * scale)
        guard paddedWidthPx > 0, paddedHeightPx > 0,
              let texture = makeMippedTexture(width: paddedWidthPx, height: paddedHeightPx),
              let commandBuffer = MetalContext.commandQueue.makeCommandBuffer() else { return nil }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        commandBuffer.commit()

        return PaddedPictureTexture(
            texture: texture, unpaddedSizePoints: unpaddedSizePoints, paddingPoints: paddingPoints, scale: scale
        )
    }

    // MARK: - Live updates

    /// Blits a live-captured frame (already exactly the interior size) into
    /// place and rebuilds the mip pyramid on the same command buffer.
    func absorbLive(_ frame: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: frame, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: interiorSizePixels,
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: interiorOriginPixels
        )
        blit.endEncoding()
        var mutableTexture: MTLTexture = texture
        _ = pyramid.encode(commandBuffer: commandBuffer, inPlaceTexture: &mutableTexture, fallbackCopyAllocator: nil)
    }

    /// One-time still-image seed into the live texture's interior, so the
    /// live overlay shows something before its first real frame arrives.
    func seedLive(with image: CGImage, commandBuffer: MTLCommandBuffer) {
        let width = Int(unpaddedSizePoints.width * scale)
        let height = Int(unpaddedSizePoints.height * scale)
        let bytesPerRow = width * 4
        guard width > 0, height > 0,
              let stagingBuffer = MetalContext.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let context = CGContext(
                  data: stagingBuffer.contents(), width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: stagingBuffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * height,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: interiorOriginPixels
        )
        blit.endEncoding()
        var mutableTexture: MTLTexture = texture
        _ = pyramid.encode(commandBuffer: commandBuffer, inPlaceTexture: &mutableTexture, fallbackCopyAllocator: nil)
    }

    private static func makeMippedTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        return MetalContext.device.makeTexture(descriptor: descriptor)
    }
}
