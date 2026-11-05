import CryptoKit
import Foundation

enum NavidromeError: Error, Equatable {
    case notConfigured
    /// Subsonic said no. The Int is Subsonic's own error code (40 is a bad
    /// password, 70 is not found), NOT an HTTP status - see `send`.
    case subsonic(Int, String)
    case http(Int, String)
    case badBaseURL(String)
}

/// Where the Navidrome server is and who we are to it.
///
/// The password is here because the Subsonic token is derived per request and
/// cannot be stored in its place. It lives in the Keychain (`NavidromeStore`)
/// and is read at the moment of use, never held longer than the call.
struct NavidromeCredentials: Codable, Equatable, Sendable {
    let baseURL: URL
    let username: String
    let password: String
}

/// One song as `search3.view` reports it.
///
/// Only the fields actually used are declared, for the same reason
/// `SavedTracksPage` declares so few of Spotify's: Navidrome's song object has
/// forty-odd keys and decoding all of them would let an unrelated one break
/// sync.
///
/// `duration` is SECONDS. Subsonic has always reported whole seconds; the index
/// stores milliseconds, and `syncTracks(from:)` below is where that conversion
/// happens exactly once.
struct SubsonicSong: Decodable, Equatable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Int?
    /// The id `getCoverArt.view` wants for this song, which is usually the
    /// ALBUM's id rather than the song's. Optional because a server that has no
    /// art for a track omits the key entirely. Nothing reads it any more: the
    /// browser asks for a cover by the same `source_ref` the queue does, and
    /// Navidrome resolves a song id to its album's art itself.
    var coverArt: String?
}

/// Talks to Navidrome over the Subsonic API.
///
/// Same shape as `IndexClient` and for the same reasons: the transport is a
/// closure so the tests never touch the network, and the credentials are a
/// closure rather than a value so a server configured after launch is picked up
/// without rebuilding this.
struct NavidromeClient {
    /// The Subsonic protocol version we claim. Navidrome keys some response
    /// fields off it, so it is pinned rather than tracking whatever is newest.
    static let apiVersion = "1.16.1"
    /// Identifies this app in Navidrome's logs and play history.
    static let clientName = "audioindex"

    let credentials: () -> NavidromeCredentials?

    /// A page of `search3.view`. 500 is Navidrome's practical ceiling for one
    /// response and is a page size, not a library limit - `allSongs` walks.
    /// Injectable so a test can prove the walk with three songs instead of a
    /// thousand.
    var pageSize = 500

    /// A fresh random salt per request. Injectable ONLY so a test can assert a
    /// known token; nothing in the app should ever pass a fixed one.
    var salt: () -> String = { NavidromeClient.randomSalt() }

    var transport: (URLRequest) async throws -> (Data, URLResponse) = { req in
        try await URLSession.shared.data(for: req)
    }

    // MARK: Requests

    /// Build one authenticated Subsonic URL.
    ///
    /// The salted form (`s` + `t`) rather than `p`: the raw password would
    /// otherwise sit in a query string, which is the one part of a request that
    /// gets written to server logs, proxy logs and crash reports verbatim. A
    /// new salt per request so a captured token is good for nothing else.
    func url(_ view: String, query: [URLQueryItem] = []) throws -> URL {
        // Fail here, not at the server. Navidrome answers an unconfigured
        // request the same way it answers a wrong password, and the two need
        // very different things said to the user.
        guard let creds = credentials() else { throw NavidromeError.notConfigured }
        let s = salt()
        guard
            var comps = URLComponents(
                url: creds.baseURL.appendingPathComponent("rest/\(view)"),
                resolvingAgainstBaseURL: false)
        else {
            throw NavidromeError.badBaseURL(creds.baseURL.absoluteString)
        }
        comps.queryItems =
            [
                URLQueryItem(name: "u", value: creds.username),
                URLQueryItem(name: "t", value: Self.token(password: creds.password, salt: s)),
                URLQueryItem(name: "s", value: s),
                URLQueryItem(name: "v", value: Self.apiVersion),
                URLQueryItem(name: "c", value: Self.clientName),
                URLQueryItem(name: "f", value: "json"),
            ] + query
        guard let out = comps.url else {
            throw NavidromeError.badBaseURL(creds.baseURL.absoluteString)
        }
        return out
    }

    /// The authenticated stream URL for one song.
    ///
    /// Not used yet - playback is the next slice - but it belongs with the
    /// client that knows how to sign a request, not with whatever eventually
    /// hands it to an audio player. It throws for the same reason every other
    /// call does: there is no such URL without credentials.
    func streamURL(for id: String) throws -> URL {
        try url("stream.view", query: [URLQueryItem(name: "id", value: id)])
    }

    /// The authenticated cover-art URL for one song or album id.
    ///
    /// `size` is Subsonic's own square resize, and it is not decoration: a
    /// 52pt row thumbnail served at the cover's full resolution pulls about a
    /// megabyte per row off the tailnet for something rendered smaller than a
    /// stamp. Omitted when nil, which is what a full-screen cover wants.
    func coverArtURL(for id: String, size: Int? = nil) throws -> URL {
        var query = [URLQueryItem(name: "id", value: id)]
        if let size { query.append(URLQueryItem(name: "size", value: String(size))) }
        return try url("getCoverArt.view", query: query)
    }

