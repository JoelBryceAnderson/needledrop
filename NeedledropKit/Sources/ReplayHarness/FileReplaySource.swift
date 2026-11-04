import AVFAudio
import AudioCapture
import Foundation
import Synchronization

/// Plays a recorded file into the ring buffer paced like a live input, so the app and
/// pipeline can be developed without the turntable running. Unlike live capture it
/// waits for ring-buffer space rather than dropping.
public final class FileReplaySource: AudioSource, @unchecked Sendable {
    public let url: URL
    /// 1 = real time; higher replays faster (still through the live path).
    public let speed: Double
    public let loop: Bool
    /// Digital silence appended after the file (and between loops) so the side-end
    /// detector sees the needle lift.
    public let trailingSilence: Double
    /// Also play the file through the Mac's output (real-time replays only), so you can
    /// hear what you're watching. The turntable path never does this — the room hears the
    /// record through its own speakers.
    public let audible: Bool

    public var displayName: String { "Replay: \(url.lastPathComponent)" }

    private let running = Atomic<Bool>(false)
    /// The audible copy's engine and player. Only touched under `output`'s lock, so it's
    /// safe to hand between threads (older compilers insist on Sendable here).
    private struct Output: @unchecked Sendable {
        var engine: AVAudioEngine
        var player: AVAudioPlayerNode
    }
    private let output = Mutex<Output?>(nil)

    public init(url: URL, speed: Double = 1, loop: Bool = false, trailingSilence: Double = 12, audible: Bool = false) {
        self.url = url
        self.speed = speed
        self.loop = loop
        self.trailingSilence = trailingSilence
        self.audible = audible && speed == 1
    }

    public func start(writingTo ring: AudioRingBuffer, status: @escaping @Sendable (SourceStatus) -> Void) throws {
        let format = try AVAudioFile(forReading: url).processingFormat
        status(.running(CaptureFormat(sampleRate: format.sampleRate, channelCount: Int(format.channelCount)),
                        sourceName: displayName))
        running.store(true, ordering: .releasing)
        let thread = Thread { [self] in
            do {
                try self.run(ring: ring)
                status(.finished)
            } catch {
                status(.failed("Replay failed: \(error.localizedDescription)"))
            }
        }
        thread.name = "needledrop.replay"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        output.withLock { o in
            o?.player.stop()
            o?.engine.stop()
            o = nil
        }
    }

    /// Starts playback of loop 0 now (and queues loop 1), returning the player.
    private func startOutput(fileFrames: AVAudioFramePosition, silenceFrames: AVAudioFramePosition) -> AVAudioPlayerNode? {
        guard audible, let file = try? AVAudioFile(forReading: url) else { return nil }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        do { try engine.start() } catch { return nil }
        schedule(player, loop: 0, fileFrames: fileFrames, silenceFrames: silenceFrames)
        if loop { schedule(player, loop: 1, fileFrames: fileFrames, silenceFrames: silenceFrames) }
        player.play()
        let started = Output(engine: engine, player: player)
        output.withLock { $0 = started }
        return player
    }

    /// Plays loop `k` at its exact place on the player's timeline (file + silence per loop).
    private func schedule(_ player: AVAudioPlayerNode, loop k: Int, fileFrames: AVAudioFramePosition, silenceFrames: AVAudioFramePosition) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let when = AVAudioTime(sampleTime: AVAudioFramePosition(k) * (fileFrames + silenceFrames), atRate: file.processingFormat.sampleRate)
        player.scheduleFile(file, at: when)
    }

    private var isRunning: Bool { running.load(ordering: .acquiring) }

    private func run(ring: AudioRingBuffer) throws {
        let file = try AVAudioFile(forReading: url)
        let chunk: AVAudioFrameCount = 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
        let sampleRate = file.processingFormat.sampleRate
        let silenceFrames = AVAudioFramePosition(Int(trailingSilence * sampleRate))
        let player = startOutput(fileFrames: file.length, silenceFrames: silenceFrames)
        // Feeding analysis and playing out both start now and both run on real time.
        let clockStart = ProcessInfo.processInfo.systemUptime
        var framesSent = 0
        var loopIndex = 0

        func pace(_ frames: Int) {
            while isRunning, ring.availableToWrite < frames { Thread.sleep(forTimeInterval: 0.002) }
            framesSent += frames
            let due = clockStart + Double(framesSent) / (sampleRate * speed)
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }

        func playSilence() {
            var remaining = Int(trailingSilence * sampleRate)
            while isRunning, remaining > 0 {
                let n = min(remaining, Int(chunk))
                pace(n)
                ring.writeSilence(frameCount: n)
                remaining -= n
            }
        }

        while isRunning {
            buffer.frameLength = 0
            if file.framePosition < file.length { try file.read(into: buffer, frameCount: chunk) }
            let frames = Int(buffer.frameLength)
            if frames == 0 {
                playSilence()
                guard loop else { break }
                file.framePosition = 0
                loopIndex += 1
                // Keep one loop queued ahead so playback never waits on this thread.
                if let player { schedule(player, loop: loopIndex + 1, fileFrames: file.length, silenceFrames: silenceFrames) }
                continue
            }
            pace(frames)
            ring.write(buffer)
        }
    }
}
