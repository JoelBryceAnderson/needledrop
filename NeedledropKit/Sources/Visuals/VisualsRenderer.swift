import Metal
import MetalKit
import simd
import QuartzCore
import SignalAnalysis

/// The lyric line to show this frame (already timed against what the room hears).
public struct LyricFrame: Sendable, Equatable {
    /// Changes when the line changes.
    public var id: Int
    public var text: String
    /// The following line, rendered ahead of time.
    public var next: String?
    /// Typewriter style: how many words are sung so far (fractional = the current word
    /// fading in). Nil prints the whole line.
    public var revealedWords: Double?

    public init(id: Int, text: String, next: String? = nil, revealedWords: Double? = nil) {
        self.id = id
        self.text = text
        self.next = next
        self.revealedWords = revealedWords
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
    /// Seconds since the last onset (drives the cover dissolve).
    public var onsetAge: Double?
    /// The side just finished: wind the picture down.
    public var sideEnded = false
    /// 0…1 through the side (the virtual record's tonearm).
    public var sideProgress = 0.0
    /// The virtual record's speed.
    public var rpm = 100.0 / 3
    /// Changes when the track changes (the choreographer opens a new scene). Nil: the album.
    public var trackID: String?
    /// Where the track is (seconds, on the song's clock): timed effects are placed on it.
    public var trackPosition: Double?
    /// Seconds until the next lyric line starts (nil: none coming). The picture moves in the
    /// gaps between lines and settles before the next one.
    public var nextLyricIn: Double?
    /// That line's index in the lyrics (for the track's score).
    public var nextLyricIndex: Int?

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
    public enum RenderResolution: String, Sendable, Codable, CaseIterable {
        /// 480 lines on a composite/standard-definition output, the display's own
        /// resolution (up to 1080 lines) anywhere else.
        case auto
        /// Always 480 lines, as the TV over composite gets it.
        case tv
    }

    public var renderResolution: RenderResolution = .auto
    /// Lines the scene is rendered at this frame (see `renderResolution`).
    public private(set) var internalHeight = 480

    private func sceneHeight(for target: any MTLTexture) -> Int {
        if renderResolution == .tv || target.height <= 600 { return 480 }
        return min(1080, target.height)
    }
    /// Forces a background for every album (the Theme setting); nil follows each album's
    /// art direction.
    public var themeOverride: LookStyle.Background?
    /// Show the album cover over the background.
    public var showCover = true
    /// Forces how the cover is shown (the Cover setting); nil follows the art direction.
    public var coverModeOverride: LookStyle.CoverMode?
    /// How much the picture is directed over a song: 0 holds still (the cover only steps
    /// aside for lyrics), 1 cuts between shots, moves the camera and the cover.
    public var motion: Double {
        get { choreographer.motion }
        set { choreographer.motion = min(1, max(0, newValue)) }
    }
    /// The cover sits small in the now-playing strip beside the title (on by default);
    /// off, the choreography places it.
    public var coverInStrip = true
    private var choreographer = Choreographer()
    /// The plan for the track playing (see `TrackScore`); nil: the built-in rules decide.
    public var score: TrackScore? {
        get { choreographer.score }
        set {
            choreographer.score = newValue
            effectCache = nil
        }
    }
    /// The track's lyric timing, which places the score's effects.
    public var scoreTimeline: LyricTimeline? {
        didSet { effectCache = nil }
    }
    private var effectCache: (tempo: Int, timeline: EffectTimeline)?
    /// This frame's effect levels.
    private var effects: [Effect.Kind: (amount: Double, progress: Double)] = [:]

    private func effectTimeline(tempo: Double?) -> EffectTimeline? {
        guard let score, !score.effects.isEmpty, let scoreTimeline else { return nil }
        let bpm = Int((tempo ?? 120).rounded())
        if let cached = effectCache, abs(cached.tempo - bpm) <= 2 { return cached.timeline }
        let built = EffectTimeline(score: score, timeline: scoreTimeline, tempo: Double(bpm))
        effectCache = (bpm, built)
        return built
    }

    private func effect(_ kind: Effect.Kind) -> Double { motion > 0 ? effects[kind]?.amount ?? 0 : 0 }
    private var shot = Choreographer.Frame(cover: .hero, camera: .identity, targetCover: .hero,
                                           targetCamera: .identity, shot: "hero", cuts: 0,
                                           moving: false, progress: 1, composition: 0)

    private var dissolve = 0.0
    private var lastKick = -Double.infinity
    private var recordAngle = 0.0
    private var windDown = 0.0
    /// Called once per frame for audio and session state.
    public var inputProvider: (() -> VisualInput)?

    private let queue: any MTLCommandQueue
    private let scenePipeline: any MTLRenderPipelineState
    private let presentPipeline: any MTLRenderPipelineState
    /// The background alone, small, read back for the lyric layout (see `LayoutField`).
    private let probePipeline: any MTLRenderPipelineState
    private var probe: LayoutProbe?
    /// 1 = the background drifts freely, 0 = held still (eased).
    private var holding = 1.0
    private var frameCount = 0
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
        var words = 0
        var revealedWords: Double?
        /// The caption's centre on screen (scene units), chosen clear of the cover.
        var screenCentre: SIMD2<Double>?
        /// Dark (1) or light (2) ink, chosen once against the background where it's set.
        var tone: Float = 0
        /// The caption once the song is under way: one line, "Title · Artist", smaller.
        var compactTexture: (any MTLTexture)?
        var compactSize: SIMD2<Double>?
        /// Set on a theme other than paper: where it sits (background scene units), not on a crease.
        var fixed: (centre: SIMD2<Double>, angle: Double)?
    }

