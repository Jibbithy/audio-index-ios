import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// The file half of the player: raw audio from Navidrome, played by THIS app.
///
/// This is the whole reason Navidrome is in the design. Spotify's App Remote
/// hands out no audio - it is a remote control for another process - so this
/// app owns nothing while Spotify is playing and can add nothing to it. A
/// Navidrome stream is ordinary HTTP audio, so `AVPlayer` plays it here, inside
/// our own `AVAudioSession`. Owning that session is what makes the lock screen
/// possible at all, and it is the same thing an equaliser or a crossfade would
/// later have to be built on.
///
/// Like `SpotifySession`, nothing in here can be unit-tested: `AVPlayer` needs
/// a device, a session and a network. Every decision it would otherwise make
/// lives in `PlaybackRouting.swift` as a pure function, and what is left is
/// glue verified by hand on the phone.
@MainActor
final class LocalPlayer: ObservableObject {

    // MARK: - Observable state

    @Published private(set) var isPaused = true
    /// Seconds into the current file. Updated on a slow tick, not every frame:
    /// the progress bar extrapolates from `progress` between updates the same
    /// way it does for Spotify.
    @Published private(set) var currentTime: Double = 0
    /// Length of the current file in seconds. Zero until the item is ready -
    /// the bar renders empty rather than dividing by it.
    @Published private(set) var duration: Double = 0
    /// The last playback failure, in words. A 404, a dead tailnet or a codec
    /// iOS will not decode all land here.
    ///
    /// This exists because the alternative is worse than useless: `AVPlayer`
    /// answers all three by simply not producing sound, which on screen is
    /// indistinguishable from a queue that stopped advancing.
    @Published private(set) var lastError: String?
    /// Position as a value carrying the instant it was measured, so the same
    /// `PlaybackProgress` the Spotify path uses can drive the same bar.
    @Published private(set) var progress = PlaybackProgress.none

    // MARK: - Callbacks

    /// Fires with the ms played when the current file finishes, mirroring
    /// `SpotifySession.onTrackEnded`. `Player` turns it into a scrobble; the
    /// URI is not carried because, unlike Spotify, nothing else can change what
    /// this player is playing behind our back.
    var onTrackEnded: ((Int) -> Void)?
    /// A playback failure, already phrased for a person.
    var onFailure: ((String) -> Void)?
    /// The lock screen's next button.
    var onRemoteNext: (() -> Void)?

    // MARK: - AVFoundation

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    /// One end per item. `didPlayToEndTimeNotification` and a rewind-to-zero
    /// can both look like an end; reporting twice would scrobble one play
    /// twice, and the index has no way to tell that apart from a real replay.
    private var didReportEnd = false
    private var sessionActive = false

    /// What the lock screen is currently told. Held because
    /// `MPNowPlayingInfoCenter` is rebuilt whole on every update.
    private var title = ""
    private var artist = ""

    private var commandTargets: [(MPRemoteCommand, Any)] = []

    // MARK: - Init

    init() {
        // Installed once for the object's whole life rather than per item.
        // Removing a periodic observer needs the same `AVPlayer` it was added
        // to, and doing that from `deinit` on a main-actor class is not
        // expressible under Swift 6 - so it is never removed, and the observer
        // simply idles when there is no item.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Transport

    /// Start a stream. Replaces whatever was playing.
    ///
    /// `title` and `artist` are what the lock screen shows. They come from the
    /// queue entry rather than from the file's tags on purpose: the files on
    /// that server are deliberately untagged, so atlas's idea of the track is
    /// the only readable one there is.
    func play(url: URL, title: String = "", artist: String = "") {
        self.title = title
        self.artist = artist
        lastError = nil
        didReportEnd = false
        currentTime = 0
        duration = 0

        activateSession()

        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)
        player.play()
        isPaused = false

        publishProgress()
        installRemoteCommands()
        updateNowPlaying()
        Diag.log("LocalPlayer.play host=\(url.host ?? "nil") path=\(url.path)")
    }

    func pause() {
        guard player.currentItem != nil else { return }
        player.pause()
        isPaused = true
        publishProgress()
        updateNowPlaying()
    }

    func resume() {
        guard player.currentItem != nil else { return }
        // Re-activated rather than assumed: a phone call, or Spotify taking the
        // session while we were paused, deactivates it underneath us and
        // `play()` on a dead session produces silence with no error.
        activateSession()
        player.play()
        isPaused = false
        publishProgress()
        updateNowPlaying()
    }

    /// Stop, drop the item, hand the audio session back and clear the lock
    /// screen. Called before Spotify is asked to play anything - see the note
    /// on `deactivateSession`.
    func stop() {
        guard player.currentItem != nil || sessionActive || !commandTargets.isEmpty else { return }
        player.pause()
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        isPaused = true
        currentTime = 0
        duration = 0
        progress = .none
        removeRemoteCommands()
        // Clears only OUR entry. Spotify's own now-playing info is its own.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateSession()
    }

    /// How far into the current file we are, as the index stores it. Read from
    /// the player's live clock, not from `currentTime`, which is half a second
    /// stale by construction.
    func msPlayedNow() -> Int {
        fileMsPlayed(
            positionSeconds: player.currentTime().seconds,
            durationSeconds: duration)
    }

