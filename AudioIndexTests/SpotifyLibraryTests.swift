// AudioIndexTests/SpotifyLibraryTests.swift
import XCTest

@testable import AudioIndex

final class SpotifyLibraryTests: XCTestCase {
    private func page(_ json: String) throws -> SavedTracksPage {
        try JSONDecoder().decode(SavedTracksPage.self, from: Data(json.utf8))
    }

    func testMapsOneTrack() throws {
        let p = try page(
            """
            {"items":[{"track":{"uri":"spotify:track:x","name":"Seraph","duration_ms":236000,
              "artists":[{"name":"Ash Meridian"}],"album":{"name":"Unsaid"}}}],"next":null}
            """)
        let out = syncTracks(from: p)
        XCTAssertEqual(
            out,
            [
                SyncTrack(
                    artist: "Ash Meridian", title: "Seraph", album: "Unsaid",
                    duration_ms: 236000, source: "spotify",
                    source_ref: "spotify:track:x")
            ])
    }

    // Spotify returns an ARRAY of artists. Joining them would produce a string
    // Navidrome will never reproduce for the same recording, and track_id is a
    // hash of artist and title - so the same song would land as two identities
    // with two separate histories once local files arrive.
    func testUsesOnlyTheFirstArtist() throws {
        let p = try page(
            """
            {"items":[{"track":{"uri":"spotify:track:y","name":"Song","duration_ms":1000,
              "artists":[{"name":"Alpha"},{"name":"Beta"}],"album":{"name":"A"}}}],"next":null}
            """)
        XCTAssertEqual(syncTracks(from: p).first?.artist, "Alpha")
    }

    // A track saved from a local file has a null uri. It cannot be played
    // through App Remote, so putting it in the index would seed the queue with
    // entries that silently fail.
    func testSkipsTracksWithNoUri() throws {
        let p = try page(
            """
            {"items":[{"track":{"uri":null,"name":"Local","duration_ms":1000,
              "artists":[{"name":"A"}],"album":{"name":"B"}}}],"next":null}
            """)
        XCTAssertTrue(syncTracks(from: p).isEmpty)
    }

    func testSkipsTracksWithNoArtistOrEmptyName() throws {
        let p = try page(
            """
            {"items":[
              {"track":{"uri":"spotify:track:a","name":"","duration_ms":1,"artists":[{"name":"A"}],"album":{"name":"B"}}},
              {"track":{"uri":"spotify:track:b","name":"Fine","duration_ms":1,"artists":[],"album":{"name":"B"}}}
            ],"next":null}
            """)
        XCTAssertTrue(syncTracks(from: p).isEmpty)
    }

    func testSurvivesAMissingAlbum() throws {
        let p = try page(
            """
            {"items":[{"track":{"uri":"spotify:track:z","name":"S","duration_ms":1,
              "artists":[{"name":"A"}]}}],"next":null}
            """)
        XCTAssertEqual(syncTracks(from: p).first?.album, nil)
    }

    func testReadsTheNextPageURL() throws {
        let p = try page(
            """
            {"items":[],"next":"https://api.spotify.com/v1/me/tracks?offset=50&limit=50"}
            """)
        XCTAssertEqual(p.next, "https://api.spotify.com/v1/me/tracks?offset=50&limit=50")
    }
}
