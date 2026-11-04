import Foundation
import GRDB
import Metadata

public enum DedupPolicy: String, Codable, CaseIterable, Sendable {
    /// One file per track: a new recording replaces the old only if it's better.
    case keepBest
    case keepAll
}

public struct AlbumRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "album"
    public var id: Int64?
    /// iTunes collection ID, or "artist|album" when there isn't one.
    public var key: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var artworkPath: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct TrackRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "track"
    public var id: Int64?
    public var identity: String
    public var albumID: Int64?
    public var title: String
    public var artist: String
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SideRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "side"
    public var id: Int64?
    public var startedAt: Date
    public var endedAt: Date
    public var endReason: String
    /// Kept only when "keep raw sides" is on.
    public var rawPath: String?

    public init(startedAt: Date, endedAt: Date, endReason: String, rawPath: String? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.rawPath = rawPath
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct RecordingRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "recording"
    public var id: Int64?
    /// Nil for unidentified tracks.
    public var trackID: Int64?
    public var sideID: Int64
    public var path: String
    public var format: String
    public var sampleRate: Double
    public var duration: Double
    public var clippedSamples: Int
    public var peakDB: Double
    public var rmsDB: Double
    public var uncertainBoundary: Bool
    public var createdAt: Date

    public init(trackID: Int64?, sideID: Int64, path: String, format: String, sampleRate: Double, duration: Double,
                clippedSamples: Int, peakDB: Double, rmsDB: Double, uncertainBoundary: Bool, createdAt: Date) {
        self.trackID = trackID
        self.sideID = sideID
        self.path = path
        self.format = format
        self.sampleRate = sampleRate
        self.duration = duration
        self.clippedSamples = clippedSamples
        self.peakDB = peakDB
        self.rmsDB = rmsDB
        self.uncertainBoundary = uncertainBoundary
        self.createdAt = createdAt
    }

    public var quality: RecordingQuality {
        RecordingQuality(clippedSamples: clippedSamples, peakDB: Float(peakDB), rmsDB: Float(rmsDB))
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PlayRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "play"
    public var id: Int64?
    public var trackID: Int64
    public var sideID: Int64?
    public var playedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One album for the library wall: most recently played first.
public struct AlbumSummary: Sendable, Equatable, FetchableRecord, Decodable {
    public var albumID: Int64
    public var title: String
    public var artist: String
    public var artworkPath: String?
    public var plays: Int
    public var lastPlayed: Date
}

/// Everything ever played and archived, in SQLite.
public final class Library: Sendable {
    let db: DatabaseQueue

    public init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        db = try DatabaseQueue(path: path)
        try Self.migrator.migrate(db)
    }

    /// In-memory, for tests.
    public init() throws {
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    public static var defaultPath: String {
        URL.applicationSupportDirectory.appendingPathComponent("Needledrop/library.sqlite").path
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "album") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("key", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("year", .integer)
                t.column("artworkPath", .text)
            }
            try db.create(table: "track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("identity", .text).notNull().unique()
                t.column("albumID", .integer).references("album", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("duration", .double)
            }
            try db.create(table: "side") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime).notNull()
                t.column("endReason", .text).notNull()
                t.column("rawPath", .text)
            }
            try db.create(table: "recording") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).references("track", onDelete: .cascade).indexed()
                t.column("sideID", .integer).notNull().references("side", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("format", .text).notNull()
                t.column("sampleRate", .double).notNull()
                t.column("duration", .double).notNull()
                t.column("clippedSamples", .integer).notNull()
                t.column("peakDB", .double).notNull()
                t.column("rmsDB", .double).notNull()
                t.column("uncertainBoundary", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "play") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade).indexed()
                t.column("sideID", .integer).references("side", onDelete: .setNull)
                t.column("playedAt", .datetime).notNull().indexed()
            }
        }
        return m
    }

    // MARK: - Writes

    /// Finds or creates the album and track for a match's metadata. Returns the track ID.
    @discardableResult
    public func upsertTrack(identity: String, metadata m: TrackMetadata, artworkPath: String? = nil) throws -> Int64 {
        try db.write { db in
            var albumID: Int64?
            if let title = m.album {
                let key = m.collectionID ?? "\(m.albumArtist ?? m.artist)|\(title)".lowercased()
                if var album = try AlbumRecord.filter(Column("key") == key).fetchOne(db) {
                    if album.artworkPath == nil, let artworkPath {
                        album.artworkPath = artworkPath
                        try album.update(db)
                    }
                    albumID = album.id
                } else {
                    var album = AlbumRecord(key: key, title: title, artist: m.albumArtist ?? m.artist, year: m.year, artworkPath: artworkPath)
                    try album.insert(db)
                    albumID = album.id
                }
            }
            if var track = try TrackRecord.filter(Column("identity") == identity).fetchOne(db) {
                track.albumID = track.albumID ?? albumID
                track.duration = track.duration ?? m.duration
                try track.update(db)
                return track.id!
            }
            var track = TrackRecord(identity: identity, albumID: albumID, title: m.title, artist: m.artist,
                                    trackNumber: m.trackNumber, discNumber: m.discNumber, duration: m.duration)
            try track.insert(db)
            return track.id!
        }
    }

    public func recordPlay(trackID: Int64, sideID: Int64? = nil, at date: Date = Date()) throws {
        try db.write { db in
            var play = PlayRecord(trackID: trackID, sideID: sideID, playedAt: date)
            try play.insert(db)
        }
    }

    public func insertSide(_ side: SideRecord) throws -> Int64 {
        try db.write { db in
            var side = side
            try side.insert(db)
            return side.id!
        }
    }

    public func setSideID(_ sideID: Int64, forPlaysSince date: Date) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE play SET sideID = ? WHERE sideID IS NULL AND playedAt >= ?", arguments: [sideID, date])
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Keep the new file; these older files are no longer wanted.
        case keep(replacing: [String])
        /// The new file is worse than one we already have.
        case discard
    }

    /// Adds a recording under `policy`, returning which files to delete. Unidentified
    /// recordings are always kept.
    public func addRecording(_ recording: RecordingRecord, policy: DedupPolicy) throws -> Decision {
        try db.write { db in
            var recording = recording
            guard let trackID = recording.trackID, policy == .keepBest else {
                try recording.insert(db)
                return .keep(replacing: [])
            }
            let existing = try RecordingRecord.filter(Column("trackID") == trackID).fetchAll(db)
            let best = existing.reduce(nil as RecordingRecord?) { best, r in
                guard let best else { return r }
                return r.quality.isBetter(than: best.quality) ? r : best
            }
            if let best, !recording.quality.isBetter(than: best.quality) { return .discard }
            for old in existing { try old.delete(db) }
            try recording.insert(db)
            return .keep(replacing: existing.map(\.path))
        }
    }

    // MARK: - Reads

    public func recordings(forTrackIdentity identity: String) throws -> [RecordingRecord] {
        try db.read { db in
            try RecordingRecord.fetchAll(db, sql: """
                SELECT recording.* FROM recording JOIN track ON track.id = recording.trackID
                WHERE track.identity = ? ORDER BY recording.createdAt
                """, arguments: [identity])
        }
    }

    public func playCount(forTrackIdentity identity: String) throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play JOIN track ON track.id = play.trackID WHERE track.identity = ?",
                             arguments: [identity]) ?? 0
        }
    }

    /// Albums by most recent play, with play counts (for the library wall).
    public func albumsByRecentPlay(limit: Int = 200) throws -> [AlbumSummary] {
        try db.read { db in
            try AlbumSummary.fetchAll(db, sql: """
                SELECT album.id AS albumID, album.title, album.artist, album.artworkPath,
                       COUNT(play.id) AS plays, MAX(play.playedAt) AS lastPlayed
                FROM album JOIN track ON track.albumID = album.id JOIN play ON play.trackID = track.id
                GROUP BY album.id ORDER BY lastPlayed DESC LIMIT ?
                """, arguments: [limit])
        }
    }
}
