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
    /// Seconds until the next lyric line starts (nil: none coming). The picture moves in the
    /// gaps between lines and settles before the next one.
    public var nextLyricIn: Double?

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
    private var choreographer = Choreographer()
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
    }

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
        // While a lyric is up the background holds nearly still; it moves between lines.
        let holding = input.lyric != nil && motion > 0 ? 0.15 : 1
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
        // The shot: where the cover is and how the camera looks at the background. With timed
        // lyrics it holds still while a line is up and moves only in the gaps between lines.
        var shotInput = Choreographer.Input(
            time: time, level: Double(audio.level), beatAge: input.beatAge, tempo: input.features.tempo,
            lyrics: input.lyricsAvailable, showCover: showCover && current?.art != nil,
            trackID: input.trackID ?? currentLookID, active: input.active && !input.sideEnded)
        shotInput.lineShowing = input.lyric != nil
        shotInput.nextLineIn = input.lyricsAvailable ? input.nextLyricIn : nil
        shot = choreographer.update(shotInput)
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
        }
        uniforms.style = SIMD4(backgroundIndex, Float(shot.cover.x), Float(shot.cover.size), 0)
        let coverIndex: Float = switch coverModeOverride ?? style.coverMode {
        case .living: 0
        case .dissolve: 1
        case .record: 2
        }
        uniforms.cover = SIMD4(coverIndex, Float(dissolve), Float(recordAngle), Float(input.sideProgress))
        uniforms.scene = SIMD4(Float(windDown), Float(shot.cover.y), Float(shot.cover.rotation),
                               Float(shot.cover.visibility))
        uniforms.setCamera(shot.camera.worldFromScreen(aspect: aspect))
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

    private var albumSeed: UInt64 {
        var seed: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (slots.first?.look.id ?? "neutral").utf8 { seed = (seed ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return seed
    }

    /// The fold composition now: the album's own to start with, a new one after each move
    /// (morphing during it). Two to four creases each, unless the art direction fixes the
    /// count: a few long seams for the words to sit on.
    private func foldLayout(aspect: Double, bass: Double) -> FoldLayout {
        let style = currentStyle
        func make(_ composition: Int) -> FoldLayout {
            let seed = composition == 0 ? albumSeed : albumSeed ^ (UInt64(truncatingIfNeeded: composition) &* 0x9E37_79B9_7F4A_7C15)
            var rng = SeededRandom(seed: seed ^ 0xA9)
            let angle = style.foldAngle.map { composition == 0 ? $0 : $0 + (rng.unit() - 0.5) * 24 }
            return FoldLayout.make(seed: seed, aspect: aspect, flow: foldFlow, bass: bass,
                                   angle: angle, count: style.foldCount ?? 2 + Int(rng.unit() * 2.99),
                                   turbulence: style.turbulence)
        }
        guard motion > 0, shot.composition > 0 else { return make(0) }
        let to = make(shot.composition)
        guard shot.progress < 1 else { return to }
        return make(shot.composition - 1).morphed(to: to, shot.progress)
    }

    static func crease(_ c: FoldLayout.Crease) -> SIMD4<Float> {
        let n = c.normal
        return SIMD4(Float(n.x), Float(n.y), Float(simd_dot(c.point, n)), 1)
    }

    /// Can a lyric put ink at background point `p`? It must show on screen under the camera
    /// now and the camera the shot is heading to, and stay clear of the cover (where it is and
    /// where it's going) and the caption.
    private func printable(aspect: Double, hasArt: Bool, time: Double, avoidCaption: Bool = true) -> (SIMD2<Double>) -> Bool {
        let cameras = [shot.camera, shot.targetCamera].map { $0.worldFromScreen(aspect: aspect).inverse }
        let covers = hasArt ? [shot.cover, shot.targetCover] : []
        var caption: CGRect?
        if avoidCaption, let slot = captionSlot, captionOpacity(slot, time: time) > 0 {
            let f = captionFrame(slot, aspect: aspect)
            caption = CGRect(x: f.centre.x - f.size.x / 2 - 0.02, y: f.centre.y - f.size.y / 2 - 0.02,
                             width: f.size.x + 0.04, height: f.size.y + 0.04)
        }
        let margin = 0.05  // room for the drift within a shot
        return { p in
            for camera in cameras {
                guard let q = CameraPose.apply(camera, p).map({ $0 + SIMD2(aspect / 2, 0.5) }),
                      q.x > margin, q.x < aspect - margin, q.y > margin, q.y < 1 - margin else { return false }
                if covers.contains(where: { $0.contains(q, aspect: aspect, padding: 0.035) }) { return false }
                if let caption, caption.contains(CGPoint(x: q.x, y: q.y)) { return false }
            }
            return true
        }
    }

    private func updatePrintedText(_ input: VisualInput, time: Double, layout: FoldLayout, hasArt: Bool, sceneHeight: Int) {
        // Caption: a new track's caption soaks in, holds, soaks out.
        if let caption = input.caption, caption.id != captionSlot?.captionID {
            let fontSize = CGFloat(sceneHeight) * 0.06 * 2
            let room = 0.8
            if let image = LyricRasterizer.caption(title: currentStyle.apply(case: caption.title), subtitle: caption.subtitle,
                                                   font: currentStyle.font,
                                                   fontSize: fontSize, maxWidth: CGFloat(Double(sceneHeight) * room * 2)),
               let tex = texture(image) {
                let size = SIMD2(Double(image.width), Double(image.height)) / (2 * Double(sceneHeight))
                captionSlot = PrintedSlot(id: 0, captionID: caption.id, texture: tex, size: size, spot: nil, enteredAt: time,
                                          screenCentre: captionCorner(size: size, aspect: layout.aspect, hasArt: hasArt))
            }
        } else if input.caption == nil, let caption = captionSlot, caption.exitedAt == nil {
            captionSlot?.exitedAt = time
        }

        // Lyrics: each line gets a crease, a side and a position along it when it starts.
        if lyricSlots.last?.id != input.lyric?.id || (input.lyric == nil && lyricSlots.last?.exitedAt == nil) {
            for i in lyricSlots.indices where lyricSlots[i].exitedAt == nil { lyricSlots[i].exitedAt = time }
            if let lyric = input.lyric {
                let allowed = printable(aspect: layout.aspect, hasArt: hasArt, time: time)
                let blocked = lyricSlots.filter { slotOpacity($0, time: time) > 0.05 }.compactMap { slot in
                        slotFrame(slot, layout: layout).map { boundingBox($0, size: slot.size) }
                    }
                // Never drop a line: if it won't fit, let it share space with the line soaking
                // out, then with the caption.
                let relaxedAllowed = printable(aspect: layout.aspect, hasArt: hasArt, time: time, avoidCaption: false)
                placing: for (obstacles, test) in [(blocked, allowed), ([], allowed), ([], relaxedAllowed)] {
                    for size in Self.lyricSizes {
                        guard let text = lyricTexture(lyric.text, size: size, sceneHeight: sceneHeight),
                              let spot = layout.spot(forLine: lyric.id, size: text.size, obstacles: obstacles,
                                                     allowed: test) else { continue }
                        lyricSlots.append(PrintedSlot(id: lyric.id, captionID: nil, texture: text.texture, size: text.size,
                                                      spot: spot, enteredAt: time,
                                                      words: LyricRasterizer.wordRanges(lyric.text).count))
                        break placing
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

    /// Where a line sits: along its crease, wherever the crease is now.
    private func slotFrame(_ slot: PrintedSlot, layout: FoldLayout) -> (centre: SIMD2<Double>, angle: Double)? {
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
        let out = slot.exitedAt ?? (slot.enteredAt + Self.captionHold)
        return ease((time - slot.enteredAt) / Self.inkIn) * (1 - ease((time - out) / Self.inkOut))
    }

    /// Printed like a title card in a corner of the screen, the first one the cover (where the
    /// shot is taking it) leaves clear.
    private func captionCorner(size: SIMD2<Double>, aspect: Double, hasArt: Bool) -> SIMD2<Double> {
        let left = 0.06 + size.x / 2, right = aspect - 0.06 - size.x / 2
        let top = 0.06 + size.y / 2, bottom = 0.95 - size.y / 2
        let corners = [SIMD2(left, top), SIMD2(left, bottom), SIMD2(right, bottom), SIMD2(right, top)]
        let covers = hasArt ? [shot.targetCover] : []
        return corners.first { c in
            !covers.contains { cover in
                (0...4).contains { i in
                    (0...2).contains { j in
                        cover.contains(c + SIMD2(size.x * (Double(i) / 4 - 0.5), size.y * (Double(j) / 2 - 0.5)),
                                       aspect: aspect, padding: 0.02)
                    }
                }
            }
        } ?? corners[0]
    }

    private func captionFrame(_ slot: PrintedSlot, aspect: Double) -> (centre: SIMD2<Double>, size: SIMD2<Double>) {
        (slot.screenCentre ?? SIMD2(0.06 + slot.size.x / 2, 0.06 + slot.size.y / 2), slot.size)
    }

    private func setInk(_ uniforms: inout SceneUniforms, time: Double, layout: FoldLayout) {
        func blur(_ opacity: Double, exiting: Bool) -> Float { Float(exiting ? (1 - opacity) * 3 : (1 - opacity) * 4.5) }
        func lyric(_ slot: PrintedSlot?) -> (SIMD4<Float>, SIMD4<Float>) {
            guard let slot, let f = slotFrame(slot, layout: layout) else { return (.zero, .zero) }
            let o = slotOpacity(slot, time: time)
            return (SIMD4(Float(f.centre.x), Float(f.centre.y), Float(slot.size.x / 2), Float(slot.size.y / 2)),
                    SIMD4(Float(f.angle), Float(o), blur(o, exiting: slot.exitedAt != nil), 0))
        }
        let newest = lyricSlots.last
        let older = lyricSlots.count > 1 ? lyricSlots[lyricSlots.count - 2] : nil
        (uniforms.ink0a, uniforms.ink0b) = lyric(newest)
        (uniforms.ink1a, uniforms.ink1b) = lyric(older)
        func words(_ slot: PrintedSlot?) -> (Float, Float) {
            guard let slot, let shown = slot.revealedWords, slot.exitedAt == nil else { return (0, 0) }
            return (Float(slot.words), Float(shown))
        }
        let (n0, r0) = words(newest), (n1, r1) = words(older)
        uniforms.inkWords = SIMD4(n0, r0, n1, r1)
        if let caption = captionSlot {
            let f = captionFrame(caption, aspect: layout.aspect)
            let o = captionOpacity(caption, time: time)
            uniforms.ink2a = SIMD4(Float(f.centre.x), Float(f.centre.y), Float(f.size.x / 2), Float(f.size.y / 2))
            uniforms.ink2b = SIMD4(0, Float(o), blur(o, exiting: time > caption.enteredAt + Self.inkIn), 0)
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
        uniforms.fold = SIMD4(Float(layout.tilt), 1, 0, 0)  // strip 1 gets the accent colour
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
