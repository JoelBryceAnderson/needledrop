import AVFAudio
import AudioCapture
import Foundation
import Synchronization

/// A finished side recording: raw float CAF plus a coarse loudness envelope for splitting.
public struct RecordedSide: Sendable {
    public var url: URL
    /// Audio time of the file's first frame.
    public var startTime: Double
    public var sampleRate: Double
    public var frameCount: Int
    /// RMS (dBFS) per `envelopeInterval`, from `startTime`.
    public var envelope: [Float]
    public static let envelopeInterval = 0.1

    public var duration: Double { Double(frameCount) / sampleRate }
    public var endTime: Double { startTime + duration }
}

/// Records sides from the analysis thread. It always keeps `preRoll` seconds of audio, so
/// a recording can begin *before* the moment it was asked to (side starts are confirmed
/// ~1.5 s after the music begins). Disk writes happen on a private queue.
public final class SideRecorder: AudioObserver, @unchecked Sendable {
    public let preRoll: Double

    private enum Command {
        case begin(url: URL, from: Double)
        case finish(CheckedContinuation<RecordedSide?, Never>)
        case cancel
    }

    private let commands = Mutex<[Command]>([])
    private let writerQueue = DispatchQueue(label: "needledrop.archive.writer")
    private let recordingFlag = Atomic<Bool>(false)

    // Analysis-thread state.
    private var sampleRate = 0.0
    private var ring: [[Float]] = [[], []]
    private var ringWrite = 0
    private var ringFilled = 0
    private var latestTime = 0.0
    private var session: Session?

    /// One recording in progress.
    private final class Session: @unchecked Sendable {
        let url: URL
        let startTime: Double
        let format: AVAudioFormat
        var file: AVAudioFile?
        var error: (any Error)?
        var staging: AVAudioPCMBuffer
        var frames = 0
        var envelope: [Float] = []
        var envelopeSum: Double = 0
        var envelopeCount = 0
        let envelopeBlock: Int

        init(url: URL, startTime: Double, format: AVAudioFormat) throws {
            self.url = url
            self.startTime = startTime
            self.format = format
            file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            staging = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 2))!
            envelopeBlock = Int(format.sampleRate * RecordedSide.envelopeInterval)
        }
    }

    public init(preRoll: Double = 6) {
        self.preRoll = preRoll
    }

    public var isRecording: Bool { recordingFlag.load(ordering: .acquiring) }

    /// Starts recording to `url` (CAF, float32, source rate) from audio time `from` — which
    /// may be up to `preRoll` seconds in the past.
    public func begin(writingTo url: URL, from time: Double) {
        commands.withLock { $0.append(.begin(url: url, from: time)) }
    }

    /// Stops and returns what was recorded (nil if nothing was).
    public func finish() async -> RecordedSide? {
        await withCheckedContinuation { continuation in
            commands.withLock { $0.append(.finish(continuation)) }
        }
    }

    /// Stops and deletes the recording.
    public func cancel() {
        commands.withLock { $0.append(.cancel) }
    }

    // MARK: - Analysis thread

    public func observe(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int,
                        endTime: Double, sampleRate: Double) {
        if sampleRate != self.sampleRate { resetRing(sampleRate: sampleRate) }
        for command in commands.withLock({ c -> [Command] in defer { c = [] }; return c }) {
            run(command)
        }
        latestTime = endTime

        session.map { append(left: left, right: right, count: frameCount, to: $0) }

        let capacity = ring[0].count
        for i in 0..<frameCount {
            ring[0][ringWrite] = left[i]
            ring[1][ringWrite] = right[i]
            ringWrite = (ringWrite + 1) % capacity
        }
        ringFilled = min(ringFilled + frameCount, capacity)
    }

    private func resetRing(sampleRate: Double) {
        self.sampleRate = sampleRate
        let capacity = Int(preRoll * sampleRate)
        ring = [[Float](repeating: 0, count: capacity), [Float](repeating: 0, count: capacity)]
        ringWrite = 0
        ringFilled = 0
        if let session { close(session, keep: false) }
        session = nil
    }

    private func run(_ command: Command) {
        switch command {
        case .begin(let url, let from):
            if let session { close(session, keep: false) }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
            // Pre-roll: as much of the ring as reaches back to `from`.
            let wanted = Int(max(0, latestTime - from) * sampleRate)
            let take = min(wanted, ringFilled)
            do {
                let session = try Session(url: url, startTime: latestTime - Double(take) / sampleRate, format: format)
                self.session = session
                recordingFlag.store(true, ordering: .releasing)
                if take > 0 {
                    let capacity = ring[0].count
                    let start = (ringWrite - take + capacity) % capacity
                    var l = [Float](repeating: 0, count: take), r = l
                    for i in 0..<take {
                        l[i] = ring[0][(start + i) % capacity]
                        r[i] = ring[1][(start + i) % capacity]
                    }
                    l.withUnsafeBufferPointer { lp in
                        r.withUnsafeBufferPointer { rp in append(left: lp.baseAddress!, right: rp.baseAddress!, count: take, to: session) }
                    }
                }
            } catch {
                session = nil
            }

        case .finish(let continuation):
            guard let session else {
                continuation.resume(returning: nil)
                return
            }
            self.session = nil
            recordingFlag.store(false, ordering: .releasing)
            flush(session)
            writerQueue.async {
                session.file = nil  // closes
                let ok = session.error == nil && session.frames > 0
                continuation.resume(returning: ok ? RecordedSide(
                    url: session.url, startTime: session.startTime, sampleRate: session.format.sampleRate,
                    frameCount: session.frames, envelope: session.envelope
                ) : nil)
            }

        case .cancel:
            if let session { close(session, keep: false) }
            session = nil
            recordingFlag.store(false, ordering: .releasing)
        }
    }

    private func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, to session: Session) {
        var done = 0
        while done < count {
            let buffer = session.staging
            let space = Int(buffer.frameCapacity - buffer.frameLength)
            let n = min(space, count - done)
            let offset = Int(buffer.frameLength)
            let data = buffer.floatChannelData!
            (data[0] + offset).update(from: left + done, count: n)
            (data[1] + offset).update(from: right + done, count: n)
            for i in 0..<n {
                let m = Double((left[done + i] + right[done + i]) * 0.5)
                session.envelopeSum += m * m
                session.envelopeCount += 1
                if session.envelopeCount == session.envelopeBlock {
                    let rms = (session.envelopeSum / Double(session.envelopeCount)).squareRoot()
                    session.envelope.append(Float(20 * log10(max(rms, 1e-10))))
                    session.envelopeSum = 0
                    session.envelopeCount = 0
                }
            }
            buffer.frameLength += AVAudioFrameCount(n)
            session.frames += n
            done += n
            if buffer.frameLength == buffer.frameCapacity { flush(session) }
        }
    }

    /// Hands the staging buffer to the writer queue and starts a fresh one.
    private func flush(_ session: Session) {
        let full = Handoff(buffer: session.staging)
        guard full.buffer.frameLength > 0 else { return }
        session.staging = AVAudioPCMBuffer(pcmFormat: session.format, frameCapacity: full.buffer.frameCapacity)!
        writerQueue.async {
            do { try session.file?.write(from: full.buffer) } catch { session.error = error }
        }
    }

    /// Ownership of a filled buffer passes to the writer queue; this thread never touches it again.
    private struct Handoff: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private func close(_ session: Session, keep: Bool) {
        writerQueue.async {
            session.file = nil
            if !keep { try? FileManager.default.removeItem(at: session.url) }
        }
    }
}
