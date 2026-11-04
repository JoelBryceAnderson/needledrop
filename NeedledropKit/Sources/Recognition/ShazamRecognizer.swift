import AVFAudio
import Foundation
import ShazamKit

/// ShazamKit catalog matching over streamed buffers.
///
/// Needs the ShazamKit App Service enabled for the app's bundle ID and a signed build;
/// without it every attempt fails, and the error is reported once per window.
public final class ShazamRecognizer: TrackRecognizer, @unchecked Sendable {
    private static let supportedRates: Set<Double> = [48_000, 44_100, 32_000, 16_000]
    private static let blockSeconds = 0.5

    private var handler: (@Sendable (RecognizerResult) -> Void)?
    private var session: SHSession?
    private var delegate: Delegate?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var block: AVAudioPCMBuffer?

    public init() {}

    public func setHandler(_ handler: @escaping @Sendable (RecognizerResult) -> Void) {
        self.handler = handler
    }

    public func beginWindow(sampleRate: Double) {
        let session = SHSession()
        let delegate = Delegate(handler: handler)
        session.delegate = delegate
        self.session = session
        self.delegate = delegate

        if inputFormat?.sampleRate != sampleRate {
            inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            let outRate = Self.supportedRates.contains(sampleRate) ? sampleRate : 48_000
            outputFormat = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 1)
            converter = outRate == sampleRate ? nil : inputFormat.flatMap { input in
                outputFormat.flatMap { AVAudioConverter(from: input, to: $0) }
            }
            block = inputFormat.flatMap {
                AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(sampleRate * Self.blockSeconds))
            }
        }
        block?.frameLength = 0
    }

    public func feed(_ mono: UnsafePointer<Float>, frameCount: Int, endTime: Double) {
        guard let block, let data = block.floatChannelData?[0] else { return }
        var consumed = 0
        while consumed < frameCount {
            let space = Int(block.frameCapacity - block.frameLength)
            let n = min(space, frameCount - consumed)
            (data + Int(block.frameLength)).update(from: mono + consumed, count: n)
            block.frameLength += AVAudioFrameCount(n)
            consumed += n
            if block.frameLength == block.frameCapacity {
                submit(block)
                block.frameLength = 0
            }
        }
    }

    public func endWindow() {
        session = nil
        delegate = nil
        block?.frameLength = 0
    }

    private func submit(_ buffer: AVAudioPCMBuffer) {
        guard let session else { return }
        guard let converter, let outputFormat else {
            session.matchStreamingBuffer(buffer, at: nil)
            return
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        ) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil { session.matchStreamingBuffer(converted, at: nil) }
    }

    private final class Delegate: NSObject, SHSessionDelegate, @unchecked Sendable {
        let handler: (@Sendable (RecognizerResult) -> Void)?
        private var reportedError = false

        init(handler: (@Sendable (RecognizerResult) -> Void)?) {
            self.handler = handler
        }

        func session(_ session: SHSession, didFind match: SHMatch) {
            guard let item = match.mediaItems.first else { return }
            handler?(.match(TrackMatch(
                title: item.title ?? "Unknown title",
                artist: item.artist ?? "Unknown artist",
                appleMusicID: item.appleMusicID,
                isrc: item.isrc,
                shazamID: item.shazamID,
                artworkURL: item.artworkURL,
                position: item.predictedCurrentMatchOffset,
                frequencySkew: Double(item.frequencySkew)
            )))
        }

        func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
            // Plain no-matches are normal mid-window; only surface real failures, once.
            guard let error, !reportedError else { return }
            reportedError = true
            handler?(.error("ShazamKit: \(error.localizedDescription)"))
        }
    }
}