    /// The background being drawn (set each frame before text is placed).
    private var currentBackground: LookStyle.Background = .paper

    /// The fold composition morphs between moves: from `composition - 1` to `composition` as
    /// the shot's move progresses. Folds wander on a clock that runs only while moving.
    private var foldFlow = 0.0

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
        probePipeline = try pipeline("layout_probe_fragment", format: .bgra8Unorm)

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
        var look = look
        look.style = look.style.clamped()
        if let body = look.style.customShaderBody { prepareCustomPipeline(body) }
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
    public var currentStyle: LookStyle { slots.first?.look.style ?? LookStyle() }

    // MARK: - Custom (Claude-written) scene shaders

    private var customPipelines: [String: any MTLRenderPipelineState] = [:]
    private var compiling: Set<String> = []

    /// Compiles off the main thread; the album shows on paper until it's ready.
    private func prepareCustomPipeline(_ body: String) {
        guard customPipelines[body] == nil, !compiling.contains(body) else { return }
        compiling.insert(body)
        let device = self.device
        Task { [weak self] in
            let result = await ShaderValidator.compile(Shaders.source(customBody: body), device: device, format: .rgba16Float)
            guard let self else { return }
            self.compiling.remove(body)
            if case .success(let pipeline) = result { self.customPipelines[body] = pipeline }
        }
    }

    /// The background this frame, and the pipeline that draws it.
    private func scenePipelineAndBackground(_ style: LookStyle) -> (any MTLRenderPipelineState, LookStyle.Background) {
        let wanted = themeOverride ?? style.background
        if wanted == .custom {
            if let body = style.customShaderBody, let pipeline = customPipelines[body] { return (pipeline, .custom) }
            return (scenePipeline, .paper)  // still compiling (or failed): paper meanwhile
        }
        return (scenePipeline, wanted)
    }

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
        let style = slots.first?.look.style ?? LookStyle()
        var audio = drive.update(features: input.features, beatAge: input.beatAge, dt: dt)
        audio.bass = min(1, audio.bass * Float(style.bassResponse))
        audio.beat = min(1, audio.beat * Float(style.beatResponse))
        // Side over: everything slows to a stop over ~3 s, like a record spinning down.
        windDown = input.sideEnded ? min(1, windDown + dt / 3) : max(0, windDown - dt / 0.8)
        let running = 1 - windDown * windDown * (3 - 2 * windDown)
        // While a lyric is up the background holds still (so the place its words were set
        // stays as calm and readable as when they were set); it moves between lines.
        let holdTarget = input.lyric != nil && motion > 0 ? 0.0 : 1.0
        holding += (holdTarget - holding) * (1 - exp(-dt / (holdTarget < 0.5 ? 0.15 : 0.5)))
        flow += dt * (0.04 + 0.10 * Double(audio.level)) * style.speed * running * holding
        recordAngle = (recordAngle + dt * input.rpm / 60 * 2 * .pi * running).truncatingRemainder(dividingBy: 2 * .pi)
        // Dissolve: a transient scatters the shards in proportion to how loud it is; they
        // drift home, faster on the beat.
        if let age = input.onsetAge, age < 0.06, time - lastKick > 0.15 {
            dissolve = max(dissolve, min(0.6, Double(audio.level) * 0.5))
            lastKick = time
        }
        if audio.beat > 0.9 { dissolve *= 0.9 }
        dissolve *= exp(-dt / 0.35)
        let frame = director.update(at: time, active: input.active)
        if frame.previousReleased, slots.count > 1 { slots.removeLast() }

        let height = sceneHeight(for: target)
        if height != internalHeight {
            internalHeight = height
            textCache.removeAll()  // lyrics are rasterised for the resolution
        }
        let width = max(1, Int((Double(height) * Double(target.width) / Double(max(1, target.height))).rounded()))
        let scene = sceneTarget(width: width, height: height)

