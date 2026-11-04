import AppKit
import CoreText

/// Renders one lyric line to an image: a bold editorial serif, centred, wrapped to at most
/// `maxLines` (shrinking to fit). White on transparent: the shader prints it in ink.
enum LyricRasterizer {
    /// - Parameters:
    ///   - fontSize: pixels.
    ///   - maxWidth: pixels; text wraps, then shrinks, to stay inside.
    static func image(for text: String, fontSize: CGFloat, maxWidth: CGFloat, maxLines: Int = 2) -> CGImage? {
        var size = fontSize
        for _ in 0..<6 {
            if let image = render(text, fontSize: size, maxWidth: maxWidth, maxLines: maxLines) { return image }
            size *= 0.85
        }
        return render(text, fontSize: size, maxWidth: maxWidth, maxLines: .max)
    }

    /// The now-playing caption: the title in the lyric face, then a smaller regular line,
    /// left-aligned like a label printed in the corner.
    static func caption(title: String, subtitle: String, fontSize: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineHeightMultiple = 0.95
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: serif(fontSize, .bold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ])
        if !subtitle.isEmpty {
            text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                .font: serif(fontSize * 0.6, .regular), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
            ]))
        }
        return draw(text, fontSize: fontSize, maxWidth: maxWidth, maxLines: 3)
    }

    private static func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    private static func render(_ text: String, fontSize: CGFloat, maxWidth: CGFloat, maxLines: Int) -> CGImage? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 0.92
        let attributed = NSAttributedString(string: text, attributes: [
            .font: serif(fontSize, .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        return draw(attributed, fontSize: fontSize, maxWidth: maxWidth, maxLines: maxLines)
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
