import Foundation
import SpotifyiOS
import UIKit

/// The Spotify half of the player: OAuth via `SPTSessionManager`, remote
/// control via `SPTAppRemote`.
///
/// App Remote hands out NO audio. It is a remote control for the Spotify app
/// installed on the same phone, which is what actually produces sound. So
/// every playback call here is a request to another process that may not be
/// running, and `connect()` can only succeed while it is.
///
/// NOTHING in this file persists the access token. The SDK owns the session
/// and its refresh; a second copy in the Keychain would drift out of date and
/// produce 401s from the Web API that look exactly like a login bug. Read the
/// token through `accessToken` at the moment of use, never earlier.
///
/// This class cannot be unit-tested: both SDK objects require the real Spotify
/// app on a real device. Everything decision-shaped lives in the pure core
/// (`QueueCursor`, `SpotifyLibrary`, `ScrobbleBuffer`) instead; what is left
/// here is glue that has to be verified by hand on the phone.
@MainActor
final class SpotifySession: NSObject, ObservableObject {

    // MARK: - Observable state

    @Published private(set) var isAuthorized = false
    @Published private(set) var isConnected = false
    /// Last thing that went wrong, for the UI. Cleared on the next success.
    @Published private(set) var lastError: String?
    /// Mirrors the Spotify app's transport so a view can show play vs pause.
    @Published private(set) var isPaused = true
    /// URI of whatever the Spotify app says it is playing right now.
    @Published private(set) var currentTrackURI: String?

    // The rest of what the now-playing screen draws. All of it is mirrored out
    // of the SDK's player state rather than guessed from `TrackRef`, because
    // the Spotify app is the authority on what is actually coming out of the
    // speaker - including when the user changes it behind our back.
    @Published private(set) var trackName = ""
    @Published private(set) var artistName = ""
    @Published private(set) var albumName = ""
    /// Position/duration as a value, carrying the instant it was reported so a
    /// progress bar can extrapolate. See `PlaybackProgress`.
    @Published private(set) var progress = PlaybackProgress.none
    /// Cover art for the CURRENT track, from the Spotify app itself.
    ///
    /// This is a different source from the queue rows' artwork, which comes
    /// from the Web API: App Remote will only ever hand over an image for what
    /// it is playing right now, so it cannot serve the list, and the Web API
    /// needs a round trip the SDK does not.
    @Published private(set) var nowPlayingImage: UIImage?

    /// Fires with (uri, msPlayed) when a track we were playing finishes.
    /// Set by `Player` in Task 9; it turns this into a `Scrobble`.
    var onTrackEnded: ((String, Int) -> Void)?

    /// Fires with every player state this app is told about, after it has been
    /// folded into the track-end bookkeeping above.
    ///
    /// Exists for Spotify's DJ, where this app does not know the track list in
    /// advance and cannot: the URI, the artist and the title of whatever the DJ
    /// chose arrive HERE and nowhere else, and `onTrackEnded` carries only a
    /// URI. Purely an observer - nothing it does feeds track-end detection, and
    /// it is called last so it can never reorder it.
    var onPlayerState: ((PlayerStateSnapshot) -> Void)?

    // MARK: - SDK objects

    /// `playURI = ""` so authorizing also resumes the user's last song. With a
    /// nil playURI the Spotify app authorizes but starts nothing, App Remote
    /// has no live player to attach to, and connecting needs a second app
    /// switch. Documented on `SPTConfiguration.playURI`.
    let configuration: SPTConfiguration = {
        let c = SPTConfiguration(
            clientID: Config.spotifyClientID,
            redirectURL: Config.spotifyRedirectURL)
        c.playURI = ""
        return c
    }()

    private lazy var sessionManager = SPTSessionManager(configuration: configuration, delegate: self)

    private lazy var appRemote: SPTAppRemote = {
        let remote = SPTAppRemote(configuration: configuration, logLevel: .info)
        remote.delegate = self
        return remote
    }()

    // MARK: - Track-end bookkeeping

