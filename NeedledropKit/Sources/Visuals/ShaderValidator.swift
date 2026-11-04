import Foundation
import Metal

/// Checks a Claude-written `customScene` body before it's ever shown: a source screen,
/// a time-boxed compile, a few offscreen frames (no NaNs, not black, not white, not flat),
/// and a frame-time budget. Failures come back as text that can be shown to Claude.
public enum ShaderValidator {
    public enum Outcome: Sendable, Equatable {
        case valid
        case invalid(String)
    }

    public static let maximumLength = 6000
    /// Constructs a fragment body has no business using (resources, preprocessor,
    /// unbounded loops).
    static let banned = ["#", "device ", "threadgroup", "texture", "sampler", "atomic", "while", "do {", "goto", "[["]
    public static let compileTimeout: Duration = .seconds(8)
    /// At the full internal resolution; the real budget is ~16 ms for everything.
    public static let frameBudget = 0.008

    public static func validate(body: String, device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) async -> Outcome {
        guard let device else { return .invalid("No Metal device") }
        if body.count > maximumLength { return .invalid("The body is \(body.count) characters; keep it under \(maximumLength).") }
        if let word = banned.first(where: { body.contains($0) }) {
            return .invalid("The body uses `\(word.trimmingCharacters(in: .whitespaces))`, which isn't allowed in this shader.")
        }
        guard body.contains("return") else { return .invalid("The body never returns a float3 colour.") }

        // Compile, time-boxed: a pathological shader mustn't stall the app.
        let source = Shaders.source(customBody: body)
        let compiled: Result<any MTLRenderPipelineState, any Error>? = await withTaskGroup(of: Result<any MTLRenderPipelineState, any Error>?.self) { group in
            group.addTask { await compile(source, device: device, fragment: "custom_probe_fragment") }
            group.addTask {
                try? await Task.sleep(for: compileTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let pipeline: any MTLRenderPipelineState
        switch compiled {
        case nil: return .invalid("Compiling took longer than \(compileTimeout); simplify it.")
        case .failure(let error): return .invalid("Metal compiler error:\n\(compilerMessage(error))")
        case .success(let p): pipeline = p
        }

        // Look at a few frames under different audio.
        let probes: [(time: Float, bass: Float, beat: Float)] = [(0.5, 0.1, 0), (7.3, 0.8, 1), (31, 0.4, 0.3)]
        for probe in probes {
            guard let pixels = render(pipeline, device: device, width: 160, height: 90, probe: probe) else {
                return .invalid("The shader failed to render.")
            }
            if pixels.contains(where: { !$0.isFinite }) { return .invalid("The shader produces NaN or infinite values (at time \(probe.time)).") }
            var sum = 0.0, sumSquares = 0.0
            var n = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let l = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
                sum += l
                sumSquares += l * l
                n += 1
            }
            let mean = sum / Double(n)
            let deviation = (sumSquares / Double(n) - mean * mean).squareRoot()
            if mean < 0.03 { return .invalid("The frame is almost black (mean luminance \(String(format: "%.3f", mean))) at time \(probe.time).") }
            if mean > 0.97 { return .invalid("The frame is almost white (mean luminance \(String(format: "%.3f", mean))) at time \(probe.time).") }
            if deviation < 0.01 { return .invalid("The frame is a flat colour at time \(probe.time); it needs shapes or variation.") }
        }

        // Frame time at full resolution. Measured twice before rejecting: the GPU is busy
        // drawing the live scene while this runs, and a cold cache inflates the first pass.
        var seconds = gpuTime(pipeline, device: device, width: 854, height: 480)
        if let first = seconds, first > frameBudget {
            try? await Task.sleep(for: .milliseconds(200))
            seconds = gpuTime(pipeline, device: device, width: 854, height: 480)
        }
        if let seconds, seconds > frameBudget {
            return .invalid("A frame takes \(String(format: "%.1f", seconds * 1000)) ms on the GPU at 854×480; it must stay under \(Int(frameBudget * 1000)) ms. Use fewer loop iterations or noise octaves.")
        }
        return .valid
    }

    /// Compiles the full scene source into a pipeline (also used by the renderer).
    static func compile(_ source: String, device: any MTLDevice, format: MTLPixelFormat = .rgba32Float,
                        fragment: String = "scene_fragment") async -> Result<any MTLRenderPipelineState, any Error> {
        do {
            let library = try await device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return .success(try await device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            return .failure(error)
        }
    }

    private static func compilerMessage(_ error: any Error) -> String {
        // Keep it short: the useful part is the first few diagnostics.
        let text = (error as NSError).localizedDescription
        return text.split(separator: "\n").prefix(12).joined(separator: "\n")
    }

    private static func uniforms(width: Int, height: Int, probe: (time: Float, bass: Float, beat: Float)) -> SceneUniforms {
        var u = SceneUniforms()
        u.frame = SIMD4(Float(width), Float(height), probe.time, 1)
        u.audio = SIMD4(probe.bass, 0.4, 0.2, 0.5)
        u.rhythm = SIMD4(probe.beat, 0, 1, 0)
        u.style = SIMD4(3, 0.5, 0.64, 0)
        u.setPalettes(.neutral, .neutral)
        return u
    }

    private static func encode(_ pipeline: any MTLRenderPipelineState, device: any MTLDevice, target: any MTLTexture,
                               probe: (time: Float, bass: Float, beat: Float)) -> (any MTLCommandBuffer)? {
        guard let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var u = uniforms(width: target.width, height: target.height, probe: probe)
        let blank = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false))!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        for i in 0..<7 { encoder.setFragmentTexture(blank, index: i) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return buffer
    }

    private static func target(_ device: any MTLDevice, width: Int, height: Int) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    private static func render(_ pipeline: any MTLRenderPipelineState, device: any MTLDevice, width: Int, height: Int,
                               probe: (time: Float, bass: Float, beat: Float)) -> [Float]? {
        guard let texture = target(device, width: width, height: height),
              let buffer = encode(pipeline, device: device, target: texture, probe: probe) else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    private static func gpuTime(_ pipeline: any MTLRenderPipelineState, device: any MTLDevice, width: Int, height: Int) -> Double? {
        guard let texture = target(device, width: width, height: height) else { return nil }
        var best = Double.infinity
        for _ in 0..<5 {  // best of five: the first runs pay for warm-up
            guard let buffer = encode(pipeline, device: device, target: texture, probe: (12, 0.5, 0.5)) else { return nil }
            buffer.commit()
            buffer.waitUntilCompleted()
            best = min(best, buffer.gpuEndTime - buffer.gpuStartTime)
        }
        return best
    }
}
