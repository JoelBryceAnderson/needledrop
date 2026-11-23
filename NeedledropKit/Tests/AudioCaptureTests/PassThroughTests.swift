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

/// When the AirPlay renderer is started, fed, topped up with silence or caught up.
@Suite struct AirPlayPacerTests {
    // At 1000 Hz: preroll 200, chunk 50, target 100, ceiling 500, low water 100.
    private func pacer() -> AirPlayPacer { AirPlayPacer(sampleRate: 1000) }

    @Test func waitsForPrerollThenStartsOnce() {
        var p = pacer()
        #expect(p.next(available: 199, ready: true, lead: 0) == .wait)
        #expect(p.next(available: 200, ready: true, lead: 0) == .start)
        #expect(p.started)
        #expect(p.next(available: 200, ready: true, lead: 0) == .play(50))
    }

    @Test func playsOnlyWhileTheRendererWantsMore() {
        var p = pacer()
        _ = p.next(available: 300, ready: true, lead: 0)
        #expect(p.next(available: 300, ready: false, lead: 2000) == .done)
        #expect(p.next(available: 300, ready: true, lead: 2000) == .play(50))
    }

    @Test func waitsForInputWhileTheRendererHasPlentyQueued() {
        var p = pacer()
        _ = p.next(available: 200, ready: true, lead: 0)
        #expect(p.next(available: 30, ready: true, lead: 400) == .done)
    }

    @Test func fillsWithSilenceWhenTheInputIsLateAndTheRendererIsRunningDry() {
        var p = pacer()
        _ = p.next(available: 200, ready: true, lead: 0)
        #expect(p.next(available: 30, ready: true, lead: 99) == .silence(50))
    }

    @Test func catchesUpWhenTheInputRunsAhead() {
        var p = pacer()
        _ = p.next(available: 200, ready: true, lead: 0)
        #expect(p.next(available: 501, ready: false, lead: 2000) == .drop(401))
        #expect(p.next(available: 500, ready: false, lead: 2000) == .done)
    }

    @Test func resetWaitsForPrerollAgain() {
        var p = pacer()
        _ = p.next(available: 200, ready: true, lead: 0)
        p.reset()
        #expect(p.next(available: 100, ready: true, lead: 0) == .wait)
    }
}

/// The output choice is stored by name in the app's settings.
@Suite struct PassThroughOutputTests {
    @Test func roundTripsByName() throws {
        let data = try JSONEncoder().encode([PassThrough.Output.airPlay])
        #expect(String(decoding: data, as: UTF8.self) == #"["airPlay"]"#)
        #expect(try JSONDecoder().decode([PassThrough.Output].self, from: data) == [.airPlay])
    }

    @Test func aPassThroughForAirPlayRemembersIt() {
        #expect(PassThrough(sampleRate: 1000, output: .airPlay).output == .airPlay)
        #expect(PassThrough(sampleRate: 1000).output == .thisMac)
    }
}
