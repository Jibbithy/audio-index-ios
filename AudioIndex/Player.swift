import Combine
import Foundation
import UIKit

// MARK: - Spotify Web API

enum SpotifyAPIError: Error, Equatable {
    case unauthorized
    case http(Int, String)
    case badNextURL(String)
}

/// The one Spotify *Web API* call this app makes: reading the saved library.
///
/// Deliberately separate from `SpotifySession`, which wraps the *SDK*. This is
/// plain HTTP carrying the session's bearer token, so the transport is
/// injectable and the paging can be tested against fixture JSON; nothing in
/// `SpotifySession` can be tested at all without the Spotify app on a device.
struct SpotifyWebAPI {
    /// 50 is the maximum Spotify allows for this endpoint; asking for more is
    /// silently clamped, so the page count is a floor set by the API, not us.
    static let firstPage = "https://api.spotify.com/v1/me/tracks?limit=50"

    var transport: (URLRequest) async throws -> (Data, URLResponse) = { req in
        try await URLSession.shared.data(for: req)
    }

    /// Page `GET /v1/me/tracks` to exhaustion and map every page with
    /// `syncTracks(from:)`.
    ///
    /// Follows the `next` URL the server returns rather than computing offsets:
    /// Spotify's own cursor is the only thing that stays correct if the library
    /// changes mid-walk.
    ///
    /// `maxPages` and the `seen` set are guards, not limits. A `next` pointing
    /// back at a page already fetched would otherwise spin forever inside a
    /// call the UI is awaiting, with no error and no way out. 200 pages is
    /// 10,000 saved tracks.
    func savedTracks(accessToken: String, maxPages: Int = 200) async throws -> [SyncTrack] {
        try await savedLibrary(accessToken: accessToken, maxPages: maxPages).tracks
    }

    /// The same walk, also reporting which artist each track belongs to.
    ///
    /// Both out of ONE walk rather than two. The genres are a second lookup
    /// keyed on the artist id, and the ids are only on these pages - walking
    /// the library twice to collect them would double the calls that this
    /// endpoint's 50-per-page cap already makes the slowest part of a sync.
    func savedLibrary(
        accessToken: String,
        maxPages: Int = 200
    ) async throws -> (
        tracks: [SyncTrack],
        artists: [TrackArtist]
    ) {
        var next: String? = Self.firstPage
        var out: [SyncTrack] = []
        var artists: [TrackArtist] = []
        var seen: Set<String> = []
        var pages = 0

        while let link = next, pages < maxPages, !seen.contains(link) {
            seen.insert(link)
            pages += 1
            guard let url = URL(string: link) else { throw SpotifyAPIError.badNextURL(link) }

            var req = URLRequest(url: url)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await transport(req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw SpotifyAPIError.unauthorized }
            guard (200..<300).contains(code) else {
                throw SpotifyAPIError.http(code, String(decoding: data, as: UTF8.self))
            }

            let page = try JSONDecoder().decode(SavedTracksPage.self, from: data)
            out.append(contentsOf: syncTracks(from: page))
            artists.append(contentsOf: trackArtists(from: page))
            next = page.next
        }
        return (out, artists)
    }
}

// MARK: - Player

/// The loop this whole app exists to run: library up, queue down, play,
/// scrobble back.
///
/// Owns the pure core (`QueueCursor`, `ScrobbleBuffer`, `IndexClient`) and the
/// SDK shell (`SpotifySession`), and is the only place the two meet. Everything
/// observable here is `@MainActor` because a SwiftUI view reads it directly and
/// because `SpotifySession` is.
///
/// The network and disk work is NOT. It lives in the `nonisolated static`
/// helpers at the bottom of this file, each of which builds its own
/// `IndexClient` and `ScrobbleBuffer` from plain values. That is a requirement,
/// not a preference: both of those types are non-Sendable, so a copy held as a
/// property of a main-actor class cannot legally be passed to their own
/// nonisolated `async` methods. Constructing them inside a nonisolated function
/// keeps each one inside a single isolation domain for its whole life.
@MainActor
final class Player: ObservableObject {

    // MARK: Observable state

    @Published private(set) var cursor = QueueCursor()
    /// Plays that failed to reach atlas and are waiting on disk. Shown only
    /// when non-zero - zero is the normal state, not information.
    @Published private(set) var pendingScrobbles = 0
    /// Count returned by the last successful `POST /sync` of the Spotify half.
    @Published private(set) var lastSyncCount: Int?
    /// The same, for the Navidrome half. Kept apart from `lastSyncCount`
    /// because the two sources sync in one pass but fail independently, and
    /// "atlas has 900 tracks" says nothing about whether the local files got
    /// there.
    @Published private(set) var lastNavidromeSyncCount: Int?
    /// How many tracks atlas placed genres on in the last sync. Its own number
    /// for the same reason the two above are separate: a library that synced
    /// and a library that got its genres are two things, and one of them can
    /// fail on its own.
    @Published private(set) var lastGenreCount: Int?
    /// Whether a Navidrome server has been configured. Mirrored out of the
    /// Keychain so the view is not calling `SecItemCopyMatching` on every
    /// redraw.
    @Published private(set) var hasNavidrome: Bool
    /// Who and where, for the settings screen. NEVER the password.
    @Published private(set) var navidromeSummary: String?
    /// The result of the last "Test connection", in words. Its own field
    /// because it is neither the sync status nor a failure of anything else.
    @Published private(set) var navidromeTest: String?
    /// Whether the track playing right now is a FILE, coming out of this app,
    /// rather than a Spotify stream coming out of the Spotify app.
    ///
    /// Every piece of display state has two possible sources depending on this
    /// one flag, so it is published rather than derived at each reader: the two
    /// players do not agree about what is playing, and only one of them is
    /// right at a time.
    @Published private(set) var isPlayingFile = false
    /// Who picks the tracks. Persisted, so the app comes back in the mode it
    /// was left in; see `PlaybackModeStore`.
    @Published private(set) var mode: PlaybackMode
    /// Whether Spotify's DJ is what is coming out of the speaker right now.
    ///
    /// Not derivable from `mode`, and that distinction is the whole of task 5:
    /// a library row or a playlist takes the speaker off the DJ while the mode
    /// is still DJ, and the plays it produces are the listener's choices, not
    /// the DJ's. This flag - not the mode - is what decides which.
    @Published private(set) var isPlayingDJ = false
    /// What the DJ is playing, learned from the player state and nowhere else.
    ///
    /// Synthesised into a `TrackRef` so the mini player, the expanded player
    /// and the transport all keep working unchanged: they ask `playingTrack`,
    /// and in DJ mode there is no cursor entry for them to find.
    @Published private(set) var djTrack: TrackRef?
    /// Why the DJ is not playing, when it was asked for and refused.
    ///
    /// Its own field rather than `error` alone because it also changes what the
    /// screen IS: with a failure standing, DJ mode falls back to the ranked
    /// queue and has to say so in the header instead of showing a DJ panel over
    /// a queue that is what is actually playing.
    @Published private(set) var djFailure: String?
    /// Informational, NOT a failure. An empty queue lands here, not in `error`.
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var isWorking = false
    /// Whether an atlas bearer token has been entered. Mirrored out of the
    /// Keychain so the view is not calling `SecItemCopyMatching` on every
    /// redraw.
    @Published private(set) var hasToken: Bool

