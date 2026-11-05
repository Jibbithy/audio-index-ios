import Foundation

/// One page of `GET /v1/me/tracks`. Only the fields that are actually used are
/// declared - Spotify's payload is enormous and decoding all of it would be a
/// standing invitation for an unrelated field's type change to break sync.
struct SavedTracksPage: Decodable {
    let items: [Item]
    let next: String?

    struct Item: Decodable { let track: Track }

    struct Track: Decodable {
        let uri: String?
        let name: String
        let duration_ms: Int
        let artists: [Artist]
        let album: Album?

        /// The id is what the genre lookup needs; the name is what identity is
        /// hashed from. Optional because Spotify omits it on the stub artist of
        /// a saved local file - see `trackArtists(from:)`.
        struct Artist: Decodable {
            let id: String?
            let name: String
        }
        struct Album: Decodable { let name: String }
    }
}

/// Map one Spotify page to what audio-index stores, dropping anything unplayable.
///
/// FIRST artist only. Spotify returns an array; joining it would produce a
/// string Navidrome will never reproduce for the same recording, and track_id
/// is a hash of artist and title - so one song would become two identities with
/// two separate histories the moment local files arrive.
func syncTracks(from page: SavedTracksPage) -> [SyncTrack] {
    page.items.compactMap { item in
        let t = item.track
        // A track saved from a local file has a null uri and cannot be played
        // through App Remote. Indexing it would seed the queue with silent
        // failures.
        guard let uri = t.uri, !uri.isEmpty else { return nil }
        guard let artist = t.artists.first?.name, !artist.isEmpty else { return nil }
        guard !t.name.isEmpty else { return nil }
        return SyncTrack(
            artist: artist, title: t.name, album: t.album?.name,
            duration_ms: t.duration_ms, source: "spotify", source_ref: uri)
    }
}
