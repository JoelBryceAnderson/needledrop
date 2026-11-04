import AppKit
import CoreText

/// Renders one lyric line to an image: a bold editorial serif, centred, wrapped to at most
/// `maxLines` (shrinking to fit). White on transparent: the shader prints it in ink.
enum LyricRasterizer {
    /// - Parameters:
    ///   - fontSize: pixels.
    ///   - maxWidth: pixels; text wraps, then shrinks, to stay inside.
    static func image(for text: String, fontSize: CGFloat, maxWidth: CGFloat, maxLines: Int = 2,
                      font: LookStyle.Font = .serif, weight: LookStyle.Weight = .bold) -> CGImage? {
        var size = fontSize
        for _ in 0..<6 {
            if let image = render(text, fontSize: size, maxWidth: maxWidth, maxLines: maxLines, font: font, weight: weight) {
                return image
            }
            size *= 0.85
        }
        return render(text, fontSize: size, maxWidth: maxWidth, maxLines: .max, font: font, weight: weight)
    }

    /// The now-playing caption: the title in the lyric face, then a smaller regular line,
    /// left-aligned like a label printed in the corner.
    static func caption(title: String, subtitle: String, font: LookStyle.Font = .serif,
                        fontSize: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineHeightMultiple = 0.95
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: typeface(font, .bold, fontSize), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ])
        if !subtitle.isEmpty {
            text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                .font: typeface(font, .regular, fontSize * 0.6), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
            ]))
        }
        return draw(text, fontSize: fontSize, maxWidth: maxWidth, maxLines: 3)
    }

    /// The art direction's typeface. All ship with macOS, so nothing needs licensing.
    static func typeface(_ font: LookStyle.Font, _ weight: LookStyle.Weight, _ size: CGFloat) -> NSFont {
        let w: NSFont.Weight = switch weight {
        case .regular: .regular
        case .bold: .bold
        case .heavy: .heavy
        }
        func designed(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: w)
            return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
        switch font {
        case .serif: return designed(.serif)
        case .sans: return NSFont.systemFont(ofSize: size, weight: w)
        case .rounded: return designed(.rounded)
        case .mono: return designed(.monospaced)
        case .condensed:
            return NSFont(name: weight == .regular ? "AvenirNextCondensed-Medium" : "AvenirNextCondensed-Heavy", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: w)
        case .geometric:
            return NSFont(name: weight == .regular ? "Futura-Medium" : "Futura-Bold", size: size)
                ?? designed(.rounded)
        }
    }

    private static func render(_ text: String, fontSize: CGFloat, maxWidth: CGFloat, maxLines: Int,
                               font: LookStyle.Font, weight: LookStyle.Weight) -> CGImage? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 0.92
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: typeface(font, weight, fontSize),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        // Word i is drawn with red = (i + 0.5) / n, so the shader can print words one at a
        // time (typewriter). Only alpha is used for the ink itself.
        let ranges = wordRanges(text)
        for (i, range) in ranges.enumerated() {
            let value = (CGFloat(i) + 0.5) / CGFloat(ranges.count)
            attributed.addAttribute(.foregroundColor, value: NSColor(srgbRed: value, green: 1, blue: 1, alpha: 1), range: range)
        }
        return draw(attributed, fontSize: fontSize, maxWidth: maxWidth, maxLines: maxLines)
    }

    /// Whitespace-separated words, matching `WordTiming.words`.
    static func wordRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "\\S+")
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    private static func draw(_ attributed: NSAttributedString, fontSize: CGFloat, maxWidth: CGFloat, maxLines: Int) -> CGImage? {

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: fit), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard lines.count <= maxLines else { return nil }

        // Padding so blurred mips (the ink bleeding in) aren't clipped.
        let pad = ceil(fontSize * 0.35)
        let width = Int(ceil(fit.width + pad * 2)), height = Int(ceil(fit.height + pad * 2))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: pad, y: pad)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(),
                                             CGPath(rect: CGRect(origin: .zero, size: CGSize(width: fit.width, height: fit.height)), transform: nil),
                                             nil), context)
        return context.makeImage()
    }
}