    // MARK: Collaborators

    let spotify: SpotifySession
    /// The file half. Owns an `AVPlayer` and, while a file is playing, this
    /// app's `AVAudioSession` - which is what a Spotify stream can never give
    /// us and the reason the lock screen works at all for local tracks.
    let local: LocalPlayer
    /// Album art for the queue rows. A separate `ObservableObject` rather than
    /// `@Published` state here: it is written by its own async loads and a
    /// nested object's changes do not propagate through this one, so the views
    /// observe it directly.
    let artwork = ArtworkStore()
    /// The library as a browsable list - ATLAS's library, holding both sources
    /// at once, not Navidrome's. Its own object for the same reason
    /// `ArtworkStore` is one: it is filled by its own async load, and a failure
    /// to READ the library is not a failure of the queue - putting it in
    /// `error` would show a browsing problem on the queue screen.
    let library = LibraryStore()
    /// The playlists, and whichever one is open. Its own object for the third
    /// time and the same reason: it is filled by its own async loads, and a
    /// failure to read the playlists is not a failure of the queue.
    let playlists = PlaylistStore()
    private let tokenStore: TokenStore
    private let navidromeStore: NavidromeStore
    private let modeStore: PlaybackModeStore
    private let bufferURL: URL
    private let baseURL: URL

    /// Read at the moment of use, never cached: a token pasted after launch has
    /// to take effect without rebuilding anything, and nothing here should hold
    /// the secret longer than the call that needs it.
    private var atlasToken: String? { tokenStore.token }

    /// Same rule as `atlasToken`, and it matters more - this one is a password.
    private var navidrome: NavidromeCredentials? { navidromeStore.credentials }

    // MARK: How long the current track has been playing

    /// A skip has to scrobble the track it is skipping, and the SDK will not
    /// tell us how far in we were: `SpotifySession.play(uri:)` resets its
    /// accounting for the incoming track, so the outgoing one is never
    /// reported. These two are the fallback measure, accurate to whatever the
    /// user did through THIS app's transport controls.
    private var playingSince: Date?
    private var accruedMs = 0

    /// The track a row in the library browser started, if one is playing.
    ///
    /// Held APART from the cursor on purpose: the ranked queue is atlas's, and
    /// a track the user reached for must not consume, reorder or replace it.
    /// While this is set it - not `cursor.current` - is what is coming out of
    /// the speaker, and when it ends the queue picks up where it was.
    ///
    /// Published because the marked row in the browser and the mini player both
    /// read it: a plain property would change without a redraw and leave the
    /// wrong row wearing the equaliser bars.
    @Published private(set) var libraryTrack: TrackRef?

    /// What a play started from the browser is called on the wire.
    ///
    /// Not `"queue"`, and that is the entire point: atlas ranks on play history,
    /// and a track the user went looking for is evidence of a different thing
    /// than a track it served them.
    static let libraryContext = "library"

    /// What a play out of the CURSOR is called on the wire.
    ///
    /// Two, because the cursor holds two different kinds of list. Atlas ranks
    /// on play history, and a track it served is evidence of a different thing
    /// than a track the user put in a playlist and started deliberately -
    /// scrobbling both as `"queue"` would let the ranking feed on its own
    /// suggestions.
    static let queueContext = "queue"
    static let playlistContext = "playlist"

    /// The last two DJ tracks we were told about, newest first.
    ///
    /// Two, not one, and not a growing list. The end of a track is reported
    /// through a `Task` hop while the state change that revealed it is handled
    /// synchronously, so by the time a DJ play is recorded the "current" track
    /// may already be the NEXT one - whichever way the two land, the track that
    /// just ended is one of these two. Anything older is history nothing will
    /// ask about again.
    private var djCurrent: PlayerStateSnapshot?
    private var djPrevious: PlayerStateSnapshot?

    /// Which of the two the cursor is holding right now. Set where the cursor
    /// is refilled and read where a play ends, so there is exactly one place
    /// that decides and exactly one that reports.
    private var cursorContext = Player.queueContext

    /// Every touch of the retry buffer queues behind the last one. The buffer
    /// is a file that `ScrobbleBuffer` rewrites whole on each change, so two
    /// overlapping operations would each save their own idea of the contents
    /// and the loser's plays would be gone - which is precisely the failure the
    /// buffer exists to prevent.
    private var bufferWork: Task<Int, Never>?