    /// The URI we last saw playing, and how far into it we had got. The end of
    /// a track is only ever observed by comparing against these.
    private var watchedURI: String?
    private var lastPosition = 0
    /// Wall-clock listening time on `watchedURI`, accumulated across the sparse
    /// state-change callbacks. `playbackPosition` alone is not enough: the
    /// delegate is not called on a timer, so a track that plays through
    /// uninterrupted can report a position from thirty seconds in.
    private var accumulatedMs = 0
    private var playingSince: Date?
    /// Guards against reporting the same track's end twice (a pause at 0 and
    /// then a URI change would otherwise fire two scrobbles for one play).
    private var reportedEndFor: String?

    /// A track we were asked to play before the remote was connected.
    private var pendingPlayURI: String?

    /// The image id we last asked the Spotify app for. `playerStateDidChange`
    /// fires several times per track (pause, seek, position); refetching the
    /// same cover on each one would be a request per callback.
    private var fetchedImageIdentifier: String?

    /// A paused state at or below this many ms is treated as "the track ended
    /// and the player rewound", not as the user pausing at the very start.
    private let endPositionToleranceMs = 1500
    /// ...but only if we had actually got somewhere in the track first.
    private let minimumProgressToCountAsEndMs = 3000

    // MARK: - Auth

    /// The live access token, for the Web API. Nil until authorized.
    ///
    /// Both of these short-circuit in demo mode. `sessionManager` is `lazy`, so
    /// merely READING either one would construct the real SDK object and, in
    /// the simulator, take the SDK down a path that has no Spotify app to talk
    /// to. Demo mode must construct neither.
    var accessToken: String? {
        #if DEBUG
            if DemoMode.isActive { return nil }
        #endif
        return sessionManager.session?.accessToken
    }

    var isSpotifyInstalled: Bool {
        #if DEBUG
            if DemoMode.isActive { return true }
        #endif
        return sessionManager.isSpotifyAppInstalled
    }

    func authorize() {
        Diag.log("authorize() installed=\(sessionManager.isSpotifyAppInstalled)")
        lastError = nil
        // `.default` rather than `.clientOnly`: clientOnly hard-fails when the
        // Spotify app is missing, default falls back to a web sheet.
        sessionManager.initiateSession(
            with: [.userLibraryRead, .appRemoteControl, .userModifyPlaybackState],
            options: .default,
            campaign: nil)
    }

    /// The OAuth callback, handed over from `.onOpenURL`.
    @discardableResult
    func handle(url: URL) -> Bool {
        Diag.log("handle(url:) scheme=\(url.scheme ?? "nil") main=\(Thread.isMainThread)")
        if sessionManager.application(UIApplication.shared, open: url, options: [:]) {
            Diag.log("handle(url:) claimed by sessionManager")
            return true
        }
        // Fallback: a URL produced by `authorizeAndPlayURI` carries the token
        // directly and the session manager does not claim it.
        guard let params = appRemote.authorizationParameters(from: url) else { return false }
        if let token = params[SPTAppRemoteAccessTokenKey] {
            Diag.log("handle(url:) token from authorizationParameters -> connect()")
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
            return true
        }
        if let description = params[SPTAppRemoteErrorDescriptionKey] {
            Diag.log("handle(url:) error param: \(description)")
            lastError = description
        }
        return false
    }

    // MARK: - App Remote

    func connect() {
        Diag.log("connect() main=\(Thread.isMainThread) hasToken=\(accessToken != nil)")
        guard let token = accessToken else {
            lastError = "Not signed in to Spotify."
            return
        }
        appRemote.connectionParameters.accessToken = token
        appRemote.connect()
    }

    func disconnect() {
        guard appRemote.isConnected else { return }
        appRemote.disconnect()
    }

