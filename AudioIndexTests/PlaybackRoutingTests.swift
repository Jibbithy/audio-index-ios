// AudioIndexTests/PlaybackRoutingTests.swift
import XCTest

@testable import AudioIndex

/// The decidable half of local playback.
///
/// Everything here is a pure function over plain values, which is the whole
/// reason `PlaybackRouting.swift` exists as a separate file: `LocalPlayer`
/// needs an `AVPlayer`, an audio session, a device and a reachable Navidrome,
/// and none of those can be asserted about in a test bundle. The routing
/// decision - the part most likely to be wrong - can.
final class PlaybackRoutingTests: XCTestCase {

    private func track(source: String, ref: String, title: String = "Tape 04") -> TrackRef {
        TrackRef(
            track_id: "t-\(ref)", source: source, source_ref: ref,
            artist: "[Unknown Artist]", title: title)
    }

    // MARK: - Extracting the id

    func testNavidromeIDIsTheRefWithoutThePrefix() {
        XCTAssertEqual(navidromeID(from: "navidrome:abc123"), "abc123")
    }

    /// Navidrome's ids are opaque strings, not hex or digits - anything after
    /// the prefix is the id, punctuation included.
    func testNavidromeIDKeepsWhateverTheServerCallsIt() {
        XCTAssertEqual(navidromeID(from: "navidrome:al-9f_3.2"), "al-9f_3.2")
        XCTAssertEqual(navidromeID(from: "navidrome:c:d"), "c:d")
    }

    func testNavidromeIDTrimsSurroundingWhitespace() {
        XCTAssertEqual(navidromeID(from: "navidrome: abc123 "), "abc123")
    }

    /// A Spotify ref is not a malformed Navidrome ref, it is a different
    /// source. Both answer nil here; `playbackRoute` is what tells them apart.
    func testNavidromeIDRejectsARefThatIsNotOne() {
        XCTAssertNil(navidromeID(from: "spotify:track:4PTG3Z6ehGkBFwjybzWkR8"))
        XCTAssertNil(navidromeID(from: "abc123"))
        XCTAssertNil(navidromeID(from: ""))
    }

    /// The malformed case that matters. `streamURL(for: "")` builds a perfectly
    /// well-formed URL that the server answers with an error, so an empty id
    /// has to be caught here or it becomes a silent stall on the phone.
    func testNavidromeIDRejectsAnEmptyID() {
        XCTAssertNil(navidromeID(from: "navidrome:"))
        XCTAssertNil(navidromeID(from: "navidrome:   "))
    }

    /// The prefix is a prefix, not a substring: a ref that merely mentions it
    /// is not one of ours.
    func testNavidromeIDRequiresThePrefixAtTheFront() {
        XCTAssertNil(navidromeID(from: "x-navidrome:abc123"))
    }

    // MARK: - Routing

    func testRouting() {
        let cases: [(name: String, track: TrackRef, hasNavidrome: Bool, expected: PlaybackRoute)] = [
            (
                "spotify entry, navidrome configured",
                track(source: "spotify", ref: "spotify:track:abc"), true, .spotify
            ),

            // Navidrome being absent says nothing about a Spotify track.
            (
                "spotify entry, no navidrome",
                track(source: "spotify", ref: "spotify:track:abc"), false, .spotify
            ),

            (
                "file entry with a server",
                track(source: "file", ref: "navidrome:abc123"), true, .local(navidromeID: "abc123")
            ),
        ]

        for c in cases {
            XCTAssertEqual(
                playbackRoute(for: c.track, hasNavidrome: c.hasNavidrome),
                c.expected, c.name)
        }
    }

    /// The skip reasons are checked by shape rather than by their exact words,
    /// which are going on a screen and will be reworded. What must not change
    /// is that it is a skip and that the reason names the track.
    func testRoutingSkips() {
        let noServer = playbackRoute(
            for: track(source: "file", ref: "navidrome:abc123"),
            hasNavidrome: false)
        guard case .skip(let reason) = noServer else {
            return XCTFail("a file with no server configured must be skipped, got \(noServer)")
        }
        XCTAssertTrue(reason.contains("Tape 04"), reason)
        XCTAssertTrue(reason.contains("Navidrome"), reason)

        let malformed = playbackRoute(
            for: track(source: "file", ref: "navidrome:"),
            hasNavidrome: true)
        guard case .skip(let malformedReason) = malformed else {
            return XCTFail("a malformed file ref must be skipped, got \(malformed)")
        }
        XCTAssertTrue(malformedReason.contains("Tape 04"), malformedReason)

        // A source this build has never heard of must be named, not handed to
        // the Spotify app to fail somewhere far from the cause.
        let unknown = playbackRoute(for: track(source: "tidal", ref: "tidal:1"), hasNavidrome: true)
        guard case .skip(let unknownReason) = unknown else {
            return XCTFail("an unknown source must be skipped, got \(unknown)")
        }
        XCTAssertTrue(unknownReason.contains("tidal"), unknownReason)
    }