    // MARK: - Audio session

    /// `.playback`, and active.
    ///
    /// `.playback` rather than `.ambient` is what makes audio continue with the
    /// screen locked and the ring switch silenced - together with
    /// `UIBackgroundModes: [audio]` in the Info.plist, without which iOS
    /// suspends this process at lock and the music stops mid-bar.
    private func activateSession() {
        guard !sessionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            sessionActive = true
        } catch {
            sessionActive = false
            report(
                "This phone would not give us the audio session "
                    + "(\(error.localizedDescription)).")
        }
    }

    /// Hand the session back, and TELL the other apps.
    ///
    /// `.notifyOthersOnDeactivation` is the load-bearing part. Two players both
    /// holding the session is the failure mode of this whole design, and it
    /// does not present as an error - one of them just silently refuses to make
    /// sound. Without the notification Spotify is never told it may take the
    /// session back, and the next Spotify track in the queue plays nothing.
    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Not surfaced. The session failing to deactivate is not something
            // the user did or can fix, and by this point we have already
            // stopped - the log is for us.
            Diag.log("LocalPlayer.deactivateSession failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Item observation

    private func observe(_ item: AVPlayerItem) {
        removeItemObservers()

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.itemDidPlayToEnd() }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] note in
            // Copied out here, on the delivering queue: `Notification` is not
            // Sendable and cannot cross the hop, a String can.
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?
                .localizedDescription
            Task { @MainActor in
                self?.report(
                    "Playback of this file stopped early"
                        + (reason.map { ": \($0)" } ?? "."))
            }
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.report("The stream stalled. Is the tailnet up?")
            }
        }

        // A 404, a refused connection and a codec iOS will not decode all
        // arrive here and NOWHERE else: none of them produce a
        // failedToPlayToEnd notification, because playback never started, and
        // the periodic observer never fires because time never moves. Without
        // this the app sits paused-looking forever with nothing said.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription
            Task { @MainActor in
                self?.report(
                    "This file could not be played"
                        + (reason.map { ": \($0)" } ?? "."))
            }
        }
    }

    private func removeItemObservers() {
        for observer in [endObserver, failObserver, stallObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil
        failObserver = nil
        stallObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
    }

    private func itemDidPlayToEnd() {
        guard !didReportEnd else { return }
        didReportEnd = true
        isPaused = true
        // The full length, not the last sampled position: the tick is half a
        // second coarse and a play short of the track's own duration reads to
        // atlas as a skip.
        let seconds = duration > 0 ? duration : player.currentTime().seconds
        currentTime = duration
        publishProgress()
        updateNowPlaying()
        onTrackEnded?(fileMsPlayed(positionSeconds: seconds, durationSeconds: duration))
    }

    private func report(_ message: String) {
        Diag.log("LocalPlayer failure: \(message)")
        lastError = message
        isPaused = true
        publishProgress()
        onFailure?(message)
    }

    // MARK: - Tick

    private func tick() {
        guard let item = player.currentItem else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { currentTime = max(0, seconds) }

        let itemDuration = item.duration.seconds
        if itemDuration.isFinite, itemDuration > 0, itemDuration != duration {
            duration = itemDuration
            // The lock screen scrubber has no length until this is known, so it
            // is pushed the moment it becomes known rather than on the next
            // transport change.
            updateNowPlaying()
        }
        publishProgress()
    }

    private func publishProgress() {
        progress = PlaybackProgress(
            positionMs: Int(max(0, currentTime) * 1000),
            durationMs: Int(max(0, duration) * 1000),
            isPaused: isPaused,
            anchor: Date())
    }

    // MARK: - Lock screen

    /// What the lock screen and Control Center show.
    ///
    /// Only ever written while a FILE is playing, and cleared in `stop()`. When
    /// Spotify is playing, the Spotify app owns that surface and publishing our
    /// own now-playing info would put two competing cards in front of the user
    /// with the transport buttons wired to the wrong one.
    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        let elapsed = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed.isFinite ? max(0, elapsed) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Play, pause and next on the lock screen, the Control Center and a pair
    /// of headphones.
    ///
    /// Previous is deliberately NOT registered: the cursor only moves forward -
    /// atlas has already excluded what was played - and a lock-screen button
    /// that does nothing is worse than one that is not there.
    private func installRemoteCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { [weak self] in self?.resume() }
        add(center.pauseCommand) { [weak self] in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }
            if self.isPaused { self.resume() } else { self.pause() }
        }
        add(center.nextTrackCommand) { [weak self] in self?.onRemoteNext?() }
    }

    /// Wraps one command target.
    ///
    /// The handler answers `.success` immediately and does the work on the next
    /// main-actor hop rather than inline: the block is called by MediaPlayer
    /// with no isolation guarantee, and asserting one would trap in exactly the
    /// situation this code exists for - the phone locked, with nobody looking.
    private func add(_ command: MPRemoteCommand, _ work: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            Task { @MainActor in work() }
            return .success
        }
        commandTargets.append((command, target))
    }

    private func removeRemoteCommands() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets.removeAll()
    }
}