    /// Reconnect on returning to the foreground, if we can and are not already.
    ///
    /// App Remote's connection does not survive backgrounding: iOS suspends
    /// this process and Spotify tears the socket down ("Connection
    /// terminated."). Without this, the next playback call finds no connection
    /// and falls into the `authorizeAndPlayURI` fallback - a full app switch
    /// that looks to the user exactly like being signed out and asked to
    /// connect again.
    ///
    /// There is deliberately NO matching disconnect on the way to the
    /// background. Disconnecting would guarantee we stop receiving
    /// player-state callbacks, and with them every track-end scrobble for
    /// music played with the phone locked - which is most listening. Letting
    /// the connection die on its own at least keeps whatever we can still see.
    func reconnectIfNeeded() {
        guard accessToken != nil else { return }
        guard !appRemote.isConnected else { return }
        Diag.log("reconnectIfNeeded -> connect()")
        connect()
    }

    // MARK: - Playback

    /// Ask the Spotify app to play a URI - a track, or a context such as a
    /// playlist.
    ///
    /// `onResult` reports what the Spotify app said: nil for accepted, the
    /// error's own description for refused. It exists for the DJ, which may
    /// legitimately be refused by a server this app cannot see, and where
    /// "accepted" and "refused" have to be told apart by the caller rather than
    /// both landing silently in `lastError`.
    ///
    /// It is NOT called on the not-connected path. Nothing has been attempted
    /// there - the play is queued behind a connection and replayed by
    /// `didEstablishConnection` - and reporting a failure would make a caller
    /// fall back over a play that is still about to happen.
    func play(uri: String, onResult: (@MainActor @Sendable (String?) -> Void)? = nil) {
        guard appRemote.isConnected, let player = appRemote.playerAPI else {
            // Spotify is not running. Remember the URI and connect; if that
            // fails we wake Spotify with it in the failure delegate.
            Diag.log("play(uri:) deferred, App Remote not connected: \(uri)")
            pendingPlayURI = uri
            connect()
            return
        }
        beginWatching(uri: uri)
        player.play(uri) { [weak self] _, error in
            let description = error?.localizedDescription
            Task { @MainActor in
                if let description { self?.lastError = description }
                onResult?(description)
            }
        }
    }

    /// Ask the Spotify app to move to the next track.
    ///
    /// Only used where this app is NOT holding the list - Spotify's DJ - and
    /// deliberately does nothing else: the URI change that follows is picked up
    /// by the ordinary track-end detection below, so the outgoing track
    /// scrobbles through exactly the same path as one that played out.
    func skipNext() {
        appRemote.playerAPI?.skip(toNext: { [weak self] _, error in
            guard let error else { return }
            Diag.log("skipNext failed: \(error.localizedDescription)")
            let description = error.localizedDescription
            Task { @MainActor in self?.lastError = description }
        })
    }

