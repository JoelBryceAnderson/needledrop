import AVFoundation
import Foundation

public enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    /// Apple Lossless in .m4a — drops straight into Apple Music.
    case alac
    case flac

    public var fileExtension: String { self == .alac ? "m4a" : "flac" }
}

public struct TrackTags: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var trackCount: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    /// JPEG or PNG bytes.
    public var artwork: Data?
    public var comment: String?

    public init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }
}

/// How good a recording is, for keeping the best of several plays of the same track.
public struct RecordingQuality: Sendable, Codable, Equatable {
    public var clippedSamples: Int
    public var peakDB: Float
    public var rmsDB: Float

    /// No clipping beats clipping; then the hotter (better-gained) recording wins.
    public func isBetter(than other: RecordingQuality) -> Bool {
        let clean = clippedSamples == 0, otherClean = other.clippedSamples == 0
        if clean != otherClean { return clean }
        if !clean, clippedSamples != other.clippedSamples { return clippedSamples < other.clippedSamples }
        return rmsDB > other.rmsDB + 0.1
    }
}

public enum EncoderError: Error, CustomStringConvertible {
    case emptyRange
    case export(String)

    public var description: String {
        switch self {
        case .emptyRange: "Nothing to encode in that range"
        case .export(let message): "Tagging failed: \(message)"
        }
    }
}

/// Cuts a range out of the raw side recording, encodes it losslessly at the source rate,
/// and tags it.
public enum TrackEncoder {
    /// Short fades at the cut points so they don't click.
    static let edgeFade = 0.005

    /// `start`/`end` are seconds from the start of `raw`.
    public static func encode(from raw: URL, start: Double, end: Double, to destination: URL,
                              format: ArchiveFormat, bitDepth: Int = 24, tags: TrackTags) async throws -> RecordingQuality {
        let input = try AVAudioFile(forReading: raw)
        let sampleRate = input.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, start) * sampleRate)
        let last = min(input.length, AVAudioFramePosition(end * sampleRate))
        guard last > first else { throw EncoderError.emptyRange }
        input.framePosition = first

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".encoding-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }

        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: input.processingFormat.channelCount,
            AVEncoderBitDepthHintKey: bitDepth,
        ]
        settings[AVFormatIDKey] = format == .alac ? kAudioFormatAppleLossless : kAudioFormatFLAC

        var quality = RecordingQuality(clippedSamples: 0, peakDB: -120, rmsDB: -120)
        do {
            let output = try AVAudioFile(forWriting: staging, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk: AVAudioFrameCount = 32_768
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk)!
            let total = Int(last - first)
            let fade = max(1, Int(edgeFade * sampleRate))
            var done = 0
            var peak: Float = 0
            var sumSquares = 0.0
            while done < total {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int(chunk), total - done)))
                let n = Int(buffer.frameLength)
                if n == 0 { break }
                for c in 0..<Int(buffer.format.channelCount) {
                    let data = buffer.floatChannelData![c]
                    for i in 0..<n {
                        let position = done + i
                        var x = data[i]
                        if position < fade { x *= Float(position) / Float(fade) }
                        if total - position <= fade { x *= Float(total - position - 1) / Float(fade) }
                        data[i] = x
                        let a = abs(x)
                        peak = max(peak, a)
                        if a >= 0.999 { quality.clippedSamples += 1 }
                        sumSquares += Double(x * x)
                    }
                }
                try output.write(from: buffer)
                done += n
            }
            let samples = Double(max(1, done) * Int(input.processingFormat.channelCount))
            quality.peakDB = 20 * log10f(max(peak, 1e-10))
            quality.rmsDB = Float(10 * log10(max(sumSquares / samples, 1e-20)))
        }

        try? FileManager.default.removeItem(at: destination)
        switch format {
        case .alac: try await tagMPEG4(staging, to: destination, tags: tags)
        case .flac:
            try FLACTagger.write(tags, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return quality
    }

    // MARK: - MPEG-4 (iTunes) tags

    private static func tagMPEG4(_ source: URL, to destination: URL, tags: TrackTags) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw EncoderError.export("no passthrough export for \(source.lastPathComponent)")
        }
        export.metadata = metadataItems(tags)
        do {
            try await export.export(to: destination, as: .m4a)
        } catch {
            throw EncoderError.export(error.localizedDescription)
        }
    }

    static func metadataItems(_ tags: TrackTags) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol, dataType: String? = nil) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let dataType { item.dataType = dataType }
            return item
        }
        func pair(_ number: Int, of total: Int?, length: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: length)
            bytes[2] = UInt8((number >> 8) & 0xFF)
            bytes[3] = UInt8(number & 0xFF)
            bytes[4] = UInt8(((total ?? 0) >> 8) & 0xFF)
            bytes[5] = UInt8((total ?? 0) & 0xFF)
            return Data(bytes)
        }
        var items = [
            item(.iTunesMetadataSongName, tags.title as NSString),
            item(.iTunesMetadataArtist, tags.artist as NSString),
        ]
        if let v = tags.album { items.append(item(.iTunesMetadataAlbum, v as NSString)) }
        if let v = tags.albumArtist { items.append(item(.iTunesMetadataAlbumArtist, v as NSString)) }
        if let v = tags.trackNumber { items.append(item(.iTunesMetadataTrackNumber, pair(v, of: tags.trackCount, length: 8) as NSData)) }
        if let v = tags.discNumber { items.append(item(.iTunesMetadataDiscNumber, pair(v, of: nil, length: 6) as NSData)) }
        if let v = tags.year { items.append(item(.iTunesMetadataReleaseDate, String(v) as NSString)) }
        if let v = tags.genre { items.append(item(.iTunesMetadataUserGenre, v as NSString)) }
        if let v = tags.comment { items.append(item(.iTunesMetadataUserComment, v as NSString)) }
        if let art = tags.artwork {
            let isPNG = art.starts(with: [0x89, 0x50, 0x4E, 0x47])
            items.append(item(.iTunesMetadataCoverArt, art as NSData,
                              dataType: (isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String))
        }
        return items
    }
}

