import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flat geometric album covers drawn from scratch: royalty-free artwork for the demo side
/// and for tests, in a few bold colours so palette extraction has something to find.
public enum CoverArtGenerator {
    public struct Scheme: Sendable {
        public var background: CGColor
        public var colors: [CGColor]
    }

    /// Deep teal, ochre sun, rust stripes, cream — for the demo album, "Crease Patterns".
    public static let paperWeather = Scheme(
        background: CGColor(srgbRed: 0.07, green: 0.20, blue: 0.23, alpha: 1),
        colors: [
            CGColor(srgbRed: 0.91, green: 0.64, blue: 0.24, alpha: 1),
            CGColor(srgbRed: 0.78, green: 0.33, blue: 0.24, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.91, blue: 0.81, alpha: 1),
        ]
    )

    public static func png(title: String, scheme: Scheme = paperWeather, size: Int = 1200) -> Data? {
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(scheme.background)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        // Horizon stripes.
        ctx.setFillColor(scheme.colors[1])
        for i in 0..<4 {
            let h = s * 0.035
            ctx.fill(CGRect(x: 0, y: s * (0.12 + Double(i) * 0.075), width: s, height: h))
        }
        // A setting sun, cut by the horizon.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: s * 0.38, width: s, height: s))
        ctx.setFillColor(scheme.colors[0])
        ctx.fillEllipse(in: CGRect(x: s * 0.22, y: s * 0.18, width: s * 0.56, height: s * 0.56))
        ctx.restoreGState()
        // A folded-paper triangle.
        ctx.setFillColor(scheme.colors[2])
        ctx.move(to: CGPoint(x: s * 0.62, y: s * 0.38))
        ctx.addLine(to: CGPoint(x: s * 0.86, y: s * 0.38))
        ctx.addLine(to: CGPoint(x: s * 0.74, y: s * 0.62))
        ctx.closePath()
        ctx.fillPath()

        // Title, small, top-left.
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, s * 0.055, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title.uppercased(), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): scheme.colors[2],
        ]))
        ctx.textPosition = CGPoint(x: s * 0.07, y: s * 0.88)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
