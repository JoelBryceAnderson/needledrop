import Foundation
import Metal
import Testing
@testable import Visuals

/// Suites that render need a Metal device; CI runners may not have one.
enum GPU {
    static let available = MTLCreateSystemDefaultDevice() != nil
}

extension Trait where Self == ConditionTrait {
    static var needsGPU: Self { .enabled(if: GPU.available, "needs a Metal device") }
    /// Checks against real frame times, which a CI runner's virtual GPU can't represent.
    static var needsRealGPUTiming: Self {
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "GPU timing on a CI runner isn't representative")
    }
}

extension VisualsRenderer {
    /// Motion off: these tests check composition, which the choreography would keep moving.
    @MainActor static func still() throws -> VisualsRenderer {
        let renderer = try VisualsRenderer()
        renderer.motion = 0
        renderer.coverInStrip = false
        return renderer
    }
}
