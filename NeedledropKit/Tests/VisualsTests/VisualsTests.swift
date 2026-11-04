import CoreGraphics
import Metal
import SignalAnalysis
import Testing
@testable import Visuals

/// A test cover: horizontal bands of solid colour with the given shares of the image.
private func bandedImage(_ bands: [(RGB, Double)], size: Int = 128) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var y = 0.0
    for (color, share) in bands {
        context.setFillColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1)
        context.fill(CGRect(x: 0, y: y, width: Double(size), height: share * Double(size)))
        y += share * Double(size)
    }
    return context.makeImage()!
}

private func close(_ a: RGB, _ b: RGB, within tolerance: Float = 0.06) -> Bool {
    abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance
}

@Suite struct PaletteTests {
    @Test func findsDominantColoursInOrder() {
        let red = RGB(0.85, 0.12, 0.1), blue = RGB(0.1, 0.2, 0.7), cream = RGB(0.95, 0.92, 0.8)
        let palette = PaletteExtractor.extract(from: bandedImage([(red, 0.55), (blue, 0.3), (cream, 0.15)]), count: 3)
        #expect(close(palette.colors[0], red), "\(palette.colors[0])")
        #expect(close(palette.colors[1], blue), "\(palette.colors[1])")
        #expect(close(palette.colors[2], cream), "\(palette.colors[2])")
        #expect(abs(palette.weights[0] - 0.55) < 0.05)
    }

    @Test func alwaysHasSixColours() {
        let palette = PaletteExtractor.extract(from: bandedImage([(RGB(1, 0, 0), 1)]), count: 6)
        #expect(palette.colors.count == Palette.size)
        #expect(Palette(colors: [RGB(0, 0, 0)]).colors.count == Palette.size)
    }

    @Test func labRoundTrips() {
        for c in [RGB(0.2, 0.5, 0.9), RGB(1, 1, 1), RGB(0, 0, 0), RGB(0.9, 0.4, 0.1)] {
            #expect(close(Lab(rgb: c).rgb, c, within: 0.01))
        }
    }

    @Test func isDeterministic() {
        let image = bandedImage([(RGB(0.3, 0.6, 0.2), 0.5), (RGB(0.8, 0.8, 0.1), 0.5)])
        #expect(PaletteExtractor.extract(from: image) == PaletteExtractor.extract(from: image))
    }
}

@Suite struct AudioDriveTests {
    private func features(db: Float) -> AudioFeatures {
        let a = powf(10, db / 20)
        return AudioFeatures(bands: BandEnergies(sub: a, bass: a, mids: a, highs: a), musicBandRMS: a)
    }

    private func run(_ filter: inout AudioDriveFilter, db: Float, seconds: Double) -> AudioDrive {
        var d = AudioDrive()
        for _ in 0..<Int(seconds * 60) { d = filter.update(features: features(db: db), beatAge: nil, dt: 1 / 60) }
        return d
    }

    @Test func silenceIsDarkAndMusicIsBright() {
        var filter = AudioDriveFilter()
        #expect(run(&filter, db: -70, seconds: 2).level < 0.02)
        #expect(run(&filter, db: -18, seconds: 1).level > 0.9)
    }

    @Test func quietRecordsAreGainedUp() {
        var filter = AudioDriveFilter()
        _ = run(&filter, db: -12, seconds: 2)
        let justAfter = run(&filter, db: -30, seconds: 0.5).level
        let later = run(&filter, db: -30, seconds: 4).level
        #expect(justAfter < 0.6)
        #expect(later > 0.9, "auto-gain should bring a quieter passage back up: \(later)")
    }

    @Test func attackIsFasterThanRelease() {
        var filter = AudioDriveFilter()
        _ = run(&filter, db: -70, seconds: 1)
        _ = run(&filter, db: -20, seconds: 3)
        var up = AudioDriveFilter()
        _ = run(&up, db: -20, seconds: 3)
        _ = run(&up, db: -70, seconds: 1)
        let rise = run(&up, db: -20, seconds: 0.1).bass
        let fall = run(&filter, db: -45, seconds: 0.1).bass
        #expect(rise > 0.9 && fall > 0.4)
    }

    @Test func beatsPulseOnlyWhenThereIsMusic() {
        var filter = AudioDriveFilter()
        _ = run(&filter, db: -70, seconds: 1)
        #expect(filter.update(features: features(db: -70), beatAge: 0, dt: 1 / 60).beat < 0.05)
        _ = run(&filter, db: -18, seconds: 1)
        #expect(filter.update(features: features(db: -18), beatAge: 0, dt: 1 / 60).beat > 0.9)
        #expect(filter.update(features: features(db: -18), beatAge: 0.3, dt: 1 / 60).beat < 0.2)
    }
}

@Suite struct SceneDirectorTests {
    @Test func firstLookCutsAndLaterOnesCrossfade() {
        var director = SceneDirector()
        director.show("a", at: 0)
        #expect(director.previousID == nil)
        for t in stride(from: 0.0, through: 2, by: 0.1) { _ = director.update(at: t, active: true) }
        director.show("b", at: 2)
        #expect(director.previousID == "a")
        #expect(director.update(at: 2, active: true).mix == 0)
        let mid = director.update(at: 3.5, active: true).mix
        #expect(mid > 0.4 && mid < 0.6)
        let done = director.update(at: 5.1, active: true)
        #expect(done.mix == 1 && done.previousReleased)
    }

