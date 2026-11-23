import AVFoundation
import CoreMedia
import Foundation
import os
import Synchronization

private let passLog = Logger(subsystem: "com.needledrop.Needledrop", category: "passthrough")

/// Plays a live input out loud, so the room hears the record when the interface takes the
/// turntable's only output: either out of the Mac's current output device, or to a group of
/// AirPlay 2 speakers at once (see `AirPlayRoute`).
///
/// Deliberately separate from capture: it only plays (it never touches an input node), fed
/// through a lock-free ring from the capture thread. If the output fails or changes, capture,
/// recognition and the archive carry on regardless.
///
/// The input and output run on different clocks, so the buffer is kept between `target`
/// and `ceiling`: an underrun plays silence and re-primes, an overrun drops back to target.
public final class PassThrough: @unchecked Sendable {
    /// Where the turntable plays.
    public enum Output: String, Codable, Sendable, CaseIterable {
        /// The Mac's current output device: its speakers, or one AirPlay speaker picked in Control Center.
        case thisMac
        /// The AirPlay 2 speakers chosen in Needledrop's picker, several at once and in sync.
        case airPlay
    }

    public let sampleRate: Double
    public let output: Output
    private let ring: AudioRingBuffer
    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var airPlay: AirPlayFeed?

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

    public init(sampleRate: Double, output: Output = .thisMac) {
        self.sampleRate = sampleRate
        self.output = output
        target = Int(sampleRate * 0.04)
        ceiling = Int(sampleRate * 0.15)
        ring = AudioRingBuffer(channelCount: 2, minimumCapacity: Int(sampleRate))
        scratch = .allocate(capacity: maxFrames * 2)
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
        airPlay?.stop()
        scratch.deallocate()
    }