    static var defaultBufferURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pending-scrobbles.json")
    }

    init(
        spotify: SpotifySession = SpotifySession(),
        local: LocalPlayer = LocalPlayer(),
        tokenStore: TokenStore = TokenStore(),
        navidromeStore: NavidromeStore = NavidromeStore(),
        modeStore: PlaybackModeStore = PlaybackModeStore(),
        bufferURL: URL = Player.defaultBufferURL,
        baseURL: URL = Config.indexBaseURL
    ) {
        self.spotify = spotify
        self.local = local
        self.tokenStore = tokenStore
        self.navidromeStore = navidromeStore
        self.modeStore = modeStore
        self.mode = modeStore.mode
        self.bufferURL = bufferURL
        self.baseURL = baseURL
        // `DemoMode.isActive` is a compile-time `false` in release, so this
        // branch does not exist outside a debug build. In demo mode neither the
        // Keychain nor the scrobble file on disk is touched.
        if DemoMode.isActive {
            self.hasToken = true
            self.pendingScrobbles = 0
            self.hasNavidrome = false
            self.navidromeSummary = nil
        } else {
            self.hasToken = !(tokenStore.token ?? "").isEmpty
            self.pendingScrobbles = ScrobbleBuffer(url: bufferURL).pending.count
            let creds = navidromeStore.credentials
            self.hasNavidrome = creds != nil
            self.navidromeSummary = creds.map { "\($0.username) at \($0.baseURL.absoluteString)" }

            // Both read the Keychain at the moment of use, like `navidrome`
            // above and for the same reason: a server added after launch has to
            // work without rebuilding anything, and neither object should hold
            // a password of its own. Installed only outside demo mode, which
            // must never touch the Keychain at all.
            // Same rule again: read at the moment of use, so a token pasted
            // after launch reaches the playlists and the library browser
            // without rebuilding anything.
            let atlas = baseURL
            playlists.connection = { [tokenStore] in (baseURL: atlas, token: tokenStore.token) }
            library.connection = { [tokenStore] in (baseURL: atlas, token: tokenStore.token) }
            artwork.navidromeCoverURL = { [navidromeStore] id in
                guard let creds = navidromeStore.credentials else { return nil }
                return try? NavidromeClient(credentials: { creds })
                    .coverArtURL(for: id, size: 300)
            }
        }

        // The end of a track is only ever observed by the SDK. Turning that
        // into a scrobble is this object's job, so the callback is wired here
        // and nowhere else.
        spotify.onTrackEnded = { [weak self] uri, msPlayed in
            Task { @MainActor in await self?.trackEnded(uri: uri, msPlayed: msPlayed) }
        }

        // The DJ's track list is only ever learned here, one state change at a
        // time. Wired in the same place and for the same reason as the callback
        // above: turning what the SDK saw into something atlas can be told is
        // this object's job and nowhere else's.
        spotify.onPlayerState = { [weak self] snapshot in
            Task { @MainActor in self?.observedPlayerState(snapshot) }
        }

        // The same three wires for the file half. A file scrobbles through the
        // SAME `finish(track:msPlayed:)` as a Spotify stream - one path, one
        // buffer, one context taken from whatever the cursor is holding -
        // because atlas resolves both sources onto one track identity and a
        // second scrobble path would be a second chance to get that wrong.
        local.onTrackEnded = { [weak self] msPlayed in
            Task { @MainActor in await self?.fileTrackEnded(msPlayed: msPlayed) }
        }
        local.onFailure = { [weak self] message in
            Task { @MainActor in self?.fileFailed(message) }
        }
        local.onRemoteNext = { [weak self] in
            Task { @MainActor in await self?.skip() }
        }
    }

    // MARK: What is playing, whichever player has it
    //
    // The views ask these instead of asking a player directly. Reading
    // `spotify.isPaused` while a file is playing is not merely stale, it is a
    // different track's state - the Spotify app is still sitting on whatever
    // it was paused on.

    var isPaused: Bool { isPlayingFile ? local.isPaused : spotify.isPaused }

    /// The track actually coming out of the speaker, which is not always the
    /// cursor's. A row tapped in the library browser plays without consuming
    /// the queue, so while it plays the cursor is still pointing at the entry
    /// we will go back to - and every view that asks "what is playing" has to
    /// be told about the one in front of it, not the one behind.
    ///
    /// `djTrack` sits between the two because a DJ track is neither: nothing in
    /// the cursor produced it, and the listener did not reach for it. Without
    /// it here the mini player, the expanded player and the transport would all
    /// find nothing playing while the DJ is audibly playing.
    var playingTrack: TrackRef? { libraryTrack ?? djTrack ?? cursor.current }

    var nowPlayingTitle: String {
        if isPlayingFile { return playingTrack?.title ?? "" }
        return spotify.trackName.isEmpty ? (playingTrack?.title ?? "") : spotify.trackName
    }

    var nowPlayingArtist: String {
        if isPlayingFile { return playingTrack?.artist ?? "" }
        return spotify.artistName.isEmpty ? (playingTrack?.artist ?? "") : spotify.artistName
    }

    var progress: PlaybackProgress { isPlayingFile ? local.progress : spotify.progress }

    /// Cover art for the current track, or nil to fall through to the
    /// generated placeholder. A file has none - the Spotify app's image is of
    /// whatever IT is holding, which is not what is coming out of the speaker.
    var nowPlayingImage: UIImage? { isPlayingFile ? nil : spotify.nowPlayingImage }

    /// The playback error worth showing, from whichever player is live.
    var playbackError: String? { isPlayingFile ? local.lastError : spotify.lastError }

    // MARK: Token

    func saveToken(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenStore.token = trimmed.isEmpty ? nil : trimmed
        hasToken = !trimmed.isEmpty
        error = nil
    }

    // MARK: Navidrome

    /// Save the Navidrome server, or clear it if the form was emptied.
    ///
    /// A bad base URL is rejected here rather than at the first request: the
    /// user is looking at the field they mistyped right now, and will not be
    /// when a sync fails three screens later.
    func saveNavidrome(baseURL raw: String, username: String, password: String) {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty && user.isEmpty && password.isEmpty {
            clearNavidrome()
            return
        }
        guard let url = URL(string: host), url.scheme != nil, url.host != nil else {
            error =
                "That is not a server address. It needs the scheme too, "
                + "like http://your-server.example"
            return
        }
        guard !user.isEmpty, !password.isEmpty else {
            error = "Navidrome needs a username and a password."
            return
        }
        navidromeStore.credentials = NavidromeCredentials(
            baseURL: url, username: user,
            password: password)
        // The cached cover URLs are signed for the OLD server with the OLD
        // password, so every one of them is now a request that will be refused.
        artwork.resetNavidrome()
        hasNavidrome = true
        navidromeSummary = "\(user) at \(url.absoluteString)"
        navidromeTest = nil
        error = nil
    }

    func clearNavidrome() {
        navidromeStore.clear()
        artwork.resetNavidrome()
        hasNavidrome = false
        navidromeSummary = nil
        navidromeTest = nil
        lastNavidromeSyncCount = nil
        error = nil
    }

    /// Ask the server whether it is there and whether these credentials work,
    /// and say which in plain words. The whole point of the button is that the
    /// answer arrives now instead of as a failed sync later.
    func testNavidrome() async {
        guard let creds = navidrome else {
            navidromeTest = "No Navidrome server configured yet."
            return
        }
        navidromeTest = "Contacting \(creds.baseURL.host ?? "the server")…"
        do {
            _ = try await Self.pingNavidrome(creds)
            navidromeTest = "Connected. Navidrome accepted that username and password."
        } catch {
            navidromeTest = Self.describe(error)
        }
    }

    // MARK: Lifecycle

    /// Retry whatever the last session could not deliver, before anything else
    /// touches atlas, so a backlog is not left sitting behind a fresh failure.
    func onAppear() async {
        #if DEBUG
            if DemoMode.isActive {
                installDemoState()
                return
            }
        #endif
        await drainBuffer()
    }

    // MARK: Library sync

    /// Push both libraries. One POST per source, each after its own full walk -
    /// a partial library arriving at atlas mid-walk is indistinguishable from a
    /// shrinking one.
    ///
    /// The two sources are INDEPENDENT. Each syncs if it is configured, neither
    /// is a precondition for the other, and one failing leaves the other's
    /// result standing. This used to early-return unless Spotify was connected,
    /// which meant a user whose files are the whole point could never sync at
    /// all - Navidrome was reachable but unreachable through this button.
    ///
    /// Sequential rather than parallel: they write to the same index, and a
    /// failure has to be readable on its own rather than as whichever error
    /// happened to be assigned last.
    func syncLibrary() async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }

        let spotifyToken = spotify.accessToken
        let creds = navidrome

        guard spotifyToken != nil || creds != nil else {
            // Neither source configured. This IS worth saying - the button did
            // nothing and there is no other way to tell.
            status = nil
            error = "Nothing to sync yet. Connect Spotify, or add a Navidrome server, or both."
            return
        }

        // Each source reports its own outcome. Collected rather than assigned,
        // so a Spotify failure cannot overwrite a Navidrome one and vice versa.
        var problems: [String] = []

        if let spotifyToken {
            status = "Reading your Spotify library…"
            var artists: [TrackArtist] = []
            do {
                let library = try await Self.fetchLibrary(spotifyToken: spotifyToken)
                artists = library.artists
                status = "Sending \(library.tracks.count) tracks to atlas…"
                lastSyncCount = try await Self.pushLibrary(
                    library.tracks, baseURL: baseURL,
                    token: atlasToken)
            } catch {
                problems.append("Spotify: \(Self.describe(error))")
            }

            // A SEPARATE outcome, after the tracks have already landed. Genres
            // are what the library is browsed by, not what it is; a failed
            // artist lookup must not report a sync that worked as one that did
            // not, and must not stop the Navidrome half below from running.
            if !artists.isEmpty {
                status = "Reading genres from Spotify…"
                do {
                    lastGenreCount = try await Self.pushGenres(
                        artists,
                        spotifyToken: spotifyToken,
                        baseURL: baseURL,
                        token: atlasToken)
                } catch {
                    problems.append("Genres: \(Self.describe(error))")
                }
            }
        }

        if let creds {
            status = "Reading your Navidrome library…"
            do {
                let tracks = try await Self.fetchNavidromeLibrary(creds)
                status = "Sending \(tracks.count) local tracks to atlas…"
                lastNavidromeSyncCount = try await Self.pushLibrary(
                    tracks, baseURL: baseURL,
                    token: atlasToken)
            } catch {
                problems.append("Navidrome: \(Self.describe(error))")
            }
        }

        status = nil
        error = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    // MARK: Queue

    /// Pull a fresh ranked queue and start it. Replaces whatever cursor we had:
    /// atlas has already excluded everything inside the cooldown window, so its
    /// list is authoritative and appending would replay what it left out.
    func loadQueue() async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        status = nil
        defer { isWorking = false }

        do {
            let tracks = try await Self.fetchQueue(baseURL: baseURL, token: atlasToken, n: 20)
            cursor.refill(with: tracks)
            // The cursor is atlas's again, whatever it was holding before.
            cursorContext = Self.queueContext
            // One batched Web API call for the whole queue's covers. Fired and
            // not awaited: artwork is decoration and must never hold up
            // playback starting.
            let refs = tracks.map(\.source_ref)
            let spotifyToken = spotify.accessToken
            Task { [artwork] in await artwork.load(refs: refs, accessToken: spotifyToken) }
            if cursor.current != nil {
                playCurrent()
            } else {
                // NOT an error. A brand-new index, and every track being inside
                // the cooldown, both legitimately return nothing.
                status = "Nothing queued right now. Sync your library, then try again."
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Mode

    /// Switch between the ranked queue and Spotify's DJ, and remember it.
    ///
    /// It deliberately starts nothing. Changing who picks the music while music
    /// is playing, from a settings sheet, is exactly the kind of surprise this
    /// app avoids elsewhere - the new mode takes effect the next time playback
    /// is asked for, from the button that says so.
    ///
    /// `isPlayingDJ` is NOT cleared here either. If the DJ is mid-track when
    /// the mode is switched back, the DJ is still what is playing and that play
    /// is still the DJ's; filing it as a queue play, or dropping it, would put
    /// a lie in the history for the sake of a setting.
    func setMode(_ newMode: PlaybackMode) {
        guard newMode != mode else { return }
        Diag.log("mode \(mode.rawValue) -> \(newMode.rawValue)")
        mode = newMode
        modeStore.mode = newMode
        // Both belong to the previous mode's last attempt. A DJ refusal is not
        // news on the ranked queue, and a queue error is not news on the DJ.
        djFailure = nil
        error = nil
        status = nil
    }

    /// Start whatever the current mode says should be playing.
    ///
    /// The ONE entry point for "play something" from the UI. The decision
    /// itself is `playbackDriver`, which is a pure function tested offline;
    /// everything here is the doing of it.
    func startPlayback() async {
        let driver = playbackDriver(
            mode: mode,
            isSpotifyConnected: spotify.isConnected,
            isPlayingChosenTrack: libraryTrack != nil)
        Diag.log(
            "startPlayback mode=\(mode.rawValue) driver=\(driver) "
                + "connected=\(spotify.isConnected)")
        switch driver {
        case .queue:
            await loadQueue()
        case .dj:
            startDJ()
        case .localTakeover:
            // Something the listener reached for is playing. Saying so is the
            // whole response: taking the speaker off them would be the app
            // overriding a deliberate choice.
            status =
                "“\(libraryTrack?.title ?? "")” is playing because you chose it. "
                + "It keeps the speaker until it ends."
        case .nothing:
            // DJ mode with no App Remote connection. There is no local
            // substitute for the DJ - it is Spotify's, and the Spotify app is
            // what plays it - so this is a real dead end and has to read as one.
            error =
                "Spotify's DJ needs the Spotify app connected. "
                + "Open Settings and connect Spotify, then try again."
        }
    }

    // MARK: The DJ

    /// Ask Spotify to play its DJ, and hand the speaker over to it.
    ///
    /// The cursor is NOT touched, in either direction: it is not refilled, not
    /// advanced and not consumed, because in this mode it means nothing. What
    /// plays is Spotify's to decide, and this app's only job is to write down
    /// what it hears.
    ///
    /// `local.stop()` first for exactly the reason `startSpotify` does it: it
    /// deactivates our audio session with `.notifyOthersOnDeactivation`, which
    /// is the only signal the Spotify app gets that it may have the session
    /// back. Skip it and Spotify accepts the command, reports itself playing,
    /// and produces no sound.
    func startDJ() {
        #if DEBUG
            if DemoMode.isActive {
                // Same rule as every other playback entry point: demo mode must
                // construct no SDK object at all. `spotify.play` would reach the
                // lazy `appRemote`, and in the simulator there is no Spotify app on
                // the other end of it.
                isPlayingDJ = true
                djFailure = nil
                status = "Spotify's DJ is choosing. Your plays are still being recorded."
                return
            }
        #endif
        local.stop()
        isPlayingFile = false
        libraryTrack = nil
        isPlayingDJ = true
        djFailure = nil
        djTrack = nil
        djCurrent = nil
        djPrevious = nil
        error = nil
        accruedMs = 0
        playingSince = nil
        status = "Asking Spotify to start the DJ…"

        Diag.log("dj play attempt uri=\(spotifyDJContextURI) connected=\(spotify.isConnected)")
        spotify.play(uri: spotifyDJContextURI) { [weak self] failure in
            guard let self else { return }
            guard let failure else {
                // ACCEPTED, which is not the same as playing. App Remote
                // answering without an error only means the Spotify app took
                // the command; whether the DJ actually starts is visible only
                // in the player states that follow, which is why this line and
                // the `playerState` lines have to be read together.
                Diag.log("dj play accepted uri=\(spotifyDJContextURI)")
                self.status = "Spotify's DJ is choosing. Your plays are still being recorded."
                return
            }
            Diag.log("dj play FAILED uri=\(spotifyDJContextURI) error=\(failure)")
            self.djFailure = failure
            self.isPlayingDJ = false
            self.djTrack = nil
            self.status = nil
            self.error =
                "Spotify refused to play the DJ: \(failure) — "
                + "playing your ranked queue instead."
            // Falling back rather than sitting silent. The MODE is left alone:
            // the preference is still the DJ, this one attempt failed, and the
            // header says both.
            Task { await self.loadQueue() }
        }
    }

    /// Note what the Spotify app says it is playing.
    ///
    /// Only ever writes DJ bookkeeping, and only while the DJ is what is
    /// playing. A player state that arrives during a queue track, a playlist or
    /// a library file is already accounted for by `SpotifySession` and the
    /// cursor; touching anything here would be a second opinion about one track.
    private func observedPlayerState(_ snapshot: PlayerStateSnapshot) {
        guard isPlayingDJ else { return }
        let uri = snapshot.uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else { return }

        if djCurrent?.uri != uri {
            djPrevious = djCurrent
            djCurrent = snapshot
            Diag.log(
                "dj now playing uri=\(uri) title=\(snapshot.trackName) "
                    + "artist=\(snapshot.artistName)")
        } else {
            djCurrent = snapshot
        }

        // Synthesised, not looked up: atlas has no queue entry for this track
        // and may never have heard of it. `track_id` is the URI because the URI
        // is the only identity there is here, and nothing reads it for anything
        // but SwiftUI's row identity.
        djTrack = TrackRef(
            track_id: uri, source: "spotify", source_ref: uri,
            artist: snapshot.artistName, title: snapshot.trackName)
    }

    /// Record a play the DJ chose.
    ///
    /// Through `deliver`, which is the same single path to atlas every other
    /// play takes - same timestamp rule, same buffer, same "any failure keeps
    /// the play". The only things that differ are where the artist and title
    /// came from, and that it says `context: "dj"`.
    private func recordDJPlay(uri: String, msPlayed: Int) async {
        // The context URI itself is not a track. `play(uri:)` starts watching
        // whatever it was handed, so the first state change of a DJ session
        // reports the END of the playlist URI - a bookkeeping artefact, not a
        // play, and scrobbling it would put the DJ's own id in the history.
        guard uri != spotifyDJContextURI else {
            Diag.log("dj ignoring the context uri as a track end")
            return
        }
        guard
            let snapshot = [djCurrent, djPrevious].compactMap({ $0 })
                .first(where: { $0.uri == uri })
        else {
            Diag.log("dj scrobble SKIPPED uri=\(uri): never saw a player state for it")
            return
        }
        guard
            let scrobble = djScrobble(
                from: snapshot, msPlayed: msPlayed,
                playedAt: Int(Date().timeIntervalSince1970 * 1000))
        else {
            Diag.log("dj scrobble SKIPPED uri=\(uri): no artist or title in the player state")
            return
        }
        Diag.log(
            "dj scrobble uri=\(uri) artist=\(scrobble.artist) "
                + "title=\(scrobble.title) ms=\(scrobble.ms_played)")
        await deliver(scrobble)
    }

    // MARK: Playlists

    /// Play a playlist, in its own order, through the SAME cursor the ranked
    /// queue uses.
    ///
    /// Nothing about playback is new here. Refilling the cursor is the whole
    /// implementation, so the routing between the two players, the audio-session
    /// handoff, the track-end detection and the scrobble all take the paths they
    /// already take - only `cursorContext` differs, and that is what tells atlas
    /// this play was a choice rather than a suggestion it made.
    ///
    /// It REPLACES the ranked queue, exactly as `loadQueue` does. That is the
    /// user asking for this list now; when it runs out, `finish` reloads the
    /// ranked queue and the ordinary loop resumes.
    ///
    /// Entries with no source are skipped when building what plays. They stay
    /// on screen - see `playableTracks(of:)` - but there is nothing to send to
    /// either player, and a queue entry that cannot start would stall the
    /// cursor on a row nobody can hear.
    /// `entries` is what is ON SCREEN, which a genre chip may have narrowed. It
    /// is passed in rather than read off the playlist because "play this list"
    /// has to mean the list the owner is looking at - handing them the tracks a
    /// chip just filtered away is the same surprise as a tapped row playing
    /// from the top.
    func playPlaylist(
        _ playlist: PlaylistDetail, entries: [PlaylistEntry]? = nil,
        startingAt position: Int? = nil
    ) async {
        let rows = entries ?? playlist.tracks
        let tracks = playableTracks(of: rows, startingAt: position)
        guard !tracks.isEmpty else {
            // NOT an error. A playlist of tracks atlas cannot place is a sync
            // problem, and saying so is more use than a silent Play button.
            playlists.say(
                rows.isEmpty
                    ? "“\(playlist.name)” is empty."
                    : "Nothing in “\(playlist.name)” can be played yet — none of its "
                        + "tracks has a source. Sync your library.",
                isError: false)
            return
        }
        #if DEBUG
            if DemoMode.isActive {
                demoStartCursor(tracks)
                return
            }
        #endif
        await endLibraryTrack()
        cursor.refill(with: tracks)
        cursorContext = Self.playlistContext
        // One batched call for the covers, fired and not awaited, exactly as
        // the queue does it: artwork is decoration and must never hold up
        // playback starting.
        let refs = tracks.map(\.source_ref)
        let spotifyToken = spotify.accessToken
        Task { [artwork] in await artwork.load(refs: refs, accessToken: spotifyToken) }
        error = nil
        status = nil
        playCurrent()
    }

    // MARK: Transport

    func togglePlayPause() {
        #if DEBUG
            if DemoMode.isActive {
                spotify.demoTogglePlayPause()
                return
            }
        #endif
        // The DJ is a context, not a track we asked for, so there is nothing to
        // compare a URI against and nothing of ours to restart - pausing and
        // resuming is all this control can mean. It comes before the guard
        // below because the DJ can legitimately be playing before the first
        // player state has told us what.
        if isPlayingDJ {
            if spotify.isPaused { spotify.resume() } else { spotify.pause() }
            return
        }

        guard let track = playingTrack else { return }

        // A file is ours; there is no other process to ask and no chance of the
        // user having started something else in it.
        if isPlayingFile {
            if local.isPaused { local.resume() } else { local.pause() }
            return
        }

        // Nothing of ours is loaded in the Spotify app yet, so the first tap
        // starts the queue rather than resuming whatever else was playing.
        guard spotify.currentTrackURI == track.source_ref else {
            playCurrent()
            return
        }
        if spotify.isPaused {
            spotify.resume()
            playingSince = Date()
        } else {
            spotify.pause()
            accrueListening()
        }
    }

    /// A skip is a play that ended early, so it scrobbles like any other. Doing
    /// that here rather than leaning on the SDK is not a choice: asking the
    /// Spotify app for the next URI resets its track-end accounting, so the
    /// outgoing track would otherwise vanish with no play recorded.
    func skip() async {
        #if DEBUG
            if DemoMode.isActive {
                demoAdvance()
                return
            }
        #endif
        // Skipping a library track is not skipping the queue: it scrobbles what
        // was heard and hands the speaker back to the cursor, which never moved.
        if let libraryTrack {
            await finishLibrary(libraryTrack, msPlayed: msPlayedOfCurrent())
            return
        }
        // Skipping the DJ is Spotify's to do: it holds the list. The URI change
        // that follows is picked up by the ordinary track-end detection, so the
        // outgoing track scrobbles down exactly the path it would have taken if
        // it had played out. The cursor is not touched - it never held this.
        if isPlayingDJ {
            Diag.log("dj skip requested")
            spotify.skipNext()
            return
        }
        guard let track = cursor.current else {
            await loadQueue()
            return
        }
        // A file's position comes from our own clock, which is exact. Spotify's
        // comes from the fallback accounting in this class, because the SDK
        // resets its own the moment we ask for the next track.
        await finish(track: track, msPlayed: isPlayingFile ? local.msPlayedNow() : elapsedMs())
    }

    // MARK: The library browser

    /// Play one song from the library browser, right now.
    ///
    /// Deliberate, so it does NOT consume the ranked queue: the cursor stays
    /// where it is and the queue picks up again when this track ends. The
    /// scrobble goes through the same buffer, the same timestamp rule and the
    /// same "any failure keeps the play" as everything else - only its
    /// `context` differs.
    /// Play a list the browser assembled - one genre, or everything, in the
    /// order it is on screen or shuffled out of it.
    ///
    /// It REPLACES the ranked queue, exactly as a playlist's Play does. That is
    /// the owner asking for this list now; when it runs out, `finish` reloads
    /// the ranked queue and the ordinary loop resumes.
    ///
    /// The context is the browser's, not the queue's: every one of these plays
    /// is a deliberate choice, and atlas ranks on history, so filing a genre
    /// the owner reached for as a track it served them would teach it the wrong
    /// thing about its own suggestions.
    func playLibrary(_ tracks: [TrackRef], shuffled: Bool) async {
        let list = playOrder(tracks, shuffled: shuffled)
        guard !list.isEmpty else { return }
        #if DEBUG
            if DemoMode.isActive {
                demoStartCursor(list)
                return
            }
        #endif
        // Whatever the browser had started is over, and nothing will resume it.
        await endLibraryTrack()
        cursor.refill(with: list)
        cursorContext = Self.libraryContext
        loadArtwork(for: list.map(\.source_ref))
        error = nil
        status = nil
        playCurrent()
    }

    /// Scrobble and forget a track a row started, if one is playing.
    ///
    /// Three callers, all of which are about to take the speaker away from it:
    /// the part that was heard is recorded now or it is lost. An outgoing QUEUE
    /// track is deliberately NOT handled here - it is being interrupted, it
    /// stays current, and it scrobbles when it actually finishes.
    private func endLibraryTrack() async {
        guard let outgoing = libraryTrack else { return }
        await record(outgoing, msPlayed: msPlayedOfCurrent(), context: Self.libraryContext)
        libraryTrack = nil
    }

    /// The library browser now lists BOTH sources, so this routes rather than
    /// assuming a file: the same `playbackRoute` the queue uses, so a Spotify
    /// row and a local row reach the speaker by the paths that already exist.
    func playNow(track: TrackRef) async {
        #if DEBUG
            if DemoMode.isActive {
                demoPlay(track)
                return
            }
        #endif
        await endLibraryTrack()
        switch playbackRoute(for: track, hasNavidrome: hasNavidrome) {
        case .spotify:
            startSpotify(track)
            libraryTrack = track
        case .local(let navidromeID):
            if startLocal(track, navidromeID: navidromeID) { libraryTrack = track }
        case .skip(let reason):
            // NOT a skip here. Nothing is being served: the user reached for
            // this row, so the reason it cannot play is the whole answer.
            error = reason
        }
    }

    /// How long whatever is playing has been playing.
    ///
    /// A file's position comes from our own clock, which is exact. Spotify's
    /// comes from the fallback accounting in this class, because the SDK resets
    /// its own the moment we ask for the next track.
    private func msPlayedOfCurrent() -> Int {
        isPlayingFile ? local.msPlayedNow() : elapsedMs()
    }

    /// Cover art for a list of rows, fetched in one batched Web API call.
    ///
    /// Fired and not awaited: artwork is decoration and must never hold up a
    /// list appearing, exactly as on the queue.
    func loadArtwork(for refs: [String]) {
        let spotifyToken = spotify.accessToken
        Task { [artwork] in await artwork.load(refs: refs, accessToken: spotifyToken) }
    }

    // MARK: Track end

    /// The SDK saw a track finish. Scrobble it and move on - but only if it is
    /// the track we asked for. If the user played something else in the Spotify
    /// app, that play is theirs and not part of this queue.
    func trackEnded(uri: String, msPlayed: Int) async {
        // A late callback from the Spotify app while a FILE is playing is not
        // ours to act on: it is the Spotify app finishing whatever it was left
        // holding, and advancing this queue on it would skip a track nobody
        // heard.
        guard !isPlayingFile else { return }
        // In DJ mode there is nothing to match against: this app did not choose
        // the track and has no entry for it. The play is still worth recording -
        // that is the entire point of the mode - and the artist and title come
        // from the player states we have been watching. The cursor is NOT
        // advanced afterwards: it never held this track.
        if isPlayingDJ {
            await recordDJPlay(uri: uri, msPlayed: msPlayed)
            return
        }
        // A Spotify track started from the BROWSER is not the cursor's, so the
        // guard below would drop it and the play would never be recorded. It
        // finishes like any other library track: scrobbled, cursor untouched.
        if let libraryTrack, libraryTrack.source_ref == uri {
            await finishLibrary(libraryTrack, msPlayed: msPlayed)
            return
        }
        guard let track = cursor.current, track.source_ref == uri else { return }
        await finish(track: track, msPlayed: msPlayed)
    }

    /// Our own player finished a file. Same path, same buffer.
    func fileTrackEnded(msPlayed: Int) async {
        guard isPlayingFile else { return }
        if let libraryTrack {
            await finishLibrary(libraryTrack, msPlayed: msPlayed)
            return
        }
        guard let track = cursor.current else { return }
        await finish(track: track, msPlayed: msPlayed)
    }

    /// A file would not play - a 404, a dead tailnet, a codec iOS will not
    /// decode. Say so and stay put rather than advancing: auto-skipping would
    /// walk silently through a whole queue of unreachable files and leave the
    /// user looking at an empty screen with no idea the server was down.
    private func fileFailed(_ message: String) {
        error = message
        status = nil
    }

    /// Send one finished play, keeping it on disk if it does not land.
    ///
    /// The ONE path to atlas for both players and both contexts. The timestamp
    /// rule, the buffer and the failure rule are identical no matter where the
    /// play came from; `context` is the only thing that varies, and a second
    /// path would be a second chance to get the rest of it wrong.
    private func record(_ track: TrackRef, msPlayed: Int, context: String) async {
        await deliver(
            Scrobble(
                source: track.source,
                source_ref: track.source_ref,
                artist: track.artist,
                title: track.title,
                // Stamped now, when the play ended - not when it is finally
                // delivered. A buffered scrobble sent three days later still has to
                // say when it actually happened, or the cooldown reasons off a lie.
                played_at: Int(Date().timeIntervalSince1970 * 1000),
                ms_played: msPlayed,
                context: context))
    }

    /// Put one play on the wire, keeping it on disk if it does not land.
    ///
    /// Split out of `record` for the DJ, which is the one case where the play
    /// is NOT built from a `TrackRef` - there is no queue entry, only what the
    /// player state said. Splitting it rather than writing a second sender is
    /// the point: the retry buffer, the failure rule and the "any failure keeps
    /// the play" are the same for every play in the app, whoever chose it.
    private func deliver(_ scrobble: Scrobble) async {
        do {
            try await Self.sendScrobble(scrobble, baseURL: baseURL, token: atlasToken)
        } catch {
            // ANY failure keeps the play, a missing token included. Losing one
            // silently corrupts the ranking this whole system exists to
            // produce, and nothing downstream would ever notice.
            let url = bufferURL
            await onBuffer { Self.appendToBuffer(scrobble, url: url) }
        }
    }

    private func finish(track: TrackRef, msPlayed: Int) async {
        await record(track, msPlayed: msPlayed, context: cursorContext)

        if cursor.advance() != nil {
            playCurrent()
        } else {
            await loadQueue()
        }
    }

    /// A track started from the browser ended or was skipped.
    ///
    /// The cursor is NOT advanced: it never played this track, and moving it
    /// would silently spend a queue entry the user has not heard. `playCurrent`
    /// then resumes whatever the queue was pointing at, or - for a queue that
    /// is empty, which is the ordinary case for someone browsing their own
    /// files - stops cleanly.
    private func finishLibrary(_ track: TrackRef, msPlayed: Int) async {
        await record(track, msPlayed: msPlayed, context: Self.libraryContext)
        libraryTrack = nil
        playCurrent()
    }

    // MARK: Retry buffer

    private func drainBuffer() async {
        guard pendingScrobbles > 0 else { return }
        let url = bufferURL
        let base = baseURL
        let token = atlasToken
        await onBuffer { await Self.drainBufferFile(url: url, baseURL: base, token: token) }
    }

    /// Serialize one piece of buffer work behind whatever is already running,
    /// and publish the new pending count.
    @discardableResult
    private func onBuffer(_ work: @escaping @Sendable () async -> Int) async -> Int {
        let previous = bufferWork
        let next = Task { () -> Int in
            _ = await previous?.value
            return await work()
        }
        bufferWork = next
        let count = await next.value
        pendingScrobbles = count
        return count
    }

    // MARK: Playback helpers

    /// Start whatever the cursor is pointing at, walking past anything nothing
    /// can play.
    ///
    /// A loop, not recursion through `finish`: a queue of `file` entries with
    /// no Navidrome server configured would otherwise skip, advance, play,
    /// skip - and each skip that ran off the end would reload the queue and
    /// meet the same entries again. This terminates at the end of the cursor,
    /// every time, and deliberately does NOT reload: a queue nothing in it can
    /// play is a configuration problem, and asking atlas for another twenty
    /// entries would only hide it.
    ///
    /// A skipped entry is NOT scrobbled. It never played.
    private func playCurrent() {
        // Whatever the browser started is over: the queue is taking the speaker
        // back, and a marker left set would report the wrong track everywhere.
        libraryTrack = nil
        var skipped: String?
        while let track = cursor.current {
            switch playbackRoute(for: track, hasNavidrome: hasNavidrome) {
            case .spotify:
                startSpotify(track)
                return
            case .local(let navidromeID):
                if startLocal(track, navidromeID: navidromeID) { return }
                // Only reachable if the stream URL could not even be built,
                // which `startLocal` has already reported.
                skipped = error
            case .skip(let reason):
                Diag.log("playCurrent skipping \(track.source_ref): \(reason)")
                skipped = reason
            }
            cursor.advance()
        }
        // Ran out. Whatever stopped us is the last thing worth saying.
        isPlayingFile = false
        local.stop()
        if let skipped { error = skipped }
    }

    /// Hand over to the Spotify app.
    ///
    /// `local.stop()` FIRST, and it is not optional. It deactivates our audio
    /// session with `.notifyOthersOnDeactivation`, which is the only signal
    /// Spotify gets that it may have the session back. Skip it and the Spotify
    /// app accepts the play command, reports itself as playing, and produces
    /// no sound.
    private func startSpotify(_ track: TrackRef) {
        local.stop()
        isPlayingFile = false
        // Whatever the DJ was doing is over - this app is choosing again, and a
        // marker left set would file the next track end as the DJ's.
        endDJ()
        spotify.play(uri: track.source_ref)
        accruedMs = 0
        playingSince = Date()
        status = nil
    }

    /// Play a Navidrome file ourselves. Returns false if the stream URL could
    /// not be built, in which case the entry is skipped.
    ///
    /// `spotify.pause()` first, for the mirror image of the reason above: the
    /// Spotify app holds the session until it is told to stop, and two players
    /// holding it is the failure mode of this whole design.
    private func startLocal(_ track: TrackRef, navidromeID: String) -> Bool {
        guard let creds = navidrome else { return false }
        let url: URL
        do {
            url = try NavidromeClient(credentials: { creds }).streamURL(for: navidromeID)
        } catch {
            self.error = Self.describe(error)
            return false
        }
        spotify.pause()
        // Same rule as `startSpotify`, and here it is the audible one: pausing
        // Spotify is what takes the DJ off the speaker, so it stops being what
        // is playing at exactly this line.
        endDJ()
        isPlayingFile = true
        local.play(url: url, title: track.title, artist: track.artist)
        accruedMs = 0
        playingSince = nil
        status = nil
        error = nil
        return true
    }

    /// The DJ no longer has the speaker.
    ///
    /// Deliberately does NOT change `mode`: the preference is still the DJ, and
    /// the screen says so along with the fact that it will not resume by
    /// itself. The remembered snapshots go too - the next DJ session learns its
    /// own tracks, and a stale one could only ever mislabel a play.
    private func endDJ() {
        guard isPlayingDJ || djTrack != nil else { return }
        Diag.log("dj handing the speaker over")
        isPlayingDJ = false
        djTrack = nil
        djCurrent = nil
        djPrevious = nil
    }

    private func accrueListening() {
        guard let since = playingSince else { return }
        accruedMs += max(0, Int(Date().timeIntervalSince(since) * 1000))
        playingSince = nil
    }

    private func elapsedMs() -> Int {
        guard let since = playingSince else { return accruedMs }
        return accruedMs + max(0, Int(Date().timeIntervalSince(since) * 1000))
    }

    // MARK: Workers
    //
    // Nonisolated on purpose - see the note on the class. Every one takes only
    // Sendable values and builds its own non-Sendable collaborators locally.

    private nonisolated static func client(baseURL: URL, token: String?) -> IndexClient {
        IndexClient(baseURL: baseURL, token: { token })
    }

    private nonisolated static func fetchLibrary(
        spotifyToken: String
    ) async throws -> (tracks: [SyncTrack], artists: [TrackArtist]) {
        try await SpotifyWebAPI().savedLibrary(accessToken: spotifyToken)
    }

    /// Look up the artists' genres and tell atlas. Returns how many tracks
    /// atlas actually placed.
    ///
    /// Every track gets a row, including the ones whose artist has no genres:
    /// the server replaces a source's genres rather than merging them, so an
    /// empty list is the only thing that can clear a genre Spotify has stopped
    /// reporting.
    private nonisolated static func pushGenres(
        _ artists: [TrackArtist],
        spotifyToken: String,
        baseURL: URL,
        token: String?
    ) async throws -> Int {
        let genres = try await SpotifyWebAPI().artistGenres(
            accessToken: spotifyToken,
            ids: uniqueArtistIDs(artists))
        let rows = genreRows(for: artists, genres: genres)
        return try await IndexClient(baseURL: baseURL, token: { token }).setGenres(rows)
    }

    private nonisolated static func fetchNavidromeLibrary(
        _ creds: NavidromeCredentials
    ) async throws -> [SyncTrack] {
        let songs = try await NavidromeClient(credentials: { creds }).allSongs()
        return syncTracks(from: songs)
    }

    private nonisolated static func pingNavidrome(
        _ creds: NavidromeCredentials
    ) async throws -> Bool {
        try await NavidromeClient(credentials: { creds }).ping()
    }

    private nonisolated static func pushLibrary(
        _ tracks: [SyncTrack],
        baseURL: URL, token: String?
    ) async throws -> Int {
        try await client(baseURL: baseURL, token: token).sync(tracks)
    }

    private nonisolated static func fetchQueue(
        baseURL: URL, token: String?,
        n: Int
    ) async throws -> [TrackRef] {
        try await client(baseURL: baseURL, token: token).queue(n: n)
    }

    private nonisolated static func sendScrobble(
        _ scrobble: Scrobble,
        baseURL: URL, token: String?
    ) async throws {
        try await client(baseURL: baseURL, token: token).scrobble(scrobble)
    }

    /// Reloads the buffer from disk rather than holding one open: the file is
    /// the durable state, and `onBuffer` guarantees nobody else is writing it.
    private nonisolated static func appendToBuffer(_ scrobble: Scrobble, url: URL) -> Int {
        let buffer = ScrobbleBuffer(url: url)
        buffer.append(scrobble)
        return buffer.pending.count
    }

    private nonisolated static func drainBufferFile(
        url: URL, baseURL: URL,
        token: String?
    ) async -> Int {
        let buffer = ScrobbleBuffer(url: url)
        let client = client(baseURL: baseURL, token: token)
        await buffer.drain { try await client.scrobble($0) }
        return buffer.pending.count
    }

    // MARK: Errors

    /// Turn an error into something a person can act on. `noToken` and
    /// `unauthorized` MUST read differently: one means "you have not pasted the
    /// token yet", the other means "the token you pasted is wrong". Telling
    /// them apart is the entire reason `IndexClient` fails before the request
    /// instead of after the 401.
    static func describe(_ error: Error) -> String {
        if let indexError = error as? IndexError {
            switch indexError {
            case .noToken:
                return "No atlas token yet. Paste the bearer token below."
            case .unauthorized:
                return "Atlas rejected that token — it is wrong or has been rotated. "
                    + "Re-read it from /var/lib/audio-index/config.json on atlas."
            case .http(let code, let body):
                return detail(body).map { "Atlas returned HTTP \(code): \($0)" }
                    ?? "Atlas returned HTTP \(code)."
            }
        }
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return "Spotify rejected the session. Connect Spotify again."
            case .http(let code, let body):
                return detail(body).map { "Spotify returned HTTP \(code): \($0)" }
                    ?? "Spotify returned HTTP \(code)."
            case .badNextURL(let link):
                return "Spotify returned a paging URL we could not read: \(link)"
            }
        }
        if let navidromeError = error as? NavidromeError {
            switch navidromeError {
            case .notConfigured:
                return "No Navidrome server configured yet."
            // Subsonic reports its refusals inside an HTTP 200, so this is the
            // only place a wrong password can be named as one. Code 40 is
            // Navidrome's "wrong username or password".
            case .subsonic(let code, let message):
                return code == 40
                    ? "Navidrome rejected that username and password."
                    : "Navidrome refused the request (\(code)): \(message)"
            case .http(let code, let body):
                return detail(body).map { "Navidrome returned HTTP \(code): \($0)" }
                    ?? "Navidrome returned HTTP \(code)."
            case .badBaseURL(let raw):
                return "That Navidrome address cannot be used: \(raw)"
            }
        }
        if let urlError = error as? URLError {
            return "Could not reach the server (\(urlError.localizedDescription)). "
                + "Is the tailnet up?"
        }
        return error.localizedDescription
    }

    private static func detail(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }
}