    func pause() {
        appRemote.playerAPI?.pause { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }

    func resume() {
        appRemote.playerAPI?.resume { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }

    // MARK: - Track-end detection

    /// Start counting a fresh track. Called when we ask for one, and again when
    /// the player reports it has moved on by itself.
    private func beginWatching(uri: String) {
        watchedURI = uri
        lastPosition = 0
        accumulatedMs = 0
        playingSince = nil
        reportedEndFor = nil
    }

    /// Fold the wall-clock time since the last callback into the total, if we
    /// were playing across it.
    private func accrue(now: Date) {
        guard let since = playingSince else { return }
        accumulatedMs += max(0, Int(now.timeIntervalSince(since) * 1000))
        playingSince = nil
    }

    private func reportEnd(of uri: String) {
        guard reportedEndFor != uri else { return }
        reportedEndFor = uri
        // Take the larger of the two measures. `playbackPosition` is right when
        // the user seeks; the accumulator is right when the track just plays.
        onTrackEnded?(uri, max(lastPosition, accumulatedMs))
    }

    // MARK: - Debug

    /// Track-end detection is the part of this file most likely to be wrong,
    /// because it depends on what the Spotify app chooses to report at the
    /// boundary between two tracks. Read this log off the device and correct
    /// `handle(playerState:)` from it rather than from theory.
    private func logState(_ state: PlayerStateSnapshot) {
        Diag.log(
            """
            playerState \
            uri=\(state.uri) \
            name=\(state.trackName) \
            paused=\(state.isPaused) \
            position=\(state.playbackPosition) \
            duration=\(state.duration) \
            speed=\(state.playbackSpeed) \
            context=\(state.contextURI) \
            watched=\(watchedURI ?? "nil") \
            lastPosition=\(lastPosition) \
            accumulatedMs=\(accumulatedMs)
            """)
    }
}

// MARK: - Player state snapshot

/// The plain values `handle(playerState:)` and `logState` read out of the SDK's
/// player state.
///
/// This exists because `SPTAppRemotePlayerState` is a non-`Sendable` Objective-C
/// object: the delegate callback may arrive on one of App Remote's own queues,
/// and the SDK object cannot be carried across the hop to the main actor. The
/// values are copied out first, on whatever thread delivered them, and only
/// this struct crosses.
struct PlayerStateSnapshot: Sendable {
    let uri: String
    let trackName: String
    let artistName: String
    let albumName: String
    /// `SPTAppRemoteTrack` conforms to `SPTAppRemoteImageRepresentable`, and
    /// this is the only part of it the image API actually reads. Copying the
    /// String out here is what lets the fetch happen on the main actor without
    /// the non-Sendable track object having to cross the hop.
    let imageIdentifier: String
    let isPaused: Bool
    let playbackPosition: Int
    let duration: UInt
    let playbackSpeed: Float
    let contextURI: String

    /// The values on their own, with no SDK object anywhere near them.
    ///
    /// This is what makes a DJ scrobble testable: `djScrobble(from:)` reads a
    /// snapshot, and building one the other way needs an `SPTAppRemotePlayerState`,
    /// which needs the real Spotify app on a real device. Everything after
    /// `artistName` defaults, because nothing downstream of the scrobble reads
    /// it and a test that had to spell out a playback speed would be describing
    /// the SDK rather than the decision.
    init(
        uri: String, trackName: String, artistName: String, albumName: String = "",
        imageIdentifier: String = "", isPaused: Bool = false, playbackPosition: Int = 0,
        duration: UInt = 0, playbackSpeed: Float = 1, contextURI: String = ""
    ) {
        self.uri = uri
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.imageIdentifier = imageIdentifier
        self.isPaused = isPaused
        self.playbackPosition = playbackPosition
        self.duration = duration
        self.playbackSpeed = playbackSpeed
        self.contextURI = contextURI
    }

    init(_ state: any SPTAppRemotePlayerState) {
        uri = state.track.uri
        trackName = state.track.name
        artistName = state.track.artist.name
        albumName = state.track.album.name
        imageIdentifier = state.track.imageIdentifier
        isPaused = state.isPaused
        playbackPosition = state.playbackPosition
        duration = state.track.duration
        playbackSpeed = state.playbackSpeed
        contextURI = state.contextURI.absoluteString
    }
}

/// The smallest thing `SPTAppRemoteImageAPI` will accept.
///
/// `fetchImageForItem:` takes an `id<SPTAppRemoteImageRepresentable>`, and the
/// only member of that protocol is `imageIdentifier`. The SDK's own track
/// object satisfies it but is not `Sendable` and cannot be carried off the
/// delegate's thread, so the identifier is re-wrapped in this instead.
final class SpotifyImageRef: NSObject, SPTAppRemoteImageRepresentable {
    let imageIdentifier: String
    init(_ imageIdentifier: String) { self.imageIdentifier = imageIdentifier }
}

// MARK: - SPTSessionManagerDelegate

// Every delegate method below is `nonisolated`, NOT `@preconcurrency`.
//
// `@preconcurrency` only silences the compile-time isolation check; under Swift
// 6 the compiler still emits a main-actor assertion at the top of each method,
// which traps as SIGTRAP - with no message - if the SDK delivers the callback
// on any other thread. App Remote's callbacks come off its own socket, so that
// assumption cannot be made. These methods therefore accept delivery on any
// thread, copy out the plain (`Sendable`) values they need, and hop to the main
// actor explicitly. The SDK objects themselves are never captured.
extension SpotifySession: SPTSessionManagerDelegate {

    nonisolated func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        Diag.log("sessionManager didInitiate main=\(Thread.isMainThread)")
        let token = session.accessToken
        Task { @MainActor [weak self] in self?.didInitiate(accessToken: token) }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didFailWith error: any Error) {
        Diag.log("sessionManager didFailWith main=\(Thread.isMainThread) error=\(error.localizedDescription)")
        let description = error.localizedDescription
        Task { @MainActor [weak self] in self?.didFailAuthorization(description) }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        Diag.log("sessionManager didRenew main=\(Thread.isMainThread)")
        let token = session.accessToken
        Task { @MainActor [weak self] in self?.didRenew(accessToken: token) }
    }

    @MainActor private func didInitiate(accessToken: String) {
        isAuthorized = true
        lastError = nil
        // Hand the fresh token to App Remote and connect straight away - the
        // Spotify app is in the foreground at this exact moment, which is the
        // one time connecting is guaranteed to be possible.
        appRemote.connectionParameters.accessToken = accessToken
        Diag.log("didInitiate -> appRemote.connect()")
        appRemote.connect()
    }

    @MainActor private func didFailAuthorization(_ description: String) {
        isAuthorized = false
        lastError = description
    }

    @MainActor private func didRenew(accessToken: String) {
        isAuthorized = true
        // Deliberately does NOT reconnect: a renew arrives while playback is
        // already running and reconnecting would interrupt it. The new token is
        // read from `accessToken` on the next Web API call.
        appRemote.connectionParameters.accessToken = accessToken
    }
}

// MARK: - SPTAppRemoteDelegate

extension SpotifySession: SPTAppRemoteDelegate {

    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Diag.log("appRemoteDidEstablishConnection main=\(Thread.isMainThread)")
        // The parameter is the same object as `self.appRemote`, and it is not
        // `Sendable`, so the hop re-reads it from `self` rather than capturing.
        Task { @MainActor [weak self] in self?.didEstablishConnection() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: (any Error)?) {
        Diag.log("appRemote didFailConnectionAttempt main=\(Thread.isMainThread) error=\(error?.localizedDescription ?? "nil")")
        let description = error?.localizedDescription
        Task { @MainActor [weak self] in self?.didFailConnection(description) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: (any Error)?) {
        Diag.log("appRemote didDisconnect main=\(Thread.isMainThread) error=\(error?.localizedDescription ?? "nil")")
        let description = error?.localizedDescription
        Task { @MainActor [weak self] in self?.didDisconnect(description) }
    }

    @MainActor private func didEstablishConnection() {
        isConnected = true
        lastError = nil
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: { [weak self] _, error in
            guard let error else { return }
            Diag.log("subscribe(toPlayerState:) failed: \(error.localizedDescription)")
            let description = error.localizedDescription
            Task { @MainActor in self?.lastError = description }
        })
        if let uri = pendingPlayURI {
            pendingPlayURI = nil
            play(uri: uri)
        }
    }