    /// A `file` entry whose ref is a Spotify URI is atlas contradicting itself.
    /// It is a skip, not a Spotify play: the source field is what the queue
    /// ranked on and quietly overriding it would scrobble against the wrong id.
    func testFileEntryWithASpotifyRefIsSkippedNotStreamed() {
        let route = playbackRoute(
            for: track(source: "file", ref: "spotify:track:abc"),
            hasNavidrome: true)
        guard case .skip = route else {
            return XCTFail("expected a skip, got \(route)")
        }
    }

    // MARK: - The scrobbled figure

    func testMsPlayedIsThePositionInMilliseconds() {
        XCTAssertEqual(fileMsPlayed(positionSeconds: 42.5, durationSeconds: 180), 42_500)
    }

    /// A full play reports the track's whole length, which is what a natural
    /// end hands in.
    func testMsPlayedAtTheEndIsTheWholeTrack() {
        XCTAssertEqual(fileMsPlayed(positionSeconds: 180, durationSeconds: 180), 180_000)
    }

    /// The one value that provably cannot be true. `AVPlayer` reports a
    /// position a shade past the end at the boundary, and a play longer than
    /// the track would be a corrupt row in the history rather than a rounding
    /// error.
    func testMsPlayedIsClampedToTheTrackLength() {
        XCTAssertEqual(fileMsPlayed(positionSeconds: 181.4, durationSeconds: 180), 180_000)
    }

    /// `AVPlayer`'s clock is NaN before an item is ready and infinite for a
    /// live stream. Both would encode into a scrobble and neither is a number
    /// the index can store.
    func testMsPlayedSurvivesAnUnreadyPlayer() {
        XCTAssertEqual(fileMsPlayed(positionSeconds: .nan, durationSeconds: 180), 0)
        XCTAssertEqual(fileMsPlayed(positionSeconds: -1, durationSeconds: 180), 0)
        XCTAssertEqual(fileMsPlayed(positionSeconds: .infinity, durationSeconds: 180), 0)
    }

    /// An unknown duration must not clamp the position to zero - a skip out of
    /// a track whose length has not arrived yet still played for as long as it
    /// played.
    func testMsPlayedWithAnUnknownDurationKeepsThePosition() {
        XCTAssertEqual(fileMsPlayed(positionSeconds: 12.4, durationSeconds: 0), 12_400)
        XCTAssertEqual(fileMsPlayed(positionSeconds: 12.4, durationSeconds: .nan), 12_400)
        XCTAssertEqual(fileMsPlayed(positionSeconds: 12.4, durationSeconds: .infinity), 12_400)
    }

    func testMsPlayedRoundsRatherThanTruncating() {
        XCTAssertEqual(fileMsPlayed(positionSeconds: 0.0006, durationSeconds: 180), 1)
    }
}

// MARK: - Playing a browsed list

final class PlayOrderTests: XCTestCase {

    private func tracks(_ n: Int) -> [TrackRef] {
        (0..<n).map {
            TrackRef(
                track_id: "t\($0)", source: "spotify",
                source_ref: "spotify:track:\($0)",
                artist: "A", title: "T\($0)")
        }
    }

    /// Not shuffled is the list EXACTLY as the screen has it. A Play button
    /// that quietly reordered the rows under it would be the same bug as a
    /// search that re-sorted as you typed.
    func testUnshuffledIsTheScreensOwnOrder() {
        let list = tracks(5)
        XCTAssertEqual(playOrder(list, shuffled: false), list)
    }

    /// The same tracks, all of them, once each. This is the assertion that
    /// matters: a shuffle that drops the tail plays a genre the owner can see
    /// more of than they can hear.
    func testShuffleKeepsEveryTrackExactlyOnce() {
        let list = tracks(50)
        let shuffled = playOrder(list, shuffled: true)
        XCTAssertEqual(shuffled.count, list.count)
        XCTAssertEqual(Set(shuffled.map(\.track_id)), Set(list.map(\.track_id)))
    }

    /// Over fifty tracks, a shuffle that returned the input order every time
    /// would be a shuffle in name only.
    func testShuffleActuallyReorders() {
        let list = tracks(50)
        XCTAssertNotEqual(playOrder(list, shuffled: true), list)
    }

    func testAnEmptyListIsEmptyEitherWay() {
        XCTAssertTrue(playOrder([], shuffled: true).isEmpty)
        XCTAssertTrue(playOrder([], shuffled: false).isEmpty)
    }
}