    public func start() {
        if output == .airPlay {
            if AirPlayRoute.shared.isAvailable {
                let feed = AirPlayFeed(ring: ring, sampleRate: sampleRate)
                feed.start()
                airPlay = feed
                return
            }
            passLog.error("AirPlay speaker groups aren't available on this macOS: playing to this Mac's output")
        }
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
        airPlay?.stop()
        airPlay = nil
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
        var under = underruns.exchange(0, ordering: .relaxed), dropped = droppedFrames.exchange(0, ordering: .relaxed)
        if let airPlay {
            under += airPlay.underruns.exchange(0, ordering: .relaxed)
            dropped += airPlay.droppedFrames.exchange(0, ordering: .relaxed)
            return "pass-through to AirPlay (\(AirPlayRoute.shared.speakerNames.joined(separator: " + "))) \(under) underruns, \(dropped) frames dropped"
        }
        return "pass-through \(under) underruns, \(dropped) frames dropped"
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

/// When to start the clock, play, fill a gap or catch up, for the AirPlay renderer. Pure, so
/// the pacing can be tested without a renderer. All amounts are in frames.
struct AirPlayPacer {
    enum Step: Equatable {
        /// Not enough buffered to start yet.
        case wait
        /// Start the renderer's clock.
        case start
        /// Too far behind the input: throw this many frames away.
        case drop(Int)
        /// Hand the renderer this many frames of input.
        case play(Int)
        /// The input is late and the renderer is about to run dry: give it this much silence.
        case silence(Int)
        /// Nothing more to do until the next tick.
        case done
    }

    /// Buffered before the clock starts.
    let preroll: Int
    /// Frames per sample buffer handed to the renderer.
    let chunk: Int
    /// What's left buffered after catching up.
    let target: Int
    /// The most allowed to build up when the renderer isn't taking it.
    let ceiling: Int
    /// The least the renderer should have queued ahead of what's playing.
    let lowWater: Int
    private(set) var started = false

    init(sampleRate: Double) {
        preroll = Int(sampleRate * 0.2)
        chunk = Int(sampleRate * 0.05)
        target = Int(sampleRate * 0.1)
        ceiling = Int(sampleRate * 0.5)
        lowWater = Int(sampleRate * 0.1)
    }

    /// `available`: frames in the ring. `ready`: the renderer wants more. `lead`: frames queued
    /// in the renderer ahead of its clock.
    mutating func next(available: Int, ready: Bool, lead: Int) -> Step {
        if !started {
            guard available >= preroll else { return .wait }
            started = true
            return .start
        }
        if available > ceiling { return .drop(available - target) }
        guard ready else { return .done }
        if available >= chunk { return .play(chunk) }
        if lead < lowWater { return .silence(chunk) }
        return .done
    }

    mutating func reset() { started = false }
}

/// Feeds the pass-through ring to an `AVSampleBufferAudioRenderer` attached to the AirPlay
/// speaker group. airplayd buffers about 2 s more before the speakers play it, which the
/// Output latency setting covers.
private final class AirPlayFeed: @unchecked Sendable {
    private let ring: AudioRingBuffer
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "needledrop.passthrough.airplay", qos: .userInitiated)
    let underruns = Atomic<Int>(0)
    let droppedFrames = Atomic<Int>(0)

    // All below confined to `queue`.
    private var renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var pacer: AirPlayPacer
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var format: CMAudioFormatDescription?
    /// Presentation time, in frames, of the next frame handed to the renderer.
    private var nextFrame: Int64 = 0
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames: Int

    init(ring: AudioRingBuffer, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate
        pacer = AirPlayPacer(sampleRate: sampleRate)
        scratchFrames = max(pacer.chunk, 1)
        scratch = .allocate(capacity: scratchFrames * 2)
        // Interleaved stereo Float32, at the input's rate (airplayd converts).
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    }

    deinit { scratch.deallocate() }

    func start() {
        queue.sync {
            attachRenderer()
            // airplayd changed the route (speakers added or removed) and threw the queued audio
            // away: start the clock again from what's coming in.
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: nil, queue: nil
            ) { [weak self] note in
                guard let self else { return }
                let flushed = ObjectIdentifier(note.object as AnyObject)
                self.queue.async {
                    guard flushed == ObjectIdentifier(self.renderer) else { return }
                    passLog.notice("AirPlay renderer was flushed (route changed): re-priming")
                    self.restartClock()
                }
            })
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.pump() }
            timer.resume()
            self.timer = timer
        }
        passLog.notice("Pass-through playing to AirPlay speakers (\(AirPlayRoute.shared.speakerNames.joined(separator: ", "), privacy: .public)) at \(self.sampleRate) Hz")
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            synchronizer.setRate(0, time: .zero)
            renderer.stopRequestingMediaData()
            renderer.flush()
            synchronizer.removeRenderer(renderer, at: .zero)
        }
    }

    private func attachRenderer() {
        if !AirPlayRoute.shared.attach(renderer: renderer) {
            passLog.error("Couldn't attach the renderer to the AirPlay group")
        }
        synchronizer.addRenderer(renderer)
    }

    private func restartClock() {
        synchronizer.setRate(0, time: .zero)
        renderer.flush()
        ring.discardAll()
        nextFrame = 0
        pacer.reset()
    }

    private func pump() {
        if renderer.status == .failed {
            passLog.error("AirPlay renderer failed: \(self.renderer.error?.localizedDescription ?? "?", privacy: .public); making a new one")
            synchronizer.removeRenderer(renderer, at: .zero)
            renderer = AVSampleBufferAudioRenderer()
            attachRenderer()
            restartClock()
            return
        }
        // Bounded, so a renderer that never stops wanting more can't keep this busy.
        for _ in 0..<32 {
            let now = synchronizer.currentTime()
            let playing = now.isValid ? Int64(now.seconds * sampleRate) : 0
            let lead = pacer.started ? Int(nextFrame - playing) : 0
            switch pacer.next(available: ring.availableToRead, ready: renderer.isReadyForMoreMediaData, lead: lead) {
            case .wait, .done:
                return
            case .start:
                // The synchronizer holds the clock until the renderer has enough for AirPlay.
                synchronizer.setRate(1, time: CMTime(value: nextFrame, timescale: CMTimeScale(sampleRate)))
            case .drop(var n):
                droppedFrames.add(n, ordering: .relaxed)
                while n > 0 {
                    let m = min(n, scratchFrames)
                    _ = ring.read(frameCount: m, into: scratch)
                    n -= m
                }
            case .play(let n):
                guard ring.read(frameCount: n, into: scratch) else { return }
                enqueue(frames: n, silent: false)
            case .silence(let n):
                underruns.add(1, ordering: .relaxed)
                enqueue(frames: n, silent: true)
            }
        }
    }

    /// Interleaves `frames` from `scratch` (planar, as the ring reads) into a sample buffer.
    private func enqueue(frames: Int, silent: Bool) {
        guard let format else { return }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return }
        let out = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: Float.self)
        if silent {
            out.update(repeating: 0, count: frames * 2)
        } else {
            for i in 0..<frames {
                out[2 * i] = scratch[i]
                out[2 * i + 1] = scratch[frames + i]
            }
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: nextFrame, timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample else { return }
        renderer.enqueue(sample)
        nextFrame += Int64(frames)
    }
}
