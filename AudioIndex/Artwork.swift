import Foundation
import SwiftUI

// MARK: - Pure helpers
//
// Everything in this section is a plain function over plain values, so the
// parts of artwork loading that can actually be wrong - parsing a URI, batching
// ids, choosing a size - are tested without a network.

/// The bare id out of a `spotify:track:<id>` URI.
///
/// Returns nil for anything that is not a track: `spotify:local:...` (a saved
/// local file, which has no album art on the service), `spotify:episode:...`,
/// a playlist URI, or a malformed ref. A nil here is normal and must render a
/// placeholder, never an error.
func spotifyTrackID(from ref: String) -> String? {
    let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" else { return nil }
    let id = String(parts[2])
    return id.isEmpty ? nil : id
}

/// Split into runs of at most `size`, preserving order.
///
/// `GET /v1/tracks` takes at most 50 ids per call. A queue is normally 20, so
/// this is usually one batch - but the cap is the API's, not ours, and a longer
/// queue must not silently lose its tail.
func batched<T>(_ items: [T], size: Int) -> [[T]] {
    guard size > 0 else { return items.isEmpty ? [] : [items] }
    return stride(from: 0, to: items.count, by: size).map {
        Array(items[$0..<min($0 + size, items.count)])
    }
}

/// One reply from `GET /v1/tracks?ids=`.
///
/// The array is `[Track?]` because Spotify returns a literal `null` in the slot
/// of any id it does not recognise, rather than shortening the array. Decoding
/// it as non-optional throws away the whole batch over one dead id.
struct TracksReply: Decodable {
    let tracks: [Track?]

    struct Track: Decodable {
        let id: String?
        let album: Album?

        struct Album: Decodable { let images: [Image] }
        struct Image: Decodable {
            let url: String
            let width: Int?
            let height: Int?
        }
    }
}

/// Map a reply to `track id -> artwork URL`.
///
/// Picks the SMALLEST image that is still at least `atLeast` wide, falling back
/// to the largest available. Spotify's first image is the 640px master; using it
/// for a 52pt row thumbnail would pull about 40x the bytes actually needed for
/// every row of the queue.
func artworkURLs(from reply: TracksReply, atLeast: Int = 300) -> [String: URL] {
    var out: [String: URL] = [:]
    for track in reply.tracks {
        guard let track, let id = track.id, let images = track.album?.images, !images.isEmpty
        else { continue }
        let sorted = images.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        let chosen = sorted.first { ($0.width ?? 0) >= atLeast } ?? sorted.last
        guard let chosen, let url = URL(string: chosen.url) else { continue }
        out[id] = url
    }
    return out
}

/// A stable colour seed for a track with no artwork.
///
/// FNV-1a, NOT `String.hashValue`: Swift's hash is seeded per process, so the
/// same track would be a different colour on every launch and the placeholder
/// would look like a bug.
func artworkSeed(for ref: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for byte in ref.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16_777_619
    }
    return hash
}

// MARK: - Store

/// Album art for queue rows, from the Spotify Web API.
///
/// ONE request per queue load, not one per row: `GET /v1/tracks` takes up to 50
/// ids, and a queue of twenty rows each firing its own request would be twenty
/// round trips on a tailnet for decoration.
///
/// Failures are swallowed on purpose. Artwork is not information the app needs
/// to work, and surfacing "could not load a JPEG" next to a real atlas error
/// would bury the one the user has to act on.
@MainActor
final class ArtworkStore: ObservableObject {

    @Published private(set) var urlsByTrackID: [String: URL] = [:]

    /// Ids already asked about, successfully or not. Stops a reload of the same
    /// queue from re-requesting art Spotify has already said it does not have.
    private var asked: Set<String> = []

    /// Builds a signed `getCoverArt.view` URL for one Navidrome id, or nil when
    /// no server is configured. A closure installed by `Player` rather than the
    /// credentials themselves, so this object never holds the password.
    var navidromeCoverURL: ((String) -> URL?)?

