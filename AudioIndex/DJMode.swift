import Foundation

// The decidable half of "who chooses what plays next". Everything in this file
// is a pure function or a plain value over plain values: no SDK, no network, no
// clock, no AVPlayer. Same rule as `PlaybackRouting.swift`, and for the same
// reason - the DJ itself can only ever be exercised on a device with the
// Spotify app running, so every decision around it is made here where it can be
// tested offline, and the shell is left with nothing to decide.

// MARK: - The mode

/// Who picks the tracks.
///
/// Only the STREAMING half of the app is affected. Navidrome files are played
/// by this app out of the library browser and out of playlists in both modes,
/// and neither of those is a queue the DJ can take over.
enum PlaybackMode: String, CaseIterable, Identifiable, Sendable {
    /// Atlas ranks the queue from this listener's own play history, and this
    /// app drives playback. The default, and the reason the index exists.
    case rankedQueue
    /// Spotify's DJ chooses, and this app only records what it hears. The
    /// ranking keeps training in the background off those plays.
    case spotifyDJ

    var id: String { rawValue }

    /// For the settings control.
    var label: String {
        switch self {
        case .rankedQueue: return "Ranked queue"
        case .spotifyDJ: return "Spotify DJ"
        }
    }

    /// For the header line over the queue screen. Upper case because that is
    /// what the label line under every screen title already is.
    var headerLabel: String {
        switch self {
        case .rankedQueue: return "RANKED BY ATLAS"
        case .spotifyDJ: return "SPOTIFY DJ"
        }
    }
}

/// The persisted mode.
///
/// `UserDefaults`, NOT the Keychain: this is a preference, not a secret. It
/// takes an injectable `UserDefaults` so the round-trip can be asserted against
/// a throwaway suite instead of the real one.
struct PlaybackModeStore {
    static let defaultsKey = "com.example.audioindex.playbackMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Anything unreadable - never written, or a value from a build that spelled
    /// the modes differently - reads as the ranked queue. A missing preference
    /// must land on the behaviour the app had before this setting existed.
    var mode: PlaybackMode {
        get {
            PlaybackMode(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .rankedQueue
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - The DJ itself

/// The URI handed to App Remote for Spotify's DJ.
///
/// UNVERIFIED. The DJ is a narrated, server-driven experience rather than an
/// ordinary playlist, and there is no documented guarantee that a third-party
/// remote may start it at all - Spotify is entitled to accept this call and
/// play nothing, or refuse it outright. It is a named constant precisely so
/// that correcting it, once the log off the phone says what the real one is, is
/// a one-line change and not a hunt.
let spotifyDJContextURI = "spotify:playlist:37i9dQZF1EYkqdzj48dyYq"

/// What a DJ play is called on the wire.
///
/// Its own context, alongside `queue`, `playlist` and `library`, and that is
/// the whole point: atlas ranks on play history, and a track SPOTIFY chose is
/// evidence of a different thing than a track this listener chose or than one
/// atlas itself suggested. Filing them all as `queue` would let the ranking
/// feed on another system's suggestions.
let djContext = "dj"

// MARK: - What drives playback

/// What should be driving playback right now.
enum PlaybackDriver: Equatable {
    /// Ask Spotify to play the DJ and record whatever it chooses.
    case dj
    /// Pull a ranked queue from atlas and play it, as ever.
    case queue
    /// Neither: something the listener reached for is already playing, and a
    /// deliberate choice outranks both a suggestion and the DJ.
    case localTakeover
    /// Nothing can drive playback. The only way to get here is DJ mode with no
    /// App Remote connection - the DJ is Spotify's, and without the Spotify app
    /// on the other end of the socket there is nothing to ask.
    case nothing
}

/// Decide who drives playback.
///
/// A function of its three arguments and nothing else, which is what lets the
/// hard case - "the mode says DJ but the user just tapped a row in their own
/// library" - be asserted offline. `isPlayingChosenTrack` covers BOTH deliberate
/// paths, a library row and a playlist, because they are the same thing here:
/// the listener asked for this, so nothing may take the speaker off them.
///
/// Note what is deliberately NOT here: connectivity does not affect the ranked
/// queue. That queue is ranked across both sources and can be entirely Navidrome
/// files, which this app plays itself with no Spotify app involved at all.
func playbackDriver(
    mode: PlaybackMode,
    isSpotifyConnected: Bool,
    isPlayingChosenTrack: Bool
) -> PlaybackDriver {
    if isPlayingChosenTrack { return .localTakeover }
    switch mode {
    case .rankedQueue:
        return .queue
    case .spotifyDJ:
        return isSpotifyConnected ? .dj : .nothing
    }
}

// MARK: - Scrobbling what the DJ chose

/// Build the play to record for a track the DJ chose, or nil if there is not
/// enough of it to record.
///
/// In DJ mode this app does not know the track list in advance and never will -
/// App Remote does not expose what the DJ is going to do next - so everything
/// known about a track is whatever arrived in the player state while it was
/// playing. `source_ref` is that URI, and artist and title ride along so atlas
/// can self-register a ref it has never seen instead of dropping the play.
///
/// Nil, NOT a scrobble with empty strings, when the title or the artist is
/// missing. A row in the play history with no artist and no title is one atlas
/// can never resolve onto a real track and never merge with the same song
/// arriving from Navidrome - it is not a partial record, it is a corrupt one,
/// and the whole point of this mode is that the history stays worth having.
func djScrobble(
    from snapshot: PlayerStateSnapshot,
    msPlayed: Int,
    playedAt: Int
) -> Scrobble? {
    let uri = snapshot.uri.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = snapshot.trackName.trimmingCharacters(in: .whitespacesAndNewlines)
    let artist = snapshot.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !uri.isEmpty, !title.isEmpty, !artist.isEmpty else { return nil }

    return Scrobble(
        source: "spotify",
        source_ref: uri,
        artist: artist,
        title: title,
        played_at: playedAt,
        ms_played: max(0, msPlayed),
        context: djContext)
}
