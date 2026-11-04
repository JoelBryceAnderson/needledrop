import CoreGraphics
import Foundation

/// sRGB colour, components 0…1 (gamma-encoded, as shaders and artwork use them).
public struct RGB: Sendable, Equatable, Codable {
    public var r: Float
    public var g: Float
    public var b: Float

    public init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
    }

    public var simd: SIMD4<Float> { SIMD4(r, g, b, 1) }

    public var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// The colours that drive a scene, most dominant first. Always `Palette.size` entries.
public struct Palette: Sendable, Equatable, Codable {
    public static let size = 6

    public var colors: [RGB]
    /// Share of the image each colour covers (sums to 1).
    public var weights: [Float]

    public init(colors: [RGB], weights: [Float]? = nil) {
        precondition(!colors.isEmpty)
        self.colors = (0..<Self.size).map { colors[$0 % colors.count] }
        let w = weights ?? Array(repeating: 1, count: colors.count)
        let padded = (0..<Self.size).map { $0 < w.count ? w[$0] : 0 }
        let total = max(padded.reduce(0, +), 1e-6)
        self.weights = padded.map { $0 / total }
    }

    /// Unrecognised records and the moments before the first match: deep, calm, not grey.
    public static let neutral = Palette(colors: [
        RGB(hex: 0x1B1F3B), RGB(hex: 0x3A2F6B), RGB(hex: 0x1E5A7A),
        RGB(hex: 0x6B3A73), RGB(hex: 0x24456B), RGB(hex: 0x0F1226),
    ])
}

/// Dominant colours by k-means in CIELAB (perceptually even, so clusters match what the
/// eye groups), on a 64×64 downsample. Deterministic for a given image.
public enum PaletteExtractor {
    public static func extract(from image: CGImage, count: Int = Palette.size, iterations: Int = 12) -> Palette {
        let pixels = samples(from: image, side: 64)
        guard pixels.count >= count else { return .neutral }
        let lab = pixels.map(Lab.init(rgb:))

        // k-means++ seeding with a fixed seed.
        var rng = SeededRandom(seed: 0x5EED)
        var centres = [lab[Int(rng.next() % UInt64(lab.count))]]
        var nearest = lab.map { $0.distanceSquared(to: centres[0]) }
        while centres.count < count {
            let total = nearest.reduce(0, +)
            guard total > 0 else { break }
            var pick = Float(rng.unit()) * total
            var index = 0
            for (i, d) in nearest.enumerated() {
                pick -= d
                if pick <= 0 { index = i; break }
            }
            centres.append(lab[index])
            for i in lab.indices { nearest[i] = min(nearest[i], lab[i].distanceSquared(to: centres.last!)) }
        }

        var assignment = [Int](repeating: 0, count: lab.count)
        for _ in 0..<iterations {
            for (i, p) in lab.enumerated() {
                assignment[i] = centres.indices.min { p.distanceSquared(to: centres[$0]) < p.distanceSquared(to: centres[$1]) }!
            }
            var sums = [Lab](repeating: Lab(l: 0, a: 0, b: 0), count: centres.count)
            var counts = [Int](repeating: 0, count: centres.count)
            for (i, p) in lab.enumerated() {
                sums[assignment[i]].add(p)
                counts[assignment[i]] += 1
            }
            for k in centres.indices where counts[k] > 0 {
                centres[k] = sums[k].scaled(by: 1 / Float(counts[k]))
            }
        }

        var counts = [Int](repeating: 0, count: centres.count)
        for a in assignment { counts[a] += 1 }
        let order = centres.indices.filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }
        return Palette(colors: order.map { centres[$0].rgb }, weights: order.map { Float(counts[$0]) })
    }

    /// RGBA8 pixels of `image` scaled to `side`×`side`, as sRGB floats.
    static func samples(from image: CGImage, side: Int) -> [RGB] {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        var pixels: [RGB] = []
        pixels.reserveCapacity(side * side)
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] >= 128 {
            let r = Float(bytes[i]) / 255
            let g = Float(bytes[i + 1]) / 255
            let b = Float(bytes[i + 2]) / 255
            pixels.append(RGB(r, g, b))
        }
        return pixels
    }
}

// MARK: - CIELAB (D65)

struct Lab: Equatable {
    var l: Float
    var a: Float
    var b: Float

    init(l: Float, a: Float, b: Float) {
        self.l = l
        self.a = a
        self.b = b
    }

    init(rgb c: RGB) {
        func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
        let r = linear(c.r), g = linear(c.g), bl = linear(c.b)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }
        l = 116 * f(y) - 16
        a = 500 * (f(x) - f(y))
        b = 200 * (f(y) - f(z))
    }

    var rgb: RGB {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func inverse(_ t: Float) -> Float { t * t * t > 0.008856 ? t * t * t : (t - 16 / 116) / 7.787 }
        let x = inverse(fx) * 0.95047, y = inverse(fy), z = inverse(fz) * 1.08883
        let r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let g = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let bl = 0.0557 * x - 0.2040 * y + 1.0570 * z
        func encode(_ v: Float) -> Float {
            let c = max(0, min(1, v))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * powf(c, 1 / 2.4) - 0.055
        }
        return RGB(encode(r), encode(g), encode(bl))
    }

    func distanceSquared(to o: Lab) -> Float {
        let dl = l - o.l, da = a - o.a, db = b - o.b
        return dl * dl + da * da + db * db
    }

    mutating func add(_ o: Lab) {
        l += o.l
        a += o.a
        b += o.b
    }

    func scaled(by s: Float) -> Lab { Lab(l: l * s, a: a * s, b: b * s) }
}

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
