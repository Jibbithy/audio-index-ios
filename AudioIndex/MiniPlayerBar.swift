import SwiftUI

/// The bar pinned above everything else, and the only route to the expanded
/// player.
///
/// It shows whichever player is live, not the cursor's idea of it. If the user
/// starts something else in the Spotify app the bar has to say so rather than
/// keep displaying the track we asked for - the cursor's `current` is what we
/// WANT playing, `player.nowPlayingTitle` is what IS.
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: Player
    /// Observed, not read directly. `Player` answers every question below, but
    /// a nested `ObservableObject`'s changes do not propagate through the
    /// object that owns it - so the file player has to be watched here or the
    /// bar would never redraw while a local track plays.
    @EnvironmentObject private var local: LocalPlayer
    @EnvironmentObject private var spotify: SpotifySession

    @Binding var showNowPlaying: Bool

    /// What is playing, which is not always the cursor's entry: a row tapped
    /// in the library browser plays without moving the queue.
    private var track: TrackRef? { player.playingTrack }
    private var title: String { player.nowPlayingTitle }
    private var artist: String { player.nowPlayingArtist }

    var body: some View {
        // A rail bar with its 3px edge above it, so the card reads as chrome
        // sitting on the page rather than as the last row of the list.
        card
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .deckBar(.bottom)
    }

    private var card: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ArtworkView(
                    ref: track?.source_ref ?? "", size: Theme.miniArt,
                    image: player.nowPlayingImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Deck.sans(14, .bold, relativeTo: .subheadline))
                        .foregroundStyle(Deck.ink)
                        .lineLimit(1)
                    Text(artist)
                        .font(Theme.rowSubtitle)
                        .foregroundStyle(Deck.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(DeckIconButtonStyle(.primary))
                .accessibilityLabel(player.isPaused ? "Play" : "Pause")

                Button {
                    Task { await player.skip() }
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(DeckIconButtonStyle())
                .accessibilityLabel("Skip")
            }
            progressBar
        }
        .padding(10)
        .deckCard()
        // The whole card is the tap target except the two buttons, which take
        // their own taps first.
        .contentShape(Rectangle())
        .onTapGesture { showNowPlaying = true }
        .accessibilityAddTraits(.isButton)
    }

    /// Orientation, not a control - seeking lives on the expanded player. A
    /// thin bordered meter rather than a bare hairline, so it still reads as a
    /// Deck bar at a glance.
    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            DeckMeter(fraction: player.progress.fraction(at: context.date), height: 8)
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
