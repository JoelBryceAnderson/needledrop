import AVFoundation
import Foundation
import ReplayHarness
import Testing
@testable import Archive

@Suite struct TrackEncoderTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-enc-\(UUID())")

    /// 10 s float CAF: a 440 Hz tone at -12 dBFS, with 50 clipped samples in the last second.
    private func rawSide() throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("side.caf")
        let sr = 48_000.0
        var tone = (0..<Int(10 * sr)).map { Float(0.25 * sin(2 * .pi * 440 * Double($0) / sr)) }
        for i in 0..<50 { tone[Int(9.5 * sr) + i * 10] = 1 }
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tone.count))!
        buffer.frameLength = buffer.frameCapacity
        tone.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: tone.count)
            buffer.floatChannelData![1].update(from: $0.baseAddress!, count: tone.count)
        }
        try file.write(from: buffer)
        return url
    }

    private var tags: TrackTags {
        var t = TrackTags(title: "Dreams", artist: "Fleetwood Mac")
        t.album = "Rumours"
        t.albumArtist = "Fleetwood Mac"
        t.trackNumber = 2
        t.trackCount = 11
        t.year = 1977
        t.comment = "boundary uncertain"
        t.artwork = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 200))
        return t
    }

    @Test func alacKeepsRateAndLengthAndCarriesTags() async throws {
        let raw = try rawSide()
        let out = dir.appendingPathComponent("02 Dreams.m4a")
        let quality = try await TrackEncoder.encode(from: raw, start: 2, end: 7, to: out, format: .alac, tags: tags)

        let file = try AVAudioFile(forReading: out)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
        #expect(abs(Double(file.length) / 48_000 - 5) < 0.01)
        #expect(quality.clippedSamples == 0)
        #expect(abs(quality.rmsDB - (-15.05)) < 0.2)  // 0.25 amplitude sine

        let metadata = try await AVURLAsset(url: out).load(.metadata)
        func string(_ id: AVMetadataIdentifier) async -> String? {
            try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first?.load(.stringValue)
        }
        #expect(await string(.iTunesMetadataSongName) == "Dreams")
        #expect(await string(.iTunesMetadataAlbum) == "Rumours")
        #expect(await string(.iTunesMetadataReleaseDate) == "1977")
        let art = try await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first?.load(.dataValue)
        #expect(art == tags.artwork)
    }

    @Test func flacCarriesVorbisCommentsAndPicture() async throws {
        let raw = try rawSide()
        let out = dir.appendingPathComponent("02 Dreams.flac")
        let quality = try await TrackEncoder.encode(from: raw, start: 8, end: 10, to: out, format: .flac, tags: tags)
        #expect(quality.clippedSamples == 100)  // 50 per channel

        let file = try AVAudioFile(forReading: out)  // still decodes after retagging
        #expect(abs(Double(file.length) / 48_000 - 2) < 0.01)
        let bytes = try Data(contentsOf: out)
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
        #expect(text.contains("TITLE=Dreams") && text.contains("TRACKNUMBER=2") && text.contains("DATE=1977"))
        #expect(bytes.range(of: Data("image/jpeg".utf8)) != nil)
    }

    @Test func qualityPrefersCleanThenHot() {
        let clean = RecordingQuality(clippedSamples: 0, peakDB: -3, rmsDB: -16)
        let hotter = RecordingQuality(clippedSamples: 0, peakDB: -1, rmsDB: -14)
        let clipped = RecordingQuality(clippedSamples: 12, peakDB: 0, rmsDB: -10)
        #expect(hotter.isBetter(than: clean))
        #expect(clean.isBetter(than: clipped))
        #expect(!clipped.isBetter(than: clean))
        #expect(!clean.isBetter(than: clean))
    }
}