    /// Signed cover URLs already built, keyed by id. Not caching for its own
    /// sake: every call to the client mints a FRESH salt, so rebuilding the URL
    /// on each redraw would hand `AsyncImage` a URL it has never seen and
    /// re-download the same cover on every scroll of the list.
    private var navidromeURLs: [String: URL] = [:]

    var transport: (URLRequest) async throws -> (Data, URLResponse) = { req in
        try await URLSession.shared.data(for: req)
    }

    /// The cover for one ref, from whichever server owns it. Nil is normal and
    /// renders the placeholder.
    func url(for ref: String) -> URL? {
        if let id = navidromeID(from: ref) { return navidromeURL(for: id) }
        return spotifyTrackID(from: ref).flatMap { urlsByTrackID[$0] }
    }

    /// The signed cover URL for one Navidrome id, built once and kept.
    ///
    /// Nothing is fetched here. Unlike the Spotify half, which has to ASK where
    /// a cover lives, Subsonic serves the image from a URL we can sign
    /// ourselves - so `AsyncImage` does the loading and the URL cache does the
    /// caching, and a server with no art for a track answers with a placeholder
    /// image rather than an error worth showing.
    func navidromeURL(for songID: String) -> URL? {
        if let known = navidromeURLs[songID] { return known }
        guard let built = navidromeCoverURL?(songID) else { return nil }
        navidromeURLs[songID] = built
        return built
    }

    /// Fetch art for every ref not already known. Never throws.
    func load(refs: [String], accessToken: String?) async {
        guard let accessToken, !accessToken.isEmpty else { return }
        let ids = refs.compactMap(spotifyTrackID(from:)).filter { !asked.contains($0) }
        guard !ids.isEmpty else { return }
        // Marked before the call, not after: two overlapping loads of the same
        // queue must not both go out.
        asked.formUnion(ids)

        for batch in batched(Array(Set(ids)), size: 50) {
            guard var comps = URLComponents(string: "https://api.spotify.com/v1/tracks")
            else { continue }
            comps.queryItems = [URLQueryItem(name: "ids", value: batch.joined(separator: ","))]
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            do {
                let (data, resp) = try await transport(req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else { continue }
                let reply = try JSONDecoder().decode(TracksReply.self, from: data)
                urlsByTrackID.merge(artworkURLs(from: reply)) { _, new in new }
            } catch {
                // Decoration. A missing cover renders a placeholder.
                continue
            }
        }
    }

    /// Drop everything. Only used when the Spotify session changes identity.
    func reset() {
        urlsByTrackID = [:]
        asked = []
    }

    /// Drop the Navidrome half. Its URLs are signed for one server with one
    /// password, so they are worth nothing the moment either changes.
    func resetNavidrome() {
        navidromeURLs = [:]
    }
}

// MARK: - View

/// A square cover, at whatever size the caller asks for - square-cornered and
/// ruled in ink, like every other Deck surface.
///
/// The placeholder is not a grey box: it is one of the Deck fills, chosen
/// deterministically from the ref, so a queue of tracks without art still
/// reads as distinct rows rather than a column of identical holes. It is also
/// what demo mode shows - no network image ever loads there.
struct ArtworkView: View {
    let ref: String
    let size: CGFloat
    /// An image handed over by the Spotify SDK, which wins over the Web API URL
    /// because it is already in memory.
    var image: UIImage?

    @EnvironmentObject private var artwork: ArtworkStore

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = artwork.url(for: ref) {
                AsyncImage(url: url) { phase in
                    if let loaded = phase.image {
                        loaded.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
    }

    /// The Deck app-block fills. Crit is left out on purpose: a red square in
    /// a list reads as an error, and this is decoration.
    private static let fills: [Color] = [Deck.accent, Deck.ok, Deck.warn, Deck.blue]

    private var placeholder: some View {
        Self.fills[Int(artworkSeed(for: ref) % UInt32(Self.fills.count))]
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(Deck.onFill)
            }
    }
}
