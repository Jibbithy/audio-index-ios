// AudioIndexTests/LibraryTests.swift
import XCTest

@testable import AudioIndex

/// Everything the library browser can get wrong that does not need a screen:
/// the search filter, the cover-art URL, and the mapping from a Subsonic song
/// to the things the rest of the app already speaks. No network, no simulator,
/// no AVPlayer.

private func song(
    _ id: String = "s1", _ title: String = "A Song",
    artist: String? = "[Unknown Artist]", album: String? = "Unknown Album",
    duration: Int? = 247, coverArt: String? = nil
) -> SubsonicSong {
    SubsonicSong(
        id: id, title: title, artist: artist, album: album,
        duration: duration, coverArt: coverArt)
}

/// A row as atlas hands it over: one identity, one place to play it from.
private func track(
    _ id: String, _ title: String, artist: String = "[Unknown Artist]",
    source: String = "file"
) -> TrackRef {
    TrackRef(
        track_id: id, source: source, source_ref: "navidrome:\(id)",
        artist: artist, title: title)
}

// MARK: - Search

final class LibrarySearchTests: XCTestCase {

    /// Shaped like the real library: filenames as titles on the untagged
    /// files, `[Unknown Artist]` throughout, and an accented artist.
    private let library = [
        track("s1", "01 - Lumenfall - Harbor.mp3"),
        track("s2", "velvet static - #3 [collected drift works vol II].mp3"),
        track("s3", "track01.mp3"),
        track("s4", "Déjà Vu (Live)", artist: "Renée"),
        track("s5", "Untitled #1", artist: "Vetur Ljós"),
    ]

    private func ids(_ query: String) -> [String] {
        librarySearch(library, matching: query).map(\.track_id)
    }

    /// The whole library, not nothing. An empty box is not a filter that
    /// matches zero rows.
    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(ids(""), ["s1", "s2", "s3", "s4", "s5"])
        XCTAssertEqual(ids("   "), ["s1", "s2", "s3", "s4", "s5"])
    }

    func testMatchesTheTitle() {
        XCTAssertEqual(ids("harbor"), ["s1"])
        XCTAssertEqual(ids("track01"), ["s3"])
    }

    /// The artist is half of what anyone types. Matching only titles would make
    /// "renee" find nothing on a library that has her on it.
    func testMatchesTheArtist() {
        XCTAssertEqual(ids("Renée"), ["s4"])
        XCTAssertEqual(ids("vetur"), ["s5"])
    }

    /// Nobody types the capitals of a filename they half remember.
    func testIsCaseInsensitive() {
        XCTAssertEqual(ids("LUMENFALL"), ["s1"])
        XCTAssertEqual(ids("vElVeT"), ["s2"])
        XCTAssertEqual(ids("VETUR LJÓS"), ["s5"])
    }

    /// And nobody reaches for the accented keys. "renee" has to find
    /// "Renée", in the artist AND in a title.
    func testIsDiacriticInsensitive() {
        XCTAssertEqual(ids("renee"), ["s4"])
        XCTAssertEqual(ids("deja vu"), ["s4"])
        XCTAssertEqual(ids("vetur ljos"), ["s5"])
    }

    func testNoMatchIsEmptyRatherThanEverything() {
        XCTAssertTrue(ids("zzzz").isEmpty)
    }

    /// The order the server gave them, untouched: a filter is not a sort, and a
    /// list that reshuffles as you type is unusable. Atlas orders by artist and
    /// then title, and the search must not quietly re-order that.
    func testKeepsServerOrder() {
        XCTAssertEqual(ids(".mp3"), ["s1", "s2", "s3"])
    }

    /// A blank artist is an empty string, not a haystack that matches anything.
    func testATrackWithNoArtistStillMatchesOnTitle() {
        let anonymous = [track("s9", "Harbor", artist: "")]
        XCTAssertEqual(librarySearch(anonymous, matching: "harbor").map(\.track_id), ["s9"])
        XCTAssertTrue(librarySearch(anonymous, matching: "unknown").isEmpty)
    }

    /// A Spotify row and a file row are one list and are searched as one.
    func testSearchesBothSourcesTogether() {
        let mixed = [
            track("t1", "Nightfall", artist: "Velour", source: "spotify"),
            track("t2", "night walk.mp3"),
        ]
        XCTAssertEqual(librarySearch(mixed, matching: "night").count, 2)
    }
}

// MARK: - Cover art

final class LibraryCoverArtTests: XCTestCase {
    // Obviously fake, and nothing here ever reaches a server.
    private let creds = NavidromeCredentials(
        baseURL: URL(string: "http://music.example")!,
        username: "tester",
        password: "fake-password")

