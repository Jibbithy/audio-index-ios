// AudioIndexTests/PlaylistsTests.swift
import XCTest

@testable import AudioIndex

/// Everything about a playlist that can be wrong without a screen: what the
/// wire shapes decode to, and which of a playlist's entries something can
/// actually play. No network, no simulator, no AVPlayer.

// MARK: - Decoding

final class PlaylistDecodingTests: XCTestCase {

    func testPlaylistDecodesTheListRow() throws {
        let json = Data(
            """
            {"id":"7f1e","name":"Late drive","track_count":12,"updated_at":1757300000000}
            """.utf8)
        let p = try JSONDecoder().decode(Playlist.self, from: json)
        XCTAssertEqual(p.id, "7f1e")
        XCTAssertEqual(p.id, p.id)
        XCTAssertEqual(p.name, "Late drive")
        XCTAssertEqual(p.track_count, 12)
        XCTAssertEqual(p.updated_at, 1_757_300_000_000)
    }

    /// The create and rename replies are the playlist ROW: id, name and the two
    /// timestamps, with no count. Decoding must not throw on the missing key -
    /// it did, once, and every "New playlist…" failed with a decoding error
    /// after the playlist had already been made on the server.
    func testPlaylistDecodesACreateReplyWithNoCount() throws {
        let json = Data(
            """
            {"id":"7f1e","name":"Sunday morning","created_at":1757300000000,
             "updated_at":1757300000000}
            """.utf8)
        let p = try JSONDecoder().decode(Playlist.self, from: json)
        XCTAssertEqual(p.name, "Sunday morning")
        XCTAssertEqual(p.track_count, 0)
    }

    func testDetailDecodesEntriesInOrder() throws {
        let json = Data(
            """
            {"id":"7f1e","name":"Late drive","created_at":1,"updated_at":2,"tracks":[
              {"entry_id":"e-1","position":0,"track_id":"t1","source":"spotify",
               "source_ref":"spotify:track:x",
               "artist":"Cold Orchard","title":"Nothing Out Of Place"},
              {"entry_id":"e-2","position":1,"track_id":"t2","source":"file",
               "source_ref":"navidrome:nd-01",
               "artist":"[Unknown Artist]","title":"01 - Lumenfall - Harbor.mp3"}
            ]}
            """.utf8)
        let d = try JSONDecoder().decode(PlaylistDetail.self, from: json)
        XCTAssertEqual(d.name, "Late drive")
        XCTAssertEqual(d.tracks.map(\.position), [0, 1])
        // Positions order the list; the entry_id is what names a row in it.
        XCTAssertEqual(d.tracks.map(\.entry_id), ["e-1", "e-2"])
        XCTAssertEqual(d.tracks.map(\.id), ["e-1", "e-2"])
        // One list, two sources. This is the whole feature in one assertion.
        XCTAssertEqual(d.tracks.map(\.source), ["spotify", "file"])
        XCTAssertEqual(d.tracks[1].source_ref, "navidrome:nd-01")
    }

    /// An entry atlas holds and has nowhere to play from arrives with BOTH
    /// `source` and `source_ref` null. It must decode, because the row is going
    /// on screen: a playlist that silently drops entries is worse than one that
    /// shows a dead row.
    func testEntryDecodesANullSource() throws {
        let json = Data(
            """
            {"entry_id":"e-9","position":3,"track_id":"t9","source":null,"source_ref":null,
             "artist":"Say Say","title":"Green Field"}
            """.utf8)
        let e = try JSONDecoder().decode(PlaylistEntry.self, from: json)
        XCTAssertNil(e.source)
        XCTAssertNil(e.source_ref)
        XCTAssertEqual(e.title, "Green Field")
        XCTAssertEqual(e.position, 3)
        // Keyed on the ENTRY, not the position: the server closes the gap
        // after a removal, so position 3 will shortly be a different song.
        XCTAssertEqual(e.id, "e-9")
    }

    /// The same track twice in one playlist is two entries with two ids, and
    /// both have to survive to the screen. Keying on `track_id` collapsed them
    /// into one row; keying on `position` renamed the survivor after every
    /// removal above it, which is what SwiftUI uses to decide a row is "the
    /// same row" across a reload.
    func testTwoEntriesOfOneTrackStayTwoRows() throws {
        let json = Data(
            """
            {"id":"7f1e","name":"Late drive","tracks":[
              {"entry_id":"e-a","position":0,"track_id":"t1","source":"spotify",
               "source_ref":"spotify:track:x","artist":"Cold Orchard","title":"Bare"},
              {"entry_id":"e-b","position":1,"track_id":"t1","source":"spotify",
               "source_ref":"spotify:track:x","artist":"Cold Orchard","title":"Bare"}
            ]}
            """.utf8)
        let d = try JSONDecoder().decode(PlaylistDetail.self, from: json)
        XCTAssertEqual(d.tracks.count, 2)
        XCTAssertEqual(d.tracks[0].track_id, d.tracks[1].track_id)
        XCTAssertNotEqual(d.tracks[0].id, d.tracks[1].id)
        XCTAssertEqual(Set(d.tracks.map(\.id)).count, 2)
    }

