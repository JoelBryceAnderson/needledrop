import Foundation
import Visuals

/// A CIE 1931 chromaticity, as Hue lights take colour.
public struct XY: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// D65, where black and greys land.
    public static let white = XY(0.3127, 0.3290)
}

/// The triangle of colours a light can make. Colours outside it are moved to the
/// nearest point on its edge, as the bridge itself would.
public struct Gamut: Sendable, Hashable, Codable {
    public var red: XY
    public var green: XY
    public var blue: XY

    public init(red: XY, green: XY, blue: XY) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Early LivingColors and LightStrips.
    public static let a = Gamut(red: XY(0.704, 0.296), green: XY(0.2151, 0.7106), blue: XY(0.138, 0.08))
    /// First-generation Hue bulbs.
    public static let b = Gamut(red: XY(0.675, 0.322), green: XY(0.409, 0.518), blue: XY(0.167, 0.04))
    /// Current bulbs and strips (and the default when a light doesn't say).
    public static let c = Gamut(red: XY(0.6915, 0.3083), green: XY(0.17, 0.7), blue: XY(0.1532, 0.0475))

    public static func named(_ type: String?) -> Gamut {
        switch type?.uppercased() {
        case "A": .a
        case "B": .b
        default: .c
        }
    }

    public func contains(_ p: XY) -> Bool {
        let d1 = Self.side(p, red, green), d2 = Self.side(p, green, blue), d3 = Self.side(p, blue, red)
        let negative = d1 < 0 || d2 < 0 || d3 < 0
        let positive = d1 > 0 || d2 > 0 || d3 > 0
        return !(negative && positive)
    }

    /// `p` if the light can make it, else the closest colour it can.
    public func clamp(_ p: XY) -> XY {
        guard !contains(p) else { return p }
        let candidates = [Self.closest(p, red, green), Self.closest(p, green, blue), Self.closest(p, blue, red)]
        return candidates.min { Self.distanceSquared($0, p) < Self.distanceSquared($1, p) }!
    }

    private static func side(_ p: XY, _ a: XY, _ b: XY) -> Double {
        (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
    }

    private static func closest(_ p: XY, _ a: XY, _ b: XY) -> XY {
        let abx = b.x - a.x, aby = b.y - a.y
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / (abx * abx + aby * aby)))
        return XY(a.x + abx * t, a.y + aby * t)
    }

    private static func distanceSquared(_ a: XY, _ b: XY) -> Double {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}

public enum HueColor {
    /// sRGB (gamma-encoded) to linear light.
    public static func linear(_ v: Float) -> Double {
        let c = Double(max(0, min(1, v)))
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear light to sRGB (gamma-encoded).
    public static func encoded(_ v: Double) -> Float {
        let c = max(0, min(1, v))
        return Float(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }

    /// Chromaticity of an sRGB colour, inside `gamut`. Brightness is carried separately.
    public static func xy(_ c: RGB, gamut: Gamut = .c) -> XY {
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let x = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        let sum = x + y + z
        guard sum > 1e-6 else { return gamut.clamp(.white) }
        return gamut.clamp(XY(x / sum, y / sum))
    }

    /// Mixes in linear light, so a fade between two colours doesn't dip through grey-brown.
    public static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let t = max(0, min(1, t))
        func m(_ u: Float, _ v: Float) -> Float { encoded(linear(u) * (1 - t) + linear(v) * t) }
        return RGB(m(a.r, b.r), m(a.g, b.g), m(a.b, b.b))
    }

    /// The brightest channel, 0…1: how much light a colour asks for, independent of hue.
    public static func value(_ c: RGB) -> Double { Double(max(c.r, c.g, c.b)) }
}
