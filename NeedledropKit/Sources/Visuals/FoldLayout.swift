import CoreGraphics
import Foundation
import simd

/// The composition of the paper: a few long creases across the frame, and where text can
/// be set along them. Shared by the shader (which draws the folds) and the lyric layout
/// (which sets words against them), so the words sit exactly on the folds.
///
/// Coordinates are scene units: y runs 0…1 down the frame, x runs 0…aspect across.
struct FoldLayout: Equatable {
    struct Crease: Equatable {
        var point: SIMD2<Double>
        /// Radians. The crease runs along (cos, sin).
        var angle: Double

        var direction: SIMD2<Double> { SIMD2(cos(angle), sin(angle)) }
        var normal: SIMD2<Double> { SIMD2(-sin(angle), cos(angle)) }
        /// Signed distance of `p` from the crease, positive on the `normal` side.
        func side(_ p: SIMD2<Double>) -> Double { simd_dot(p - point, normal) }
    }

    var aspect: Double
    /// Ordered along the shared normal, so the strip index is the count of creases passed.
    var creases: [Crease]
    /// Fold depth (radians each strip tilts).
    var tilt: Double
    /// The light, slowly swinging so strips take turns catching it.
    var light: SIMD3<Double>

    static let maximumCreases = 4

    /// A composition for an album (`seed`) at animation time `flow`. The creases drift a
    /// little; the base geometry is the album's own unless the art direction fixes the
    /// angle or count.
    static func make(seed: UInt64, aspect: Double, flow: Double, bass: Double = 0,
                     angle: Double? = nil, count: Int? = nil, turbulence: Double = 0.5) -> FoldLayout {
        var rng = SeededRandom(seed: seed ^ 0xF01D)
        // A dramatic diagonal, leaning one way or the other.
        let seededLean = (12 + 22 * rng.unit()) * (rng.unit() < 0.5 ? -1 : 1)
        let lean = angle ?? seededLean
        let base = lean * .pi / 180
        let normal = SIMD2(-sin(base), cos(base))
        let centre = SIMD2(aspect / 2, 0.5)

        // Spread the creases across the frame's extent along the normal.
        let corners = [SIMD2(0.0, 0.0), SIMD2(aspect, 0), SIMD2(0, 1), SIMD2(aspect, 1)]
        let extents = corners.map { simd_dot($0 - centre, normal) }
        let lo = extents.min()!, hi = extents.max()!
        let n = min(maximumCreases, max(2, count ?? 3))
        let fractions = (0..<n).map { (Double($0) + 0.8) / (Double(n) + 0.6) }
        let wander = 0.5 + turbulence

        var creases: [Crease] = []
        for (i, f) in fractions.enumerated() {
            let jitter = (rng.unit() - 0.5) * 0.08
            let wobble = 0.018 * wander * sin(flow * 0.2 + Double(i) * 2.1)
            let offset = lo + (hi - lo) * (f + jitter) + wobble
            let creaseAngle = base + (rng.unit() - 0.5) * 0.07 + 0.02 * wander * sin(flow * 0.13 + Double(i))
            creases.append(Crease(point: centre + normal * offset, angle: creaseAngle))
        }

        let tilt = 0.5 * (0.8 + 0.2 * sin(flow * 0.15)) + 0.08 * bass
        let swing = cos(flow * 0.1)
        let light = simd_normalize(SIMD3(normal.x * 0.65 * swing, normal.y * 0.65 * swing, 0.75))
        return FoldLayout(aspect: aspect, creases: creases, tilt: tilt, light: light)
    }

    /// Part-way from this composition to `other` (t 0…1): each crease turns and slides to
    /// its counterpart. Creases one side has and the other doesn't enter (or leave) from beyond
    /// the edge of the frame, so the paper refolds rather than jumping.
    func morphed(to other: FoldLayout, _ t: Double) -> FoldLayout {
        let n = max(creases.count, other.creases.count)
        func offstage(_ layout: FoldLayout, _ i: Int) -> Crease {
            // Beyond the far edge along the composition's normal, at the same angle.
            let reference = layout.creases.last ?? Crease(point: SIMD2(aspect / 2, 0.5), angle: 0)
            let far = SIMD2(aspect / 2, 0.5) + reference.normal * (1.25 + 0.3 * Double(i))
            return Crease(point: far, angle: reference.angle)
        }
        var mixed: [Crease] = []
        for i in 0..<n {
            let a = i < creases.count ? creases[i] : offstage(self, i)
            let b = i < other.creases.count ? other.creases[i] : offstage(other, i)
            // Turn the short way round.
            var turn = (b.angle - a.angle).truncatingRemainder(dividingBy: .pi)
            if turn > .pi / 2 { turn -= .pi } else if turn < -.pi / 2 { turn += .pi }
            mixed.append(Crease(point: a.point + (b.point - a.point) * t, angle: a.angle + turn * t))
        }
        // Indices stay put (a line soaking out keeps its crease); offstage creases lie beyond
        // the frame on the far side, so no point on screen counts them.
        return FoldLayout(aspect: aspect, creases: mixed, tilt: tilt + (other.tilt - tilt) * t,
                          light: simd_normalize(light + (other.light - light) * t))
    }

