@testable import Archive
import Foundation
import Metadata
import Recognition
import Testing

@Suite struct LibraryTests {
    private func metadata(_ title: String, album: String = "Rumours", collection: String = "1") -> TrackMetadata {
        var m = TrackMetadata(title: title, artist: "Fleetwood Mac")
        m.album = album
        m.collectionID = collection
        m.duration = 250
        return m
    }

    private func recording(_ trackID: Int64?, side: Int64, path: String, clipped: Int = 0, rms: Double = -16) -> RecordingRecord {
        RecordingRecord(trackID: trackID, sideID: side, path: path, format: "alac", sampleRate: 48_000, duration: 250,
                        clippedSamples: clipped, peakDB: -1, rmsDB: rms, uncertainBoundary: false, createdAt: Date())
    }

    private func side(_ library: Library) throws -> Int64 {
        try library.insertSide(SideRecord(startedAt: Date(), endedAt: Date(), endReason: "runout"))
    }

    @Test func upsertsAlbumsAndTracksOnce() throws {
        let library = try Library()
        let a = try library.upsertTrack(identity: "isrc:A", metadata: metadata("Dreams"))
        let again = try library.upsertTrack(identity: "isrc:A", metadata: metadata("Dreams"))
        let b = try library.upsertTrack(identity: "isrc:B", metadata: metadata("Songbird"), artworkPath: "/art/1.jpg")
        #expect(a == again && a != b)
        try library.recordPlay(trackID: a)
        try library.recordPlay(trackID: b)
        let albums = try library.albumsByRecentPlay()
        #expect(albums.count == 1 && albums[0].plays == 2 && albums[0].artworkPath == "/art/1.jpg")
    }

    @Test func keepBestReplacesOnlyWithBetterRecordings() throws {
        let library = try Library()
        let track = try library.upsertTrack(identity: "isrc:A", metadata: metadata("Dreams"))
        let s = try side(library)

        #expect(try library.addRecording(recording(track, side: s, path: "/1.m4a", rms: -16), policy: .keepBest) == .keep(replacing: []))
        // Quieter: not wanted.
        #expect(try library.addRecording(recording(track, side: s, path: "/2.m4a", rms: -18), policy: .keepBest) == .discard)
        // Clipped, even though louder: not wanted.
        #expect(try library.addRecording(recording(track, side: s, path: "/3.m4a", clipped: 40, rms: -12), policy: .keepBest) == .discard)
        // Cleaner and hotter: replaces the first.
        #expect(try library.addRecording(recording(track, side: s, path: "/4.m4a", rms: -14), policy: .keepBest) == .keep(replacing: ["/1.m4a"]))
        #expect(try library.recordings(forTrackIdentity: "isrc:A").map(\.path) == ["/4.m4a"])
    }

    @Test func keepAllAndUnknownsKeepEverything() throws {
        let library = try Library()
        let track = try library.upsertTrack(identity: "isrc:A", metadata: metadata("Dreams"))
        let s = try side(library)
        _ = try library.addRecording(recording(track, side: s, path: "/1.m4a"), policy: .keepAll)
        _ = try library.addRecording(recording(track, side: s, path: "/2.m4a", rms: -30), policy: .keepAll)
        #expect(try library.recordings(forTrackIdentity: "isrc:A").count == 2)
        #expect(try library.addRecording(recording(nil, side: s, path: "/u.m4a"), policy: .keepBest) == .keep(replacing: []))
    }

    @Test func persistsOnDisk() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-lib-\(UUID())/library.sqlite").path
        let id = try Library(path: path).upsertTrack(identity: "isrc:A", metadata: metadata("Dreams"))
        try Library(path: path).recordPlay(trackID: id)
        #expect(try Library(path: path).playCount(forTrackIdentity: "isrc:A") == 1)
    }
}

@Suite struct ArchiverTests {
    @Test func metadataArrivingBeforeTheTrackIsStillUsed() async throws {
        let archiver = Archiver(settings: ArchiveSettings(), library: nil)
        var info = TrackMetadata(title: "Dreams", artist: "Fleetwood Mac")
        info.album = "Rumours"
        info.duration = 257
        let match = TrackMatch(title: "Dreams", artist: "Fleetwood Mac", isrc: "A")
        _ = await archiver.handle(.metadata(identity: match.identity, info, artwork: nil))
        _ = await archiver.handle(.trackSeen(match, clockStart: 0, at: 1))
        #expect(await archiver.observedAlbums() == ["Rumours"])
        #expect(await archiver.observedDurations() == [257])
    }
}
