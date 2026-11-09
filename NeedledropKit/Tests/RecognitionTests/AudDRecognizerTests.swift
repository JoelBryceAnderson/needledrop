import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import Recognition

/// Replies with a fixed body after an optional delay, and records requests.
private final class FakeAudD: AudDTransport {
    let reply: Data
    let delay: Duration
    let requests = Mutex<[URLRequest]>([])

    init(_ json: String, delay: Duration = .zero) {
        reply = Data(json.utf8)
        self.delay = delay
    }

    func post(_ request: URLRequest) async throws -> Data {
        requests.withLock { $0.append(request) }
        if delay > .zero { try await Task.sleep(for: delay) }
        return reply
    }
}

private let success = #"""
{"status":"success","result":{"artist":"Tears For Fears","title":"Everybody Wants To Rule The World",
 "album":"Songs From The Big Chair","timecode":"00:57",
 "apple_music":{"isrc":"GBUM71403885","durationInMillis":261013,"playParams":{"id":"1440826582","kind":"song"},
   "artwork":{"url":"https://example.com/art/{w}x{h}bb.jpg"}}}}
"""#

@Suite struct AudDRecognizerTests {
    @Test func readsAMatchWithWhereTheClipWas() throws {
        guard case .match(let match, let start) = try AudDRecognizer.parse(Data(success.utf8)) else {
            Issue.record("expected a match")
            return
        }
        #expect(match.title == "Everybody Wants To Rule The World" && match.artist == "Tears For Fears")
        #expect(match.appleMusicID == "1440826582" && match.isrc == "GBUM71403885")
        #expect(match.albumHint == "Songs From The Big Chair")
        #expect(match.durationHint == 261.013)
        #expect(match.artworkURL?.absoluteString == "https://example.com/art/1200x1200bb.jpg")
        #expect(start == 57)
    }

    @Test func noMatchAndErrorsAreTold() throws {
        #expect(try AudDRecognizer.parse(Data(#"{"status":"success","result":null}"#.utf8)) == .noMatch)
        let failed = try AudDRecognizer.parse(Data(#"{"status":"error","error":{"error_code":900,"error_message":"Wrong API token"}}"#.utf8))
        #expect(failed == .failure("AudD couldn't recognise: Wrong API token (900)"))
        #expect(AudDRecognizer.timecode("01:02:03") == 3723)
        #expect(AudDRecognizer.timecode("1:23") == 83)
    }

    @Test func clipsAre16kHzMonoWAV() throws {
        let tone = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.5 }
        let down = AudDRecognizer.resample(tone, from: 48_000, to: 16_000)
        #expect(abs(down.count - 16_000) <= 16)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audd-\(UUID()).wav")
        try AudDRecognizer.wav(down, sampleRate: 16_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1 && abs(file.length - 16_000) <= 16)
    }

    @Test func stereoClipsKeepBothChannelsAndFilterAliasing() throws {
        // 440 Hz left, silence right; plus a 10 kHz tone that must not fold into the 16 kHz clip.
        let n = 48_000
        let left = (0..<n).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000) * 0.5) }
        let high = (0..<n).map { Float(sin(Double($0) * 2 * .pi * 10_000 / 48_000) * 0.5) }
        let down = AudDRecognizer.resample([left, high], from: 48_000, to: 16_000)
        #expect(down.count == 2 && abs(down[0].count - 16_000) <= 16)
        let rms = { (x: ArraySlice<Float>) in (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }
        #expect(rms(down[0][1000..<15000]) > 0.3)   // the 440 Hz tone survives (0.35 RMS)
        #expect(rms(down[1][1000..<15000]) < 0.01)  // 10 kHz is above 8 kHz: filtered, not aliased
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audd-\(UUID()).wav")
        try AudDRecognizer.wav(down, sampleRate: 16_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 2)
    }

    @Test func sendsOneClipPerWindowAndReportsWhereTheSongIsNow() async throws {
        let transport = FakeAudD(success)
        let recognizer = AudDRecognizer(token: "token-123", transport: transport)
        let results = Mutex<[RecognizerResult]>([])
        recognizer.setHandler { result in results.withLock { $0.append(result) } }
        recognizer.beginWindow(sampleRate: 16_000)
        let second = [Float](repeating: 0.1, count: 16_000)
        for t in 1...12 { second.withUnsafeBufferPointer { recognizer.feed($0.baseAddress!, frameCount: 16_000, endTime: Double(t)) } }
        for _ in 0..<100 where results.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.requests.withLock { $0.count } == 1)  // one clip, not one per second
        let body = try #require(transport.requests.withLock { $0.first?.httpBody })
        let text = String(decoding: body.prefix(400), as: UTF8.self)
        #expect(text.contains("name=\"api_token\"\r\n\r\ntoken-123"))
        guard case .match(let match) = try #require(results.withLock { $0.first }) else {
            Issue.record("expected a match")
            return
        }
        // The clip started 57 s in and lasted 9 s: the song is at least at 1:06 now.
        #expect(match.position >= 66 && match.position < 67)
    }

    @Test func aReplyForAClosedWindowIsDropped() async throws {
        let transport = FakeAudD(success, delay: .milliseconds(150))
        let recognizer = AudDRecognizer(token: "t", transport: transport)
        let results = Mutex<[RecognizerResult]>([])
        recognizer.setHandler { result in results.withLock { $0.append(result) } }
        recognizer.beginWindow(sampleRate: 16_000)
        let clip = [Float](repeating: 0.1, count: 16_000 * 10)
        clip.withUnsafeBufferPointer { recognizer.feed($0.baseAddress!, frameCount: clip.count, endTime: 10) }
        recognizer.endWindow()  // the session moved on before AudD answered
        try await Task.sleep(for: .milliseconds(400))
        #expect(transport.requests.withLock { $0.count } == 1)
        #expect(results.withLock { $0.isEmpty })
    }
}
