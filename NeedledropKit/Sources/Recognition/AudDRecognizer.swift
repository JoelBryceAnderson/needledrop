import AVFAudio
import Foundation
import os
import Secrets
import Synchronization

private let auddLog = Logger(subsystem: "com.needledrop.Needledrop", category: "audd")

/// Sends HTTP requests (URLSession in the app, a fake in tests).
public protocol AudDTransport: Sendable {
    func post(_ request: URLRequest) async throws -> Data
}

extension URLSession: AudDTransport {
    public func post(_ request: URLRequest) async throws -> Data {
        try await data(for: request).0
    }
}

/// Recognises records with AudD (audd.io): one short clip per matching window, sent as a
/// 16 kHz stereo WAV. Stereo matters: on a Mac mini test, clips that missed as mono (at
/// any rate) matched as stereo. For when ShazamKit isn't available (it needs an approved, signed build).
///
/// AudD says where in the song the clip was (to the second). The match is reported with the
/// position at the moment it comes back, so the playback clock and lyrics line up; later
/// re-matches refine it.
public final class AudDRecognizer: StereoTrackRecognizer, @unchecked Sendable {
    /// Seconds of audio sent per window: plenty for AudD, short enough to keep requests small.
    public static let clipSeconds = 9.0
    static let endpoint = URL(string: "https://api.audd.io/")!
    static let uploadRate = 16_000.0

    private let token: String
    private let transport: any AudDTransport
    private var handler: (@Sendable (RecognizerResult) -> Void)?

    // Analysis-thread state.
    private var sampleRate = 48_000.0
    private var left: [Float] = []
    private var right: [Float] = []
    private var sent = false
    private var window = 0
    /// Shared with replies arriving off-thread: the window results are still wanted for, and
    /// whether an error has been reported (once is enough).
    private final class Shared: Sendable {
        let openWindow = Mutex<Int?>(nil)
        let reportedError = Mutex(false)
    }
    private let shared = Shared()

    public init(token: String, transport: any AudDTransport = URLSession.shared) {
        self.token = token
        self.transport = transport
    }

    public func setHandler(_ handler: @escaping @Sendable (RecognizerResult) -> Void) {
        self.handler = handler
    }

    public func beginWindow(sampleRate: Double) {
        self.sampleRate = sampleRate
        let capacity = Int(sampleRate * Self.clipSeconds) + 4096
        left.removeAll(keepingCapacity: true)
        right.removeAll(keepingCapacity: true)
        left.reserveCapacity(capacity)
        right.reserveCapacity(capacity)
        sent = false
        window += 1
        shared.openWindow.withLock { $0 = window }
        auddLog.notice("Window \(self.window) opened at \(sampleRate) Hz")
    }

    public func feed(_ mono: UnsafePointer<Float>, frameCount: Int, endTime: Double) {
        feed(left: mono, right: mono, frameCount: frameCount, endTime: endTime)
    }

    public func feed(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, frameCount: Int, endTime: Double) {
        guard !sent else { return }
        left.append(contentsOf: UnsafeBufferPointer(start: l, count: frameCount))
        right.append(contentsOf: UnsafeBufferPointer(start: r, count: frameCount))
        guard Double(left.count) >= sampleRate * Self.clipSeconds else { return }
        sent = true
        let peak = left.reduce(Float(0)) { max($0, abs($1)) }
        auddLog.notice("Window \(self.window): sending \(Self.clipSeconds) s clip, peak \(String(format: "%.1f", peak > 0 ? 20 * log10(peak) : -120), privacy: .public) dB")
        let wav = Self.wav(Self.resample([left, right], from: sampleRate, to: Self.uploadRate), sampleRate: Self.uploadRate)
        Self.saveDebugClip(wav, window: window)
        let request = Self.request(token: token, wav: wav)
        let mine = window, sentAt = ContinuousClock.now
        let transport = self.transport, handler = self.handler
        let shared = self.shared
        Task.detached {
            do {
                let data = try await transport.post(request)
                // A window that has closed (the session moved on) doesn't want it any more.
                let reply = try Self.parse(data)
                auddLog.notice("Window \(mine): reply after \(ContinuousClock.now - sentAt, privacy: .public): \(Self.summary(reply, data), privacy: .public)")
                guard shared.openWindow.withLock({ $0 == mine }) else {
                    auddLog.notice("Window \(mine) closed before the reply; ignoring it")
                    return
                }
                switch reply {
                case .match(var match, let clipStart):
                    let elapsed = ContinuousClock.now - sentAt
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    match.position = clipStart + Self.clipSeconds + seconds
                    handler?(.match(match))
                case .noMatch:
                    break
                case .failure(let message):
                    if !shared.reportedError.withLock({ let was = $0; $0 = true; return was }) { handler?(.error(message)) }
                }
            } catch {
                auddLog.error("Window \(mine): request failed: \(error.localizedDescription, privacy: .public)")
                if !shared.reportedError.withLock({ let was = $0; $0 = true; return was }) {
                    handler?(.error("AudD: \(error.localizedDescription)"))
                }
            }
        }
    }

    public func endWindow() {
        left.removeAll(keepingCapacity: true)
        right.removeAll(keepingCapacity: true)
        shared.openWindow.withLock { $0 = nil }
    }

    // MARK: - Request and reply