    /// What `POST /playlists/:id/tracks` now answers with. The append carries
    /// the entry it created, which is what lets the new row go on screen
    /// without the whole playlist being read back.
    func testAddedReplyDecodesTheEntryItMade() throws {
        let json = Data(#"{"ok":true,"entry_id":"e-4c1a","position":4,"track_id":"t7"}"#.utf8)
        let added = try JSONDecoder().decode(PlaylistAdded.self, from: json)
        XCTAssertEqual(added.entry_id, "e-4c1a")
        XCTAssertEqual(added.position, 4)
        XCTAssertEqual(added.track_id, "t7")
    }

    func testAdditionEncodesTheFourFieldsThatLetATrackSelfRegister() throws {
        let addition = PlaylistAddition(
            track: TrackRef(
                track_id: "t", source: "file", source_ref: "navidrome:nd-01",
                artist: "[Unknown Artist]", title: "track01.mp3"))
        let obj =
            try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(addition)) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["source", "source_ref", "artist", "title"])
        XCTAssertEqual(obj["title"] as? String, "track01.mp3")
    }
}

// MARK: - What plays

final class PlayablePlaylistTests: XCTestCase {

    private func entry(
        _ position: Int, source: String?, ref: String?,
        title: String = "t"
    ) -> PlaylistEntry {
        PlaylistEntry(
            entry_id: "e-\(position)", position: position,
            track_id: "id-\(position)", source: source,
            source_ref: ref, artist: "a", title: title)
    }

    private let mixed = [
        PlaylistEntry(
            entry_id: "e-0", position: 0, track_id: "t0", source: "spotify",
            source_ref: "spotify:track:x", artist: "a", title: "spotify one"),
        PlaylistEntry(
            entry_id: "e-1", position: 1, track_id: "t1", source: nil,
            source_ref: nil, artist: "a", title: "no source"),
        PlaylistEntry(
            entry_id: "e-2", position: 2, track_id: "t2", source: "file",
            source_ref: "navidrome:nd-01", artist: "a", title: "a file"),
    ]

    /// Both sources come through, in the playlist's own order, and the dead
    /// entry is dropped from what PLAYS - never from what is shown.
    func testOnlyEntriesWithASourceArePlayed() {
        let tracks = playableTracks(of: mixed)
        XCTAssertEqual(tracks.map(\.title), ["spotify one", "a file"])
        XCTAssertEqual(tracks.map(\.source), ["spotify", "file"])
        XCTAssertEqual(tracks.map(\.source_ref), ["spotify:track:x", "navidrome:nd-01"])
        // The track identity is atlas's, not one rebuilt from the ref: that is
        // what lets one playlist entry change source without changing track.
        XCTAssertEqual(tracks.map(\.track_id), ["t0", "t2"])
    }

    /// A half-null entry is as unplayable as a fully null one. A `source` with
    /// no ref would be handed to a player as an empty URI.
    func testAnEntryWithASourceButNoRefIsNotPlayable() {
        XCTAssertTrue(playableTracks(of: [entry(0, source: "spotify", ref: nil)]).isEmpty)
        XCTAssertTrue(playableTracks(of: [entry(0, source: "spotify", ref: "")]).isEmpty)
        XCTAssertTrue(playableTracks(of: [entry(0, source: "", ref: "spotify:track:x")]).isEmpty)
    }

    /// A playlist of nothing but dead entries plays nothing at all - which the
    /// screen has to be able to say, rather than starting silence.
    func testAPlaylistWithNoSourcesPlaysNothing() {
        XCTAssertTrue(
            playableTracks(of: [
                entry(0, source: nil, ref: nil),
                entry(1, source: nil, ref: nil),
            ]).isEmpty)
        XCTAssertTrue(playableTracks(of: []).isEmpty)
    }

    /// Tapping a row plays from THAT row. Compared against the position rather
    /// than counted into the array, so the entries before it - dead ones
    /// included - are behind us and not silently re-added.
    func testStartingAtAPositionDropsEverythingBeforeIt() {
        XCTAssertEqual(playableTracks(of: mixed, startingAt: 2).map(\.title), ["a file"])
        XCTAssertEqual(
            playableTracks(of: mixed, startingAt: 0).map(\.title),
            ["spotify one", "a file"])
        // Starting at the dead row starts at the next thing that can play, not
        // at nothing and not at the top.
        XCTAssertEqual(playableTracks(of: mixed, startingAt: 1).map(\.title), ["a file"])
        XCTAssertTrue(playableTracks(of: mixed, startingAt: 99).isEmpty)
    }
}

// MARK: - Adding songs from inside the playlist

final class AddSongsTests: XCTestCase {

    private func entry(_ position: Int, _ trackID: String) -> PlaylistEntry {
        PlaylistEntry(
            entry_id: "e\(position)", position: position, track_id: trackID,
            source: "spotify", source_ref: "spotify:track:\(trackID)",
            artist: "Someone", title: "Something")
    }

    func testReportsWhichTracksThePlaylistAlreadyHolds() {
        XCTAssertEqual(trackIDs(in: [entry(0, "t1"), entry(1, "t2")]), ["t1", "t2"])
    }

    /// One track in the list twice is still one id. The marks say "this is in
    /// the playlist", not how many times.
    func testTheSameTrackTwiceIsOneID() {
        XCTAssertEqual(trackIDs(in: [entry(0, "t1"), entry(1, "t1")]), ["t1"])
    }

    func testAnEmptyPlaylistMarksNothing() {
        XCTAssertTrue(trackIDs(in: []).isEmpty)
    }
}
