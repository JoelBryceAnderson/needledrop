import AVFAudio
import Foundation
import os
import Synchronization

private let passLog = Logger(subsystem: "com.needledrop.Needledrop", category: "passthrough")

/// Plays a live input out of the Mac's current output device, so the room hears the record
/// when the interface takes the turntable's only output.
///
/// Deliberately separate from capture: its own AVAudioEngine that only plays (it never
/// touches an input node), fed through a lock-free ring from the capture thread. If the
/// output fails or changes, capture, recognition and the archive carry on regardless.
///
/// The input and output run on different clocks, so the buffer is kept between `target`
/// and `ceiling`: an underrun plays silence and re-primes, an overrun drops back to target.
public final class PassThrough: @unchecked Sendable {
    public let sampleRate: Double
    private let ring: AudioRingBuffer
    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?

    /// Frames buffered before playing starts (≈ 40 ms), and the most allowed (≈ 150 ms).
    private let target: Int
    private let ceiling: Int

    // Render-thread state.
    private(set) var primed = false
    private let maxFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>

    // For the log.
    private let underruns = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        target = Int(sampleRate * 0.04)
        ceiling = Int(sampleRate * 0.15)
        ring = AudioRingBuffer(channelCount: 2, minimumCapacity: Int(sampleRate))
        scratch = .allocate(capacity: maxFrames * 2)
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
        scratch.deallocate()
    }

    public func start() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, data in
            self.render(Int(frameCount), into: UnsafeMutableAudioBufferListPointer(data))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // The output device changed (speakers ↔ AirPlay, headphones): start again on the new one.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            passLog.notice("Output changed: restarting pass-through")
            self.ring.discardAll()
            try? self.engine.start()
        }
        do {
            try engine.start()
            passLog.notice("Pass-through playing at \(self.sampleRate) Hz")
        } catch {
            passLog.error("Pass-through couldn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.stop()
    }

    // MARK: - Producer (capture thread)

    public func write(_ buffer: AVAudioPCMBuffer) {
        ring.write(buffer)
    }

    public func write(frameCount: Int, left: UnsafePointer<Float>, right: UnsafePointer<Float>) {
        ring.write(frameCount: frameCount, channelCount: 2) { $0 == 0 ? left : right }
    }

    /// "N underruns, M frames dropped" since the last call, for the capture log.
    public func takeStats() -> String {
        "pass-through \(underruns.exchange(0, ordering: .relaxed)) underruns, \(droppedFrames.exchange(0, ordering: .relaxed)) frames dropped"
    }

    // MARK: - Render (output thread)

    /// Internal for tests.
    func render(_ frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        var available = ring.availableToRead
        if !primed, available >= target { primed = true }
        // Too far behind the input: skip ahead to the target.
        if primed, available > ceiling {
            var skip = available - target
            droppedFrames.add(skip, ordering: .relaxed)
            while skip > 0 {
                let n = min(skip, maxFrames)
                _ = ring.read(frameCount: n, into: scratch)
                skip -= n
            }
            available = target
        }
        let n = min(frames, maxFrames)
        if primed, available >= n, ring.read(frameCount: n, into: scratch) {
            for (c, buffer) in buffers.enumerated() {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                out.update(from: scratch + min(c, 1) * n, count: n)
            }
            return
        }
        if primed {
            underruns.add(1, ordering: .relaxed)
            primed = false
        }
        for buffer in buffers {
            if let out = buffer.mData { memset(out, 0, Int(buffer.mDataByteSize)) }
        }
    }
}