    static func request(token: String, wav: Data) -> URLRequest {
        let boundary = "needledrop-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("api_token", token)
        field("return", "apple_music")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    enum Reply: Equatable {
        /// The track, and where in it the clip started (seconds).
        case match(TrackMatch, clipStart: Double)
        case noMatch
        case failure(String)
    }

    static func parse(_ data: Data) throws -> Reply {
        struct Body: Decodable {
            struct AudDError: Decodable {
                var error_code: Int?
                var error_message: String?
            }
            struct AppleMusic: Decodable {
                struct Artwork: Decodable { var url: String? }
                struct PlayParams: Decodable { var id: String? }
                var isrc: String?
                var durationInMillis: Double?
                var artwork: Artwork?
                var playParams: PlayParams?
            }
            struct Result: Decodable {
                var artist: String?
                var title: String?
                var album: String?
                var timecode: String?
                var apple_music: AppleMusic?
            }
            var status: String?
            var result: Result?
            var error: AudDError?
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        if body.status != "success" {
            let message = body.error?.error_message ?? "unknown error"
            return .failure("AudD couldn't recognise: \(message)" + (body.error?.error_code.map { " (\($0))" } ?? ""))
        }
        guard let result = body.result, let title = result.title, let artist = result.artist else { return .noMatch }
        var match = TrackMatch(title: title, artist: artist)
        let apple = result.apple_music
        match.appleMusicID = apple?.playParams?.id
        match.isrc = apple?.isrc
        match.albumHint = result.album
        match.durationHint = apple?.durationInMillis.map { $0 / 1000 }
        match.artworkURL = apple?.artwork?.url.flatMap {
            URL(string: $0.replacingOccurrences(of: "{w}", with: "1200").replacingOccurrences(of: "{h}", with: "1200"))
        }
        return .match(match, clipStart: timecode(result.timecode ?? "") ?? 0)
    }

    /// Debug builds keep the last few clips sent, to listen to what AudD heard:
    /// ~/Library/Application Support/Needledrop/Debug/audd-clip-N.wav.
    static func saveDebugClip(_ wav: Data, window: Int) {
        #if DEBUG
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("Needledrop/Debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? wav.write(to: dir.appendingPathComponent("audd-clip-\(window % 5).wav"))
        #endif
    }

    /// For the log: what came back, never the request (it carries the token).
    static func summary(_ reply: Reply, _ data: Data) -> String {
        switch reply {
        case .match(let match, let clipStart): "match \(match.artist) — \(match.title) at \(clipStart) s"
        case .noMatch: "no match (\(String(decoding: data.prefix(200), as: UTF8.self)))"
        case .failure(let message): message
        }
    }

    /// "1:23" or "01:02:03" → seconds.
    static func timecode(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }

    // MARK: - Audio

    /// Down to `rate` with AVAudioConverter (properly band-limited: a crude average let
    /// aliasing through, and AudD missed clips it matched once resampled properly).
    /// `channels` are planar and equally long.
    static func resample(_ channels: [[Float]], from source: Double, to rate: Double) -> [[Float]] {
        guard source != rate, let count = channels.first?.count, count > 0,
              let inFormat = AVAudioFormat(standardFormatWithSampleRate: source, channels: AVAudioChannelCount(channels.count)),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count)),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(count)),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: AVAudioFrameCount(Double(count) * rate / source) + 1024)
        else { return channels }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(count)
        for (c, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { input.floatChannelData![c].update(from: $0.baseAddress!, count: count) }
        }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        guard error == nil else { return channels }
        let n = Int(output.frameLength)
        return (0..<channels.count).map { Array(UnsafeBufferPointer(start: output.floatChannelData![$0], count: n)) }
    }

    static func resample(_ input: [Float], from source: Double, to rate: Double) -> [Float] {
        resample([input], from: source, to: rate).first ?? input
    }

    /// 16-bit PCM WAV, interleaving the planar `channels`.
    static func wav(_ channels: [[Float]], sampleRate: Double) -> Data {
        let count = channels.map(\.count).min() ?? 0
        var pcm = Data(capacity: count * channels.count * 2)
        for i in 0..<count {
            for channel in channels {
                var v = Int16(max(-1, min(1, channel[i])) * Float(Int16.max)).littleEndian
                withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
            }
        }
        var header = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate), n = UInt16(channels.count)
        header.append(Data("RIFF".utf8)); u32(36 + UInt32(pcm.count)); header.append(Data("WAVE".utf8))
        header.append(Data("fmt ".utf8)); u32(16); u16(1); u16(n); u32(rate); u32(rate * UInt32(n) * 2); u16(n * 2); u16(16)
        header.append(Data("data".utf8)); u32(UInt32(pcm.count))
        return header + pcm
    }

    static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        wav([samples], sampleRate: sampleRate)
    }
}

/// The AudD API token, in a file only this user can read (see `SecretStore`).
public enum AudDTokenStore {
    static let name = "audd-api-token"

    /// The saved token, else `AUDD_API_TOKEN` from the environment (handy in development).
    public static func load() -> String? {
        SecretStore.loadString(name, environment: "AUDD_API_TOKEN")
    }

    /// Saves (or, with an empty string, deletes) the token.
    @discardableResult
    public static func save(_ token: String) -> Bool {
        SecretStore.saveString(name, token)
    }
}
