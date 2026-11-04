import Foundation
import Metal
import simd

/// A small picture of the background as it is on screen (no words, cover or strip), read back
/// from the GPU every few frames. The lyric layout uses it to find where words will be
/// readable: calm areas (one flat colour, no edges running through) and how light they are.
public struct LayoutField: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Colour 0…1, row by row, top first.
    public let rgb: [SIMD3<Float>]

    public init(width: Int, height: Int, rgb: [SIMD3<Float>]) {
        precondition(rgb.count == width * height)
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    /// From BGRA8 pixels.
    public init(width: Int, height: Int, bgra: [UInt8]) {
        var values = [SIMD3<Float>](repeating: .zero, count: width * height)
        for i in 0..<(width * height) {
            values[i] = SIMD3(Float(bgra[i * 4 + 2]), Float(bgra[i * 4 + 1]), Float(bgra[i * 4])) / 255
        }
        self.init(width: width, height: height, rgb: values)
    }

    static func luminance(_ c: SIMD3<Float>) -> Float { simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }

    /// Colour at a screen point (scene units: x 0…aspect, y 0…1), bilinear.
    public func sample(_ p: SIMD2<Double>, aspect: Double) -> SIMD3<Float> {
        let x = min(Double(width - 1), max(0, p.x / aspect * Double(width) - 0.5))
        let y = min(Double(height - 1), max(0, p.y * Double(height) - 0.5))
        let x0 = Int(x), y0 = Int(y), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> { rgb[y * width + x] }
        return (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy
    }

    /// How a rotated text box would sit: mean lightness under it, and how busy it is (spread of
    /// colour plus the sharpest colour edge inside it — two pieces of equal lightness but
    /// different colour still make an edge). Lower `busyness` reads better.
    public struct Reading: Sendable, Equatable {
        public var mean: Float
        public var busyness: Float
        /// Ink that stands out here: 1 dark, 2 light.
        public var tone: Float { mean > 0.45 ? 1 : 2 }
        /// How far the ground is from the ink's own lightness.
        public var contrast: Float { tone == 1 ? mean - 0.12 : 0.88 - mean }
    }

    public func read(centre: SIMD2<Double>, angle: Double, size: SIMD2<Double>, aspect: Double) -> Reading {
        let d = SIMD2(cos(angle), sin(angle)), n = SIMD2(-sin(angle), cos(angle))
        let columns = 14, rows = 4
        var values: [SIMD3<Float>] = []
        values.reserveCapacity((columns + 1) * (rows + 1))
        // Well past the text's own box, so words never sit right against an edge.
        let padded = size + SIMD2(0.08, 0.06)
        for j in 0...rows {
            for i in 0...columns {
                let p = centre + d * padded.x * (Double(i) / Double(columns) - 0.5) + n * padded.y * (Double(j) / Double(rows) - 0.5)
                values.append(sample(p, aspect: aspect))
            }
        }
        let mean = values.reduce(SIMD3<Float>.zero, +) / Float(values.count)
        let spread = (values.reduce(0) { $0 + simd_length_squared($1 - mean) } / Float(values.count)).squareRoot()
        var edges: Float = 0
        for j in 0...rows {
            for i in 0...columns {
                let here = values[j * (columns + 1) + i]
                if i < columns { edges = max(edges, simd_length(values[j * (columns + 1) + i + 1] - here)) }
                if j < rows { edges = max(edges, simd_length(values[(j + 1) * (columns + 1) + i] - here)) }
            }
        }
        return Reading(mean: Self.luminance(mean), busyness: spread + 1.2 * edges)
    }
}

/// Copies the probe texture back to the CPU off the main thread.
final class LayoutProbe: @unchecked Sendable {
    let width: Int
    let height: Int
    let texture: any MTLTexture
    private let latest = NSLock()
    private var field: LayoutField?

    init(width: Int, height: Int, texture: any MTLTexture) {
        self.width = width
        self.height = height
        self.texture = texture
    }

    var current: LayoutField? {
        latest.lock()
        defer { latest.unlock() }
        return field
    }

    /// Call when the command buffer that rendered the probe has completed.
    func readBack() {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let read = LayoutField(width: width, height: height, bgra: pixels)
        latest.lock()
        field = read
        latest.unlock()
    }
}