/// Writes Vorbis comments and a front-cover picture into a FLAC file's metadata blocks.
enum FLACTagger {
    enum Failure: Error { case notFLAC }

    static func write(_ tags: TrackTags, to url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count > 8, data.prefix(4) == Data("fLaC".utf8) else { throw Failure.notFLAC }

        var blocks: [(type: UInt8, body: Data)] = []
        var offset = 4
        var last = false
        while !last, offset + 4 <= data.count {
            let header = data[data.startIndex + offset]
            last = header & 0x80 != 0
            let type = header & 0x7F
            let length = Int(data[data.startIndex + offset + 1]) << 16 | Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
            let body = data.subdata(in: (offset + 4)..<(offset + 4 + length))
            // Drop padding and any existing comments/pictures; ours replace them.
            if ![1, 4, 6].contains(type) { blocks.append((type, body)) }
            offset += 4 + length
        }
        let audio = data.subdata(in: offset..<data.count)

        blocks.append((4, vorbisComment(tags)))
        if let art = tags.artwork { blocks.append((6, picture(art))) }

        var out = Data("fLaC".utf8)
        for (i, block) in blocks.enumerated() {
            let flag: UInt8 = i == blocks.count - 1 ? 0x80 : 0
            out.append(flag | block.type)
            out.append(contentsOf: [UInt8((block.body.count >> 16) & 0xFF), UInt8((block.body.count >> 8) & 0xFF), UInt8(block.body.count & 0xFF)])
            out.append(block.body)
        }
        out.append(audio)
        try out.write(to: url, options: .atomic)
    }

    private static func vorbisComment(_ tags: TrackTags) -> Data {
        var fields = ["TITLE=\(tags.title)", "ARTIST=\(tags.artist)"]
        if let v = tags.album { fields.append("ALBUM=\(v)") }
        if let v = tags.albumArtist { fields.append("ALBUMARTIST=\(v)") }
        if let v = tags.trackNumber { fields.append("TRACKNUMBER=\(v)") }
        if let v = tags.trackCount { fields.append("TRACKTOTAL=\(v)") }
        if let v = tags.discNumber { fields.append("DISCNUMBER=\(v)") }
        if let v = tags.year { fields.append("DATE=\(v)") }
        if let v = tags.genre { fields.append("GENRE=\(v)") }
        if let v = tags.comment { fields.append("COMMENT=\(v)") }
        var body = Data()
        func le32(_ v: Int) { body.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        let vendor = Data("Needledrop".utf8)
        le32(vendor.count)
        body.append(vendor)
        le32(fields.count)
        for field in fields {
            let bytes = Data(field.utf8)
            le32(bytes.count)
            body.append(bytes)
        }
        return body
    }

    private static func picture(_ art: Data) -> Data {
        var body = Data()
        func be32(_ v: Int) { body.append(contentsOf: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        let mime = Data((art.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg").utf8)
        be32(3)  // front cover
        be32(mime.count)
        body.append(mime)
        be32(0)  // description
        for _ in 0..<4 { be32(0) }  // width, height, depth, colours: unknown is allowed
        be32(art.count)
        body.append(art)
        return body
    }
}
