import AVFAudio

public struct CaptureFormat: Sendable, Hashable, Codable, CustomStringConvertible {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var description: String {
        let khz = sampleRate / 1000
        let rate = khz.rounded() == khz ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
        return "\(rate) kHz · \(channelCount) ch"
    }
}

public enum SourceStatus: Sendable, Equatable {
    /// Audio is flowing (or about to). Sources report this *before* their first write so
    /// the consumer can configure itself for the format.
    case running(CaptureFormat, sourceName: String)
    case waitingForDevice(String)
    case finished
    case failed(String)
}

/// Something that produces PCM into a ring buffer: a live interface or a replayed file.
/// Both go through exactly the same downstream path.
public protocol AudioSource: AnyObject, Sendable {
    var displayName: String { get }
    func start(writingTo ring: AudioRingBuffer, status: @escaping @Sendable (SourceStatus) -> Void) throws
    func stop()
}

extension AudioRingBuffer {
    /// Writes a deinterleaved float buffer (what AVAudioEngine taps and AVAudioFile deliver).
    @discardableResult
    public func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData, !buffer.format.isInterleaved else { return false }
        return write(frameCount: Int(buffer.frameLength), channelCount: Int(buffer.format.channelCount)) {
            UnsafePointer(data[$0])
        }
    }
}

public enum MicrophoneAccess {
    /// Prompts on first use. Without access, AVAudioEngine delivers silence rather than failing.
    public static func request() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}

/// Gets the analysed PCM, hop by hop, on the analysis thread (never the capture thread).
/// Recognition and, later, the archive hang off this. Implementations must not block.
public protocol AudioObserver: AnyObject, Sendable {
    /// `endTime` is the audio time (seconds) at the end of this block.
    func observe(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int,
                 endTime: Double, sampleRate: Double)
}
