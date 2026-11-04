import Foundation
import simd

/// A never-ending, seamless pull-back across folded paper. The sheet is pleated along
/// parallel creases whose spacing grows geometrically away from a vanishing line just off
/// screen: scaling about `centre` by `scale` maps the pleats exactly onto themselves. So the
/// camera can draw back forever — pleats flowing towards the vanishing edge, new ones arriving
/// from the far side — with no frames, edges or seams.
///
/// Coordinates are scene units (x 0…aspect, y 0…1 is the screen at rest). A "level" is how
/// many stages ago something was printed: level-l coordinates are level-0 ones scaled up by
/// `scale`^l about `centre`.
struct Dive: Equatable {
    /// How much the camera pulls back per stage.
    static let scale = 2.4
    /// Pleats per stage (even, so mountain and valley folds line up from stage to stage).
    static let pleats = 4
    /// Lines older than this many stages have shrunk away.
    static let levels = 4

    /// The vanishing point (off screen); the pleats converge on the line through it.
    var centre: SIMD2<Double>
    /// Unit normal of the creases.
    var normal: SIMD2<Double>
    /// 1 → 0 through the current stage; pulling back runs it down.
    var phase = 1.0

    static func make(seed: UInt64, aspect: Double) -> Dive {
        var rng = SeededRandom(seed: seed ^ 0xD1FE)
        // The pleats run nearly horizontal, vanishing just below (or above) the frame.
        let below = rng.unit() < 0.7
        let lean = (4 + 8 * rng.unit()) * (rng.unit() < 0.5 ? -1 : 1) * .pi / 180
        let centre = SIMD2(aspect * (0.3 + 0.4 * rng.unit()), below ? 1.12 : -0.12)
        return Dive(centre: centre, normal: SIMD2(-sin(lean), cos(lean)))
    }

    /// Pulls back by `stages`; returns how many stage boundaries were crossed (each one moves
    /// everything printed one level deeper).
    mutating func pullBack(by stages: Double) -> Int {
        phase -= max(0, stages)
        var crossed = 0
        while phase < 0 {
            phase += 1
            crossed += 1
        }
        return crossed
    }

    /// A level-`level` point in level-0 coordinates.
    func toLevelZero(_ p: SIMD2<Double>, level: Int) -> SIMD2<Double> {
        centre + (p - centre) * pow(Self.scale, -Double(level))
    }

    /// The camera's place in the stage, as a map from "at rest" coordinates to level 0:
    /// c + S^-t · (r − c). As t runs down from 1 to 0 the view widens by `scale`.
    func view() -> simd_double3x3 {
        let s = pow(Self.scale, -phase)
        let t = centre * (1 - s)
        return simd_double3x3(rows: [SIMD3(s, 0, t.x), SIMD3(0, s, t.y), SIMD3(0, 0, 1)])
    }

    /// The creases (level-0 coordinates) within `reach` of the vanishing line, skipping ones
    /// too close together to print along. Ordered along the normal, as FoldLayout expects.
    func creases(reach: Double, closest: Double = 0.04) -> [FoldLayout.Crease] {
        let angle = atan2(-normal.x, normal.y)  // direction (cos, sin) with normal (-sin, cos)
        let step = pow(Self.scale, 1 / Double(Self.pleats))
        var offsets: [Double] = []
        var d = pow(step, (log(closest) / log(step)).rounded(.up))
        while d < reach {
            offsets += [-d, d]
            d *= step
        }
        return offsets.sorted().map { FoldLayout.Crease(point: centre + normal * $0, angle: angle) }
    }
}