        let current = slots.first
        let aspect = Double(width) / Double(height)
        let (pipeline, background) = scenePipelineAndBackground(style)
        currentBackground = background
        // The shot: where the cover is and how the camera looks at the background. With timed
        // lyrics it holds still while a line is up and moves only in the gaps between lines.
        var shotInput = Choreographer.Input(
            time: time, level: Double(audio.level), beatAge: input.beatAge, tempo: input.features.tempo,
            lyrics: input.lyricsAvailable, showCover: showCover && current?.art != nil,
            trackID: input.trackID ?? currentLookID, active: input.active && !input.sideEnded)
        shotInput.lineShowing = input.lyric != nil
        shotInput.nextLineIn = input.lyricsAvailable ? input.nextLyricIn : nil
        shotInput.nextLineIndex = input.nextLyricIndex
        shot = choreographer.update(shotInput)
        // The score's timed effects, on the song's clock.
        let effectTimes = effectTimeline(tempo: input.features.tempo)
        effects = input.trackPosition.flatMap { position in effectTimes?.levels(at: position) } ?? [:]
        let shake = effect(.shake)
        if shake > 0 {
            shot.camera.pan += SIMD2(sin(time * 31), cos(time * 27)) * 0.012 * shake
            shot.camera.roll += sin(time * 23) * 0.012 * shake
        }
        // The cover lives in the now-playing strip, small and always there; the choreography
        // moves the camera and the folds around it.
        if coverInStrip {
            // Tuck the strip down a few seconds into the track.
            let tucked = captionSlot.map { time - $0.enteredAt > Self.compactAfter } ?? true
            stripCompact = min(1, max(0, stripCompact + (tucked ? dt : -dt * 2) / 0.9))
            let strip = stripCover(aspect: aspect)
            shot.cover = strip
            shot.targetCover = strip
        }
        if shot.moving { foldFlow += dt * style.speed * running }
        let layout = foldLayout(aspect: aspect, bass: Double(audio.bass))
        updatePrintedText(input, time: time, layout: layout, hasArt: current?.art != nil && showCover, sceneHeight: height)

