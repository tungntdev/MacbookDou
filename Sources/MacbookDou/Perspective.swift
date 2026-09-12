import CoreGraphics
import simd

/// Projective mapping of an axis-aligned rectangle onto an arbitrary
/// quadrilateral, aka a planar homography.
enum Homography {

    /// The 3x3 matrix `M` such that `M * (x, y, 1)` (divided by its third
    /// component) maps a point in the `width`x`height` source rectangle to
    /// `corners`, given bottom-left, bottom-right, top-right, top-left.
    ///
    /// Solved with Heckbert's square-to-quad construction: first find the
    /// projective map from the unit square to the quad, then fold in the
    /// scale that turns source pixels into unit-square coordinates.
    static func mapping(sourceWidth: Double, sourceHeight: Double, toQuad corners: [SIMD2<Double>]) -> simd_double3x3 {
        precondition(corners.count == 4)
        let p0 = corners[0], p1 = corners[1], p2 = corners[2], p3 = corners[3]

        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y

        var g = 0.0, h = 0.0
        if abs(dx3) > 1e-9 || abs(dy3) > 1e-9 {
            let det = dx1 * dy2 - dx2 * dy1
            if abs(det) > 1e-12 {
                g = (dx3 * dy2 - dx2 * dy3) / det
                h = (dx1 * dy3 - dx3 * dy1) / det
            }
        }

        let a = p1.x - p0.x + g * p1.x
        let b = p3.x - p0.x + h * p3.x
        let c = p0.x
        let d = p1.y - p0.y + g * p1.y
        let e = p3.y - p0.y + h * p3.y
        let f = p0.y

        // Compose with the unit-square scale (u = x/width, v = y/height) so
        // the matrix consumes raw source coordinates directly.
        return simd_double3x3(columns: (
            SIMD3(a / sourceWidth, d / sourceWidth, g / sourceWidth),
            SIMD3(b / sourceHeight, e / sourceHeight, h / sourceHeight),
            SIMD3(c, f, 1)
        ))
    }
}

/// Places the four corners of the captured screen image in screen-space as
/// if it were a rigid sheet of glass hinged at the bottom edge, tilting back
/// as the lid closes, viewed by a fixed eye in front of the machine.
struct HingeProjection {

    /// Past this many degrees of tilt the sheet would be edge-on (or facing
    /// away) to the viewer; clamp before it gets there.
    var maxTiltDegrees: Double = 88

    /// Bottom-left, bottom-right, top-right, top-left, in screen points.
    func projectedCorners(
        startAngle: Double,
        currentAngle: Double,
        eyeDistanceInScreenHeights: Double,
        leanFactor: Double,
        screenSize: CGSize
    ) -> [CGPoint] {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let startRadians = startAngle * .pi / 180
        let currentRadians = currentAngle * .pi / 180

        let closedBy = max(startAngle - currentAngle, 0)
        let tiltRadians = min(leanFactor * closedBy, maxTiltDegrees) * .pi / 180

        // Fix the eye in world space at the moment the effect starts, with
        // the hinge as the origin, then re-express it relative to the glass
        // as the glass itself rotates under it.
        let eyeForward = height * eyeDistanceInScreenHeights + height / 2 * cos(startRadians)
        let eyeUp = height / 2 * sin(startRadians)

        let alongGlass = eyeForward * cos(currentRadians) + eyeUp * sin(currentRadians)
        let awayFromGlass = max(eyeForward * sin(currentRadians) - eyeUp * cos(currentRadians), height / 10)

        let halfWidth = width / 2
        func project(_ x: Double, _ y: Double) -> CGPoint {
            let perspectiveScale = awayFromGlass / (awayFromGlass + y * sin(tiltRadians))
            return CGPoint(
                x: halfWidth + (x - halfWidth) * perspectiveScale,
                y: alongGlass + (y * cos(tiltRadians) - alongGlass) * perspectiveScale
            )
        }

        return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
    }
}
