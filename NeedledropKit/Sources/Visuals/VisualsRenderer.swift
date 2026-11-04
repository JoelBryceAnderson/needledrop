import Metal
import MetalKit
import simd
import QuartzCore
import SignalAnalysis

public enum BackgroundStyle: String, Codable, CaseIterable, Sendable {
    /// Folded paper: big flat planes in the album's colours.
    case paper
    /// The original palette-bleed flow.
    case smoke
}

/// The lyric line to show this frame (already timed against what the room hears).
public struct LyricFrame: Sendable, Equatable {
    /// Changes when the line changes.
    public var id: Int
    public var text: String
    /// The following line, rendered ahead of time.
    public var next: String?

    public init(id: Int, text: String, next: String? = nil) {
        self.id = id
        self.text = text
        self.next = next
    }
}

/// The now-playing caption, printed in the corner when a track is identified.
public struct CaptionFrame: Sendable, Equatable {
    /// Changes when the track changes.
    public var id: String
    public var title: String
    public var subtitle: String

    public init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// What the renderer reads each frame.
public struct VisualInput: Sendable {
    public var features: AudioFeatures
    /// Seconds since the last tracked beat.
    public var beatAge: Double?
    /// Music playing or about to: anything but idle / side ended.
    public var active: Bool
    /// The track has synced lyrics: the cover moves aside to give them a field.
    public var lyricsAvailable: Bool
    public var lyric: LyricFrame?
    public var caption: CaptionFrame?

    public init(features: AudioFeatures = AudioFeatures(), beatAge: Double? = nil, active: Bool = false,
                lyricsAvailable: Bool = false, lyric: LyricFrame? = nil, caption: CaptionFrame? = nil) {
        self.features = features
        self.beatAge = beatAge
        self.active = active
        self.lyricsAvailable = lyricsAvailable || lyric != nil
        self.lyric = lyric
        self.caption = caption
    }
}

public enum VisualsError: Error, CustomStringConvertible {
    case noMetalDevice
    case shaderCompilation(String)

    public var description: String {
        switch self {
        case .noMetalDevice: "No Metal device"
        case .shaderCompilation(let message): "Shader compilation failed: \(message)"
        }
    }
}

/// Draws the scene at a fixed low internal resolution (480 lines by default, the width
/// following the display's aspect), then scales it up to the drawable. Two look slots —
/// current and previous — crossfade on album changes.
@MainActor
public final class VisualsRenderer: NSObject, MTKViewDelegate {
    public let device: any MTLDevice
    public var internalHeight = 480
    public var background: BackgroundStyle = .paper
    /// Show the album cover (living cover) over the background.
    public var showCover = true
    /// Called once per frame for audio and session state.
    public var inputProvider: (() -> VisualInput)?

    private let queue: any MTLCommandQueue
    private let scenePipeline: any MTLRenderPipelineState
    private let presentPipeline: any MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private let placeholder: any MTLTexture
    private var sceneTexture: (any MTLTexture)?

    private struct Slot {
        var look: AlbumLook
        var art: (any MTLTexture)?
        var mask: (any MTLTexture)?
    }

    private var slots: [Slot] = []
    private var director = SceneDirector()
    private var drive: AudioDriveFilter = {
        // Slower than the raw meter: the picture should move with the music, not twitch.
        var d = AudioDriveFilter()
        d.attack = 0.12
        d.release = 0.6
        return d
    }()
    private var flow = 0.0
    private var lastTime: Double?

    /// Text printed on the scene: a lyric line (set along a crease) or the caption.
    private struct PrintedSlot {
        var id: Int
        var captionID: String?
        var texture: any MTLTexture
        /// Scene units (frame height = 1).
        var size: SIMD2<Double>
        var spot: FoldLayout.TextSpot?
        var enteredAt: Double
        var exitedAt: Double?
    }