    /// Which strip `p` is on (0…creaseCount).
    func strip(at p: SIMD2<Double>) -> Int {
        creases.filter { $0.side(p) > 0 }.count
    }

    // MARK: - Setting text along a crease

    /// Text set on one side of a crease: its centre, at `along` (scene units from the
    /// crease's point), offset off the crease by half its height plus a gap.
    struct TextSpot: Equatable {
        var crease: Int
        /// +1: on the crease's normal side; -1: the other side.
        var side: Double
        var along: Double
    }

    /// Centre and angle of text of `size` (width along the crease, height across) at `spot`.
    func frame(for spot: TextSpot, size: SIMD2<Double>) -> (centre: SIMD2<Double>, angle: Double) {
        let c = creases[spot.crease]
        let gap = 0.025
        let centre = c.point + c.direction * spot.along + c.normal * spot.side * (size.y / 2 + gap)
        return (centre, c.angle)
    }

    /// Corners of a rotated rectangle.
    static func corners(centre: SIMD2<Double>, angle: Double, size: SIMD2<Double>) -> [SIMD2<Double>] {
        let d = SIMD2(cos(angle), sin(angle)), n = SIMD2(-sin(angle), cos(angle))
        let hw = d * size.x / 2, hh = n * size.y / 2
        return [centre - hw - hh, centre + hw - hh, centre + hw + hh, centre - hw + hh]
    }

    /// Does the rotated text rectangle stay on screen, on one strip, and clear of `obstacles`?
    /// `allowed`, when given, decides "on screen" point by point (the camera may be looking
    /// at only part of the sheet) and can rule out more (the cover).
    func fits(_ spot: TextSpot, size: SIMD2<Double>, obstacles: [CGRect], oneStrip: Bool = true,
              margin: Double = 0.035, allowed: ((SIMD2<Double>) -> Bool)? = nil) -> Bool {
        let (centre, angle) = frame(for: spot, size: size)
        let cs = Self.corners(centre: centre, angle: angle, size: size)
        if let allowed {
            let d = SIMD2(cos(angle), sin(angle)), n = SIMD2(-sin(angle), cos(angle))
            for i in 0...12 {
                for j in 0...2 {
                    let p = centre + d * size.x * (Double(i) / 12 - 0.5) + n * size.y * (Double(j) / 2 - 0.5)
                    if !allowed(p) { return false }
                }
            }
        } else {
            for p in cs where p.x < margin || p.x > aspect - margin || p.y < margin || p.y > 1 - margin { return false }
        }
        // Entirely on one strip: no other crease runs through the words.
        if oneStrip {
            let strip = strip(at: centre)
            guard cs.allSatisfy({ self.strip(at: $0) == strip }) else { return false }
        }
        // Clear of obstacles: sample the text area, and check obstacle corners aren't inside it.
        let d = SIMD2(cos(angle), sin(angle)), n = SIMD2(-sin(angle), cos(angle))
        for obstacle in obstacles {
            for i in 0...6 {
                for j in 0...3 {
                    let p = centre + d * size.x * (Double(i) / 6 - 0.5) + n * size.y * (Double(j) / 3 - 0.5)
                    if obstacle.contains(CGPoint(x: p.x, y: p.y)) { return false }
                }
            }
            let oc = [CGPoint(x: obstacle.minX, y: obstacle.minY), CGPoint(x: obstacle.maxX, y: obstacle.minY),
                      CGPoint(x: obstacle.maxX, y: obstacle.maxY), CGPoint(x: obstacle.minX, y: obstacle.maxY)]
            for o in oc {
                let local = SIMD2(o.x, o.y) - centre
                if abs(simd_dot(local, d)) < size.x / 2, abs(simd_dot(local, n)) < size.y / 2 { return false }
            }
        }
        return true
    }

    /// A good spot for line number `index`: crease, side and position along it take turns
    /// (so lines move through the composition), sliding along the crease until the text
    /// fits. Nil if nothing fits at this size.
    func spot(forLine index: Int, size: SIMD2<Double>, obstacles: [CGRect],
              allowed: ((SIMD2<Double>) -> Bool)? = nil) -> TextSpot? {
        var candidates: [(crease: Int, side: Double)] = []
        for k in 0..<creases.count { candidates += [(k, -1), (k, 1)] }
        // Each line moves on: a different crease or side, and a different stretch along it.
        let start = (index * 3) % candidates.count
        let ranked = (0..<candidates.count).map { candidates[($0 + start) % candidates.count] }
        let anchors = [-0.28, 0.12, 0.38, -0.05]
        let preferred = anchors[abs(index) % anchors.count] * aspect
        let positions = stride(from: -aspect, through: aspect, by: 0.025).sorted { abs($0 - preferred) < abs($1 - preferred) }
        // Ideally the words sit on one strip; failing that, they may run across another fold.
        for oneStrip in [true, false] {
            for candidate in ranked {
                for along in positions {
                    let spot = TextSpot(crease: candidate.crease, side: candidate.side, along: along)
                    if fits(spot, size: size, obstacles: obstacles, oneStrip: oneStrip, allowed: allowed) { return spot }
                }
            }
        }
        return nil
    }
}
