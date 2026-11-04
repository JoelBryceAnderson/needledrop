import Metal
import MetalKit
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

/// What the renderer reads each frame.
public struct VisualInput: Sendable {
    public var features: AudioFeatures
    /// Seconds since the last tracked beat.
    public var beatAge: Double?
    /// Music playing or about to: anything but idle / side ended.
    public var active: Bool
    public var lyric: LyricFrame?

    public init(features: AudioFeatures = AudioFeatures(), beatAge: Double? = nil, active: Bool = false,
                lyric: LyricFrame? = nil) {
        self.features = features
        self.beatAge = beatAge
        self.active = active
        self.lyric = lyric
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

    private struct LyricSlot {
        var id: Int
        var texture: any MTLTexture
        /// Pixel size of the rasterised line (at 2× the internal resolution).
        var size: CGSize
        var placement: Placement
        var enteredAt: Double
        var exitedAt: Double?
    }

    private var lyricSlots: [LyricSlot] = []
    private var textCache: [String: (texture: any MTLTexture, size: CGSize)] = [:]

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
        updateLyrics(input, time: time, sceneWidth: width, hasArt: current?.art != nil && showCover)

        var uniforms = SceneUniforms()
        uniforms.frame = SIMD4(Float(width), Float(height), Float(flow), frame.brightness)
        uniforms.audio = SIMD4(audio.bass, audio.mids, audio.highs, audio.level)
        uniforms.rhythm = SIMD4(audio.beat, 0, slots.count > 1 ? frame.mix : 1, showCover ? 1 : 0)
        uniforms.style = SIMD4(background == .paper ? 0 : 1, 0, 0, 0)
        setInk(&uniforms, time: time, sceneWidth: width, sceneHeight: height)
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

    // MARK: - Lyrics (printed on the scene)

    /// Where a line is printed: centre (fractions of width/height), how wide it may wrap
    /// (fraction of width), and a slight tilt, as if set on the sheet.
    private struct Placement {
        var x: Double
        var y: Double
        var width: Double
        var degrees: Double
        var lines: Int
    }

    /// Around the cover: beside it, under it. Lines take turns so the words move through
    /// the scene instead of sitting in one caption slot.
    private static let besideCover: [Placement] = [
        Placement(x: 0.165, y: 0.40, width: 0.27, degrees: -4, lines: 4),
        Placement(x: 0.835, y: 0.60, width: 0.27, degrees: 3.5, lines: 4),
        Placement(x: 0.50, y: 0.905, width: 0.74, degrees: -1.5, lines: 2),
        Placement(x: 0.165, y: 0.66, width: 0.27, degrees: 2.5, lines: 4),
        Placement(x: 0.835, y: 0.32, width: 0.27, degrees: -3, lines: 4),
    ]
    private static let openPaper: [Placement] = [
        Placement(x: 0.34, y: 0.36, width: 0.55, degrees: -5, lines: 3),
        Placement(x: 0.66, y: 0.63, width: 0.55, degrees: 4, lines: 3),
        Placement(x: 0.50, y: 0.50, width: 0.78, degrees: -2, lines: 2),
        Placement(x: 0.40, y: 0.70, width: 0.60, degrees: 3, lines: 3),
    ]

    private static let inkIn = 0.7
    private static let inkOut = 0.9

    private func updateLyrics(_ input: VisualInput, time: Double, sceneWidth: Int, hasArt: Bool) {
        if lyricSlots.last?.id != input.lyric?.id || (input.lyric == nil && lyricSlots.last?.exitedAt == nil) {
            for i in lyricSlots.indices where lyricSlots[i].exitedAt == nil { lyricSlots[i].exitedAt = time }
            if let lyric = input.lyric {
                let placements = hasArt ? Self.besideCover : Self.openPaper
                let placement = placements[abs(lyric.id) % placements.count]
                if let text = textTexture(lyric.text, placement: placement, sceneWidth: sceneWidth) {
                    lyricSlots.append(LyricSlot(id: lyric.id, texture: text.texture, size: text.size,
                                                placement: placement, enteredAt: time))
                }
                if let next = lyric.next {
                    _ = textTexture(next, placement: placements[abs(lyric.id + 1) % placements.count], sceneWidth: sceneWidth)
                }
            }
        }
        lyricSlots.removeAll { slot in slot.exitedAt.map { time - $0 > Self.inkOut } ?? false }
        if lyricSlots.count > 2 { lyricSlots.removeFirst(lyricSlots.count - 2) }
    }

    /// Ink soaks in from soft to sharp, and soaks back out.
    private func setInk(_ uniforms: inout SceneUniforms, time: Double, sceneWidth: Int, sceneHeight: Int) {
        func ease(_ x: Double) -> Double {
            let c = min(1, max(0, x))
            return c * c * (3 - 2 * c)
        }
        let aspect = Double(sceneWidth) / Double(sceneHeight)
        func uniformsFor(_ slot: LyricSlot?) -> (SIMD4<Float>, SIMD4<Float>) {
            guard let slot else { return (.zero, .zero) }
            let reveal = ease((time - slot.enteredAt) / Self.inkIn)
            let exit = slot.exitedAt.map { ease((time - $0) / Self.inkOut) } ?? 0
            let p = slot.placement
            let scale = 2.0 * Double(sceneHeight)  // rasterised at 2× the internal resolution
            return (
                SIMD4(Float(p.x * aspect), Float(p.y), Float(slot.size.width / 2 / scale), Float(slot.size.height / 2 / scale)),
                SIMD4(Float(p.degrees * .pi / 180), Float(reveal * (1 - exit)), Float((1 - reveal) * 4.5 + exit * 3), 0)
            )
        }
        let newest = lyricSlots.last
        let older = lyricSlots.count > 1 ? lyricSlots[lyricSlots.count - 2] : nil
        (uniforms.ink0a, uniforms.ink0b) = uniformsFor(newest)
        (uniforms.ink1a, uniforms.ink1b) = uniformsFor(older)
    }

    /// Rasterised at twice the internal resolution, mipmapped (the shader blurs with mips).
    private func textTexture(_ text: String, placement: Placement, sceneWidth: Int) -> (texture: any MTLTexture, size: CGSize)? {
        let key = "\(placement.width)|\(text)"
        if let cached = textCache[key] { return cached }
        let fontSize = CGFloat(internalHeight) * (placement.width < 0.4 ? 0.068 : 0.085) * 2
        guard let image = LyricRasterizer.image(for: text, fontSize: fontSize,
                                                maxWidth: CGFloat(Double(sceneWidth) * placement.width) * 2,
                                                maxLines: placement.lines),
              let texture = texture(image) else { return nil }
        if textCache.count >= 12 { textCache.removeAll() }
        let entry = (texture: texture, size: CGSize(width: image.width, height: image.height))
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
