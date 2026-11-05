// AudioIndexTests/DJModeTests.swift
import XCTest

@testable import AudioIndex

/// The decidable half of Spotify's DJ.
///
/// Nothing here touches App Remote, the network or a device - and it could not:
/// the DJ itself is a server-driven experience inside another app, and the only
/// way to find out whether it plays at all is to try it on the phone. So what
/// is asserted here is everything AROUND that unknown: which mode is remembered,
/// what should be driving playback given the mode, and what gets written down
/// when a track the DJ chose goes past. If the DJ URI turns out to be wrong,
/// every one of these still holds.
final class DJModeTests: XCTestCase {

    // MARK: - The mode setting

    /// Its own defaults domain per test. `.standard` is the real preference on
    /// the machine running the suite, and a test that wrote to it would both
    /// leak into other tests and change the app's behaviour on the simulator.
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.example.audioindex.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// The default is the behaviour the app had before this setting existed.
    /// Anything else would change what an existing install does on upgrade,
    /// silently, with nobody having asked for it.
    func testTheModeDefaultsToTheRankedQueue() {
        let store = PlaybackModeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .rankedQueue)
    }

    func testTheModeRoundTrips() {
        let store = PlaybackModeStore(defaults: defaults)
        store.mode = .spotifyDJ
        XCTAssertEqual(store.mode, .spotifyDJ)
        // A second store over the same defaults is what the NEXT launch sees.
        XCTAssertEqual(PlaybackModeStore(defaults: defaults).mode, .spotifyDJ)

        store.mode = .rankedQueue
        XCTAssertEqual(PlaybackModeStore(defaults: defaults).mode, .rankedQueue)
    }

    /// A value from a build that spelled the modes differently, or anything
    /// else that is not one of ours, must read as the ranked queue rather than
    /// crashing or leaving the app in no mode at all.
    func testAnUnreadableStoredModeFallsBackToTheRankedQueue() {
        defaults.set("shuffleEverything", forKey: PlaybackModeStore.defaultsKey)
        XCTAssertEqual(PlaybackModeStore(defaults: defaults).mode, .rankedQueue)
    }

    // MARK: - What drives playback

    /// Every combination that can occur, in one table, because the interesting
    /// part is not any single row - it is that a deliberate choice outranks
    /// BOTH the queue and the DJ, and that the DJ alone needs Spotify.
    func testWhatDrivesPlayback() {
        let cases:
            [(
                mode: PlaybackMode, connected: Bool, chosen: Bool,
                expected: PlaybackDriver, why: String
            )] = [
                (
                    .rankedQueue, true, false, .queue,
                    "the ordinary case: atlas ranks, this app plays"
                ),
                (
                    .rankedQueue, false, false, .queue,
                    "the ranked queue does not need Spotify - it can be all Navidrome files"
                ),
                (
                    .rankedQueue, true, true, .localTakeover,
                    "a row the listener tapped keeps the speaker, queue or no queue"
                ),
                (
                    .rankedQueue, false, true, .localTakeover,
                    "and it keeps it whether or not Spotify is there at all"
                ),
                (
                    .spotifyDJ, true, false, .dj,
                    "DJ mode with Spotify connected is the whole point of the mode"
                ),
                (
                    .spotifyDJ, false, false, .nothing,
                    "the DJ is Spotify's; with no App Remote connection there is nothing to ask"
                ),
                (
                    .spotifyDJ, true, true, .localTakeover,
                    "a deliberate choice outranks the DJ exactly as it outranks the queue"
                ),
                (
                    .spotifyDJ, false, true, .localTakeover,
                    "and the missing connection does not matter - the file is already playing"
                ),
            ]

        for row in cases {
            XCTAssertEqual(
                playbackDriver(
                    mode: row.mode,
                    isSpotifyConnected: row.connected,
                    isPlayingChosenTrack: row.chosen),
                row.expected,
                "\(row.mode.rawValue), connected=\(row.connected), chosen=\(row.chosen): "
                    + row.why)
        }
    }

    // MARK: - Scrobbling what the DJ chose

    private func snapshot(
        uri: String = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b",
        title: String = "Nothing Out Of Place",
        artist: String = "Cold Orchard"
    ) -> PlayerStateSnapshot {
        PlayerStateSnapshot(uri: uri, trackName: title, artistName: artist)
    }

    func testADJPlayIsBuiltFromWhatThePlayerStateSaid() {
        let scrobble = djScrobble(
            from: snapshot(), msPlayed: 214_000,
            playedAt: 1_757_000_000_000)
        XCTAssertEqual(scrobble?.source, "spotify")
        XCTAssertEqual(scrobble?.source_ref, "spotify:track:0VjIjW4GlUZAMYd2vXMi3b")
        XCTAssertEqual(scrobble?.artist, "Cold Orchard")
        XCTAssertEqual(scrobble?.title, "Nothing Out Of Place")
        XCTAssertEqual(scrobble?.ms_played, 214_000)
        XCTAssertEqual(scrobble?.played_at, 1_757_000_000_000)
    }

    /// Its own context, and not `queue`. Atlas ranks on play history, and a
    /// track SPOTIFY chose is evidence of a different thing than one this
    /// listener chose or one atlas itself suggested - filing them together
    /// would let the ranking feed on another system's suggestions.
    func testADJPlayIsFiledAsTheDJsAndNotAsAQueuePlay() {
        XCTAssertEqual(djScrobble(from: snapshot(), msPlayed: 1_000, playedAt: 1)?.context, "dj")
        XCTAssertEqual(djContext, "dj")
    }

    /// The important refusal. Atlas self-registers a ref it has never seen ONLY
    /// when the artist and title are there; without them the row can never be
    /// resolved onto a real track or merged with the same song arriving from
    /// Navidrome. That is not a partial record, it is a corrupt one.
    func testASnapshotWithNoTitleOrArtistProducesNoScrobbleAtAll() {
        XCTAssertNil(djScrobble(from: snapshot(title: ""), msPlayed: 9_000, playedAt: 1))
        XCTAssertNil(djScrobble(from: snapshot(artist: ""), msPlayed: 9_000, playedAt: 1))
        XCTAssertNil(
            djScrobble(
                from: snapshot(title: "", artist: ""),
                msPlayed: 9_000, playedAt: 1))
    }

    /// Whitespace is emptiness here. A player state carrying a single space for
    /// an artist is the same missing metadata as an empty one, and trimming it
    /// at the boundary is what stops " " reaching atlas as a real name.
    func testWhitespaceOnlyMetadataIsTreatedAsMissing() {
        XCTAssertNil(djScrobble(from: snapshot(title: "   "), msPlayed: 9_000, playedAt: 1))
        XCTAssertNil(djScrobble(from: snapshot(artist: "\n "), msPlayed: 9_000, playedAt: 1))
        XCTAssertNil(djScrobble(from: snapshot(uri: " "), msPlayed: 9_000, playedAt: 1))
    }

    /// No URI is no play. The ref is the only identity a DJ track has - this
    /// app never sees a track id for it - so a state with an empty one cannot
    /// be recorded as anything.
    func testASnapshotWithNoURIProducesNoScrobble() {
        XCTAssertNil(djScrobble(from: snapshot(uri: ""), msPlayed: 9_000, playedAt: 1))
    }

    /// A negative position is the SDK reporting something impossible, not a
    /// play of negative length. It is clamped rather than dropped: the track
    /// did play, and the ms figure is the least important field on the row.
    func testANegativeMsPlayedIsClampedRatherThanRecorded() {
        XCTAssertEqual(djScrobble(from: snapshot(), msPlayed: -5, playedAt: 1)?.ms_played, 0)
    }

    // MARK: - The URI itself

    /// Pinned deliberately. This is the one value in the feature that is a
    /// guess, and the test exists so that changing it is a decision somebody
    /// makes rather than a typo nobody notices.
    func testTheDJURIIsTheOneWeThinkItIs() {
        XCTAssertEqual(spotifyDJContextURI, "spotify:playlist:37i9dQZF1EYkqdzj48dyYq")
    }
}
