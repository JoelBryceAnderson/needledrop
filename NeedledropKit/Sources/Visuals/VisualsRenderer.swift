import Metal
import MetalKit
import QuartzCore
import SignalAnalysis

public enum VisualMode: String, Codable, CaseIterable, Sendable {
    /// Living cover when there's artwork, palette bleed otherwise.
    case auto
    case paletteBleed
}

/// What the renderer reads each frame.
public struct VisualInput: Sendable {
    public var features: AudioFeatures
    /// Seconds since the last tracked beat.
    public var beatAge: Double?
    /// Music playing or about to: anything but idle / side ended.
    public var active: Bool

    public init(features: AudioFeatures = AudioFeatures(), beatAge: Double? = nil, active: Bool = false) {
        self.features = features
        self.beatAge = beatAge
        self.active = active
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
    public var mode: VisualMode = .auto
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
    private var drive = AudioDriveFilter()
    private var flow = 0.0
    private var lastTime: Double?

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

        var uniforms = SceneUniforms()
        uniforms.frame = SIMD4(Float(width), Float(height), Float(flow), frame.brightness)
        uniforms.audio = SIMD4(audio.bass, audio.mids, audio.highs, audio.level)
        uniforms.rhythm = SIMD4(audio.beat, 0, slots.count > 1 ? frame.mix : 1, mode == .paletteBleed ? 0 : 1)
        let current = slots.first
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
