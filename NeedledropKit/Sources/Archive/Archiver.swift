import Foundation
import Metadata
import Recognition

public struct ArchiveSettings: Sendable, Codable, Equatable {
    public var enabled = true
    public var format: ArchiveFormat = .alac
    public var rootPath = Self.defaultRoot.path
    public var keepRawSides = false
    public var dedup: DedupPolicy = .keepBest
    /// Encoded bit depth. The pipeline sees float, so this is the interface's (24 for
    /// any modern USB interface).
    public var bitDepth = 24

    public init() {}

    public static var defaultRoot: URL {
        URL.musicDirectory.appendingPathComponent("Needledrop", isDirectory: true)
    }

    public var root: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ArchiveSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        format = (try? c.decodeIfPresent(ArchiveFormat.self, forKey: .format)) ?? d.format
        rootPath = try c.decodeIfPresent(String.self, forKey: .rootPath) ?? d.rootPath
        keepRawSides = try c.decodeIfPresent(Bool.self, forKey: .keepRawSides) ?? d.keepRawSides
        dedup = (try? c.decodeIfPresent(DedupPolicy.self, forKey: .dedup)) ?? d.dedup
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth) ?? d.bitDepth
    }
}

/// What the session tells the archive, in order.
public enum ArchiveEvent: Sendable {
    case sideStarted(at: Double)
    case gap(ClosedRange<Double>)
    case sideEnded(start: Double, end: Double, reason: String)
    /// Sent on every session tick while an identified track plays.
    case trackSeen(TrackMatch, clockStart: Double, at: Double)
    case metadata(identity: String, TrackMetadata, artwork: Data?)
    case settings(ArchiveSettings)
    /// Listening stopped mid-side: drop the recording.
    case abandon
}

public struct ArchiveReport: Sendable {
    public struct Track: Sendable {
        public var title: String
        /// Nil if it was discarded as worse than an existing recording.
        public var path: String?
        public var uncertain: Bool
    }
    public var tracks: [Track]
    public var rawPath: String?
    public var error: String?
}

