import SwiftUI

/// The expanded player, presented as a sheet so a swipe down dismisses it for
/// free - that gesture is the one thing every user of a phone player already
/// knows, and re-implementing it with a drag gesture would only get it slightly
/// wrong.
struct NowPlayingScreen: View {
    @EnvironmentObject private var player: Player
    /// Watched so the screen redraws while a local file plays - see the note in
    /// `MiniPlayerBar`.
    @EnvironmentObject private var local: LocalPlayer
    @EnvironmentObject private var spotify: SpotifySession
    @Environment(\.dismiss) private var dismiss

    @Binding var showSettings: Bool

    /// What is playing, which is not always the cursor's entry - a row tapped
    /// in the library browser plays without moving the queue.
    private var track: TrackRef? { player.playingTrack }
    private var ref: String { track?.source_ref ?? "" }

    private var title: String {
        let name = player.nowPlayingTitle
        return name.isEmpty ? "Nothing playing" : name
    }

    private var artist: String { player.nowPlayingArtist }

    /// Where the audio is actually coming from. Worth a line on the screen:
    /// which player owns the sound decides what the lock screen shows and what
    /// happens when the phone locks, and the two are not interchangeable.
    private var sourceLabel: String {
        if player.isPlayingFile { return "Your files, via Navidrome" }
        // Three sources, not two: a DJ track came out of Spotify's choosing,
        // not out of the index, and saying "your atlas index" over it would
        // credit the ranking for a track it had no part in.
        if player.isPlayingDJ { return "Spotify's DJ" }
        return "Your atlas index"
    }

    var body: some View {
        ZStack {
            // The plain page. The old per-track colour wash is gone: Deck has
            // one ground, and the cover is the only picture on it.
            Deck.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                chrome
                Spacer(minLength: 12)
                artwork
                Spacer(minLength: 12)
                // Titles, progress and transport in one Deck card, so the
                // player reads as a single physical control panel.
                VStack(spacing: 0) {
                    titles
                    progress
                    transport
                }
                .padding(16)
                .deckCard()
                footer
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    // MARK: Chrome

    private var chrome: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(DeckIconButtonStyle())
            .accessibilityLabel("Close")

            Spacer()
            VStack(spacing: 3) {
                Text("Playing from")
                    .deckLabel()
                Text(sourceLabel)
                    .font(Deck.sans(13, .bold, relativeTo: .subheadline))
                    .textCase(.uppercase)
                    .foregroundStyle(Deck.ink)
            }
            .multilineTextAlignment(.center)
            Spacer()

            Button {
                dismiss()
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(DeckIconButtonStyle())
            .accessibilityLabel("Settings")
        }
        .padding(.top, 14)
    }

    // MARK: Artwork

    /// Square, ink-bordered, on the large hard shadow - a Deck card with a
    /// cover in it rather than a soft-shadowed photo.
    private var artwork: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - Deck.shadowLarge
            ArtworkView(ref: ref, size: max(0, side), image: player.nowPlayingImage)
                .deckCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Titles

    private var titles: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Deck.title)
                .foregroundStyle(Deck.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(artist)
                .font(Deck.mono(13, .medium, relativeTo: .subheadline))
                .foregroundStyle(Deck.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Progress

    /// Redrawn on a timer rather than on SDK callbacks: App Remote reports a
    /// position only when something changes, so a bar bound straight to it sits
    /// still for the length of the song. `PlaybackProgress` extrapolates from
    /// the last real report.
    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let value = player.progress
            let fraction = min(1, max(0, value.fraction(at: context.date)))
            VStack(spacing: 6) {
                DeckMeter(fraction: fraction, height: 12)

                HStack {
                    Text(clockString(value.estimatedMs(at: context.date)))
                    Spacer()
                    Text("-" + clockString(value.remainingMs(at: context.date)))
                }
                .font(Deck.mono(11.5, .medium, relativeTo: .caption))
                .foregroundStyle(Deck.muted)
                .monospacedDigit()
            }
        }
        .padding(.top, 16)
    }

    // MARK: Transport

    private var transport: some View {
        HStack {
            // Whatever the mode says: a fresh ranked queue, or the DJ again.
            // Reloading a queue in DJ mode would silently take the speaker off
            // Spotify from a button that says nothing of the sort.
            Button {
                Task { await player.startPlayback() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(DeckIconButtonStyle(.ghost))
            .disabled(player.isWorking)
            .accessibilityLabel(player.mode == .spotifyDJ ? "Restart the DJ" : "Reload queue")

            Spacer()

            // Shown but never enabled. The cursor only moves forward - atlas
            // has already excluded what was played - and hiding the control
            // would make the row of transport buttons jump around instead of
            // saying plainly that going back is not a thing here.
            // Drawn as Deck's disabled control - dashed edge, muted glyph, no
            // shadow - which says "not a thing here" without leaning on
            // opacity alone.
            Image(systemName: "backward.end.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Deck.muted)
                .frame(width: 50, height: 50)
                .background(Deck.rail)
                .overlay(
                    Rectangle().strokeBorder(
                        Deck.muted, style: StrokeStyle(lineWidth: Deck.borderWidth, dash: [5, 4]))
                )
                .accessibilityHidden(true)

            Spacer()

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 26, weight: .bold))
            }
            .buttonStyle(DeckIconButtonStyle(.primary, side: 64))
            .accessibilityLabel(player.isPaused ? "Play" : "Pause")

            Spacer()

            Button {
                Task { await player.skip() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 20, weight: .semibold))
            }
            .buttonStyle(DeckIconButtonStyle(side: 50))
            .accessibilityLabel("Skip")

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(DeckIconButtonStyle(.ghost))
            .accessibilityLabel("Back to queue")
        }
        .padding(.top, 16)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack(spacing: 4) {
            if let error = player.error ?? player.playbackError {
                DeckErrorText(error)
            } else if let status = player.status {
                DeckHint(status)
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
    }
}