    /// A fixed salt so the token is a known constant - md5("fake-password" +
    /// "s4lt"), taken from `md5(1)` rather than computed with the helper under
    /// test. Nothing in the app ever passes a fixed salt.
    private func client() -> NavidromeClient {
        var c = NavidromeClient(credentials: { self.creds })
        c.salt = { "s4lt" }
        return c
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, b in b }
    }

    func testCoverArtURLIsSignedAndCarriesTheId() throws {
        let url = try client().coverArtURL(for: "al-0a1b")
        XCTAssertEqual(url.path, "/rest/getCoverArt.view")

        let q = query(url)
        XCTAssertEqual(q["id"], "al-0a1b")
        XCTAssertEqual(q["u"], "tester")
        XCTAssertEqual(q["t"], "e2425e602b1ce8bd1b1f4e24e6905af5")
        XCTAssertEqual(q["s"], "s4lt")
        XCTAssertEqual(q["v"], "1.16.1")
        XCTAssertEqual(q["c"], "audioindex")
        XCTAssertEqual(q["f"], "json")
    }

    /// The same rule as every other call: the raw password is the one thing
    /// that must never be in a query string, because that is the part of a
    /// request that lands verbatim in server and proxy logs.
    func testTheRawPasswordNeverAppearsInACoverURL() throws {
        let url = try client().coverArtURL(for: "al-0a1b", size: 300)
        XCTAssertFalse(url.absoluteString.contains("fake-password"))
        XCTAssertNil(query(url)["p"])
    }

    /// A 52pt thumbnail served at full resolution is about a megabyte per row.
    func testSizeIsSentWhenAskedForAndOmittedWhenNot() throws {
        XCTAssertEqual(query(try client().coverArtURL(for: "x", size: 300))["size"], "300")
        XCTAssertNil(query(try client().coverArtURL(for: "x"))["size"])
    }

    func testNoCredentialsMeansNoURL() {
        var c = NavidromeClient(credentials: { nil })
        c.salt = { "s4lt" }
        XCTAssertThrowsError(try c.coverArtURL(for: "x")) { error in
            XCTAssertEqual(error as? NavidromeError, .notConfigured)
        }
    }

}

// MARK: - Mapping a browsed song to a playable track

final class LibraryTrackRefTests: XCTestCase {

    /// A play from the browser has to route, display and scrobble through the
    /// paths that already exist, which all speak `TrackRef`.
    func testMapsASongToAFileTrack() {
        XCTAssertEqual(
            trackRef(from: song("al-0a1b", "01 - Lumenfall - Harbor.mp3")),
            TrackRef(
                track_id: "navidrome:al-0a1b",
                source: "file",
                source_ref: "navidrome:al-0a1b",
                artist: "[Unknown Artist]",
                title: "01 - Lumenfall - Harbor.mp3"))
    }

    /// The ref has to survive the round trip into the router, or the tap plays
    /// nothing and the row looks broken.
    func testTheRefRoutesToTheLocalPlayer() throws {
        let track = try XCTUnwrap(trackRef(from: song("al-0a1b")))
        XCTAssertEqual(playbackRoute(for: track, hasNavidrome: true), .local(navidromeID: "al-0a1b"))
    }

    /// Verbatim, `"[Unknown Artist]"` included: those files are deliberately
    /// untagged, and inventing an artist here mints an identity the server can
    /// never reproduce.
    func testKeepsTheArtistExactlyAsReported() {
        XCTAssertEqual(
            trackRef(from: song(artist: "[Unknown Artist]"))?.artist,
            "[Unknown Artist]")
        XCTAssertEqual(trackRef(from: song(artist: nil))?.artist, "")
    }

    /// Same rule as the sync path: no id is nothing to stream, no title is
    /// nothing to identify it by.
    func testRejectsSongsThatCannotBePlayed() {
        XCTAssertNil(trackRef(from: song("", "Fine")))
        XCTAssertNil(trackRef(from: song("s1", "")))
    }

    /// The browser and the sync agree about what a song is called on the wire.
    /// A divergence would make every browsed play a track atlas has never seen.
    func testAgreesWithTheSyncPathAboutTheRef() {
        let mapped = trackRef(from: song("al-0a1b"))
        XCTAssertEqual(mapped?.source_ref, syncTracks(from: [song("al-0a1b")]).first?.source_ref)
        XCTAssertEqual(mapped?.source, syncTracks(from: [song("al-0a1b")]).first?.source)
    }
}
