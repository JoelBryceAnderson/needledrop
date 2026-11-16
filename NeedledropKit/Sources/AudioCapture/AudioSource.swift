import AVFAudio
import AVFoundation

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
    /// What TCC says right now, for the log: "authorized", "denied", "restricted" or "not determined".
    public static var statusDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unknown"
        }
    }

    public static var isGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Prompts on first use and waits for the answer. Without access, an input delivers
    /// digital silence rather than failing, and keeps doing so after access is granted
    /// until it's restarted, so callers restart capture once this turns true.
    public static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
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
