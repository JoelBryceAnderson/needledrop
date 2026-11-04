import CoreGraphics
import Metal
import SignalAnalysis
import Testing
@testable import Visuals

/// Milestone 7 visuals, checked on rendered pixels.
@MainActor
@Suite struct PolishRenderTests {
    private let playing = AudioFeatures(bands: BandEnergies(sub: 0.1, bass: 0.1, mids: 0.05, highs: 0.01), musicBandRMS: 0.08)

    private func cover(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }

    private func render(_ renderer: VisualsRenderer, frames: Int = 90, input: (Int) -> VisualInput) -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320, height: 180, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = renderer.device.makeTexture(descriptor: d)!
        let queue = renderer.device.makeCommandQueue()!
        for i in 0..<frames {
            let buffer = queue.makeCommandBuffer()!
            renderer.render(to: target, input: input(i), time: Double(i) / 60, commandBuffer: buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        var pixels = [UInt8](repeating: 0, count: 320 * 180 * 4)
        target.getBytes(&pixels, bytesPerRow: 320 * 4, from: MTLRegionMake2D(0, 0, 320, 180), mipmapLevel: 0)
        return pixels
    }

    private func pixel(_ p: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * 320 + x) * 4
        return (Int(p[i + 2]), Int(p[i + 1]), Int(p[i]))
    }

    private func renderer(mode: LookStyle.CoverMode, art: (CGFloat, CGFloat, CGFloat) = (1, 0.85, 0.2)) throws -> VisualsRenderer {
        let r = try VisualsRenderer()
        r.coverModeOverride = mode
        r.show(AlbumLook(id: "x", palette: Palette(colors: [RGB(0.3, 0.5, 0.7), RGB(0.6, 0.7, 0.8)]), artwork: cover(art)), at: 0)
        return r
    }

    @Test func recordIsADarkDiscWithTheArtAsItsLabel() throws {
        let pixels = render(try renderer(mode: .record)) { _ in VisualInput(features: playing, active: true) }
        let vinyl = pixel(pixels, 160 - 40, 90)           // on the disc, off the label
        let label = pixel(pixels, 160 - 5, 90 - 5)        // near the centre
        #expect(vinyl.r < 60 && vinyl.g < 60 && vinyl.b < 70, "vinyl \(vinyl)")
        #expect(label.r > 150 && label.g > 120, "label \(label)")
    }

    @Test func aTransientBreaksTheDissolveCoverUp() throws {
        func intactCoverPixels(onset: Bool) throws -> Int {
            let pixels = render(try renderer(mode: .dissolve)) { i in
                var input = VisualInput(features: playing, active: true)
                if onset, i == 80 { input.onsetAge = 0.01 }
                return input
            }
            var n = 0
            for y in 50..<130 { for x in 110..<210 where pixel(pixels, x, y).r > 200 && pixel(pixels, x, y).b < 100 { n += 1 } }
            return n
        }
        let calm = try intactCoverPixels(onset: false)
        let hit = try intactCoverPixels(onset: true)
        #expect(hit < calm - 50, "calm \(calm), hit \(hit)")
    }

    @Test func typewriterPrintsOnlyTheWordsSungSoFar() throws {
        func ink(_ revealed: Double?) throws -> Int {
            let r = try VisualsRenderer()
            let pixels = render(r) { _ in
                VisualInput(features: playing, active: true,
                            lyric: LyricFrame(id: 0, text: "one two three four five six", revealedWords: revealed))
            }
            let plain = render(try VisualsRenderer()) { _ in VisualInput(features: playing, active: true) }
            var n = 0
            for i in stride(from: 0, to: pixels.count, by: 4) where abs(Int(pixels[i]) - Int(plain[i])) > 30 { n += 1 }
            return n
        }
        let one = try ink(1), all = try ink(nil)
        #expect(one > 20 && one < all / 3, "one word \(one), whole line \(all)")
    }

    @Test func theSideEndDrainsTheColour() throws {
        func saturation(ended: Bool) throws -> Double {
            let pixels = render(try renderer(mode: .living), frames: 240) { _ in
                var input = VisualInput(features: playing, active: true)
                input.sideEnded = ended
                return input
            }
            var total = 0.0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let c = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
                total += c.max()! - c.min()!
            }
            return total / Double(pixels.count / 4)
        }
        #expect(try saturation(ended: true) < saturation(ended: false) * 0.7)
    }
}
