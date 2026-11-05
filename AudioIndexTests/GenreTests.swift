// AudioIndexTests/GenreTests.swift
import XCTest

@testable import AudioIndex

/// The pure half of genres: what Spotify's replies mean, and which chips the
/// counts turn into. Neither needs a network, a server or a screen.
final class GenreMappingTests: XCTestCase {

    private func page(_ json: String) throws -> SavedTracksPage {
        try JSONDecoder().decode(SavedTracksPage.self, from: Data(json.utf8))
    }

    private let twoTracks = """
        {"items":[
          {"track":{"uri":"spotify:track:1","name":"Seraph","duration_ms":236000,
                    "artists":[{"id":"a1","name":"Ash Meridian"},{"id":"a2","name":"Someone"}],
                    "album":{"name":"Unsaid"}}},
          {"track":{"uri":"spotify:track:2","name":"Pale Echoes","duration_ms":214000,
                    "artists":[{"id":"a3","name":"Six Reed"}],"album":{"name":"Here Is Light"}}}
        ],"next":null}
        """

    func testTrackArtistsTakesTheFirstArtistOnly() throws {
        let rows = trackArtists(from: try page(twoTracks))
        XCTAssertEqual(
            rows,
            [
                TrackArtist(source_ref: "spotify:track:1", artistID: "a1"),
                TrackArtist(source_ref: "spotify:track:2", artistID: "a3"),
            ])
    }

    // The same rule syncTracks(from:) uses, and it has to be the same rule: a
    // track dropped from the sync but kept here would send atlas a ref it has
    // never heard of, and one kept there but dropped here would never be genred.
    func testATrackWithNoUriOrNoArtistIsDropped() throws {
        let rows = trackArtists(
            from: try page(
                """
                {"items":[
                  {"track":{"uri":null,"name":"Local File","duration_ms":1,"artists":[{"id":"a1","name":"X"}],"album":null}},
                  {"track":{"uri":"spotify:track:9","name":"No Artists","duration_ms":1,"artists":[],"album":null}},
                  {"track":{"uri":"spotify:track:8","name":"Blank Id","duration_ms":1,"artists":[{"id":"","name":"X"}],"album":null}}
                ],"next":null}
                """))
        XCTAssertEqual(rows, [])
    }

    func testArtistGenresAreReadByArtistId() throws {
        let reply = try JSONDecoder().decode(
            ArtistsReply.self,
            from: Data(
                """
                {"artists":[
                  {"id":"a1","genres":["dubstep","future garage"]},
                  null,
                  {"id":"a3","genres":[]}
                ]}
                """.utf8))
        XCTAssertEqual(genresByArtist(from: reply), ["a1": ["dubstep", "future garage"], "a3": []])
    }

    // A track whose artist Spotify has no genres for still gets a row, carrying
    // an EMPTY list. Sending nothing would leave a stale genre standing on
    // atlas forever, because the server replaces per source rather than merging.
    func testEveryTrackGetsARowEvenWithNoGenres() throws {
        let rows = genreRows(
            for: trackArtists(from: try page(twoTracks)),
            genres: ["a1": ["dubstep"]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].source_ref, "spotify:track:1")
        XCTAssertEqual(rows[0].genres, ["dubstep"])
        XCTAssertEqual(rows[1].genres, [])
        XCTAssertEqual(rows[1].source, "spotify")
    }

    // Spotify's cap is 50 ids per call. A library of a few hundred artists is
    // several calls, and the tail must not be silently dropped.
    func testArtistIdsAreDeduplicatedForFetching() {
        let rows = (0..<120).map { TrackArtist(source_ref: "r\($0)", artistID: "a\($0 % 30)") }
        XCTAssertEqual(uniqueArtistIDs(rows).count, 30)
    }
}

final class GenreChipTests: XCTestCase {

    private func summary(_ pairs: [(String, Int)], untagged: Int = 0) -> GenreSummary {
        GenreSummary(
            genres: pairs.map { GenreCount(genre: $0.0, track_count: $0.1) },
            untagged: untagged)
    }

    func testChipsLeadWithAllAndKeepTheServersOrder() {
        let chips = genreChips(summary([("electronic", 40), ("dubstep", 12)]), top: 12)
        XCTAssertEqual(chips.map(\.filter), [.all, .genre("electronic"), .genre("dubstep")])
        XCTAssertEqual(chips[1].label, "electronic")
        XCTAssertEqual(chips[1].count, 40)
    }

