import Synchronization

/// Single-producer / single-consumer lock-free ring buffer of planar Float32 audio.
///
/// The producer (capture tap or replay thread) calls `write`; the consumer (analysis
/// thread) calls `read`. Neither side blocks or allocates. The heads are monotonically
/// increasing frame counts, so `writeHead - readHead` is always the fill level.
public final class AudioRingBuffer: @unchecked Sendable {
    public let channelCount: Int
    public let capacity: Int

    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeHead = Atomic<Int>(0)
    private let readHead = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)

    /// - Parameter minimumCapacity: frames per channel; rounded up to a power of two.
    public init(channelCount: Int = 2, minimumCapacity: Int) {
        precondition(channelCount > 0 && minimumCapacity > 0)
        var capacity = 1
        while capacity < minimumCapacity { capacity <<= 1 }
        self.channelCount = channelCount
        self.capacity = capacity
        self.mask = capacity - 1
        storage = .allocate(capacity: capacity * channelCount)
        storage.initialize(repeating: 0, count: capacity * channelCount)
    }

    deinit { storage.deallocate() }

    /// Frames ready for the consumer. Call from the consumer side.
    public var availableToRead: Int {
        writeHead.load(ordering: .acquiring) - readHead.load(ordering: .relaxed)
    }

    /// Free space for the producer. Call from the producer side.
    public var availableToWrite: Int {
        capacity - (writeHead.load(ordering: .relaxed) - readHead.load(ordering: .acquiring))
    }

    /// Frames discarded because the consumer fell behind. Should stay at zero.
    public var droppedFrameCount: Int { droppedFrames.load(ordering: .relaxed) }

    /// Writes `frameCount` frames. `channel(i)` returns source channel `i`; missing
    /// channels repeat the last source channel (mono → stereo). If there isn't room for
    /// the whole block it's dropped, counted, and `false` is returned.
    @discardableResult
    public func write(
        frameCount: Int,
        channelCount sourceChannels: Int,
        channel: (Int) -> UnsafePointer<Float>
    ) -> Bool {
        guard frameCount > 0, sourceChannels > 0 else { return true }
        let w = writeHead.load(ordering: .relaxed)
        let r = readHead.load(ordering: .acquiring)
        guard frameCount <= capacity - (w - r) else {
            droppedFrames.add(frameCount, ordering: .relaxed)
            return false
        }
        let start = w & mask
        let first = min(frameCount, capacity - start)
        for c in 0..<channelCount {
            let src = channel(min(c, sourceChannels - 1))
            let dst = storage + c * capacity
            (dst + start).update(from: src, count: first)
            if first < frameCount {
                dst.update(from: src + first, count: frameCount - first)
            }
        }
        writeHead.store(w + frameCount, ordering: .releasing)
        return true
    }

    /// Writes silence (used by replay to pad the end of a file).
    @discardableResult
    public func writeSilence(frameCount: Int) -> Bool {
        let w = writeHead.load(ordering: .relaxed)
        let r = readHead.load(ordering: .acquiring)
        guard frameCount <= capacity - (w - r) else { return false }
        let start = w & mask
        let first = min(frameCount, capacity - start)
        for c in 0..<channelCount {
            let dst = storage + c * capacity
            (dst + start).update(repeating: 0, count: first)
            if first < frameCount { dst.update(repeating: 0, count: frameCount - first) }
        }
        writeHead.store(w + frameCount, ordering: .releasing)
        return true
    }

    /// Reads exactly `frameCount` frames into planar `destination` (channel `c` starts at
    /// `destination + c * frameCount`). Returns `false`, consuming nothing, if fewer are available.
    public func read(frameCount: Int, into destination: UnsafeMutablePointer<Float>) -> Bool {
        let r = readHead.load(ordering: .relaxed)
        let w = writeHead.load(ordering: .acquiring)
        guard w - r >= frameCount else { return false }
        let start = r & mask
        let first = min(frameCount, capacity - start)
        for c in 0..<channelCount {
            let src = storage + c * capacity
            let dst = destination + c * frameCount
            dst.update(from: src + start, count: first)
            if first < frameCount {
                (dst + first).update(from: src, count: frameCount - first)
            }
        }
        readHead.store(r + frameCount, ordering: .releasing)
        return true
    }

    /// Consumer-side: throw away everything currently buffered.
    public func discardAll() {
        readHead.store(writeHead.load(ordering: .acquiring), ordering: .releasing)
    }
}