    // MARK: Calls

    private struct Envelope: Decodable {
        let response: Response

        private enum CodingKeys: String, CodingKey { case response = "subsonic-response" }

        struct Response: Decodable {
            let status: String
            let error: Fault?
            let searchResult3: SearchResult3?

            struct Fault: Decodable {
                let code: Int
                let message: String?
            }
            /// `song` is absent, not empty, when nothing matches - and absent
            /// on a `ping`, which carries no result at all.
            struct SearchResult3: Decodable { let song: [SubsonicSong]? }
        }
    }

    private func send(_ url: URL) async throws -> Envelope.Response {
        let (data, resp) = try await transport(URLRequest(url: url))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NavidromeError.http(code, String(decoding: data, as: UTF8.self))
        }
        let body = try JSONDecoder().decode(Envelope.self, from: data).response
        // Subsonic reports FAILURE inside a 200. A client that read only the
        // status line would hand back an empty library on a wrong password -
        // indistinguishable from a library that is genuinely empty, and the
        // user would go looking for their missing files instead of their typo.
        guard body.status == "ok" else {
            throw NavidromeError.subsonic(
                body.error?.code ?? -1,
                body.error?.message ?? "Navidrome returned no reason.")
        }
        return body
    }

    /// Does the server answer, and do these credentials work? Both, in one
    /// call - `ping` is authenticated like everything else.
    func ping() async throws -> Bool {
        _ = try await send(url("ping.view"))
        return true
    }

    /// Every song on the server.
    ///
    /// `search3` with an empty query is Subsonic's "match everything", and is
    /// the only endpoint that returns songs in bulk - `getSong` is one at a
    /// time and there are no ids to feed it without a listing first.
    ///
    /// A short page ends the walk. `maxPages` is a guard, not a limit: a server
    /// that ignored `songOffset` would otherwise return the same full page
    /// forever inside a call the UI is awaiting.
    func allSongs(maxPages: Int = 200) async throws -> [SubsonicSong] {
        var out: [SubsonicSong] = []
        var offset = 0
        var pages = 0

        while pages < maxPages {
            pages += 1
            let page = try await send(
                url(
                    "search3.view",
                    query: [
                        URLQueryItem(name: "query", value: ""),
                        URLQueryItem(name: "songCount", value: String(pageSize)),
                        URLQueryItem(name: "songOffset", value: String(offset)),
                        // Asked for explicitly. Navidrome defaults artistCount and
                        // albumCount to 20 each, and every one of those is rows we
                        // decode and throw away on every page of the walk.
                        URLQueryItem(name: "artistCount", value: "0"),
                        URLQueryItem(name: "albumCount", value: "0"),
                    ]))
            let songs = page.searchResult3?.song ?? []
            out.append(contentsOf: songs)
            if songs.count < pageSize { break }
            offset += songs.count
        }
        return out
    }

    // MARK: Auth

    /// `t` = md5(password + salt), lowercase hex. Subsonic's own scheme, not a
    /// choice - MD5 is weak, which is exactly why the salt is per request and
    /// why this only ever travels the tailnet.
    static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 16 hex characters of system randomness. Subsonic requires only that the
    /// salt be at least six characters and unpredictable.
    static func randomSalt() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Map Navidrome's songs to what audio-index stores, dropping anything
/// unplayable, in the same spirit as `syncTracks(from:)` for Spotify.
///
/// `artist` is passed through EXACTLY as reported, `"[Unknown Artist]"`
/// included. The files on that server carry no ID3 tags and are not to be
/// modified, so that string is the truth about them right now; inventing an
/// artist here would mint a track identity the server can never reproduce once
/// the tags are eventually written.
func syncTracks(from songs: [SubsonicSong]) -> [SyncTrack] {
    songs.compactMap { song in
        // No id means nothing to stream later; no title means nothing to
        // identify it by, and track_id is a hash of artist and title.
        guard !song.id.isEmpty, !song.title.isEmpty else { return nil }
        return SyncTrack(
            artist: song.artist ?? "",
            title: song.title,
            album: song.album,
            // Subsonic reports SECONDS. The index stores
            // milliseconds; this is the only place that converts.
            duration_ms: (song.duration ?? 0) * 1000,
            source: "file",
            source_ref: "navidrome:\(song.id)")
    }
}

/// One library song as a queue entry.
///
/// A play started from the browser travels the SAME `TrackRef` as one the queue
/// served, so the routing, the mini player and the scrobble all take the path
/// they already take and only the scrobble's `context` differs. Same rule as
/// `syncTracks(from:)` about what is unplayable, and the same verbatim artist.
func trackRef(from song: SubsonicSong) -> TrackRef? {
    guard !song.id.isEmpty, !song.title.isEmpty else { return nil }
    return TrackRef(
        track_id: navidromeRefPrefix + song.id,
        source: "file",
        source_ref: navidromeRefPrefix + song.id,
        artist: song.artist ?? "",
        title: song.title)
}
