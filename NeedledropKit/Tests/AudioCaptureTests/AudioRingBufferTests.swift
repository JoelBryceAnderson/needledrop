import AudioCapture
import Foundation
import Testing

@Suite struct AudioRingBufferTests {
    private func write(_ ring: AudioRingBuffer, _ left: [Float], _ right: [Float]? = nil) -> Bool {
        let channels = [left, right].compactMap { $0 }
        return channels[0].withUnsafeBufferPointer { l in
            (channels.last!).withUnsafeBufferPointer { r in
                ring.write(frameCount: left.count, channelCount: channels.count) { $0 == 0 ? l.baseAddress! : r.baseAddress! }
            }
        }
    }

    private func read(_ ring: AudioRingBuffer, _ n: Int) -> [Float]? {
        var out = [Float](repeating: .nan, count: n * ring.channelCount)
        let ok = out.withUnsafeMutableBufferPointer { ring.read(frameCount: n, into: $0.baseAddress!) }
        return ok ? out : nil
    }

    @Test func roundTripsAcrossTheWrapPoint() {
        let ring = AudioRingBuffer(channelCount: 2, minimumCapacity: 8)
        #expect(ring.capacity == 8)
        #expect(write(ring, [1, 2, 3, 4, 5, 6], [-1, -2, -3, -4, -5, -6]))
        #expect(read(ring, 4) == [1, 2, 3, 4, -1, -2, -3, -4])
        #expect(write(ring, [7, 8, 9, 10, 11], [-7, -8, -9, -10, -11]))  // wraps
        #expect(ring.availableToRead == 7)
        #expect(read(ring, 7) == [5, 6, 7, 8, 9, 10, 11, -5, -6, -7, -8, -9, -10, -11])
        #expect(ring.availableToRead == 0)
    }

    @Test func monoIsDuplicatedToBothChannels() {
        let ring = AudioRingBuffer(channelCount: 2, minimumCapacity: 4)
        #expect(write(ring, [0.5, 0.25]))
        #expect(read(ring, 2) == [0.5, 0.25, 0.5, 0.25])
    }

    @Test func overflowDropsTheWholeBlockAndCountsIt() {
        let ring = AudioRingBuffer(channelCount: 1, minimumCapacity: 4)
        #expect(write(ring, [1, 2, 3]))
        #expect(!write(ring, [4, 5]))
        #expect(ring.droppedFrameCount == 2)
        #expect(read(ring, 3) == [1, 2, 3])
    }

    @Test func readNeverConsumesAPartialHop() {
        let ring = AudioRingBuffer(channelCount: 1, minimumCapacity: 16)
        #expect(write(ring, [1, 2, 3]))
        #expect(read(ring, 4) == nil)
        #expect(ring.availableToRead == 3)
    }

    @Test func concurrentProducerAndConsumerPreserveEverySample() async {
        let ring = AudioRingBuffer(channelCount: 2, minimumCapacity: 4096)
        let total = 1_000_000
        let producer = Thread {
            var next = 0
            var block = [Float](repeating: 0, count: 777)
            while next < total {
                let n = min(Int.random(in: 1...777), total - next)
                for i in 0..<n { block[i] = Float(next + i) }
                guard ring.availableToWrite >= n else { Thread.sleep(forTimeInterval: 0.0001); continue }
                let written = block.withUnsafeBufferPointer { p in
                    ring.write(frameCount: n, channelCount: 1) { _ in p.baseAddress! }
                }
                if written { next += n }
            }
        }
        producer.start()

        let hop = 512
        var expected = 0
        var out = [Float](repeating: 0, count: hop * 2)
        var mismatch = false
        while expected + hop <= total {
            let ok = out.withUnsafeMutableBufferPointer { ring.read(frameCount: hop, into: $0.baseAddress!) }
            guard ok else { continue }
            for i in 0..<hop where out[i] != Float(expected + i) || out[hop + i] != Float(expected + i) { mismatch = true }
            expected += hop
        }
        #expect(!mismatch)
        #expect(ring.droppedFrameCount == 0)
    }
}
