import Foundation

// Genres, end to end on the client: what Spotify's replies mean, what atlas is
// told, and which chips the counts turn into.
//
// Every function here is a plain function over plain values. The part of this
// feature that can actually be WRONG is the mapping - which artist describes
// which track, and which genres make it onto the row - so it is tested without
// a network, a server or a screen, exactly as `librarySearch` and
// `playbackRoute` are.
//
// The genres are the ARTIST's, not the track's. Spotify has no track-level
// genre to give: `audio-features` was deprecated for new apps in Nov 2024 along
// with `recommendations` and `related-artists`, so an artist lookup is what is
// left. Every track by one artist therefore carries the same genres, which is
// a property of the data and not something a later version fixes.

// MARK: - Wire types

/// One track's link to the artist whose genres describe it.
///
/// The FIRST artist only, which is not a shortcut: `track_id` on atlas is a
/// hash of the first artist and the title, so taking a different one here would
/// describe a track the index does not have under that name.
struct TrackArtist: Equatable {
    let source_ref: String
    let artistID: String
}

/// One reply from `GET /v1/artists?ids=`.
///
/// `[Artist?]` for the same reason `TracksReply` is: Spotify puts a literal
/// `null` in the slot of an id it does not recognise rather than shortening the
/// array, and decoding it as non-optional throws away the whole batch over one
/// dead id.
struct ArtistsReply: Decodable {
    let artists: [Artist?]

    struct Artist: Decodable {
        let id: String?
        let genres: [String]?
    }
}

/// One row of `POST /genres`.
struct GenreRow: Encodable, Equatable {
    let source: String
    let source_ref: String
    let genres: [String]
}

/// One row of `GET /genres`: a genre and how many tracks hold it.
struct GenreCount: Decodable, Equatable, Identifiable {
    let genre: String
    let track_count: Int

    var id: String { genre }
}

/// The whole reply to `GET /genres`.
///
/// `untagged` is a count, not a genre: tracks with no genre at all are most of
/// a fresh library, and folding them into the list under an empty name would
/// put a nameless chip in the middle of the row.
struct GenreSummary: Decodable, Equatable {
    let genres: [GenreCount]
    let untagged: Int

    static let empty = GenreSummary(genres: [], untagged: 0)

    init(genres: [GenreCount], untagged: Int) {
        self.genres = genres
        self.untagged = untagged
    }

    private enum CodingKeys: String, CodingKey { case genres, untagged }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = try c.decodeIfPresent([GenreCount].self, forKey: .genres) ?? []
        untagged = try c.decodeIfPresent(Int.self, forKey: .untagged) ?? 0
    }
}

/// What the library is narrowed to. One value rather than an optional string
/// plus a boolean, because "everything", "one genre" and "the ones with no
/// genre" are three states and two of them are not a genre name.
enum GenreFilter: Equatable, Hashable {
    case all
    case genre(String)
    case untagged
}

/// One control in the chip row.
struct GenreChip: Equatable, Identifiable {
    let filter: GenreFilter
    let label: String
    /// How many tracks it would show. Nil for "All", which is the whole list
    /// and would just be repeating the header's own count.
    let count: Int?

    var id: String {
        switch filter {
        case .all: return "__all__"
        case .untagged: return "__untagged__"
        case .genre(let name): return "g:\(name)"
        }
    }
}

// MARK: - Mapping

/// Which artist describes each track on one page of saved tracks.
///
/// The SAME guards as `syncTracks(from:)`, deliberately: a track kept here but
/// dropped there would send atlas a ref it has never heard of, and one dropped
/// here but kept there would sit in the library ungenred forever with nothing
/// to say why.
func trackArtists(from page: SavedTracksPage) -> [TrackArtist] {
    page.items.compactMap { item in
        let t = item.track
        guard let uri = t.uri, !uri.isEmpty else { return nil }
        guard let artist = t.artists.first, let id = artist.id, !id.isEmpty else { return nil }
        return TrackArtist(source_ref: uri, artistID: id)
    }
}

/// The artist ids worth asking about, each once.
///
/// A library of a few thousand tracks is a few hundred artists, so this is the
/// difference between eight calls and eighty.
func uniqueArtistIDs(_ rows: [TrackArtist]) -> [String] {
    var seen = Set<String>()
    return rows.compactMap { seen.insert($0.artistID).inserted ? $0.artistID : nil }
}

/// `artist id -> genres`, dropping the nulls Spotify pads its reply with.
func genresByArtist(from reply: ArtistsReply) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for artist in reply.artists {
        guard let artist, let id = artist.id, !id.isEmpty else { continue }
        out[id] = artist.genres ?? []
    }
    return out
}

