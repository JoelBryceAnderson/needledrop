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

    private static func render(_ text: String, fontSize: CGFloat, maxWidth: CGFloat, maxLines: Int) -> CGImage? {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 0.92
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])

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
