import SwiftUI

/// The shell.
///
/// One app with three surfaces: the ranked queue, which says what to play next,
/// the Navidrome library, which says what there IS, and the playlists, which
/// say what the owner chose to keep. Everything that is setup rather than
/// listening (Spotify sign-in, the atlas token, library sync) lives behind the
/// gear in `SettingsSheet`, reachable from every state.
///
/// The header, the switch between the two and the mini player live HERE rather
/// than in any of the screens. That is what makes them read as three views of
/// one app: one title in one place, one bar that does not blink when the list
/// under it changes, and one gear that is in the same corner on all of them.
///
/// Three blocking states, in the order they block: no source of music at all,
/// no atlas token, running.
///
/// The first one is NOT "not signed in to Spotify" any more. Navidrome plays
/// through this app itself, so a user whose own files are the whole point can
/// get all the way to a playing queue without the Spotify app existing - and
/// blocking them on a sign-in they do not need made the file half unreachable.
struct ContentView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var spotify: SpotifySession
    /// Read for the track count in the header - the one number that says
    /// whether the browser is worth opening - and for which genre it is a
    /// count OF.
    @EnvironmentObject private var library: LibraryStore
    /// Read for the count in the header and for the "+", which only exists on
    /// the playlists tab.
    @EnvironmentObject private var playlists: PlaylistStore

    @State private var showSettings = false
    @State private var showNowPlaying = false
    // Opens on the library, not the queue. The library is what the owner
    // actually has and can choose from; the queue is a suggestion, and a
    // suggestion is a worse first screen than a shelf.
    @State private var tab = MainTab.library
    /// Owned here, like `showSettings`, because the control that raises it is
    /// in this header and the sheet it raises belongs to `PlaylistsScreen`.
    @State private var isCreatingPlaylist = false

    var body: some View {
        ZStack {
            Deck.ground.ignoresSafeArea()
            content
        }
        // No forced colour scheme: every Deck token is a light/dark pair, so
        // the app follows the system - cream by day, soot by night. The tint
        // is the accent's TEXT twin, because system controls draw it as text.
        .tint(Deck.accentInk)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .deckSheet()
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingScreen(showSettings: $showSettings)
                .deckSheet()
        }
        .task {
            await player.onAppear()
            // Once, here, rather than from every row that offers the
            // "Add to playlist…" menu: the menu has to be able to open with
            // the list already in it.
            await player.playlists.loadIfNeeded()
            if DemoMode.opensLibrary { tab = .library }
            if DemoMode.opensQueue { tab = .queue }
            if DemoMode.opensPlaylists { tab = .playlists }
            if DemoMode.opensNowPlaying { showNowPlaying = true }
            if DemoMode.opensSettings { showSettings = true }
        }
    }

    @ViewBuilder private var content: some View {
        if !spotify.isAuthorized && !player.hasNavidrome {
            BlockedScreen(
                icon: "music.note.house",
                title: "No music source yet",
                message: "Connect Spotify, which produces the audio for streamed tracks, or "
                    + "add your Navidrome server in Settings and this app will play your "
                    + "own files itself. Either one is enough; both is the point.",
                actionTitle: "Connect Spotify",
                action: { spotify.authorize() },
                footnote: spotify.isSpotifyInstalled
                    ? nil
                    : "The Spotify app is not installed. Sign-in falls back to a web sheet, "
                        + "but playback needs the app.",
                secondaryTitle: "Settings",
                secondary: { showSettings = true })
        } else if !player.hasToken {
            BlockedScreen(
                icon: "key.horizontal",
                title: "Atlas token needed",
                // Deliberately NOT the same words as a rejected token. This one
                // means "you have not pasted it yet".
                message: "Paste the bearer token from /var/lib/audio-index/config.json on "
                    + "atlas. It is stored in the Keychain on this device only.",
                actionTitle: "Open settings",
                action: { showSettings = true },
                footnote: nil,
                secondaryTitle: nil,
                secondary: nil)
        } else {
            main
        }
    }

    // MARK: The two surfaces

    private var main: some View {
        VStack(spacing: 0) {
            header
            switch tab {
            case .queue:
                QueueScreen(showSettings: $showSettings)
            case .library:
                LibraryScreen(showSettings: $showSettings)
            case .playlists:
                PlaylistsScreen(showSettings: $showSettings, isCreating: $isCreatingPlaylist)
            }
        }
        // An inset rather than an overlay: the last row of either list has to
        // be scrollable clear of the mini player, not permanently hidden behind
        // it. It asks `playingTrack`, not the cursor, so a track started from
        // the browser gets a bar even when the queue is empty.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Above the bar, below the list: what a playlist write just did
                // has to be visible from the screen the user did it on, which
                // is usually not the playlists tab.
                PlaylistNoticeBar()
                if player.playingTrack != nil {
                    MiniPlayerBar(showNowPlaying: $showNowPlaying)
                }
            }
        }
    }

    /// The rail bar: title, the one label line, the controls, and the switch
    /// between the three surfaces - one piece of chrome, ruled off from the
    /// page by the 3px edge.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Deck.title)
                        .textCase(.uppercase)
                        .foregroundStyle(Deck.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(subtitle)
                        .deckLabel()
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if player.isWorking {
                    ProgressView().tint(Deck.muted).padding(.trailing, 4)
                }
                // Only where it means something. A "+" on the queue would have to
                // invent an answer to "plus what".
                if tab == .playlists {
                    Button {
                        isCreatingPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(DeckIconButtonStyle())
                    .accessibilityLabel("New playlist")
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(DeckIconButtonStyle())
                .accessibilityLabel("Settings")
            }
            tabPicker
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .deckBar(.top)
    }

    /// The screen title, which on the queue tab depends on who is choosing.
    ///
    /// "Your queue" over a list Spotify picked would be a lie, and a quiet one -
    /// the two modes look similar enough that the header has to be the thing
    /// that tells them apart.
    private var title: String {
        guard tab == .queue, player.mode == .spotifyDJ, player.djFailure == nil else {
            return tab.title
        }
        return "Spotify DJ"
    }

    /// Where the tracks on screen came from, said once, in the label line the
    /// queue already had. The count is the useful half on the library side:
    /// nineteen files is a different screen from four thousand.
    private var subtitle: String {
        switch tab {
        case .queue:
            // A DJ that was refused is showing the RANKED queue, so it says so.
            // Naming both halves is the point: the preference and what is
            // actually on screen have come apart, and hiding either one would
            // leave the header contradicting the list under it.
            if player.mode == .spotifyDJ {
                return player.djFailure == nil
                    ? "SPOTIFY CHOOSES · ATLAS RECORDS"
                    : "SPOTIFY DJ UNAVAILABLE · RANKED BY ATLAS"
            }
            return PlaybackMode.rankedQueue.headerLabel
        case .library:
            // What is ON SCREEN, not what exists. Under a genre chip the list
            // is a subset, and a count of the whole library over a filtered
            // list is a number the user can visibly disprove by scrolling.
            let n = library.tracks.count
            switch library.filter {
            case .all:
                return n == 0 ? "YOUR WHOLE LIBRARY" : "\(n) IN YOUR LIBRARY"
            case .genre(let name):
                return "\(n) IN \(name.uppercased())"
            case .untagged:
                return "\(n) WITH NO GENRE"
            }
        case .playlists:
            return playlists.playlists.isEmpty
                ? "SAVED ON ATLAS"
                : "\(playlists.playlists.count) SAVED ON ATLAS"
        }
    }

    /// A segmented control, not a tab bar.
    ///
    /// A tab bar would be a second piece of chrome at the bottom, under a mini
    /// player that is already there - two stacked bars over a list. This sits
    /// in the header that already exists, keeps the gear exactly where it was,
    /// and leaves one mini player instead of one per tab.
    ///
    /// `DeckSegmented`, not the system Picker: the system control's rounded
    /// pill cannot be restyled into Deck's bordered strip. The selected cell is
    /// the inverted ink fill and carries `.isSelected` for VoiceOver.
    private var tabPicker: some View {
        DeckSegmented(
            selection: $tab,
            options: MainTab.allCases.map { ($0, $0.label) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section")
    }
}

/// The three surfaces of the app.
enum MainTab: String, CaseIterable, Identifiable {
    case queue
    case library
    case playlists

    var id: String { rawValue }

    var label: String {
        switch self {
        case .queue: return "Queue"
        case .library: return "Library"
        case .playlists: return "Playlists"
        }
    }

    var title: String {
        switch self {
        case .queue: return "Your queue"
        case .library: return "Your library"
        case .playlists: return "Your playlists"
        }
    }
}

/// A full-screen "you cannot get any further until you do this" state.
///
/// Every blocking state gets the same shape so they are recognisably the same
/// KIND of thing, and so that none of them can be mistaken for a failure of
/// something that was already working.
struct BlockedScreen: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    var footnote: String?
    var secondaryTitle: String?
    var secondary: (() -> Void)?

    @EnvironmentObject private var spotify: SpotifySession

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    // An app colour block, as on the Rack OS overview.
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Deck.onFill)
                        .frame(width: 44, height: 44)
                        .background(Deck.accent)
                        .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
                        .accessibilityHidden(true)
                    Text("Setup").deckLabel()
                }
                Text(title)
                    .font(Deck.heading)
                    .textCase(.uppercase)
                    .foregroundStyle(Deck.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(Deck.body)
                    .foregroundStyle(Deck.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(actionTitle, action: action)
                        .buttonStyle(.deckPrimary)
                    if let secondaryTitle, let secondary {
                        Button(secondaryTitle, action: secondary)
                            .buttonStyle(.deckGhost)
                    }
                }
                .padding(.top, 2)

                if let footnote {
                    DeckHint(footnote)
                }
                if let error = spotify.lastError {
                    DeckErrorText(error)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckCard()
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}
