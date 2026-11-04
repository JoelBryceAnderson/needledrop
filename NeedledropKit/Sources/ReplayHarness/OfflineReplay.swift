import AVFAudio
import AudioCapture
import Foundation
import Pipeline
import SessionState
import SignalAnalysis

public struct OfflineReplayResult: Sendable {
    public var format: CaptureFormat
    /// Seconds of audio analysed, including trailing silence.
    public var duration: Double
    public var events: [SideEvent]
    /// Every hop's features (empty unless requested).
    public var timeline: [AudioFeatures]
    public var peak: Float
    public var clippedSamples: Int
}

/// Runs audio through `AnalysisCore` as fast as possible. Same code path as live, minus
/// the ring buffer and thread — results are deterministic.
public enum OfflineReplay {
    public static func analyze(
        url: URL,
        config: SideDetectorConfig = SideDetectorConfig(),
        trailingSilence: Double = 12,
        keepTimeline: Bool = false
    ) throws -> OfflineReplayResult {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let core = AnalysisCore(sampleRate: format.sampleRate, config: config)
        let hop = AVAudioFrameCount(core.hopSize)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hop),
              let data = buffer.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let channels = Int(format.channelCount)
        var accumulator = Accumulator(core: core, keepTimeline: keepTimeline)

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: hop)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            if frames < Int(hop) {
                for c in 0..<channels { (data[c] + frames).update(repeating: 0, count: Int(hop) - frames) }
            }
            accumulator.feed(left: data[0], right: channels > 1 ? data[1] : nil)
        }
        accumulator.feedSilence(seconds: trailingSilence, sampleRate: format.sampleRate)
        return accumulator.result(format: CaptureFormat(sampleRate: format.sampleRate, channelCount: channels))
    }

    /// Analyses in-memory planar audio (tests, synthetic fixtures).
    public static func analyze(
        left: [Float],
        right: [Float]?,
        sampleRate: Double,
        config: SideDetectorConfig = SideDetectorConfig(),
        trailingSilence: Double = 12,
        keepTimeline: Bool = false
    ) -> OfflineReplayResult {
        let core = AnalysisCore(sampleRate: sampleRate, config: config)
        let hop = core.hopSize
        var accumulator = Accumulator(core: core, keepTimeline: keepTimeline)
        var l = [Float](repeating: 0, count: hop)
        var r = [Float](repeating: 0, count: hop)
        var position = 0
        while position < left.count {
            let n = min(hop, left.count - position)
            for i in 0..<hop {
                l[i] = i < n ? left[position + i] : 0
                r[i] = i < n ? (right?[position + i] ?? left[position + i]) : 0
            }
            accumulator.feed(left: l, right: right == nil ? nil : r)
            position += hop
        }
        accumulator.feedSilence(seconds: trailingSilence, sampleRate: sampleRate)
        return accumulator.result(format: CaptureFormat(sampleRate: sampleRate, channelCount: right == nil ? 1 : 2))
    }

    private struct Accumulator {
        let core: AnalysisCore
        let keepTimeline: Bool
        var events: [SideEvent] = []
        var timeline: [AudioFeatures] = []
        var peak: Float = 0
        var clipped = 0
        var lastTime = 0.0

        init(core: AnalysisCore, keepTimeline: Bool) {
            self.core = core
            self.keepTimeline = keepTimeline
        }

        mutating func feed(left: UnsafePointer<Float>, right: UnsafePointer<Float>?) {
            let (features, newEvents) = core.process(left: left, right: right)
            events += newEvents
            if keepTimeline { timeline.append(features) }
            peak = max(peak, features.peak)
            clipped += features.clippedSamples
            lastTime = features.time
        }

        mutating func feedSilence(seconds: Double, sampleRate: Double) {
            let zeros = [Float](repeating: 0, count: core.hopSize)
            for _ in 0..<Int(seconds * sampleRate) / core.hopSize {
                feed(left: zeros, right: zeros)
            }
        }

        func result(format: CaptureFormat) -> OfflineReplayResult {
            OfflineReplayResult(format: format, duration: lastTime, events: events, timeline: timeline,
                                peak: peak, clippedSamples: clipped)
        }
    }
}