// MARK: - Demo

#if DEBUG
    extension Player {
        /// Fill the view models with plausible offline data for `-AudioIndexDemo`.
        ///
        /// Everything it writes is state the real app would have written after a
        /// successful sign-in, queue load and playback start - so the screens under
        /// review are the real screens, not a mock-up of them. No network, no SDK,
        /// no Keychain, and no artwork URLs: covers fall through to the generated
        /// placeholder in `ArtworkView`.
        func installDemoState() {
            var demoCursor = QueueCursor()
            demoCursor.refill(with: DemoMode.tracks)
            for _ in 0..<DemoMode.playingIndex { demoCursor.advance() }
            cursor = demoCursor

            hasToken = true
            lastSyncCount = DemoMode.syncedTrackCount
            pendingScrobbles = DemoMode.pendingScrobbles
            status = nil
            error = nil
            // The browser gets a library without a server, which is the state the
            // simulator can never reach on its own and the reason this exists.
            library.installDemoLibrary()

            guard let track = cursor.current else { return }
            spotify.applyDemoState(
                title: track.title, artist: track.artist,
                album: "Side A", uri: track.source_ref,
                durationMs: DemoMode.durationMs,
                positionMs: DemoMode.positionMs)

            // Landing on the browser means landing on a row that is playing:
            // the marked row and the mini bar agreeing is half of what there is to
            // review there, and `simctl` cannot tap the row to produce it.
            if DemoMode.opensLibrary, let song = DemoMode.playingSong,
                let libraryDemo = trackRef(from: song)
            {
                demoPlay(libraryDemo)
            }
        }

        /// Play a library row with no AVPlayer, no network and no Keychain, leaving
        /// behind the same state the real path would.
        func demoPlay(_ track: TrackRef) {
            libraryTrack = track
            spotify.applyDemoState(
                title: track.title, artist: track.artist,
                album: "Navidrome", uri: track.source_ref,
                durationMs: DemoMode.durationMs,
                positionMs: DemoMode.positionMs)
        }

        /// Start a playlist with no SDK, no AVPlayer and no network, leaving the
        /// same state the real path would: the cursor holding the list and the
        /// first entry showing as playing.
        func demoStartCursor(_ tracks: [TrackRef]) {
            libraryTrack = nil
            var demoCursor = QueueCursor()
            demoCursor.refill(with: tracks)
            cursor = demoCursor
            guard let track = cursor.current else { return }
            spotify.applyDemoState(
                title: track.title, artist: track.artist,
                album: "Playlist", uri: track.source_ref,
                durationMs: DemoMode.durationMs, positionMs: 0)
        }

        /// Skip, without a scrobble and without the SDK.
        func demoAdvance() {
            libraryTrack = nil
            if cursor.advance() == nil {
                installDemoState()
                return
            }
            guard let track = cursor.current else { return }
            spotify.applyDemoState(
                title: track.title, artist: track.artist,
                album: "Side A", uri: track.source_ref,
                durationMs: DemoMode.durationMs, positionMs: 0)
        }
    }
#endif