    @MainActor private func didFailConnection(_ description: String?) {
        isConnected = false
        lastError = description ?? "Could not reach the Spotify app."
        // The usual cause is that Spotify is not running. `connect` cannot wake
        // it; `authorizeAndPlayURI` can, at the cost of an app switch.
        if let uri = pendingPlayURI {
            pendingPlayURI = nil
            beginWatching(uri: uri)
            appRemote.authorizeAndPlayURI(uri) { [weak self] success in
                guard !success else { return }
                Task { @MainActor in self?.lastError = "Spotify is not installed." }
            }
        }
    }

    @MainActor private func didDisconnect(_ description: String?) {
        isConnected = false
        if let description { lastError = description }
    }
}

// MARK: - SPTAppRemotePlayerStateDelegate

extension SpotifySession: SPTAppRemotePlayerStateDelegate {

    nonisolated func playerStateDidChange(_ playerState: any SPTAppRemotePlayerState) {
        Diag.log("playerStateDidChange main=\(Thread.isMainThread)")
        // Copy before hopping: `playerState` cannot cross to the main actor.
        let snapshot = PlayerStateSnapshot(playerState)
        Task { @MainActor [weak self] in
            self?.logState(snapshot)
            self?.handle(playerState: snapshot)
        }
    }

    /// Two ways a track ends, both observed only through this one callback:
    ///
    /// 1. The URI changes - the Spotify app moved on by itself. Unambiguous.
    /// 2. The URI stays the same but the player reports paused at ~0 after
    ///    having made progress. That is the player rewinding at the end of a
    ///    single-track context, which is exactly what our queue produces.
    ///
    /// A pause at 0 with no progress behind it is NOT an end - it is a user who
    /// pressed pause immediately - hence `minimumProgressToCountAsEndMs`.
    @MainActor private func handle(playerState state: PlayerStateSnapshot) {
        let now = Date()
        let uri = state.uri
        let position = state.playbackPosition
        let paused = state.isPaused

        accrue(now: now)

        if let watched = watchedURI, uri != watched {
            reportEnd(of: watched)
            beginWatching(uri: uri)
        } else if watchedURI == nil {
            beginWatching(uri: uri)
        } else if paused,
            position <= endPositionToleranceMs,
            max(lastPosition, accumulatedMs) >= minimumProgressToCountAsEndMs
        {
            reportEnd(of: uri)
        }

        lastPosition = position
        if !paused { playingSince = now }

        isPaused = paused
        currentTrackURI = uri

        // Display state only, below this line. Nothing here feeds track-end
        // detection or scrobbling.
        trackName = state.trackName
        artistName = state.artistName
        albumName = state.albumName
        progress = PlaybackProgress(
            positionMs: position,
            durationMs: Int(state.duration),
            isPaused: paused,
            anchor: now)
        fetchArtwork(identifier: state.imageIdentifier)

        // LAST, deliberately. Everything above has already happened, so an
        // observer cannot change what this method decided about the end of a
        // track - it can only be told what was seen.
        onPlayerState?(state)
    }