    /// Cover placement, eased: centre x as a fraction of width, size in frame heights.
    private var coverX = 0.5
    private var coverSize = 0.64
    private var lyricSlots: [PrintedSlot] = []
    private var captionSlot: PrintedSlot?
    private var textCache: [String: (texture: any MTLTexture, size: SIMD2<Double>)] = [:]

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw VisualsError.noMetalDevice }
        self.device = device
        self.queue = queue
        loader = MTKTextureLoader(device: device)

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw VisualsError.shaderCompilation(error.localizedDescription)
        }
        func pipeline(_ fragment: String, format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        scenePipeline = try pipeline("scene_fragment", format: .rgba16Float)
        presentPipeline = try pipeline("present_fragment", format: .bgra8Unorm)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        placeholder = device.makeTexture(descriptor: descriptor)!
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4)
        super.init()
        show(.neutral, at: 0)
    }

    public func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
    }

    /// Puts a look on screen, crossfading from the current one. Re-showing the same id
    /// (e.g. the subject mask finished later) swaps textures without a transition.
    public func show(_ look: AlbumLook, at time: Double = CACurrentMediaTime()) {
        let slot = Slot(look: look, art: texture(look.artwork), mask: texture(look.subjectMask))
        if slots.first?.look.id == look.id {
            slots[0] = slot
            return
        }
        slots.insert(slot, at: 0)
        if slots.count > 2 { slots.removeLast(slots.count - 2) }
        director.show(look.id, at: time)
        if director.previousID == nil, slots.count > 1 { slots.removeLast() }
    }

    public var currentLookID: String? { slots.first?.look.id }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commandBuffer = queue.makeCommandBuffer() else { return }
        render(to: drawable.texture, input: inputProvider?() ?? VisualInput(), time: CACurrentMediaTime(),
               commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Rendering

    /// Encodes one frame into `target` (bgra8Unorm, any size).
    public func render(to target: any MTLTexture, input: VisualInput, time: Double, commandBuffer: any MTLCommandBuffer) {
        let dt = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        let audio = drive.update(features: input.features, beatAge: input.beatAge, dt: dt)
        flow += dt * (0.04 + 0.10 * Double(audio.level))
        let frame = director.update(at: time, active: input.active)
        if frame.previousReleased, slots.count > 1 { slots.removeLast() }

        let height = internalHeight
        let width = max(1, Int((Double(height) * Double(target.width) / Double(max(1, target.height))).rounded()))
        let scene = sceneTarget(width: width, height: height)

        let current = slots.first
        let layout = foldLayout(aspect: Double(width) / Double(height), bass: Double(audio.bass))
        // With lyrics, the cover slides to the left third and shrinks, opening a field for type.
        let aside = input.lyricsAvailable && showCover
        let ease = 1 - exp(-dt / 0.8)
        coverX += ((aside ? 0.3 : 0.5) - coverX) * ease
        coverSize += ((aside ? 0.52 : 0.64) - coverSize) * ease
        updatePrintedText(input, time: time, layout: layout, hasArt: current?.art != nil && showCover, sceneHeight: height)

        var uniforms = SceneUniforms()
        uniforms.frame = SIMD4(Float(width), Float(height), Float(flow), frame.brightness)
        uniforms.audio = SIMD4(audio.bass, audio.mids, audio.highs, audio.level)
        uniforms.rhythm = SIMD4(audio.beat, 0, slots.count > 1 ? frame.mix : 1, showCover ? 1 : 0)
        uniforms.style = SIMD4(background == .paper ? 0 : 1, Float(coverX), Float(coverSize), 0)
        setInk(&uniforms, time: time, layout: layout)
        let previous = slots.count > 1 ? slots[1] : nil
        uniforms.slots = SIMD4(current?.art == nil ? 0 : 1, previous?.art == nil ? 0 : 1,
                               current?.mask == nil ? 0 : 1, previous?.mask == nil ? 0 : 1)
        uniforms.setPalettes(current?.look.palette ?? .neutral, previous?.look.palette ?? .neutral)

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = scene
        scenePass.colorAttachments[0].loadAction = .dontCare
        scenePass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.setRenderPipelineState(scenePipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            encoder.setFragmentTexture(current?.art ?? placeholder, index: 0)
            encoder.setFragmentTexture(current?.mask ?? placeholder, index: 1)
            encoder.setFragmentTexture(previous?.art ?? placeholder, index: 2)
            encoder.setFragmentTexture(previous?.mask ?? placeholder, index: 3)
            encoder.setFragmentTexture(lyricSlots.last?.texture ?? placeholder, index: 4)
            encoder.setFragmentTexture(lyricSlots.count > 1 ? lyricSlots[lyricSlots.count - 2].texture : placeholder, index: 5)
            encoder.setFragmentTexture(captionSlot?.texture ?? placeholder, index: 6)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        let presentPass = MTLRenderPassDescriptor()
        presentPass.colorAttachments[0].texture = target
        presentPass.colorAttachments[0].loadAction = .dontCare
        presentPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: presentPass) {
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentTexture(scene, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    // MARK: - Printed text: lyrics along the folds, and the now-playing caption

    private static let inkIn = 0.7
    private static let inkOut = 0.9
    private static let captionHold = 8.0

    /// Text sizes to try, widest first (scene units: frame height = 1): (max width, font, lines).
    /// One long line running along the crease reads best; wrap only when it won't fit.
    private static let lyricSizes: [(width: Double, font: Double, lines: Int)] = [
        (1.5, 0.08, 1), (1.1, 0.07, 1), (0.8, 0.06, 1), (0.9, 0.065, 2), (0.6, 0.058, 3),
    ]

    private func ease(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    /// The fold composition for the album on screen now.
    private func foldLayout(aspect: Double, bass: Double) -> FoldLayout {
        let id = slots.first?.look.id ?? "neutral"
        var seed: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 { seed = (seed ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return FoldLayout.make(seed: seed, aspect: aspect, flow: flow, bass: bass)
    }

    /// The cover's square, padded, and the caption's box while it's up: lyrics stay clear.
    private func obstacles(aspect: Double, hasArt: Bool, time: Double) -> [CGRect] {
        var rects: [CGRect] = []
        if hasArt {
            let half = coverSize / 2 + 0.035
            rects.append(CGRect(x: aspect * coverX - half, y: 0.5 - half, width: half * 2, height: half * 2))
        }
        if let caption = captionSlot, captionOpacity(caption, time: time) > 0 {
            let f = captionFrame(caption)
            rects.append(CGRect(x: f.centre.x - f.size.x / 2 - 0.02, y: f.centre.y - f.size.y / 2 - 0.02,
                                width: f.size.x + 0.04, height: f.size.y + 0.04))
        }
        return rects
    }

    private func updatePrintedText(_ input: VisualInput, time: Double, layout: FoldLayout, hasArt: Bool, sceneHeight: Int) {
        // Caption: a new track's caption soaks in, holds, soaks out.
        if let caption = input.caption, caption.id != captionSlot?.captionID {
            let fontSize = CGFloat(sceneHeight) * 0.06 * 2
            // Keep to the space left of the cover (when there is one).
            let room = hasArt && !input.lyricsAvailable ? max(0.3, layout.aspect * coverX - coverSize / 2 - 0.1) : 0.9
            if let image = LyricRasterizer.caption(title: caption.title, subtitle: caption.subtitle,
                                                   fontSize: fontSize, maxWidth: CGFloat(Double(sceneHeight) * room * 2)),
               let tex = texture(image) {
                captionSlot = PrintedSlot(id: 0, captionID: caption.id, texture: tex,
                                          size: SIMD2(Double(image.width), Double(image.height)) / (2 * Double(sceneHeight)),
                                          spot: nil, enteredAt: time)
            }
        } else if input.caption == nil, let caption = captionSlot, caption.exitedAt == nil {
            captionSlot?.exitedAt = time
        }

        // Lyrics: each line gets a crease, a side and a position along it when it starts.
        if lyricSlots.last?.id != input.lyric?.id || (input.lyric == nil && lyricSlots.last?.exitedAt == nil) {
            for i in lyricSlots.indices where lyricSlots[i].exitedAt == nil { lyricSlots[i].exitedAt = time }
            if let lyric = input.lyric {
                let blocked = obstacles(aspect: layout.aspect, hasArt: hasArt, time: time)
                    + lyricSlots.filter { slotOpacity($0, time: time) > 0.05 }.compactMap { slot in
                        slot.spot.map { boundingBox(layout.frame(for: $0, size: slot.size), size: slot.size) }
                    }
                for size in Self.lyricSizes {
                    guard let text = lyricTexture(lyric.text, size: size, sceneHeight: sceneHeight),
                          let spot = layout.spot(forLine: lyric.id, size: text.size, obstacles: blocked) else { continue }
                    lyricSlots.append(PrintedSlot(id: lyric.id, captionID: nil, texture: text.texture, size: text.size,
                                                  spot: spot, enteredAt: time))
                    break
                }
            }
        }
        lyricSlots.removeAll { slot in slot.exitedAt.map { time - $0 > Self.inkOut } ?? false }
        if lyricSlots.count > 2 { lyricSlots.removeFirst(lyricSlots.count - 2) }
    }

    private func boundingBox(_ frame: (centre: SIMD2<Double>, angle: Double), size: SIMD2<Double>) -> CGRect {
        let cs = FoldLayout.corners(centre: frame.centre, angle: frame.angle, size: size)
        let xs = cs.map(\.x), ys = cs.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private func slotOpacity(_ slot: PrintedSlot, time: Double) -> Double {
        ease((time - slot.enteredAt) / Self.inkIn) * (1 - (slot.exitedAt.map { ease((time - $0) / Self.inkOut) } ?? 0))
    }

    private func captionOpacity(_ slot: PrintedSlot, time: Double) -> Double {
        let out = slot.exitedAt ?? (slot.enteredAt + Self.captionHold)
        return ease((time - slot.enteredAt) / Self.inkIn) * (1 - ease((time - out) / Self.inkOut))
    }

    /// Printed like a label: top-left beside a centred cover, or under the cover once it has
    /// moved aside for lyrics (that corner is then the cover's).
    private func captionFrame(_ slot: PrintedSlot) -> (centre: SIMD2<Double>, size: SIMD2<Double>) {
        let y = coverX < 0.45 ? 0.95 - slot.size.y / 2 : 0.06 + slot.size.y / 2
        return (SIMD2(0.06 + slot.size.x / 2, y), slot.size)
    }

    private func setInk(_ uniforms: inout SceneUniforms, time: Double, layout: FoldLayout) {
        func blur(_ opacity: Double, exiting: Bool) -> Float { Float(exiting ? (1 - opacity) * 3 : (1 - opacity) * 4.5) }
        func lyric(_ slot: PrintedSlot?) -> (SIMD4<Float>, SIMD4<Float>) {
            guard let slot, let spot = slot.spot else { return (.zero, .zero) }
            let f = layout.frame(for: spot, size: slot.size)
            let o = slotOpacity(slot, time: time)
            return (SIMD4(Float(f.centre.x), Float(f.centre.y), Float(slot.size.x / 2), Float(slot.size.y / 2)),
                    SIMD4(Float(f.angle), Float(o), blur(o, exiting: slot.exitedAt != nil), 0))
        }
        (uniforms.ink0a, uniforms.ink0b) = lyric(lyricSlots.last)
        (uniforms.ink1a, uniforms.ink1b) = lyric(lyricSlots.count > 1 ? lyricSlots[lyricSlots.count - 2] : nil)
        if let caption = captionSlot {
            let f = captionFrame(caption)
            let o = captionOpacity(caption, time: time)
            uniforms.ink2a = SIMD4(Float(f.centre.x), Float(f.centre.y), Float(f.size.x / 2), Float(f.size.y / 2))
            uniforms.ink2b = SIMD4(0, Float(o), blur(o, exiting: time > caption.enteredAt + Self.inkIn), 0)
        }
        for (i, c) in layout.creases.prefix(3).enumerated() {
            let n = c.normal
            let crease = SIMD4(Float(n.x), Float(n.y), Float(simd_dot(c.point, n)), 1)
            switch i {
            case 0: uniforms.crease.0 = crease
            case 1: uniforms.crease.1 = crease
            default: uniforms.crease.2 = crease
            }
        }
        uniforms.fold = SIMD4(Float(layout.tilt), 1, 0, 0)  // strip 1 gets the accent colour
        uniforms.light = SIMD4(Float(layout.light.x), Float(layout.light.y), Float(layout.light.z), 0)
    }

    /// Rasterised at twice the internal resolution, mipmapped (the shader blurs with mips).
    private func lyricTexture(_ text: String, size: (width: Double, font: Double, lines: Int), sceneHeight: Int)
        -> (texture: any MTLTexture, size: SIMD2<Double>)? {
        let key = "\(size.width)|\(text)"
        if let cached = textCache[key] { return cached }
        let scale = 2 * Double(sceneHeight)
        guard let image = LyricRasterizer.image(for: text, fontSize: CGFloat(size.font * scale),
                                                maxWidth: CGFloat(size.width * scale), maxLines: size.lines),
              let texture = texture(image) else { return nil }
        if textCache.count >= 16 { textCache.removeAll() }
        let entry = (texture: texture, size: SIMD2(Double(image.width), Double(image.height)) / scale)
        textCache[key] = entry
        return entry
    }

    private func sceneTarget(width: Int, height: Int) -> any MTLTexture {
        if let sceneTexture, sceneTexture.width == width, sceneTexture.height == height { return sceneTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        sceneTexture = texture
        return texture
    }

    private func texture(_ image: CGImage?) -> (any MTLTexture)? {
        guard let image else { return nil }
        return try? loader.newTexture(cgImage: image, options: [
            .SRGB: false,  // keep sRGB values as-is; the whole pipeline works in display space
            .generateMipmaps: true,
            .textureStorageMode: MTLStorageMode.private.rawValue,
        ])
    }
}

/// Mirrors `Uniforms` in `Shaders.source`.
struct SceneUniforms {
    var frame = SIMD4<Float>()
    var audio = SIMD4<Float>()
    var rhythm = SIMD4<Float>()
    var slots = SIMD4<Float>()
    var style = SIMD4<Float>()
    var ink0a = SIMD4<Float>()
    var ink0b = SIMD4<Float>()
    var ink1a = SIMD4<Float>()
    var ink1b = SIMD4<Float>()
    var ink2a = SIMD4<Float>()
    var ink2b = SIMD4<Float>()
    var crease: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)
    var fold = SIMD4<Float>()
    var light = SIMD4<Float>(0, 0, 1, 0)
    var palette0 = SceneUniforms.emptyPalette
    var palette1 = SceneUniforms.emptyPalette

    typealias PaletteBlock = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    static let emptyPalette: PaletteBlock = (.zero, .zero, .zero, .zero, .zero, .zero)

    mutating func setPalettes(_ current: Palette, _ previous: Palette) {
        func block(_ p: Palette) -> PaletteBlock {
            let c = p.colors.sorted { $0.luminance < $1.luminance }.map(\.simd)
            return (c[0], c[1], c[2], c[3], c[4], c[5])
        }
        palette0 = block(current)
        palette1 = block(previous)
    }
}
