import Foundation

// The wire types audio-index speaks. Property names are snake_case on purpose,
// matching the service exactly, so there are no CodingKeys to drift out of sync
// with the server - the mapping IS the property list.

/// One track pushed to `POST /sync`.
struct SyncTrack: Codable, Equatable {
    let artist: String
    let title: String
    let album: String?
    let duration_ms: Int
    let source: String
    let source_ref: String

    private enum CodingKeys: String, CodingKey {
        case artist, title, album, duration_ms, source, source_ref
    }

    // Swift's synthesized Encodable uses encodeIfPresent for Optional
    // properties, which OMITS the key entirely when album is nil. audio-index
    // expects the key present (it COALESCEs a null), so encode is called here
    // explicitly instead of relying on that synthesized behavior.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(artist, forKey: .artist)
        try container.encode(title, forKey: .title)
        try container.encode(album, forKey: .album)
        try container.encode(duration_ms, forKey: .duration_ms)
        try container.encode(source, forKey: .source)
        try container.encode(source_ref, forKey: .source_ref)
    }
}

/// One entry returned by `GET /queue`.
struct TrackRef: Codable, Equatable, Identifiable {
    let track_id: String
    let source: String
    let source_ref: String
    let artist: String
    let title: String

    var id: String { track_id }
}

/// One play posted to `POST /scrobble`.
///
/// `artist` and `title` ride along even though the ref is usually enough: if
/// atlas has never seen this ref, sending them lets the track self-register
/// instead of the play being dropped, and a sync only runs when the app opens.
struct Scrobble: Codable, Equatable {
    let source: String
    let source_ref: String
    let artist: String
    let title: String
    let played_at: Int  // epoch milliseconds
    let ms_played: Int
    let context: String
}

// MARK: - Playlists
//
// A playlist entry names a `track_id`, never a source ref. That is the whole
// reason one list can hold Spotify tracks and local files together, and why a
// track that later gains a better source starts playing from it without the
// playlist being edited - so nothing here stores a ref as an identity.

/// One row of `GET /playlists`.
struct Playlist: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    /// How many entries it holds.
    ///
    /// Only `GET /playlists` reports it. The create and rename replies are the
    /// playlist ROW and carry no count, so it decodes as zero there - true of a
    /// playlist that has just been made, and the reason a rename reloads the
    /// list instead of substituting its own reply into it.
    let track_count: Int
    /// Epoch milliseconds. Kept because atlas still sends it and it is the
    /// only "when" a playlist has - NOT because it orders anything. The list
    /// arrives ordered by NAME (case-insensitively), so adding a track no
    /// longer slides the row the reader was aiming at to the top.
    let updated_at: Int

    init(id: String, name: String, track_count: Int, updated_at: Int) {
        self.id = id
        self.name = name
        self.track_count = track_count
        self.updated_at = updated_at
    }

    private enum CodingKeys: String, CodingKey { case id, name, track_count, updated_at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        track_count = try c.decodeIfPresent(Int.self, forKey: .track_count) ?? 0
        updated_at = try c.decodeIfPresent(Int.self, forKey: .updated_at) ?? 0
    }
}

/// One entry of `GET /playlists/:id`.
///
/// `source` and `source_ref` are BOTH nullable, and together: atlas knows the
/// track but has nowhere to play it from - a Spotify track saved before the
/// library sync ran, or a file whose server has gone. That entry still comes
/// back, and is still rendered, because a playlist that silently drops rows is
/// worse than one that shows a dead one; the owner cannot fix what they cannot
/// see.
struct PlaylistEntry: Decodable, Equatable, Identifiable {
    /// What this entry IS, for as long as it is in the playlist. Minted by
    /// atlas per entry, so the same track added twice is two different ids.
    let entry_id: String
    /// Where this entry sits. Positions ORDER the list and nothing else: the
    /// server closes the gap after a removal, so every position from the
    /// entry below it downwards is rewritten by a write this client did not
    /// make. Never address an entry by one.
    let position: Int
    let track_id: String
    let source: String?
    let source_ref: String?
    let artist: String
    let title: String
    /// This track's genres, sorted, and EMPTY rather than absent when it has
    /// none - the server sends the key either way, because "no genres" is a
    /// fact and a client that has to tell it from a missing key will
    /// eventually get it wrong.
    ///
    /// They ride along with the playlist rather than being looked up, because
    /// the chip row inside a playlist counts the PLAYLIST's tracks: asking the
    /// library how many are "rock" would put a number on a chip that its own
    /// list could never produce.
    let genres: [String]

    /// The ENTRY, not the track and not the position. Keying on `track_id`
    /// would collapse a track that sits in one playlist twice into a single
    /// row while the server still held two; keying on `position` would hand
    /// SwiftUI an identity that the next removal silently reassigns to a
    /// different song.
    var id: String { entry_id }

    init(
        entry_id: String, position: Int, track_id: String, source: String?,
        source_ref: String?, artist: String, title: String, genres: [String] = []
    ) {
        self.genres = genres
        self.entry_id = entry_id
        self.position = position
        self.track_id = track_id
        self.source = source
        self.source_ref = source_ref
        self.artist = artist
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case entry_id, position, track_id, source, source_ref, artist, title, genres
    }

    /// Hand-written for one key: `genres` arrived after this app shipped, and
    /// the synthesized decoder would THROW on a reply from an atlas that
    /// predates it - turning "no chips on this screen" into "this playlist
    /// could not be read".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entry_id = try c.decode(String.self, forKey: .entry_id)
        position = try c.decode(Int.self, forKey: .position)
        track_id = try c.decode(String.self, forKey: .track_id)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        source_ref = try c.decodeIfPresent(String.self, forKey: .source_ref)
        artist = try c.decode(String.self, forKey: .artist)
        title = try c.decode(String.self, forKey: .title)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
    }
}

/// The reply to `GET /playlists/:id`: the playlist and everything in it.
///
/// Only the fields the app uses are declared, for the same reason
/// `SubsonicSong` declares so few of Navidrome's - `created_at` is on the wire
/// and nothing on screen has any use for it.
struct PlaylistDetail: Decodable, Equatable {
    let id: String
    let name: String
    let tracks: [PlaylistEntry]

    init(id: String, name: String, tracks: [PlaylistEntry]) {
        self.id = id
        self.name = name
        self.tracks = tracks
    }
}

/// The reply to `POST /playlists/:id/tracks`: the entry that was just made.
///
/// The `entry_id` comes back with the append so the caller can put the new row
/// on screen - and act on it - without re-reading the whole playlist. The
/// `track_id` is atlas's, not one guessed from the ref that was sent: a ref
/// the index already knew resolves to the track it already had.
struct PlaylistAdded: Decodable, Equatable {
    let entry_id: String
    let position: Int
    let track_id: String

    init(entry_id: String, position: Int, track_id: String) {
        self.entry_id = entry_id
        self.position = position
        self.track_id = track_id
    }
}

/// One track posted to `POST /playlists/:id/tracks`.
///
/// The server accepts a bare `track_id`, or a source ref, or a ref with artist
/// and title. This app always sends the last of the three, for the same reason
/// `Scrobble` carries them: if atlas has never seen this ref the track
/// self-registers instead of the add being refused, and a sync only runs when
/// the app opens.
struct PlaylistAddition: Encodable, Equatable {
    let source: String
    let source_ref: String
    let artist: String
    let title: String

    init(track: TrackRef) {
        source = track.source
        source_ref = track.source_ref
        artist = track.artist
        title = track.title
    }
}