    /// Ask the Spotify app for the current cover, once per image.
    ///
    /// 640pt square because the expanded player fills the screen width; the SDK
    /// downsamples for us and a row thumbnail never uses this path.
    @MainActor private func fetchArtwork(identifier: String) {
        guard !identifier.isEmpty, identifier != fetchedImageIdentifier,
            let imageAPI = appRemote.imageAPI
        else { return }
        fetchedImageIdentifier = identifier
        imageAPI.fetchImage(
            forItem: SpotifyImageRef(identifier),
            with: CGSize(width: 640, height: 640)
        ) { [weak self] result, error in
            if let error {
                Diag.log("fetchImage failed: \(error.localizedDescription)")
                return
            }
            // `UIImage` is not Sendable, so the hop cannot capture it. Turning
            // it into PNG data here - on whatever queue the SDK used - and
            // rebuilding on the main actor is what keeps this legal under
            // Swift 6 strict concurrency.
            guard let image = result as? UIImage, let data = image.pngData() else { return }
            Task { @MainActor in
                self?.nowPlayingImage = UIImage(data: data)
            }
        }
    }
}

// MARK: - Demo

#if DEBUG
    extension SpotifySession {
        /// Pretend the Spotify app is connected and playing, for `-AudioIndexDemo`.
        ///
        /// Sets only published display state. It never touches `sessionManager` or
        /// `appRemote` - both are `lazy`, so in demo mode neither is ever
        /// constructed and no SDK code runs at all.
        func applyDemoState(
            title: String, artist: String, album: String,
            uri: String, durationMs: Int, positionMs: Int
        ) {
            isAuthorized = true
            isConnected = true
            isPaused = false
            lastError = nil
            currentTrackURI = uri
            trackName = title
            artistName = artist
            albumName = album
            progress = PlaybackProgress(
                positionMs: positionMs, durationMs: durationMs,
                isPaused: false, anchor: Date())
        }

        func demoTogglePlayPause() {
            let now = Date()
            let position = progress.estimatedMs(at: now)
            isPaused.toggle()
            progress = PlaybackProgress(
                positionMs: position, durationMs: progress.durationMs,
                isPaused: isPaused, anchor: now)
        }
    }
#endif
