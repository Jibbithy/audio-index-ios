import Foundation

enum IndexError: Error, Equatable {
    case noToken
    case unauthorized
    case http(Int, String)
}

/// Talks to audio-index on atlas. The transport is injected as a closure so the
/// tests never touch the network, and the token is a closure rather than a
/// value so a token entered after launch is picked up without rebuilding this.
struct IndexClient {
    let baseURL: URL
    let token: () -> String?
    var transport: (URLRequest) async throws -> (Data, URLResponse) = { req in
        try await URLSession.shared.data(for: req)
    }

    private func request(
        _ path: String, query: [URLQueryItem] = [],
        method: String = "GET", body: Data? = nil
    ) throws -> URLRequest {
        // Fail here, not at the server. A missing token that goes out and comes
        // back 401 is indistinguishable from a WRONG token, and the two need
        // very different things said to the user.
        guard let t = token(), !t.isEmpty else { throw IndexError.noToken }
        var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await transport(req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw IndexError.unauthorized }
        guard (200..<300).contains(code) else {
            throw IndexError.http(code, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct SyncReply: Decodable { let tracks: Int }
    private struct QueueReply: Decodable { let tracks: [TrackRef] }
    private struct OkReply: Decodable { let ok: Bool }

    /// Push the whole known library. Not a delta - atlas upserts, and a missed
    /// sync must not leave the index permanently behind.
    @discardableResult
    func sync(_ tracks: [SyncTrack]) async throws -> Int {
        let body = try JSONEncoder().encode(["tracks": tracks])
        return try await send(request("/sync", method: "POST", body: body), as: SyncReply.self).tracks
    }

    func queue(n: Int = 20) async throws -> [TrackRef] {
        let req = try request("/queue", query: [URLQueryItem(name: "n", value: String(n))])
        return try await send(req, as: QueueReply.self).tracks
    }

    func scrobble(_ s: Scrobble) async throws {
        let body = try JSONEncoder().encode(s)
        _ = try await send(request("/scrobble", method: "POST", body: body), as: OkReply.self)
    }
    // MARK: The library and its genres
    //
    // The browsable library is ATLAS's, not Navidrome's. Atlas is the only
    // place that knows both sources at once, so it is the only place that can
    // hand back one shelf holding Spotify tracks and local files together - and
    // the only place a genre learned from Spotify can survive the arrival of a
    // local copy of the same recording.

    private struct LibraryReply: Decodable { let tracks: [TrackRef] }
    private struct GenresReply: Decodable { let tracks: Int }

    /// The library, optionally narrowed to one genre.
    ///
    /// The filter is applied by the server rather than here. The list is the
    /// whole library and the chip is a question about all of it, so filtering
    /// locally would mean holding every track in memory to answer it - and
    /// would silently answer it wrongly for anything the client had not
    /// fetched yet.
    func library(_ filter: GenreFilter = .all) async throws -> [TrackRef] {
        var query: [URLQueryItem] = []
        switch filter {
        case .all: break
        case .genre(let name): query = [URLQueryItem(name: "genre", value: name)]
        case .untagged: query = [URLQueryItem(name: "untagged", value: "1")]
        }
        return try await send(request("/library", query: query), as: LibraryReply.self).tracks
    }

    /// Every genre with its track count, and how many tracks have none.
    func genres() async throws -> GenreSummary {
        try await send(request("/genres"), as: GenreSummary.self)
    }

    /// Tell atlas what Spotify says these tracks are.
    ///
    /// Returns how many landed. A row naming a ref atlas has never seen is
    /// skipped by the server rather than refused, so this can be fewer than
    /// were sent - which is normal right after a library changes and not worth
    /// interrupting a sync over.
    @discardableResult
    func setGenres(_ rows: [GenreRow]) async throws -> Int {
        let body = try JSONEncoder().encode(["tracks": rows])
        return try await send(
            request("/genres", method: "POST", body: body),
            as: GenresReply.self
        ).tracks
    }

    // MARK: Playlists
    //
    // Seven calls, all keyed on the playlist id atlas minted, and an entry
    // addressed by its ENTRY_ID rather than by its position. The server keeps
    // positions contiguous from zero and closes the gap after a removal, so a
    // position names whatever has since moved into that slot - it orders the
    // list, it does not identify a row in it.

    private struct PlaylistsReply: Decodable { let playlists: [Playlist] }

    /// The playlists, in the order atlas sends them - by name, case
    /// insensitively. Not re-sorted here: the server's order is the order, and
    /// a second opinion in the client is one more thing to disagree.
    func playlists() async throws -> [Playlist] {
        try await send(request("/playlists"), as: PlaylistsReply.self).playlists
    }

    /// Make one. Returns the playlist row, which carries no `track_count` - a
    /// new playlist holds nothing, so `Playlist` decodes it as zero.
    func createPlaylist(name: String) async throws -> Playlist {
        let body = try JSONEncoder().encode(["name": name])
        return try await send(request("/playlists", method: "POST", body: body), as: Playlist.self)
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        try await send(request("/playlists/\(id)"), as: PlaylistDetail.self)
    }

    @discardableResult
    func renamePlaylist(id: String, name: String) async throws -> Playlist {
        let body = try JSONEncoder().encode(["name": name])
        return try await send(
            request("/playlists/\(id)", method: "PATCH", body: body),
            as: Playlist.self)
    }

    func deletePlaylist(id: String) async throws {
        _ = try await send(request("/playlists/\(id)", method: "DELETE"), as: OkReply.self)
    }

    /// Append one track, and report the entry that was made - its id, the
    /// position it landed at, and the track atlas resolved it to.
    @discardableResult
    func addToPlaylist(id: String, track: PlaylistAddition) async throws -> PlaylistAdded {
        let body = try JSONEncoder().encode(track)
        return try await send(
            request("/playlists/\(id)/tracks", method: "POST", body: body),
            as: PlaylistAdded.self)
    }

    /// Remove ONE entry by its id, not a track and not a position: a playlist
    /// may hold the same track twice, so "the track" is ambiguous, and a
    /// position is only true until the next removal closes the gap above it.
    ///
    /// `/entries/` rather than `/tracks/` is deliberate on the server's side
    /// too - it keeps this call more than a single lost path segment away from
    /// `DELETE /playlists/:id`, which destroys the whole playlist.
    func removeFromPlaylist(id: String, entryId: String) async throws {
        _ = try await send(
            request("/playlists/\(id)/entries/\(entryId)", method: "DELETE"),
            as: OkReply.self)
    }
}