    func testOnlyTheTopGenresGetAChip() {
        let many = (1...20).map { ("g\($0)", 100 - $0) }
        let chips = genreChips(summary(many), top: 12)
        // All + 12 genres. Everything else lives in the sheet.
        XCTAssertEqual(chips.count, 13)
        XCTAssertEqual(chips.last?.filter, .genre("g12"))
    }

    // The untagged chip is not a genre named "": those tracks are most of a
    // fresh library, and having no way to see them would read as data loss.
    func testUntaggedGetsItsOwnChipOnlyWhenThereAreSome() {
        XCTAssertEqual(genreChips(summary([("jazz", 1)], untagged: 3)).last?.filter, .untagged)
        XCTAssertNil(
            genreChips(summary([("jazz", 1)], untagged: 0))
                .first { $0.filter == .untagged })
    }

    func testAnEmptyLibraryHasNoChipsAtAll() {
        XCTAssertEqual(genreChips(summary([])), [])
    }
}

// MARK: - Genres inside one playlist

final class PlaylistGenreTests: XCTestCase {

    private static func entry(
        _ position: Int, _ trackID: String, _ genres: [String],
        source: String? = "spotify"
    ) -> PlaylistEntry {
        PlaylistEntry(
            entry_id: "e\(position)", position: position, track_id: trackID,
            source: source, source_ref: source == nil ? nil : "spotify:track:\(trackID)",
            artist: "Someone", title: "Song \(position)", genres: genres)
    }

    private let list = [
        PlaylistGenreTests.entry(0, "t1", ["rock", "grunge"]),
        PlaylistGenreTests.entry(1, "t2", ["rock"]),
        PlaylistGenreTests.entry(2, "t3", []),
        PlaylistGenreTests.entry(3, "t1", ["rock", "grunge"]),  // the same track a second time
    ]

    /// ENTRIES, not tracks. This playlist shows "t1" twice, and a chip reading
    /// "1" over two visible rows is wrong in the easiest place to check.
    func testCountsEntriesRatherThanTracks() {
        XCTAssertEqual(
            genreSummary(of: list).genres,
            [
                GenreCount(genre: "rock", track_count: 3),
                GenreCount(genre: "grunge", track_count: 2),
            ])
    }

    func testCountsTheEntriesWithNoGenreAtAll() {
        XCTAssertEqual(genreSummary(of: list).untagged, 1)
    }

    /// A genre repeated on one entry must not count twice - the server sends
    /// them distinct, and this does not lean on that.
    func testADuplicateGenreOnOneEntryCountsOnce() {
        let summary = genreSummary(of: [PlaylistGenreTests.entry(0, "t1", ["rock", "rock"])])
        XCTAssertEqual(summary.genres, [GenreCount(genre: "rock", track_count: 1)])
    }

    func testAnEmptyPlaylistHasNoChips() {
        XCTAssertEqual(genreChips(genreSummary(of: [])), [])
    }

    // MARK: Filtering

    func testFilteringKeepsThePlaylistsOwnOrder() {
        XCTAssertEqual(
            entries(list, matching: .genre("rock")).map(\.entry_id),
            ["e0", "e1", "e3"])
    }

    func testTheUntaggedChipKeepsTheEntriesWithNoGenres() {
        XCTAssertEqual(entries(list, matching: .untagged).map(\.entry_id), ["e2"])
    }

    func testAllIsNotAFilter() {
        XCTAssertEqual(entries(list, matching: .all).count, 4)
    }

    /// Positions are NOT renumbered by a filter: they order the whole playlist
    /// and are what "play from here" is addressed by, so a filtered list has to
    /// keep the originals or a tapped row starts the wrong track.
    func testFilteringLeavesPositionsAlone() {
        XCTAssertEqual(entries(list, matching: .genre("grunge")).map(\.position), [0, 3])
    }

    /// A dead row - nothing to play it from - still carries its genres and is
    /// still shown under its chip. It is on screen so it can be removed.
    func testADeadRowIsStillFilteredNormally() {
        let dead = [PlaylistGenreTests.entry(0, "t9", ["jazz"], source: nil)]
        XCTAssertEqual(entries(dead, matching: .genre("jazz")).count, 1)
    }
}
