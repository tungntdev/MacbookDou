import Metal

/// The one Metal device and command queue shared by capture (for wrapping
/// captured pixel buffers as textures) and rendering.
enum MetalContext {
    static let device: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this Mac")
        }
        return device
    }()

    static let commandQueue: MTLCommandQueue = {
        guard let queue = device.makeCommandQueue() else {
            fatalError("failed to create a Metal command queue")
        }
        return queue
    }()
}
