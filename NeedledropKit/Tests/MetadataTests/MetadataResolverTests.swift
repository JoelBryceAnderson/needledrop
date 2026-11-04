import Foundation
import Metadata
import Recognition
import Synchronization
import Testing

/// Serves canned responses by URL substring and counts requests.
private final class FakeHTTP: HTTPClient {
    let routes: [(String, Data)]
    let requests = Mutex<[URL]>([])

    init(_ routes: [(String, String)]) {
        self.routes = routes.map { ($0.0, Data($0.1.utf8)) }
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        requests.withLock { $0.append(url) }
        guard let route = routes.first(where: { url.absoluteString.contains($0.0) }) else { throw URLError(.fileDoesNotExist) }
        return route.1
    }

    var count: Int { requests.withLock { $0.count } }
}

private let lookupJSON = """
{"resultCount":2,"results":[
 {"wrapperType":"track","kind":"song","trackId":1440833098,"collectionId":1440832918,
  "artistName":"Fleetwood Mac","collectionName":"Rumours (Super Deluxe)","trackName":"Dreams",
  "artworkUrl100":"https://is1.mzstatic.com/image/thumb/Music/x/100x100bb.jpg",
  "releaseDate":"1977-02-04T08:00:00Z","trackCount":11,"trackNumber":2,"discNumber":1,
  "trackTimeMillis":257800,"primaryGenreName":"Rock"}]}
"""

private let searchJSON = """
{"resultCount":3,"results":[
 {"kind":"song","trackId":1,"collectionId":10,"artistName":"Various Artists","collectionArtistName":"Various Artists",
  "collectionName":"80s Hits","trackName":"Dreams","releaseDate":"2001-01-01T00:00:00Z","trackTimeMillis":250000},
 {"kind":"song","trackId":2,"collectionId":20,"artistName":"Fleetwood Mac","collectionName":"Greatest Hits",
  "trackName":"Dreams","releaseDate":"1988-11-21T00:00:00Z","trackTimeMillis":254000},
 {"kind":"song","trackId":3,"collectionId":30,"artistName":"Fleetwood Mac","collectionName":"Rumours",
  "trackName":"Dreams (2004 Remaster)","releaseDate":"1977-02-04T00:00:00Z","trackTimeMillis":257000,
  "artworkUrl100":"https://example.com/rumours/100x100bb.jpg"}]}
"""

@Suite struct MetadataResolverTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-meta-\(UUID())")
    }

    @Test func looksUpByAppleMusicID() async {
        let http = FakeHTTP([("lookup?id=1440833098", lookupJSON)])
        let resolver = MetadataResolver(cacheDirectory: tempDir(), http: http)
        let m = await resolver.resolve(TrackMatch(title: "Dreams", artist: "Fleetwood Mac", appleMusicID: "1440833098"))
        #expect(m.album == "Rumours")
        #expect(m.year == 1977)
        #expect(m.trackNumber == 2 && m.trackCount == 11)
        #expect(m.duration == 257.8)
        #expect(m.collectionID == "1440832918")
        #expect(m.artworkURL?.absoluteString.hasSuffix("3000x3000bb.jpg") == true)
    }

    @Test func searchPrefersTheOriginalAlbum() async {
        let http = FakeHTTP([("search?", searchJSON)])
        let resolver = MetadataResolver(cacheDirectory: tempDir(), http: http)
        let m = await resolver.resolve(TrackMatch(title: "Dreams", artist: "Fleetwood Mac"))
        #expect(m.album == "Rumours")
        #expect(m.appleMusicID == "3")
    }

    @Test func searchRejectsTheSameTitleByAnotherArtist() async {
        let http = FakeHTTP([("search?", """
            {"resultCount":2,"results":[
             {"kind":"song","trackId":1,"collectionId":10,"artistName":"Someone Else","collectionName":"Elsewhere",
              "trackName":"Dreams","releaseDate":"1970-01-01T00:00:00Z"},
             {"kind":"song","trackId":2,"collectionId":20,"artistName":"Cranberries","collectionName":"Everybody Else",
              "trackName":"Dreams","releaseDate":"1993-03-01T00:00:00Z"}]}
            """)])
        let resolver = MetadataResolver(cacheDirectory: tempDir(), http: http)
        let hit = await resolver.resolve(TrackMatch(title: "Dreams", artist: "The Cranberries"))
        #expect(hit.album == "Everybody Else")  // "The" ignored; "Someone Else" never considered
        let miss = await resolver.resolve(TrackMatch(title: "Dreams", artist: "Fleetwood Mac"))
        #expect(miss.album == nil && miss.artist == "Fleetwood Mac")  // no wrong record
    }

    @Test func cachesOnDiskAcrossInstances() async {
        let dir = tempDir()
        let match = TrackMatch(title: "Dreams", artist: "Fleetwood Mac", appleMusicID: "1440833098")
        let http = FakeHTTP([("lookup?id=1440833098", lookupJSON)])
        _ = await MetadataResolver(cacheDirectory: dir, http: http).resolve(match)
        let again = await MetadataResolver(cacheDirectory: dir, http: http).resolve(match)
        #expect(http.count == 1)
        #expect(again.album == "Rumours")
    }

    @Test func fallsBackToTheMatchWhenOffline() async {
        let resolver = MetadataResolver(cacheDirectory: tempDir(), http: FakeHTTP([]))
        let art = URL(string: "https://example.com/a.jpg")!
        let m = await resolver.resolve(TrackMatch(title: "Rare B-side", artist: "Nobody", artworkURL: art))
        #expect(m.title == "Rare B-side" && m.album == nil && m.artworkURL == art)
    }

    @Test func artworkIsCachedPerAlbum() async {
        let http = FakeHTTP([("lookup?id=", lookupJSON), ("mzstatic", "JPEGBYTES")])
        let resolver = MetadataResolver(cacheDirectory: tempDir(), http: http)
        let m = await resolver.resolve(TrackMatch(title: "Dreams", artist: "Fleetwood Mac", appleMusicID: "1440833098"))
        let first = await resolver.artwork(for: m)
        let second = await resolver.artwork(for: m)
        #expect(first == Data("JPEGBYTES".utf8) && second == first)
        #expect(http.count == 2)  // one lookup, one image
    }
}

@Suite struct ArtistMatchTests {
    @Test func creditsMatchWhateverTheOrderOrStyling() {
        // Apple Music vs the iTunes catalogue for the same record.
        #expect(MetadataResolver.artistMatch("JAY-Z & Kanye West", "Kanye West & JAŸ-Z") == 2)
        #expect(MetadataResolver.artistMatch("Beyonce", "Beyoncé") == 3)
        #expect(MetadataResolver.artistMatch("Childish Gambino", "Childish Gambino") == 3)
        #expect(MetadataResolver.artistMatch("Kanye West", "Kanye West, JAY-Z feat. Frank Ocean") == 1)
        // Still no match for someone else's song of the same name.
        #expect(MetadataResolver.artistMatch("Fleetwood Mac", "The Corrs") == 0)
        #expect(MetadataResolver.artistMatch("JAY-Z & Kanye West", "Otis Redding") == 0)
    }
}
