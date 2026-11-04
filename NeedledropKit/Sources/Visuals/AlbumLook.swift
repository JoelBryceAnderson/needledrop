import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Everything the renderer needs to draw one album: its palette, artwork, and a subject
/// mask (the part of the cover that floats forward in "living cover").
public struct AlbumLook: @unchecked Sendable {  // CGImage is immutable
    public var id: String
    public var palette: Palette
    public var artwork: CGImage?
    public var subjectMask: CGImage?

    public init(id: String, palette: Palette, artwork: CGImage? = nil, subjectMask: CGImage? = nil) {
        self.id = id
        self.palette = palette
        self.artwork = artwork
        self.subjectMask = subjectMask
    }

    /// Unknown records and the moments before the first match.
    public static let neutral = AlbumLook(id: "neutral", palette: .neutral)

    /// Builds a look from artwork off the main thread: palette (k-means) and subject mask
    /// (Vision foreground segmentation). Covers with no clear subject — type, abstract
    /// art — get no mask and simply drift as a whole.
    public static func make(id: String, artwork: CGImage) async -> AlbumLook {
        await Task.detached(priority: .userInitiated) {
            AlbumLook(
                id: id,
                palette: PaletteExtractor.extract(from: artwork),
                artwork: artwork,
                subjectMask: SubjectMasker.mask(for: artwork)
            )
        }.value
    }
}

enum SubjectMasker {
    /// Soft-edged greyscale mask of the foreground subjects, or nil if Vision finds none.
    static func mask(for image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            let mask = CIImage(cvPixelBuffer: buffer)
            // Feather the cut-out: hard edges shimmer when layers move at 480 lines.
            let radius = Double(max(mask.extent.width, mask.extent.height)) / 200
            let feathered = mask.clampedToExtent()
                .applyingGaussianBlur(sigma: radius)
                .cropped(to: mask.extent)
            return CIContext().createCGImage(feathered, from: mask.extent, format: .L8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.linearGray))
        } catch {
            return nil
        }
    }
}
