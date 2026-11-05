import SwiftUI

/// The ranked queue atlas handed us.
///
/// The header, the switch to the library and the mini player belong to the
/// shell in `ContentView`, so this file is only the list and the states it can
/// be in - and switching tabs cannot make the chrome flicker.
///
/// Split into "now playing" and "next up" rather than one undifferentiated
/// list, because the single most important thing on the screen is which row is
/// coming out of the speaker. Rows the cursor has already passed are dropped
/// entirely - they are history, and atlas has already excluded them from the
/// next queue.
struct QueueScreen: View {
    @EnvironmentObject private var player: Player
    /// Watched so the mini bar inside this screen redraws while a local file
    /// plays - see the note in `MiniPlayerBar`.
    @EnvironmentObject private var local: LocalPlayer
    @EnvironmentObject private var spotify: SpotifySession

    @Binding var showSettings: Bool

    private var tracks: [TrackRef] { player.cursor.tracks }
    private var current: TrackRef? { player.cursor.current }
    private var upcoming: ArraySlice<TrackRef> {
        let next = player.cursor.index + 1
        guard next < tracks.count else { return [] }
        return tracks[next...]
    }

    var body: some View {
        Group {
            // A refused DJ falls back to the ranked queue, so it falls back to
            // the ranked SCREEN too - the list below is then what is really
            // playing, and the red banner on it carries Spotify's own words.
            if player.mode == .spotifyDJ && player.djFailure == nil {
                djPanel
            } else if tracks.isEmpty {
                emptyOrError
            } else {
                list
            }
        }
    }

    // MARK: The DJ

    /// What is happening, instead of a list that does not exist.
    ///
    /// There is deliberately no "next up" here and there never can be: App
    /// Remote does not expose what the DJ intends to play, and inventing a list
    /// - the last ranked queue, say - would be showing the user tracks that are
    /// not going to play. So this screen says who is choosing, what is playing
    /// now, and that the plays are still being written down, which is the whole
    /// bargain of the mode.
    private var djPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("NOW PLAYING")