/// What to POST to atlas.
///
/// A track whose artist has no genres still gets a row, carrying an EMPTY list.
/// That is not a wasted row: the server REPLACES a source's genres rather than
/// merging them, so an empty list is the only thing that can clear a genre
/// Spotify has stopped reporting. Sending nothing would leave it standing
/// forever.
func genreRows(for tracks: [TrackArtist], genres: [String: [String]]) -> [GenreRow] {
    tracks.map {
        GenreRow(
            source: "spotify", source_ref: $0.source_ref,
            genres: genres[$0.artistID] ?? [])
    }
}

// MARK: - Chips

/// The chip row: "All", the genres holding the most tracks, and - when there
/// are any - the ones holding none.
///
/// A PREFIX of what the server sent, not a re-sort: `GET /genres` already
/// orders by count then name, and re-deriving that order here would be a second
/// copy of the rule that could disagree with the sheet behind "More…".
///
/// Twelve is a row the eye can cross. Everything past it is still reachable -
/// the sheet lists all of them - so this hides nothing, it only chooses what is
/// worth a tap without one.
func genreChips(_ summary: GenreSummary, top: Int = 12) -> [GenreChip] {
    guard !summary.genres.isEmpty || summary.untagged > 0 else { return [] }
    var chips = [GenreChip(filter: .all, label: "All", count: nil)]
    chips += summary.genres.prefix(top).map {
        GenreChip(filter: .genre($0.genre), label: $0.genre, count: $0.track_count)
    }
    if summary.untagged > 0 {
        chips.append(GenreChip(filter: .untagged, label: "No genre", count: summary.untagged))
    }
    return chips
}

// MARK: - Fetching

extension SpotifyWebAPI {
    /// 50 ids is Spotify's cap for `GET /v1/artists`, the same cap the artwork
    /// lookup works to.
    static let artistBatch = 50

    /// Genres for every artist named, in as few calls as the cap allows.
    ///
    /// A batch that fails is SKIPPED, not thrown: the tracks it covered come
    /// back with no genres, which is the honest answer, and a whole library
    /// must not go ungenred because one call in twelve timed out. An expired
    /// token IS thrown - that is not a gap in the data, it is the sync being
    /// unable to run at all, and it needs saying out loud.
    func artistGenres(accessToken: String, ids: [String]) async throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for batch in batched(ids, size: Self.artistBatch) {
            guard var comps = URLComponents(string: "https://api.spotify.com/v1/artists")
            else { continue }
            comps.queryItems = [URLQueryItem(name: "ids", value: batch.joined(separator: ","))]
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await transport(req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw SpotifyAPIError.unauthorized }
            guard (200..<300).contains(code) else { continue }
            guard let reply = try? JSONDecoder().decode(ArtistsReply.self, from: data) else { continue }
            out.merge(genresByArtist(from: reply)) { _, new in new }
        }
        return out
    }
}

// MARK: - Genres inside one playlist
//
// The same chips, over a much smaller set. The counts are the PLAYLIST's, not
// the library's, and they count ENTRIES rather than tracks: a playlist may hold
// one track twice, those are two rows the owner can see, and a chip that said
// "1" over two visible rows would be wrong in the one place it is easiest to
// check.

/// The chip row's numbers for one playlist.
func genreSummary(of entries: [PlaylistEntry]) -> GenreSummary {
    var counts: [String: Int] = [:]
    var untagged = 0
    for entry in entries {
        if entry.genres.isEmpty { untagged += 1 }
        // A genre listed twice on one entry would double-count it. The server
        // sends them DISTINCT, and this does not rely on that.
        for genre in Set(entry.genres) { counts[genre, default: 0] += 1 }
    }
    let rows = counts.map { GenreCount(genre: $0.key, track_count: $0.value) }
        .sorted {
            $0.track_count == $1.track_count
                ? $0.genre < $1.genre
                : $0.track_count > $1.track_count
        }
    return GenreSummary(genres: rows, untagged: untagged)
}

/// The entries one chip keeps, in the playlist's own order.
///
/// Filtering here rather than at the server, unlike the library: a playlist
/// arrives whole and is small, so a round trip per chip would spend a network
/// call to answer a question already sitting in memory - and would make the
/// list unfilterable the moment the tailnet blinked.
func entries(_ entries: [PlaylistEntry], matching filter: GenreFilter) -> [PlaylistEntry] {
    switch filter {
    case .all: return entries
    case .untagged: return entries.filter { $0.genres.isEmpty }
    case .genre(let name): return entries.filter { $0.genres.contains(name) }
    }
}