/// Records sides and turns them into tagged lossless tracks plus library entries.
public actor Archiver {
    public nonisolated let recorder: SideRecorder
    private let library: Library?
    private var settings: ArchiveSettings

    private struct Seen {
        var observation: TrackObservation
        var match: TrackMatch
        var metadata: TrackMetadata?
        var artwork: Data?
    }

    private var sideStart: (audio: Double, date: Date)?
    private var gaps: [ClosedRange<Double>] = []
    private var seen: [Seen] = []
    private var playsLogged: Set<String> = []
    /// Metadata can arrive before the track's first tick (it's often cached), so keep it
    /// by identity and attach it whenever the track turns up.
    private var metadataByIdentity: [String: (TrackMetadata, Data?)] = [:]

    public init(settings: ArchiveSettings, library: Library?, recorder: SideRecorder = SideRecorder()) {
        self.settings = settings
        self.library = library
        self.recorder = recorder
    }

    /// Handles one event; a side end returns what was archived.
    public func handle(_ event: ArchiveEvent) async -> ArchiveReport? {
        switch event {
        case .settings(let new):
            settings = new
        case .sideStarted(let t):
            sideStart = (t, Date())
            gaps = []
            seen = []
            playsLogged = []
            if settings.enabled { startRecording(at: t) }
        case .gap(let range):
            gaps.append(range)
        case .trackSeen(let match, let clockStart, let t):
            if let i = seen.lastIndex(where: { $0.observation.identity == match.identity }), i == seen.count - 1 {
                seen[i].observation.lastSeen = t
                seen[i].observation.clockStart = clockStart
            } else {
                let known = metadataByIdentity[match.identity]
                seen.append(Seen(observation: TrackObservation(identity: match.identity, clockStart: clockStart,
                                                               duration: known?.0.duration, firstSeen: t, lastSeen: t),
                                 match: match, metadata: known?.0, artwork: known?.1))
            }
        case .metadata(let identity, let info, let artwork):
            metadataByIdentity[identity] = (info, artwork)
            for i in seen.indices where seen[i].observation.identity == identity {
                seen[i].metadata = info
                seen[i].artwork = artwork
                seen[i].observation.duration = info.duration
            }
            logPlay(identity: identity, info: info, artwork: artwork)
        case .abandon:
            if recorder.isRecording { recorder.cancel() }
            sideStart = nil
        case .sideEnded(let start, let end, let reason):
            return await finishSide(start: start, end: end, reason: reason)
        }
        return nil
    }

    // For tests.
    func observedAlbums() -> [String?] { seen.map { $0.metadata?.album } }
    func observedDurations() -> [Double?] { seen.map(\.observation.duration) }

    private func startRecording(at t: Double) {
        let incoming = settings.root.appendingPathComponent(".incoming", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            recorder.begin(writingTo: incoming.appendingPathComponent("\(UUID().uuidString).caf"), from: t - 1)
        } catch {
            // Archive volume missing (NAS asleep, drive unplugged): play on, unarchived.
        }
    }

    private func logPlay(identity: String, info: TrackMetadata, artwork: Data?) {
        guard let library, !playsLogged.contains(identity) else { return }
        playsLogged.insert(identity)
        let artworkPath = artwork.flatMap { saveLibraryArtwork($0, key: info.collectionID ?? "\(info.artist)|\(info.album ?? info.title)") }
        if let trackID = try? library.upsertTrack(identity: identity, metadata: info, artworkPath: artworkPath) {
            try? library.recordPlay(trackID: trackID)
        }
    }

    // MARK: - Side end

    private func finishSide(start: Double, end: Double, reason: String) async -> ArchiveReport? {
        defer { sideStart = nil }
        guard recorder.isRecording, let side = await recorder.finish() else { return nil }
        let startedAt = sideStart?.date ?? Date()
        var report = ArchiveReport(tracks: [])

        let segments = TrackSplitter.split(.init(
            sideStart: start, sideEnd: end, recordingStart: side.startTime, recordingEnd: side.endTime,
            gaps: gaps, observations: seen.map(\.observation),
            envelope: side.envelope, envelopeInterval: RecordedSide.envelopeInterval
        ))

        var rawPath: String?
        if settings.keepRawSides {
            let sides = settings.root.appendingPathComponent("Sides", isDirectory: true)
            let dest = sides.appendingPathComponent("\(Self.stamp(startedAt)).caf")
            if (try? FileManager.default.createDirectory(at: sides, withIntermediateDirectories: true)) != nil,
               (try? FileManager.default.moveItem(at: side.url, to: dest)) != nil {
                rawPath = dest.path
            }
        }
        let source = rawPath.map { URL(fileURLWithPath: $0) } ?? side.url
        defer { if rawPath == nil { try? FileManager.default.removeItem(at: side.url) } }

        let sideID = try? library?.insertSide(SideRecord(startedAt: startedAt, endedAt: Date(), endReason: reason, rawPath: rawPath))
        if let sideID { try? library?.setSideID(sideID, forPlaysSince: startedAt) }

        var unknownNumber = 0
        for segment in segments {
            let info = segment.observation.map { seen[$0] }
            var tags: TrackTags
            let folder: URL
            let filename: String
            if let info {
                let m = info.metadata ?? TrackMetadata(match: info.match)
                tags = TrackTags(title: m.title, artist: m.artist)
                tags.album = m.album
                tags.albumArtist = m.albumArtist ?? m.artist
                tags.trackNumber = m.trackNumber
                tags.trackCount = m.trackCount
                tags.discNumber = m.discNumber
                tags.year = m.year
                tags.genre = m.genre
                tags.artwork = info.artwork
                folder = settings.root
                    .appendingPathComponent(Self.safe(tags.albumArtist ?? m.artist), isDirectory: true)
                    .appendingPathComponent(Self.safe(m.album ?? "Unknown Album"), isDirectory: true)
                filename = (m.trackNumber.map { String(format: "%02d ", $0) } ?? "") + Self.safe(m.title)
            } else {
                unknownNumber += 1
                tags = TrackTags(title: "Unknown – \(Self.stamp(startedAt)) #\(unknownNumber)", artist: "Unknown")
                tags.album = "Unknown – \(Self.stamp(startedAt))"
                folder = settings.root.appendingPathComponent("Unknown", isDirectory: true)
                    .appendingPathComponent(Self.safe(tags.album!), isDirectory: true)
                filename = String(format: "%02d Unknown", unknownNumber)
            }
            if segment.uncertain { tags.comment = "Needledrop: track boundary estimated — check the start/end" }

            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let pending = folder.appendingPathComponent(".pending-\(UUID().uuidString).\(settings.format.fileExtension)")
                let quality = try await TrackEncoder.encode(
                    from: source, start: segment.start - side.startTime, end: segment.end - side.startTime,
                    to: pending, format: settings.format, bitDepth: settings.bitDepth, tags: tags
                )
                var destination = folder.appendingPathComponent("\(filename).\(settings.format.fileExtension)")
                if settings.dedup == .keepAll || info == nil { destination = Self.unique(destination) }

                var keep = true
                var replaced: [String] = []
                if let library, let sideID {
                    let trackID = info.flatMap { i -> Int64? in
                        let m = i.metadata ?? TrackMetadata(match: i.match)
                        return try? library.upsertTrack(identity: i.observation.identity, metadata: m)
                    }
                    let record = RecordingRecord(
                        trackID: trackID, sideID: sideID, path: destination.path, format: settings.format.rawValue,
                        sampleRate: side.sampleRate, duration: segment.duration, clippedSamples: quality.clippedSamples,
                        peakDB: Double(quality.peakDB), rmsDB: Double(quality.rmsDB),
                        uncertainBoundary: segment.uncertain, createdAt: Date()
                    )
                    switch try library.addRecording(record, policy: settings.dedup) {
                    case .discard: keep = false
                    case .keep(let paths): replaced = paths
                    }
                }
                if keep {
                    for path in replaced { try? FileManager.default.removeItem(atPath: path) }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: pending, to: destination)
                } else {
                    try? FileManager.default.removeItem(at: pending)
                }
                report.tracks.append(.init(title: tags.title, path: keep ? destination.path : nil, uncertain: segment.uncertain))
            } catch {
                report.error = "\(tags.title): \(error)"
            }
        }
        report.rawPath = rawPath
        return report
    }

    private func saveLibraryArtwork(_ data: Data, key: String) -> String? {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("Needledrop/Artwork", isDirectory: true)
        let file = dir.appendingPathComponent("\(Self.safe(key)).img")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file.path
    }

    // MARK: - Names

    static func safe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    }

    static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(n))")
                .appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: date)
    }
}
