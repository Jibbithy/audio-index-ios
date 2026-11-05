import SwiftUI

@main
struct AudioIndexApp: App {
    /// `Player` owns the `SpotifySession`, so there is exactly one of each and
    /// they cannot drift apart. Both go into the environment: the view watches
    /// both objects, and SDK state changes (paused, connected) arrive without
    /// `Player` having to republish them.
    @StateObject private var player = Player()

    /// Watched so App Remote can be reconnected on the way back in - see
    /// `SpotifySession.reconnectIfNeeded`.
    @Environment(\.scenePhase) private var scenePhase

    /// The Deck faces are registered at runtime from the bundled .ttf files,
    /// before the first view asks for one - a font requested before this runs
    /// falls back to the system face without a word.
    init() {
        Deck.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Auto / Cream / Dark from Settings, stamped on the WINDOW so
                // system chrome flips with the content - see DeckTheme in
                // DeckCream.swift.
                .deckTheme()
                .environmentObject(player)
                .environmentObject(player.spotify)
                // The file player, for the same reason: it is a nested
                // ObservableObject, and a nested object's changes do not
                // propagate through the one that owns it. Without this the
                // transport button and the progress bar would freeze for the
                // whole of every local track.
                .environmentObject(player.local)
                // Artwork is its own object because it is written by async
                // loads that have nothing to do with playback; nesting it
                // inside `Player` would publish nothing to the views.
                .environmentObject(player.artwork)
                // The library browser's own store, for the same reason again:
                // it is filled by its own async load, and nested inside
                // `Player` it would publish nothing to the list watching it.
                .environmentObject(player.library)
                // And the playlists, for the third time and the same reason -
                // plus the "Add to playlist…" menu hangs off rows on every
                // screen, so the store has to be reachable from all of them.
                .environmentObject(player.playlists)
                // The OAuth callback comes back as `audioindex://callback`.
                // Without this the Spotify app reopens us and the session
                // manager never sees the code, so authorization silently
                // never completes.
                .onOpenURL { url in
                    player.spotify.handle(url: url)
                }
                // The connection is torn down while we are suspended, so it
                // has to be rebuilt on every return - not just at launch.
                // Without this the first playback call after unlocking the
                // phone triggers a full Spotify app switch that reads as
                // "connect to Spotify again".
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    player.spotify.reconnectIfNeeded()
                }
        }
    }
}
