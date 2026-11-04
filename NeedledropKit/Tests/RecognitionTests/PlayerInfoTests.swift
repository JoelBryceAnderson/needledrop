import Recognition
import Testing

@Suite struct PlayerInfoTests {
    @Test func readsAppleMusic() throws {
        let track = try #require(PlayerTrack(source: .appleMusic, userInfo: [
            "Name": "Dreams", "Artist": "Fleetwood Mac", "Album": "Rumours",
            "Total Time": 257_800, "Player State": "Playing",
        ]))
        #expect(track.title == "Dreams" && track.album == "Rumours" && track.playing)
        #expect(track.duration == 257.8 && track.position == nil)
    }

    @Test func readsSpotifyWithPosition() throws {
        let track = try #require(PlayerTrack(source: .spotify, userInfo: [
            "Name": "Redbone", "Artist": "Childish Gambino", "Duration": 326_000,
            "Playback Position": 42.5, "Player State": "Paused",
        ]))
        #expect(track.position == 42.5 && !track.playing && track.duration == 326)
    }

    @Test func ignoresStopsAndMissingMetadata() {
        #expect(PlayerTrack(source: .appleMusic, userInfo: ["Player State": "Stopped"]) == nil)
        #expect(PlayerTrack(source: .appleMusic, userInfo: ["Name": "Live radio", "Player State": "Playing"]) == nil)
        #expect(PlayerTrack(source: .spotify, userInfo: ["Name": "X", "Artist": "Y", "Player State": "Stopped"]) == nil)
    }
}
