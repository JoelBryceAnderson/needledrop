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

    public var displayName: String { "Replay: \(url.lastPathComponent)" }

    private let running = Atomic<Bool>(false)

    public init(url: URL, speed: Double = 1, loop: Bool = false, trailingSilence: Double = 12) {
        self.url = url
        self.speed = speed
        self.loop = loop
        self.trailingSilence = trailingSilence
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
    }

    private var isRunning: Bool { running.load(ordering: .acquiring) }

    private func run(ring: AudioRingBuffer) throws {
        let file = try AVAudioFile(forReading: url)
        let chunk: AVAudioFrameCount = 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
        let sampleRate = file.processingFormat.sampleRate
        let clockStart = ProcessInfo.processInfo.systemUptime
        var framesSent = 0

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
                continue
            }
            pace(frames)
            ring.write(buffer)
        }
    }
}