                if let track = player.djTrack {
                    QueueRow(track: track, isCurrent: true, separator: false)
                        .addToPlaylistMenu(for: track)
                } else {
                    Text(djWaitingLine)
                        .font(Deck.body)
                        .foregroundStyle(Deck.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .deckRow(separator: false)
                }

                sectionLabel("WHAT THIS MODE IS")
                VStack(alignment: .leading, spacing: 10) {
                    djNote(
                        "music.mic",
                        "Spotify's DJ is choosing. This app is not ranking anything "
                            + "while it does.")
                    djNote(
                        "square.and.arrow.up.on.square",
                        player.pendingScrobbles > 0
                            ? "Every play is still recorded to atlas — \(player.pendingScrobbles) "
                                + "waiting to send. Your ranking keeps training in the background."
                            : "Every play is still recorded to atlas, so your ranking keeps "
                                + "training in the background.")
                    djNote(
                        "list.bullet",
                        "Spotify does not tell this app what the DJ will play next, so "
                            + "there is no queue to show.")
                    if player.libraryTrack != nil {
                        djNote(
                            "hand.raised",
                            "Something you chose is playing instead. The DJ will not come "
                                + "back on its own — tap “Play the DJ” when you want it.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Button {
                    Task { await player.startPlayback() }
                } label: {
                    Text(player.isPlayingDJ ? "Restart the DJ" : "Play the DJ")
                }
                .buttonStyle(.deckPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 18)

                banner
                Color.clear.frame(height: 12)
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Why there is no track on screen yet. The two reasons are different
    /// problems and must not read as one.
    private var djWaitingLine: String {
        if !spotify.isConnected {
            return "Spotify is not connected, so the DJ cannot be started. "
                + "Connect Spotify in Settings."
        }
        return player.isPlayingDJ
            ? "Waiting for Spotify to say what the DJ picked…"
            : "The DJ is not playing. Tap “Play the DJ” below."
    }

    private func djNote(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Deck.accentInk)
                .frame(width: 18)
            Text(text)
                .font(Deck.small)
                .foregroundStyle(Deck.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if let current {
                    sectionLabel("NOW PLAYING")
                    QueueRow(track: current, isCurrent: true, separator: false)
                        .addToPlaylistMenu(for: current)
                }
                if !upcoming.isEmpty {
                    sectionLabel("NEXT UP")
                    ForEach(Array(upcoming), id: \.track_id) { track in
                        QueueRow(
                            track: track, isCurrent: false,
                            separator: track.track_id != upcoming.first?.track_id
                        )
                        .addToPlaylistMenu(for: track)
                    }
                }
                if current != nil || !upcoming.isEmpty { DeckRule() }
                banner
                Color.clear.frame(height: 12)
            }
        }
        .scrollIndicators(.hidden)
    }

    /// A table head: the rail strip the rows hang from.
    private func sectionLabel(_ text: String) -> some View {
        DeckTableHead(text)
            .padding(.top, 14)
    }

    // MARK: Empty and error

    /// An empty queue is NOT a failure - a fresh index, or every track sitting
    /// inside its cooldown, both legitimately return nothing. It gets its own
    /// neutral state; only a real error is red.
    @ViewBuilder private var emptyOrError: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            if let error = player.error {
                DeckAlert(.crit, title: "Atlas could not be read.", message: error) {
                    queueActions.padding(.top, 6)
                }
            } else {
                DeckEmpty(
                    label: "Empty", title: "Nothing queued.",
                    message: player.status ?? "Sync your library, then load the queue."
                ) {
                    queueActions.padding(.top, 6)
                }
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueActions: some View {
        HStack(spacing: 10) {
            Button("Load queue") {
                Task { await player.loadQueue() }
            }
            .buttonStyle(.deckPrimary)
            .disabled(player.isWorking)

            Button("Settings") { showSettings = true }
                .buttonStyle(.deck)
        }
    }

    /// Progress is muted, failure is crit-ink behind a ■, and they are never
    /// the same control.
    @ViewBuilder private var banner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = player.status {
                DeckHint(status)
            }
            if let error = player.error {
                DeckErrorText(error)
            }
            if let spotifyError = spotify.lastError {
                DeckErrorText("Spotify: \(spotifyError)")
            }
            // A file that will not play says so here rather than leaving the
            // bar sitting paused, which reads as a bug in the queue.
            if let fileError = local.lastError {
                DeckErrorText("Files: \(fileError)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }
}

// MARK: - Row

struct QueueRow: View {
    let track: TrackRef
    let isCurrent: Bool
    /// The hair above the row - off for the first row under a table head.
    var separator = true

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(ref: track.source_ref, size: Theme.rowArt)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(Theme.rowTitle)
                    .foregroundStyle(isCurrent ? Deck.accentInk : Deck.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(track.artist)
                    .font(Theme.rowSubtitle)
                    .foregroundStyle(Deck.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent { EqualiserBars() }
        }
        .deckRow(selected: isCurrent, separator: separator)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.artist)\(isCurrent ? ", now playing" : "")")
    }
}

/// Three bars, the universal "this is the one that is sounding".
///
/// Cheaper and clearer than a text label: it survives being read at a glance
/// down a scrolling list, which "NOW PLAYING" repeated on one row does not.
/// Square-ended, and in the accent's ink twin so they clear 3:1 on the rail.
struct EqualiserBars: View {
    @State private var animating = false
    private let heights: [CGFloat] = [7, 14, 10]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Rectangle()
                    .fill(Deck.accentInk)
                    .frame(width: 3, height: animating ? 15 : height)
                    .animation(
                        .easeInOut(duration: 0.42 + Double(index) * 0.13)
                            .repeatForever(autoreverses: true),
                        value: animating)
            }
        }
        .frame(height: 16)
        .onAppear { animating = true }
        .accessibilityHidden(true)
    }
}
