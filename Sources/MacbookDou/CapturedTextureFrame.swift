import CoreVideo
import Metal

/// Pairs a zero-copy `MTLTexture` view of a captured frame with the
/// `CVMetalTexture` that vends it. `CVMetalTexture` owns a reference back to
/// the underlying `IOSurface`; dropping it early would let CoreVideo recycle
/// that surface while the GPU might still be reading from it, so it must be
/// kept alive for exactly as long as the plain `MTLTexture` is in use.
struct CapturedTextureFrame: @unchecked Sendable {
    let texture: MTLTexture
    private let backing: CVMetalTexture

    init(backing: CVMetalTexture) {
        self.backing = backing
        // Force-unwrap is safe: callers only construct this from a
        // `CVMetalTexture` they just successfully created.
        self.texture = CVMetalTextureGetTexture(backing)!
    }
}
