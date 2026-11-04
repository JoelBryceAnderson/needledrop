import SessionState
import SignalAnalysis

/// The deterministic heart of the pipeline: feature extraction + side detection, one hop
/// at a time. Live capture and offline replay both drive exactly this.
public final class AnalysisCore {
    public let parameters: AnalysisParameters
    public let extractor: FeatureExtractor
    public var detector: SideDetector

    public init(sampleRate: Double, config: SideDetectorConfig) {
        parameters = .standard(sampleRate: sampleRate)
        extractor = FeatureExtractor(parameters: parameters)
        detector = SideDetector(config: config)
    }

    public var hopSize: Int { parameters.hopSize }

    /// Processes exactly `hopSize` frames.
    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>?) -> (features: AudioFeatures, events: [SideEvent]) {
        let features = extractor.process(left: left, right: right)
        return (features, detector.process(features))
    }
}
