/// Recognition switched off: listens to nothing and never answers, so no audio leaves the Mac.
/// Tracks stay unnamed unless named by hand (What's Playing?) or by a music app.
public final class NoRecognizer: TrackRecognizer, Sendable {
    public init() {}
    public func setHandler(_ handler: @escaping @Sendable (RecognizerResult) -> Void) {}
    public func beginWindow(sampleRate: Double) {}
    public func feed(_ mono: UnsafePointer<Float>, frameCount: Int, endTime: Double) {}
    public func endWindow() {}
}