    @Test func sameLookIsNotATransition() {
        var director = SceneDirector()
        director.show("a", at: 0)
        _ = director.update(at: 2, active: true)
        let changed = director.show("a", at: 2)
        #expect(!changed)
    }

    @Test func fadesInThenOutAfterIdling() {
        var director = SceneDirector()
        director.show("a", at: 0)
        var t = 0.0
        func step(to end: Double, active: Bool) -> Float {
            var b: Float = 0
            while t < end { t += 1 / 60; b = director.update(at: t, active: active).brightness }
            return b
        }
        #expect(step(to: 2, active: true) == 1)
        #expect(step(to: 21, active: false) == 1)   // still within idleDelay
        let fading = step(to: 23, active: false)
        #expect(fading > 0 && fading < 1)
        #expect(step(to: 30, active: false) == 0)
        #expect(step(to: 32, active: true) == 1)     // needle back down
    }
}

@MainActor
@Suite(.needsGPU) struct RendererTests {
    /// Renders one frame and returns RGBA8 pixels.
    private func render(_ renderer: VisualsRenderer, input: VisualInput, frames: Int = 90,
                        width: Int = 320, height: Int = 180) -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = renderer.device.makeTexture(descriptor: descriptor)!
        let queue = renderer.device.makeCommandQueue()!
        for i in 0..<frames {
            let buffer = queue.makeCommandBuffer()!
            renderer.render(to: target, input: input, time: Double(i) / 60, commandBuffer: buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    private func stats(_ pixels: [UInt8]) -> (mean: Double, spread: Double) {
        let lum = stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) + Double(pixels[$0 + 1]) + Double(pixels[$0 + 2]) }
        let mean = lum.reduce(0, +) / Double(lum.count)
        let spread = (lum.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lum.count)).squareRoot()
        return (mean / 765, spread / 765)
    }

    private let playing = VisualInput(
        features: AudioFeatures(bands: BandEnergies(sub: 0.1, bass: 0.1, mids: 0.05, highs: 0.01), musicBandRMS: 0.08),
        beatAge: 0.05, active: true
    )

    @Test func shadersCompileAndDrawAPicture() throws {
        let renderer = try VisualsRenderer()
        let (mean, spread) = stats(render(renderer, input: playing))
        #expect(mean > 0.05, "frame is black (\(mean))")
        #expect(mean < 0.95, "frame is white (\(mean))")
        #expect(spread > 0.01, "frame is flat (\(spread))")
    }

    @Test func coverAppearsWithArtwork() throws {
        let renderer = try VisualsRenderer()
        let art = bandedImage([(RGB(1, 0.9, 0.2), 1)])
        renderer.show(AlbumLook(id: "yellow", palette: .neutral, artwork: art), at: 0)
        let pixels = render(renderer, input: playing)
        // Centre pixel should be the (yellow) cover, not the dark neutral field.
        let centre = (90 * 320 + 160) * 4
        let (b, g, r) = (pixels[centre], pixels[centre + 1], pixels[centre + 2])
        #expect(r > 180 && g > 150 && b < 100, "centre is \(r),\(g),\(b)")
    }

    @Test func lyricsArePrintedInTheFieldBesideTheCover() throws {
        // Two identical scenes for a track with lyrics (cover moved to the left third), one
        // with a line showing: only the ink differs, in the open field, never on the cover.
        func frame(_ lyric: LyricFrame?) throws -> [UInt8] {
            let renderer = try VisualsRenderer()
            renderer.show(AlbumLook(id: "blue", palette: Palette(colors: [RGB(0.2, 0.5, 0.75), RGB(0.1, 0.2, 0.35)]),
                                    artwork: bandedImage([(RGB(0.1, 0.1, 0.2), 1)])), at: 0)
            return render(renderer, input: VisualInput(features: playing.features, active: true, lyricsAvailable: true,
                                                       lyric: lyric), frames: 90)
        }
        let plain = try frame(nil)
        let printed = try frame(LyricFrame(id: 0, text: "Thunder only happens when it's raining"))
        func changed(x: Range<Int>, y: Range<Int>) -> Int {
            var n = 0
            for row in y {
                for col in x {
                    let i = (row * 320 + col) * 4
                    if abs(Int(plain[i]) - Int(printed[i])) + abs(Int(plain[i + 1]) - Int(printed[i + 1])) > 40 { n += 1 }
                }
            }
            return n
        }
        #expect(changed(x: 160..<315, y: 5..<175) > 300, "ink in the open field")
        #expect(changed(x: 60..<130, y: 55..<125) == 0, "nothing printed over the cover")
    }

    @Test func staysBlackWhenNothingHasPlayed() throws {
        let renderer = try VisualsRenderer()
        let (mean, _) = stats(render(renderer, input: VisualInput(active: false), frames: 30))
        #expect(mean < 0.3)  // fading in from black, never blown out
    }
}
