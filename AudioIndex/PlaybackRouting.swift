import Foundation

// The decidable half of playing a queue. Everything in this file is a pure
// function over plain values: no AVPlayer, no SDK, no network, no clock. That
// is deliberate - the routing decision is the part most likely to be wrong and
// the part that is hardest to reproduce on a device, so it is tested offline
// and the shells (`LocalPlayer`, `SpotifySession`) are left with nothing to
// decide.

/// Which player takes one queue entry.
enum PlaybackRoute: Equatable {
    /// The Spotify app, driven over App Remote, as before.
    case spotify
    /// This app, with `AVPlayer`, from the Navidrome song with this id.
    case local(navidromeID: String)
    /// Nothing can play it. The reason is written for a person to read, because
    /// it is going on the screen - a queue that silently stops on an entry it
    /// cannot play is indistinguishable from a bug.
    case skip(reason: String)
}

/// How a Navidrome song id is spelled inside a `source_ref`.
///
/// One constant rather than a literal at each end: `syncTracks(from:)` in
/// `NavidromeClient.swift` writes this prefix and this file reads it back, and
/// a divergence would look like every local track being unplayable.
let navidromeRefPrefix = "navidrome:"

/// The Navidrome song id inside a `source_ref`, or nil if this is not one.
///
/// Rejects a bare prefix with nothing after it: `streamURL(for: "")` would
/// build a perfectly well-formed URL that Navidrome answers with an error, so
/// the malformed ref has to be caught here where it can still be named.
func navidromeID(from sourceRef: String) -> String? {
    guard sourceRef.hasPrefix(navidromeRefPrefix) else { return nil }
    let id = String(sourceRef.dropFirst(navidromeRefPrefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return id.isEmpty ? nil : id
}

/// Decide who plays this entry.
///
/// `hasNavidrome` is passed in rather than read from the Keychain so this stays
/// a function of its arguments. A `file` entry with no server configured is a
/// SKIP, not an error and not a stall: the queue is ranked across both sources,
/// so a user who has only ever connected Spotify can still be handed one, and
/// the right response is to move past it saying why.
func playbackRoute(for track: TrackRef, hasNavidrome: Bool) -> PlaybackRoute {
    switch track.source {
    case "spotify":
        return .spotify
    case "file":
        guard hasNavidrome else {
            return .skip(
                reason: "Skipped “\(track.title)” — it is a file on Navidrome and no "
                    + "Navidrome server is configured. Add one in Settings.")
        }
        guard let id = navidromeID(from: track.source_ref) else {
            return .skip(
                reason: "Skipped “\(track.title)” — atlas gave a file reference this "
                    + "app cannot read (\(track.source_ref)).")
        }
        return .local(navidromeID: id)
    default:
        // A source this build has never heard of. Naming it is the whole point:
        // the alternative is handing an unknown ref to the Spotify app, which
        // fails somewhere far away from the cause.
        return .skip(reason: "Skipped “\(track.title)” — unknown source “\(track.source)”.")
    }
}

/// The ms-played figure for a file scrobble.
///
/// `AVPlayer`'s clock is a `Double` of seconds and can legitimately be NaN
/// (before an item is ready) or infinite (a live stream), and a scrobble with
/// either in it is a corrupt row in the play history, not a rounding error.
/// Both collapse to a figure the index can store.
///
/// Clamped to the track's own length, because a play longer than the track is
/// the one value that provably cannot be true.
func fileMsPlayed(positionSeconds: Double, durationSeconds: Double) -> Int {
    guard positionSeconds.isFinite, positionSeconds > 0 else { return 0 }
    let position = Int((positionSeconds * 1000).rounded())
    guard durationSeconds.isFinite, durationSeconds > 0 else { return position }
    return min(position, Int((durationSeconds * 1000).rounded()))
}

/// The order a browsed list plays in.
///
/// Shuffling is a copy, never a sort in place, and it must not drop or
/// duplicate anything - the list on screen and the list that plays are the same
/// tracks, which is the whole promise of a Play button over a filtered view.
///
/// A genre has no order of its own. It arrives sorted by artist, which plays
/// one artist's whole catalogue before the next one is heard from, so shuffle
/// is the mode this button exists for - but not the only one, because "play
/// this alphabetically" is a legitimate thing to want and silently overriding
/// it would be worse than offering both.
func playOrder(_ tracks: [TrackRef], shuffled: Bool) -> [TrackRef] {
    shuffled ? tracks.shuffled() : tracks
}
