import Metal
import Testing

/// Suites that render need a Metal device; CI runners may not have one.
enum GPU {
    static let available = MTLCreateSystemDefaultDevice() != nil
}

extension Trait where Self == ConditionTrait {
    static var needsGPU: Self { .enabled(if: GPU.available, "needs a Metal device") }
}
