import AudioToolbox
@testable import AudioCapture
import Foundation
import Testing

/// The buffering between the input clock and the output clock (no engine is started).
@Suite struct PassThroughTests {
    private let rate = 1000.0  // target 40 frames, ceiling 150

    /// Renders `n` frames; returns the left channel.
    private func render(_ p: PassThrough, _ n: Int) -> [Float] {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: l)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: r)
        p.render(n, into: list)
        return Array(UnsafeBufferPointer(start: l, count: n))
    }

    private func write(_ p: PassThrough, from start: Int, count: Int) {
        let samples = (start..<start + count).map(Float.init)
        samples.withUnsafeBufferPointer { p.write(frameCount: count, left: $0.baseAddress!, right: $0.baseAddress!) }
    }

    @Test func silentUntilPrimedThenPlaysInOrder() {
        let p = PassThrough(sampleRate: rate)
        write(p, from: 1, count: 20)
        #expect(render(p, 10) == Array(repeating: 0, count: 10))
        #expect(!p.primed)
        write(p, from: 21, count: 30)  // 50 buffered ≥ target 40
        #expect(render(p, 10) == (1...10).map(Float.init))
        #expect(p.primed)
    }

    @Test func underrunPlaysSilenceAndReprimes() {
        let p = PassThrough(sampleRate: rate)
        write(p, from: 1, count: 45)
        _ = render(p, 40)
        #expect(render(p, 10) == Array(repeating: 0, count: 10))  // only 5 left
        #expect(!p.primed)
        write(p, from: 46, count: 40)
        #expect(render(p, 5) == (41...45).map(Float.init))  // nothing lost, just late
    }

    @Test func fallingBehindSkipsAheadToTarget() {
        let p = PassThrough(sampleRate: rate)
        write(p, from: 1, count: 50)
        _ = render(p, 10)  // primed, 40 left (11…50)
        write(p, from: 51, count: 200)  // 240 buffered > ceiling 150
        // Keeps the newest 40 frames (211…250).
        #expect(render(p, 10) == (211...220).map(Float.init))
        #expect(p.takeStats().contains("200 frames dropped"))
    }
}