        var uniforms = SceneUniforms()
        uniforms.frame = SIMD4(Float(width), Float(height), Float(flow), frame.brightness)
        uniforms.audio = SIMD4(audio.bass, audio.mids, audio.highs, audio.level)
        // The cover's presence is the shot's visibility (scene.w), so it can fade and return.
        uniforms.rhythm = SIMD4(audio.beat, 0, slots.count > 1 ? frame.mix : 1, 1)
        let backgroundIndex: Float = switch background {
        case .paper: 0
        case .smoke: 1
        case .googie: 2
        case .custom: 3
        case .collage: 4
        case .risograph: 5
        }
        uniforms.style = SIMD4(backgroundIndex, Float(shot.cover.x), Float(shot.cover.size), flatTone)
        let coverIndex: Float = switch coverModeOverride ?? style.coverMode {
        case .living: 0
        case .dissolve: 1
        case .record: 2
        }
        uniforms.cover = SIMD4(coverIndex, Float(dissolve), Float(recordAngle), Float(input.sideProgress))
        uniforms.scene = SIMD4(Float(windDown), Float(shot.cover.y), Float(shot.cover.rotation),
                               Float(shot.cover.visibility))
        uniforms.setCamera(shot.camera.worldFromScreen(aspect: aspect))
        uniforms.strip = stripBacking(aspect: aspect, hasArt: current?.art != nil && showCover, time: time)
        uniforms.effects0 = SIMD4(Float(effect(.creaseSnap)), Float(effect(.lightSweep)), Float(effect(.flash)), Float(effect(.inkBleed)))
        uniforms.effects1 = SIMD4(Float(effect(.wordSwell)), Float(effect(.letterbox)), Float(effect(.duotone)), Float(shake))
        uniforms.effectsPhase = SIMD4(Float(effects[.lightSweep]?.progress ?? 0), 0, 0, 0)
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
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            encoder.setFragmentTexture(current?.art ?? placeholder, index: 0)
            encoder.setFragmentTexture(current?.mask ?? placeholder, index: 1)
            encoder.setFragmentTexture(previous?.art ?? placeholder, index: 2)
            encoder.setFragmentTexture(previous?.mask ?? placeholder, index: 3)
            encoder.setFragmentTexture(lyricSlots.last?.texture ?? placeholder, index: 4)
            encoder.setFragmentTexture(lyricSlots.count > 1 ? lyricSlots[lyricSlots.count - 2].texture : placeholder, index: 5)
            encoder.setFragmentTexture(stripText.texture ?? placeholder, index: 6)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        // Every few frames: the background alone, small, for the lyric layout to read.
        frameCount += 1
        if frameCount % 6 == 0, background != .custom {
            encodeProbe(&uniforms, aspect: aspect, commandBuffer: commandBuffer)
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
    /// The now-playing strip, bottom left: the cover (frame heights) and the gap to the words.
    private static let stripMargin = 0.05
    private static let stripCoverSize = 0.15
    /// Once the song is under way the strip tucks down: a smaller cover, one line of words.
    private static let compactCoverSize = 0.075
    private static let compactAfter = 6.0
    /// 0 = the strip as a track starts, 1 = tucked down (eased).
    private var stripCompact = 0.0
    private var stripCompactEased: Double { stripCompact * stripCompact * (3 - 2 * stripCompact) }
    private var stripCoverSizeNow: Double {
        Self.stripCoverSize + (Self.compactCoverSize - Self.stripCoverSize) * stripCompactEased
    }

    /// The caption texture showing now, and its size: the full one, then the one-line one.
    private var stripText: (texture: (any MTLTexture)?, size: SIMD2<Double>?) {
        guard let slot = captionSlot else { return (nil, nil) }
        if stripCompact > 0.5, let compact = slot.compactTexture { return (compact, slot.compactSize) }
        return (slot.texture, slot.size)
    }
    private static let stripGap = 0.03

    func stripCover(aspect: Double) -> CoverPose {
        let size = stripCoverSizeNow
        return CoverPose(x: (Self.stripMargin + size / 2) / aspect, y: 1 - Self.stripMargin - size / 2, size: size)
    }

    /// Text sizes to try, widest first (scene units: frame height = 1): (max width, font, lines).
    /// One long line running along the crease reads best; wrap only when it won't fit.
    /// Is a letterbox up, or due within the next few seconds?
    private func letterboxSoon(position: Double?) -> Bool {
        guard let position, let timeline = effectCache?.timeline ?? effectTimeline(tempo: nil) else { return false }
        return timeline.events.contains { $0.kind == .letterbox && $0.start < position + 5 && $0.end > position }
    }

    /// Sizes to try for a line the score marks big or as a whisper.
    nonisolated static func sizes(for emphasis: TrackScore.Emphasis) -> [(width: Double, font: Double, lines: Int)] {
        switch emphasis {
        case .normal: lyricSizes
        case .big: [(1.6, 0.12, 1), (1.4, 0.105, 1), (1.1, 0.1, 2), (0.9, 0.09, 2)] + lyricSizes
        case .whisper: [(0.9, 0.05, 1), (0.7, 0.045, 2)] + lyricSizes.suffix(2)
        }
    }

    nonisolated static let lyricSizes: [(width: Double, font: Double, lines: Int)] = [
        (1.5, 0.08, 1), (1.1, 0.07, 1), (0.8, 0.06, 1), (0.9, 0.065, 2), (0.6, 0.058, 3),
    ]

    private func ease(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    private var albumSeed: UInt64 {
        var seed: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (slots.first?.look.id ?? "neutral").utf8 { seed = (seed ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return seed
    }

    /// The fold composition now: the album's own to start with, a new one after each move
    /// (morphing during it). Two to four creases each, unless the art direction fixes the
    /// count: a few long seams for the words to sit on.
    private func foldLayout(aspect: Double, bass: Double) -> FoldLayout {
        guard motion > 0, shot.composition > 0 else { return foldLayout(aspect: aspect, bass: bass, composition: 0, directive: nil) }
        let to = foldLayout(aspect: aspect, bass: bass, composition: shot.composition, directive: shot.directive)
        guard shot.progress < 1 else { return to }
        return foldLayout(aspect: aspect, bass: bass, composition: shot.composition - 1, directive: shot.previousDirective)
            .morphed(to: to, shot.progress)
    }

    /// One composition: seeded, unless the score's keyframe fixes its crease count or angle.
    func foldLayout(aspect: Double, bass: Double, composition: Int, directive: TrackScore.Keyframe?) -> FoldLayout {
        let style = currentStyle
        let seed = composition == 0 ? albumSeed : albumSeed ^ (UInt64(truncatingIfNeeded: composition) &* 0x9E37_79B9_7F4A_7C15)
        var rng = SeededRandom(seed: seed ^ 0xA9)
        let seededAngle = style.foldAngle.map { composition == 0 ? $0 : $0 + (rng.unit() - 0.5) * 24 }
        let seededCount = style.foldCount ?? 2 + Int(rng.unit() * 2.99)
        return FoldLayout.make(seed: seed, aspect: aspect, flow: foldFlow, bass: bass,
                               angle: directive?.angleDegrees ?? seededAngle, count: directive?.creases ?? seededCount,
                               turbulence: style.turbulence)
    }

    /// The score's palette moves and accent strip, blended across the move: (accent strip,
    /// swap 0…1, mute 0…1).
    private var paletteMoves: (accent: Float, swap: Float, mute: Float) {
        func amounts(_ k: TrackScore.Keyframe?) -> (Float, Float) {
            switch k?.palette ?? TrackScore.PaletteMove.none {
            case .none: (0, 0)
            case .swap: (1, 0)
            case .mute: (0, 1)
            }
        }
        let t = Float(shot.moving ? shot.progress : 1)
        let a = amounts(shot.previousDirective), b = amounts(shot.directive)
        let accent = Float((t < 0.5 ? shot.previousDirective : shot.directive)?.accentStrip ?? 1)
        return (accent, a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
    }

    static func crease(_ c: FoldLayout.Crease) -> SIMD4<Float> {
        let n = c.normal
        return SIMD4(Float(n.x), Float(n.y), Float(simd_dot(c.point, n)), 1)
    }

    /// Can a lyric put ink at background point `p`? It must show on screen under the camera
    /// now and the camera the shot is heading to, and stay clear of the cover (where it is and
    /// where it's going) and the caption.
    private func printable(aspect: Double, hasArt: Bool, time: Double, avoidCaption: Bool = true,
                           band: ClosedRange<Double>? = nil) -> (SIMD2<Double>) -> Bool {
        let cameras = [shot.camera, shot.targetCamera].map { $0.worldFromScreen(aspect: aspect).inverse }
        let covers = hasArt ? [shot.cover, shot.targetCover] : []
        var caption: CGRect?
        if avoidCaption, let slot = captionSlot, captionOpacity(slot, time: time) > 0 {
            let f = captionFrame(slot, aspect: aspect)
            caption = CGRect(x: f.centre.x - f.size.x / 2 - 0.02, y: f.centre.y - f.size.y / 2 - 0.02,
                             width: f.size.x + 0.04, height: f.size.y + 0.04)
        }
        let margin = 0.05  // room for the drift within a shot
        // The now-playing strip is always there: keep a clear margin round all of it.
        let backing = stripBacking(aspect: aspect, hasArt: hasArt, time: time)
        let strip: CGRect? = backing.z > backing.x
            ? CGRect(x: Double(backing.x) - 0.04, y: Double(backing.y) - 0.04,
                     width: Double(backing.z - backing.x) + 0.08, height: Double(backing.w - backing.y) + 0.08)
            : nil
        return { p in
            for camera in cameras {
                guard let q = CameraPose.apply(camera, p).map({ $0 + SIMD2(aspect / 2, 0.5) }),
                      q.x > margin, q.x < aspect - margin, q.y > margin, q.y < 1 - margin else { return false }
                if covers.contains(where: { $0.contains(q, aspect: aspect, padding: 0.035) }) { return false }
                if let caption, caption.contains(CGPoint(x: q.x, y: q.y)) { return false }
                if let strip, strip.contains(CGPoint(x: q.x, y: q.y)) { return false }
                if let band, !band.contains(q.y) { return false }
            }
            return true
        }
    }

    private func updatePrintedText(_ input: VisualInput, time: Double, layout: FoldLayout, hasArt: Bool, sceneHeight: Int) {
        // Caption: a new track's caption soaks in, holds, soaks out.
        if let caption = input.caption, caption.id != captionSlot?.captionID {
            let fontSize = CGFloat(sceneHeight) * 0.042 * 2
            let room = 0.7
            if let image = LyricRasterizer.caption(title: currentStyle.apply(case: caption.title), subtitle: caption.subtitle,
                                                   font: currentStyle.font,
                                                   fontSize: fontSize, maxWidth: CGFloat(Double(sceneHeight) * room * 2)),
               let tex = texture(image) {
                let size = SIMD2(Double(image.width), Double(image.height)) / (2 * Double(sceneHeight))
                let corner = stripCaptionCentre(size: size, hasArt: hasArt && coverInStrip)
                // Light words on the strip's dark backing.
                captionSlot = PrintedSlot(id: 0, captionID: caption.id, texture: tex, size: size, spot: nil, enteredAt: time,
                                          screenCentre: corner, tone: 2)
                // And the one-line version for once the song is under way.
                let artist = caption.subtitle.components(separatedBy: "  ·  ").first ?? caption.subtitle
                let line = artist.isEmpty ? currentStyle.apply(case: caption.title) : "\(currentStyle.apply(case: caption.title))  ·  \(artist)"
                let compactScale = 2 * Double(sceneHeight)
                if let compact = LyricRasterizer.image(for: line, fontSize: CGFloat(0.03 * compactScale),
                                                       maxWidth: CGFloat(0.9 * compactScale), maxLines: 1,
                                                       font: currentStyle.font, weight: .regular),
                   let compactTexture = texture(compact) {
                    captionSlot?.compactTexture = compactTexture
                    captionSlot?.compactSize = SIMD2(Double(compact.width), Double(compact.height)) / compactScale
                }
                stripCompact = 0
            }
        } else if input.caption == nil, let caption = captionSlot, caption.exitedAt == nil {
            captionSlot?.exitedAt = time
        }

        // Lyrics: each line gets a crease, a side and a position along it when it starts.
        if lyricSlots.last?.id != input.lyric?.id || (input.lyric == nil && lyricSlots.last?.exitedAt == nil) {
            for i in lyricSlots.indices where lyricSlots[i].exitedAt == nil { lyricSlots[i].exitedAt = time }
            if let lyric = input.lyric {
                // The score may ask for a line to be big or a whisper, and where on screen.
                let treatment = score?.treatment(line: lyric.id)
                var band: ClosedRange<Double>? = switch treatment?.placement ?? .any {
                case .any: nil
                case .upper: 0...0.55
                case .middle: 0.2...0.8
                case .lower: 0.45...1
                }
                // Letterbox bars now or coming while the line is up: keep it between them.
                if letterboxSoon(position: input.trackPosition) {
                    let safe = 0.19...0.81
                    band = band.map { max($0.lowerBound, safe.lowerBound)...min($0.upperBound, safe.upperBound) } ?? safe
                    if let b = band, b.lowerBound >= b.upperBound { band = safe }
                }
                let sizes = Self.sizes(for: treatment?.emphasis ?? .normal)
                let placed = printable(aspect: layout.aspect, hasArt: hasArt, time: time, band: band)
                let allowed = printable(aspect: layout.aspect, hasArt: hasArt, time: time)
                let blocked = lyricSlots.filter { slotOpacity($0, time: time) > 0.05 }.compactMap { slot in
                        slotFrame(slot, layout: layout).map { boundingBox($0, size: slot.size) }
                    }
                // Never drop a line: if it won't fit, let it share space with the line soaking
                // out, then with the caption.
                let relaxedAllowed = printable(aspect: layout.aspect, hasArt: hasArt, time: time, avoidCaption: false)
                // Themes other than paper: placed by what's actually on screen, at the theme's angles.
                if currentBackground != .paper,
                   let spot = placeOnTheme(lyric.text, line: lyric.id, sizes: sizes, allowed: placed, blocked: blocked,
                                           aspect: layout.aspect, sceneHeight: sceneHeight)
                    ?? placeOnTheme(lyric.text, line: lyric.id, sizes: Self.lyricSizes, allowed: allowed, blocked: [],
                                    aspect: layout.aspect, sceneHeight: sceneHeight) {
                    lyricSlots.append(PrintedSlot(id: lyric.id, captionID: nil, texture: spot.texture, size: spot.size,
                                                  spot: nil, enteredAt: time,
                                                  words: LyricRasterizer.wordRanges(lyric.text).count,
                                                  tone: spot.tone, fixed: (spot.centre, spot.angle)))
                } else {
                placing: for (obstacles, test, choices) in [(blocked, placed, sizes), (blocked, allowed, sizes),
                                                            (blocked, allowed, Self.lyricSizes), ([], allowed, Self.lyricSizes),
                                                            ([], relaxedAllowed, Self.lyricSizes)] {
                    for size in choices {
                        guard let text = lyricTexture(lyric.text, size: size, sceneHeight: sceneHeight),
                              let spot = layout.spot(forLine: lyric.id, size: text.size, obstacles: obstacles,
                                                     allowed: test) else { continue }
                        lyricSlots.append(PrintedSlot(id: lyric.id, captionID: nil, texture: text.texture, size: text.size,
                                                      spot: spot, enteredAt: time,
                                                      words: LyricRasterizer.wordRanges(lyric.text).count,
                                                      tone: tone(at: layout.frame(for: spot, size: text.size).centre, layout: layout)))
                        break placing
                    }
                }
                }
            }
        }
        // The sung line's word count moves on every frame (typewriter); older lines are whole.
        if let lyric = input.lyric, let i = lyricSlots.lastIndex(where: { $0.id == lyric.id && $0.exitedAt == nil }) {
            lyricSlots[i].revealedWords = lyric.revealedWords
        }
        lyricSlots.removeAll { slot in slot.exitedAt.map { time - $0 > Self.inkOut } ?? false }
        if lyricSlots.count > 2 { lyricSlots.removeFirst(lyricSlots.count - 2) }
    }

    /// Dark or light ink for text set at `p` (background scene units): against the lit fold it
    /// sits on (paper), or the background's overall lightness. Chosen once, so it never flickers.
    private func tone(at p: SIMD2<Double>, layout: FoldLayout) -> Float {
        guard currentBackground == .paper else { return flatTone }
        let palette = (slots.first?.look.palette ?? .neutral).colors.sorted { $0.luminance < $1.luminance }
        let k = layout.strip(at: p)
        // As the shader colours it once the move has settled (accent strip, palette swap).
        let accentStrip = shot.directive?.accentStrip ?? 1
        let swap = shot.directive?.palette == .swap
        let base = (k == accentStrip) != swap ? palette[4] : palette[3]
        let colour = SIMD3(Double(max(base.r, 0.12)), Double(max(base.g, 0.12)), Double(max(base.b, 0.12)))
        let m = layout.creases.first?.normal ?? SIMD2(0, 1)
        let sgn = k % 2 == 0 ? 1.0 : -1.0
        let n = simd_normalize(SIMD3(m.x * sin(layout.tilt) * sgn, m.y * sin(layout.tilt) * sgn, cos(layout.tilt)))
        let lit = 0.38 + 0.85 * max(0, simd_dot(n, layout.light))
        let lum = simd_dot(colour * lit, SIMD3(0.2126, 0.7152, 0.0722))
        return lum > 0.4 ? 1 : 2
    }

    /// Ink for the flat backgrounds, from how light the album's colours are overall.
    private var flatTone: Float {
        if [.googie, .collage, .risograph].contains(currentBackground) { return 1 }  // cream grounds
        let colours = (slots.first?.look.palette ?? .neutral).colors
        let mean = colours.reduce(Float(0)) { $0 + $1.luminance } / Float(max(1, colours.count))
        return mean > 0.45 ? 1 : 2
    }

    /// Where a line sits: along its crease, wherever the crease is now.
    private func encodeProbe(_ uniforms: inout SceneUniforms, aspect: Double, commandBuffer: any MTLCommandBuffer) {
        let height = 90, width = max(1, Int((Double(height) * aspect).rounded()))
        if probe?.width != width {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return }
            probe = LayoutProbe(width: width, height: height, texture: texture)
        }
        guard let probe else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = probe.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(probePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in probe.readBack() }
    }

    /// Angles each theme sets its words at, in degrees: its own idea of intentional type.
    static func themeAngles(_ background: LookStyle.Background) -> [Double] {
        switch background {
        case .paper: [0]                  // (paper sets words along its creases instead)
        case .googie: [0, -7, 7]          // signage: level, or a jaunty tilt
        case .collage: [-12, -5, 5, 12]   // cut out and pasted down at an angle
        case .risograph: [0, -3]          // set square, as printed
        case .smoke: [0]
        case .custom: [0, -8, 8]
        }
    }

    /// On a theme other than paper: the calmest place on screen, at one of the theme's angles,
    /// where the words are readable (judged on the background as rendered) and clear of the
    /// strip, the cover, the edges and the other line. Nil if the probe hasn't been read yet.
    private func placeOnTheme(_ text: String, line: Int, sizes: [(width: Double, font: Double, lines: Int)],
                              allowed: (SIMD2<Double>) -> Bool, blocked: [CGRect], aspect: Double,
                              sceneHeight: Int) -> (texture: any MTLTexture, size: SIMD2<Double>, centre: SIMD2<Double>,
                                                    angle: Double, tone: Float)? {
        guard let field = probe?.current else { return nil }
        let camera = shot.targetCamera
        var best: (score: Double, texture: any MTLTexture, size: SIMD2<Double>, centre: SIMD2<Double>, angle: Double, tone: Float)?
        // Lines take turns across the screen, so successive ones don't stack in one spot.
        let preferredX = [0.36, 0.64, 0.5, 0.42, 0.58][abs(line) % 5] * aspect
        // Crowded grounds need words that fit inside one shape or a narrow gap: smaller, wrapped.
        let choices = Array(sizes.prefix(5)) + [(0.55, 0.055, 3), (0.45, 0.05, 3), (0.38, 0.045, 4)]
        for size in choices {
            guard let raster = lyricTexture(text, size: size, sceneHeight: sceneHeight) else { continue }
            for degrees in Self.themeAngles(currentBackground) {
                let angle = degrees * .pi / 180
                let d = SIMD2(cos(angle), sin(angle)), n = SIMD2(-sin(angle), cos(angle))
                for y in stride(from: 0.1, through: 0.88, by: 0.035) {
                    for x in stride(from: 0.08, through: 0.92, by: 0.035) {
                        let screen = SIMD2(x * aspect, y)
                        let reading = field.read(centre: screen, angle: angle, size: raster.size, aspect: aspect)
                        let score = Double(reading.busyness) * 6 - Double(min(0.35, reading.contrast)) * 1.5
                            + abs(screen.x - preferredX) * 0.08 + abs(y - 0.45) * 0.1
                        guard score < (best?.score ?? .infinity), reading.contrast > 0.18,
                              let centre = camera.world(of: screen, aspect: aspect) else { continue }
                        // The whole box must be printable and clear of the other line.
                        var clear = true
                        check: for i in 0...12 {
                            for j in 0...2 {
                                let p = centre + d * raster.size.x * (Double(i) / 12 - 0.5) + n * raster.size.y * (Double(j) / 2 - 0.5)
                                if !allowed(p) || blocked.contains(where: { $0.contains(CGPoint(x: p.x, y: p.y)) }) {
                                    clear = false
                                    break check
                                }
                            }
                        }
                        if clear { best = (score, raster.texture, raster.size, centre, angle, reading.tone) }
                    }
                }
            }
            // The biggest size that sits on calm ground is the one; otherwise a smaller size that
            // fits inside one area beats a big one across an edge.
            if let best, best.score < 0 { break }
        }
        if ProcessInfo.processInfo.environment["NEEDLEDROP_DEBUG_LAYOUT"] != nil, let best {
            print("placed line \(line) score \(best.score) at \(best.centre) angle \(best.angle) size \(best.size)")
        }
        return best.map { ($0.texture, $0.size, $0.centre, $0.angle, $0.tone) }
    }

    private func slotFrame(_ slot: PrintedSlot, layout: FoldLayout) -> (centre: SIMD2<Double>, angle: Double)? {
        if let fixed = slot.fixed { return fixed }
        guard let spot = slot.spot, spot.crease < layout.creases.count else { return nil }
        return layout.frame(for: spot, size: slot.size)
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
        // Stays up for the whole track (the now-playing strip).
        let out = slot.exitedAt ?? .infinity
        return ease((time - slot.enteredAt) / Self.inkIn) * (1 - ease((time - out) / Self.inkOut))
    }

    /// The backing behind the strip (cover and words), while there's something in it.
    private func stripBacking(aspect: Double, hasArt: Bool, time: Double) -> SIMD4<Float> {
        let pad = 0.018
        var lo = SIMD2(Double.infinity, .infinity), hi = SIMD2(-Double.infinity, -.infinity)
        if hasArt {
            let c = SIMD2(shot.cover.x * aspect, shot.cover.y), h = shot.cover.size / 2
            lo = simd_min(lo, c - h)
            hi = simd_max(hi, c + h)
        }
        if let caption = captionSlot, captionOpacity(caption, time: time) > 0.01 {
            let f = captionFrame(caption, aspect: aspect)
            lo = simd_min(lo, f.centre - f.size / 2)
            hi = simd_max(hi, f.centre + f.size / 2)
        }
        guard lo.x < hi.x else { return .zero }
        return SIMD4(Float(lo.x - pad), Float(lo.y - pad), Float(hi.x + pad * 1.6), Float(hi.y + pad))
    }

    /// The title and artist sit beside the strip's cover, centred on it (or in its place
    /// when the cover is hidden).
    private func stripCaptionCentre(size: SIMD2<Double>, hasArt: Bool) -> SIMD2<Double> {
        let cover = stripCoverSizeNow
        let left = Self.stripMargin + (hasArt ? cover + Self.stripGap * (1 - 0.4 * stripCompactEased) : 0)
        let centreY = 1 - Self.stripMargin - (hasArt ? cover / 2 : size.y / 2)
        return SIMD2(left + size.x / 2, centreY)
    }

    /// Beside the strip's cover whenever it's showing — worked out each frame, since the title
    /// often arrives before the artwork does.
    private func captionFrame(_ slot: PrintedSlot, aspect: Double) -> (centre: SIMD2<Double>, size: SIMD2<Double>) {
        if coverInStrip {
            let size = stripText.size ?? slot.size
            return (stripCaptionCentre(size: size, hasArt: slots.first?.art != nil && showCover), size)
        }
        return (slot.screenCentre ?? SIMD2(0.06 + slot.size.x / 2, 0.06 + slot.size.y / 2), slot.size)
    }

    private func setInk(_ uniforms: inout SceneUniforms, time: Double, layout: FoldLayout) {
        // Ink bleed softens and spreads the words; word swell pulses the line on screen.
        let bleed = effect(.inkBleed), swell = effect(.wordSwell)
        func blur(_ opacity: Double, exiting: Bool) -> Float {
            Float((exiting ? (1 - opacity) * 3 : (1 - opacity) * 4.5) + bleed * 2.2)
        }
        func lyric(_ slot: PrintedSlot?, current: Bool) -> (SIMD4<Float>, SIMD4<Float>) {
            guard let slot, let f = slotFrame(slot, layout: layout) else { return (.zero, .zero) }
            let o = min(1, slotOpacity(slot, time: time) * (1 + bleed * 0.3))
            let scale = current ? 1 + 0.07 * swell : 1
            return (SIMD4(Float(f.centre.x), Float(f.centre.y), Float(slot.size.x / 2 * scale), Float(slot.size.y / 2 * scale)),
                    SIMD4(Float(f.angle), Float(o), blur(o, exiting: slot.exitedAt != nil), slot.tone))
        }
        let newest = lyricSlots.last
        let older = lyricSlots.count > 1 ? lyricSlots[lyricSlots.count - 2] : nil
        (uniforms.ink0a, uniforms.ink0b) = lyric(newest, current: newest?.exitedAt == nil)
        (uniforms.ink1a, uniforms.ink1b) = lyric(older, current: false)
        func words(_ slot: PrintedSlot?) -> (Float, Float) {
            guard let slot, let shown = slot.revealedWords, slot.exitedAt == nil else { return (0, 0) }
            return (Float(slot.words), Float(shown))
        }
        let (n0, r0) = words(newest), (n1, r1) = words(older)
        uniforms.inkWords = SIMD4(n0, r0, n1, r1)
        if let caption = captionSlot {
            let f = captionFrame(caption, aspect: layout.aspect)
            // The words dip out and back in as they switch to the one-line strip.
            let dip = caption.compactTexture == nil ? 1 : abs(1 - 2 * stripCompact)
            let o = captionOpacity(caption, time: time) * dip
            uniforms.ink2a = SIMD4(Float(f.centre.x), Float(f.centre.y), Float(f.size.x / 2), Float(f.size.y / 2))
            uniforms.ink2b = SIMD4(0, Float(o), blur(o, exiting: time > caption.enteredAt + Self.inkIn), caption.tone)
        }
        for (i, c) in layout.creases.prefix(FoldLayout.maximumCreases).enumerated() {
            let crease = Self.crease(c)
            switch i {
            case 0: uniforms.crease.0 = crease
            case 1: uniforms.crease.1 = crease
            case 2: uniforms.crease.2 = crease
            default: uniforms.crease.3 = crease
            }
        }
        let moves = paletteMoves
        uniforms.fold = SIMD4(Float(layout.tilt), moves.accent, moves.swap, moves.mute)
        uniforms.light = SIMD4(Float(layout.light.x), Float(layout.light.y), Float(layout.light.z), 0)
    }

    /// Rasterised at twice the internal resolution, mipmapped (the shader blurs with mips).
    private func lyricTexture(_ text: String, size: (width: Double, font: Double, lines: Int), sceneHeight: Int)
        -> (texture: any MTLTexture, size: SIMD2<Double>)? {
        let style = currentStyle
        let key = "\(size.width)|\(style.font)|\(style.weight)|\(style.letterCase)|\(text)"
        if let cached = textCache[key] { return cached }
        let scale = 2 * Double(sceneHeight)
        guard let image = LyricRasterizer.image(for: style.apply(case: text), fontSize: CGFloat(size.font * scale),
                                                maxWidth: CGFloat(size.width * scale), maxLines: size.lines,
                                                font: style.font, weight: style.weight),
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
    var inkWords = SIMD4<Float>()
    var crease: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var fold = SIMD4<Float>()
    var cover = SIMD4<Float>()
    var scene = SIMD4<Float>()
    var light = SIMD4<Float>(0, 0, 1, 0)
    var palette0 = SceneUniforms.emptyPalette
    var palette1 = SceneUniforms.emptyPalette
    /// World-from-screen homography rows (see `CameraPose.worldFromScreen`).
    var camera: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0))

    var strip = SIMD4<Float>()
    var effects0 = SIMD4<Float>()
    var effects1 = SIMD4<Float>()
    var effectsPhase = SIMD4<Float>()

    mutating func setCamera(_ m: simd_double3x3) {
        let r = m.transpose
        func row(_ v: SIMD3<Double>) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), 0) }
        camera = (row(r.columns.0), row(r.columns.1), row(r.columns.2))
    }

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
