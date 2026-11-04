import CoreGraphics
import Testing
@testable import Visuals

@Suite struct CaptionRasterTests {
    @Test func captionHasTitleAndSubtitle() throws {
        let image = try #require(LyricRasterizer.caption(title: "Sample Track", subtitle: "Sample Artist  ·  Sample Album",
                                                         fontSize: 67, maxWidth: 864))
        // Title line (67 px) + subtitle line (40 px) + padding: well over one line tall, and wide
        // enough for the whole title.
        #expect(image.height > 67 + 40)
        #expect(image.width > 300, "width \(image.width), height \(image.height)")
    }
}
