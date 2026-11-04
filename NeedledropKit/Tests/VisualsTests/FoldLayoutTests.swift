import CoreGraphics
import simd
import Testing
@testable import Visuals

@Suite struct FoldLayoutTests {
    private let aspect = 16.0 / 9
    /// The cover moved aside for lyrics (left third, 0.52 tall), padded.
    private var cover: CGRect { CGRect(x: aspect * 0.3 - 0.295, y: 0.5 - 0.295, width: 0.59, height: 0.59) }

    @Test func eachAlbumHasItsOwnFewFolds() {
        let a = FoldLayout.make(seed: 1, aspect: aspect, flow: 0)
        let b = FoldLayout.make(seed: 2, aspect: aspect, flow: 0)
        #expect(a.creases.count == 3)
        #expect(FoldLayout.make(seed: 1, aspect: aspect, flow: 0, angle: 20, count: 2).creases.count == 2)
        #expect(abs(FoldLayout.make(seed: 1, aspect: aspect, flow: 0, angle: 20).creases[0].angle - 20 * .pi / 180) < 0.06)
        #expect(a != b)
        #expect(FoldLayout.make(seed: 1, aspect: aspect, flow: 0) == a)  // deterministic
        // Roughly parallel, and ordered: the strip index climbs 0…3 across the frame.
        let angles = a.creases.map(\.angle)
        #expect(angles.max()! - angles.min()! < 0.1)
        let n = a.creases[0].normal
        let far = SIMD2(aspect / 2, 0.5) + n * 3, near = SIMD2(aspect / 2, 0.5) - n * 3
        #expect(a.strip(at: near) == 0 && a.strip(at: far) == a.creases.count)
    }

    @Test func linesAreSetAlongACreaseOnScreenAndClearOfTheCover() throws {
        for seed in UInt64(1)...20 {
            let layout = FoldLayout.make(seed: seed, aspect: aspect, flow: 3)
            let size = SIMD2(0.7, 0.16)
            let spot = try #require(layout.spot(forLine: 0, size: size, obstacles: [cover]), "seed \(seed)")
            let (centre, angle) = layout.frame(for: spot, size: size)
            let crease = layout.creases[spot.crease]
            // Parallel to its crease, just off it.
            #expect(angle == crease.angle)
            #expect(abs(abs(crease.side(centre)) - (size.y / 2 + 0.025)) < 1e-9)
            for p in FoldLayout.corners(centre: centre, angle: angle, size: size) {
                #expect(p.x > 0 && p.x < aspect && p.y > 0 && p.y < 1)
                #expect(!cover.contains(CGPoint(x: p.x, y: p.y)))
            }
        }
    }

    @Test func consecutiveLinesMoveThroughTheComposition() {
        let layout = FoldLayout.make(seed: 7, aspect: aspect, flow: 0)
        let spots = (0..<4).compactMap { layout.spot(forLine: $0, size: SIMD2(0.6, 0.14), obstacles: [cover]) }
        #expect(spots.count == 4)
        let distinct = Set(spots.map { "\($0.crease)\($0.side)\(Int($0.along * 10))" })
        #expect(distinct.count >= 3)
    }

    @Test func nothingFitsWhenThereIsNoRoom() {
        let layout = FoldLayout.make(seed: 3, aspect: aspect, flow: 0)
        let everything = CGRect(x: 0, y: 0, width: aspect, height: 1)
        #expect(layout.spot(forLine: 0, size: SIMD2(0.5, 0.1), obstacles: [everything]) == nil)
    }
}
