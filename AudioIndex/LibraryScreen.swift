import SwiftUI

// MARK: - Pure helpers
//
// The one part of browsing that can actually be wrong is which rows a query
// keeps, so it is a plain function over plain values and is tested without a
// server, a screen or a keystroke.

/// The rows a query matches, over the library ALREADY in memory.
///
/// Local, not a request per keystroke: the genre CHIP is the server's question
/// - it is about the whole library, including tracks this screen has not been
/// handed - and the search box is a question about what is on screen. A round
/// trip per character would be slower, would fail every time the tailnet
/// blinked, and would make typing the one thing that can break browsing.
///
/// Case- AND diacritic-insensitive, against the title or the artist. Both
/// halves matter: local files are named by hand, so "harbor" has to find
/// `01 - Lumenfall - Harbor.mp3` and "vetur ljos" has to find "Vetur Ljós".
///
/// An empty query is not a filter. It returns everything, including the tracks
/// whose title and artist are both empty strings.
func librarySearch(_ tracks: [TrackRef], matching query: String) -> [TrackRef] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return tracks }
    return tracks.filter {
        loosely($0.title, contains: needle) || loosely($0.artist, contains: needle)
    }
}

/// Substring match ignoring case and accents.
///
/// `.diacriticInsensitive` is doing real work here rather than being defensive:
/// half the titles in that library were typed by whoever named the file, and
/// nobody reaches for the accented keys when they are looking for something.
private func loosely(_ haystack: String, contains needle: String) -> Bool {
    haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

// MARK: - Store

/// The library as atlas knows it, the genres it can be narrowed by, and which
/// of four states the screen is in.
///
/// ATLAS, not Navidrome, and that is the load-bearing change. Navidrome knows
/// only the files on that one server; atlas knows every track from every
/// source, which is why one shelf can hold a Spotify track and a local file
/// together, why a genre learned from Spotify survives a local copy arriving,
/// and why this screen has anything on it at all while there are no local
/// files.
///
/// Separate from `Player` for the same reason it always was: a failure to READ
/// the library is not a failure of the queue, and belongs next to the list that
/// could not be filled rather than in the banner under the ranked one.
@MainActor
final class LibraryStore: ObservableObject {

    /// One value rather than three booleans, because the states are mutually
    /// exclusive and every interesting bug is a combination of them: an empty
    /// list while loading reads as "no music", and an empty list after a
    /// failure reads as "your library is empty" when the truth is that nobody
    /// could reach it.
    enum State: Equatable {
        /// No atlas token yet. Not a failure - the user has not got there yet,
        /// and the only useful thing to say points at Settings.
        case notConfigured
        case loading
        /// Atlas answered. The list may still be empty, and an empty library IS
        /// this state, not an error.
        case loaded
        case failed(String)
    }

    /// The tracks currently on screen: the whole library, or one genre of it.
    @Published private(set) var tracks: [TrackRef] = []
    /// Every genre with its count, and how many tracks have none. Loaded
    /// alongside the list, and NOT reloaded when a chip is tapped - the counts
    /// describe the whole library, so recomputing them per filter would make
    /// the row's numbers change meaning as it was used.
    @Published private(set) var summary: GenreSummary = .empty
    @Published private(set) var filter: GenreFilter = .all
    @Published private(set) var state: State = .notConfigured

    /// Where atlas is and the token to reach it, read at the moment of use and
    /// never held - same rule as `PlaylistStore.connection`, and it matters for
    /// the same reason. Nil in demo mode, which must never touch the Keychain.
    var connection: () -> (baseURL: URL, token: String?)? = { nil }

    /// The WHOLE library, filter or no filter.
    ///
    /// Its own list rather than a reader of `tracks`, because the two answer
    /// different questions: `tracks` is what the Library tab is showing, which
    /// a genre chip narrows, and this is everything there is to pick from when
    /// adding songs to a playlist. Sharing one would mean that opening a
    /// playlist and adding songs silently offered only the genre the other tab
    /// happened to be filtered to.
    @Published private(set) var everything: [TrackRef] = []

    /// Fill `everything` once. Cheap to keep - a few thousand rows of two
    /// strings - and it means the picker opens with the list already in it
    /// rather than spinning on every "Add songs".
    func loadEverything() async {
        guard everything.isEmpty else { return }
        #if DEBUG
            if DemoMode.isActive {
                everything = DemoMode.libraryTracks(for: .all)
                return
            }
        #endif
        guard let conn = connection() else { return }
        // Deliberately silent on failure: this feeds a picker that says its own
        // empty state, and a library-wide error banner does not belong on the
        // playlist screen that opened it.
        everything = (try? await Self.fetchTracks(conn, filter: .all)) ?? []
    }

    /// Fill the list the first time the screen is looked at, and after a
    /// failure, but not on every return to the tab: a library that loaded is
    /// good until the user pulls to refresh it.
    func loadIfNeeded() async {
        switch state {
        case .loading, .loaded: return
        case .notConfigured, .failed: await load()
        }
    }

    /// Reload the list AND the counts, keeping whichever chip is selected.
    func load() async {
        #if DEBUG
            if DemoMode.isActive {
                summary = DemoMode.genreSummary
                tracks = DemoMode.libraryTracks(for: filter)
                state = .loaded
                return
            }
        #endif
        guard let conn = connection() else {
            tracks = []
            state = .notConfigured
            return
        }
        state = .loading
        let wanted = filter
        do {
            let (list, counts) = try await Self.fetchAll(conn, filter: wanted)
            // A chip tapped while this was in flight wins. The reply describes
            // a filter the user has already moved off, and letting it land
            // would put the previous genre's tracks under the new chip's name.
            guard wanted == filter else { return }
            tracks = list
            summary = counts
            state = .loaded
        } catch {
            // The tracks from the last good load are KEPT. A refresh that fails
            // on a dropped tailnet should say so above a list that still works,
            // not replace a browsable library with an error page.
            state = .failed(Player.describe(error))
        }
    }

    /// Narrow to one genre, or back to everything.
    ///
    /// Only the LIST is refetched. The counts are about the whole library and
    /// do not change with the filter, so re-reading them here would spend a
    /// round trip to produce the identical row.
    func choose(_ next: GenreFilter) async {
        guard next != filter else { return }
        filter = next
        #if DEBUG
            if DemoMode.isActive {
                tracks = DemoMode.libraryTracks(for: next)
                state = .loaded
                return
            }
        #endif
        guard let conn = connection() else { return }
        state = .loading
        do {
            let list = try await Self.fetchTracks(conn, filter: next)
            guard next == filter else { return }
            tracks = list
            state = .loaded
        } catch {
            state = .failed(Player.describe(error))
        }
    }

    // MARK: Talking to atlas
    //
    // Nonisolated, each building its own `IndexClient` from plain values, for
    // the reason spelled out on `Player` and `PlaylistStore`: `IndexClient` is
    // not Sendable, so one built on the main actor cannot legally be handed to
    // its own nonisolated `async` methods.

    private typealias Conn = (baseURL: URL, token: String?)

    private nonisolated static func client(_ conn: Conn) -> IndexClient {
        IndexClient(baseURL: conn.baseURL, token: { conn.token })
    }

    private nonisolated static func fetchTracks(
        _ conn: Conn,
        filter: GenreFilter
    ) async throws -> [TrackRef] {
        try await client(conn).library(filter)
    }

    #if DEBUG
        /// A library with no server behind it, for `-AudioIndexDemo`.
        func installDemoLibrary() {
            summary = DemoMode.genreSummary
            tracks = DemoMode.libraryTracks(for: .all)
            state = .loaded
        }
    #endif

    /// Both halves, in parallel: they are independent reads and the screen
    /// needs both before it can draw itself.
    private nonisolated static func fetchAll(
        _ conn: Conn, filter: GenreFilter
    ) async throws -> ([TrackRef], GenreSummary) {
        async let list = client(conn).library(filter)
        async let counts = client(conn).genres()
        return (try await list, try await counts)
    }
}

// MARK: - Screen

/// Everything the owner has, as a list they can see instead of only hear.
///
/// The queue is still the point of this app - this is the other half of it: the
/// ranked queue says what to play next, and this says what there IS. A row
/// tapped here plays immediately and scrobbles as a deliberate choice rather
/// than as a served one.
///
/// Two filters, deliberately different in kind. The genre chip is a question
/// about the WHOLE library and is answered by atlas; the search box is a
/// question about what came back and is answered here. That is why typing is
/// instant and tapping a chip is a load.
struct LibraryScreen: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    /// Watched so the marked row follows the file player - see the note in
    /// `MiniPlayerBar`.
    @EnvironmentObject private var local: LocalPlayer
    /// Read for the "which playlist?" sheet, which has to open with the list
    /// already in it - and written to by "Add to playlist…".
    @EnvironmentObject private var playlists: PlaylistStore

    @Binding var showSettings: Bool

    @State private var query = ""

    /// Whether a tap picks a row or plays it. One flag rather than two modes
    /// with their own row bodies: the list is the same list, and leaving this
    /// puts tap-to-play back exactly as it was.
    @State private var isSelecting = false
    /// The picked rows, by track_id - atlas's identity for the recording, which
    /// is the one thing that survives a refresh, a genre change and a track
    /// gaining a second source.
    @State private var picked: Set<String> = []
    @State private var isChoosing = false
    /// The "More…" sheet: every genre, not just the twelve with chips.
    @State private var isBrowsingGenres = false

    private var results: [TrackRef] { librarySearch(library.tracks, matching: query) }

    /// What "Add to playlist…" would send, over everything CURRENTLY LOADED
    /// rather than the searched rows: a selection made under one query and
    /// added under another is still a selection, and dropping half of it
    /// because the search box changed would be the quietest possible bug.
    ///
    /// It cannot reach across a genre change, and that is honest - the tracks
    /// under the old chip are not on this screen any more.
    private var pickedTracks: [TrackRef] {
        library.tracks.filter { picked.contains($0.track_id) }
    }

    /// Every row is playable: atlas only lists tracks that have a source. So
    /// unlike the Navidrome-backed list this replaces, there is no row that
    /// cannot be put in a playlist, and "Select all" means what it says.
    private var pickableIDs: [String] { results.map(\.track_id) }

    /// What is playing, if this screen started it.
    private var playingID: String? { player.playingTrack?.track_id }

    var body: some View {
        VStack(spacing: 0) {
            if !library.tracks.isEmpty || library.filter != .all {
                genreChipRow
                searchField
                selectionBar
                if isSelecting { actions }
            }
            content
        }
        // Covers for whatever is on screen now, in one batched call. Also fires
        // after a chip changes the list, which is the case a `.task` alone
        // misses - the screen is not reappearing, only its contents are.
        .onChange(of: library.tracks) { _, tracks in
            player.loadArtwork(for: tracks.map(\.source_ref))
        }
        .task {
            await library.loadIfNeeded()
            player.loadArtwork(for: library.tracks.map(\.source_ref))
            #if DEBUG
                // `simctl` cannot tap a row and this Xcode has no `simctl io tap`,
                // so selection mode is otherwise impossible to look at.
                if DemoMode.opensSelection {
                    isSelecting = true
                    picked = DemoMode.selectedTrackIDs
                }
            #endif
        }
        .sheet(isPresented: $isBrowsingGenres) {
            GenrePicker(summary: library.summary, selected: library.filter) { chosen in
                isBrowsingGenres = false
                choose(chosen)
            }
            .deckSheet()
        }
        .playlistChooser(
            isPresented: $isChoosing,
            title: chooserTitle,
            onChoose: { playlist in
                let tracks = pickedTracks
                leaveSelection()
                Task { await playlists.addMany(tracks, to: playlist) }
            },
            onCreate: { name in
                let tracks = pickedTracks
                leaveSelection()
                Task { await playlists.createAndAddMany(name: name, tracks: tracks) }
            })
    }

    // MARK: Genres

    /// The chip row: "All", the twelve genres holding the most tracks, the
    /// tracks holding none, and a way to the rest.
    ///
    /// Horizontal rather than wrapped, so the row is one line tall whatever the
    /// library holds - a filter that pushes the list down the screen as it
    /// grows is a filter that costs more than it saves.
    private var genreChipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(genreChips(library.summary)) { chip in
                    GenreChipView(chip: chip, isSelected: chip.filter == library.filter) {
                        choose(chip.filter)
                    }
                }
                if library.summary.genres.count > genreChipLimit {
                    GenreChipView(
                        chip: GenreChip(filter: .all, label: "More…", count: nil),
                        isSelected: false,
                        isOverflow: true
                    ) { isBrowsingGenres = true }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// Changing the filter clears the selection.
    ///
    /// The picked rows are about to leave the screen, and a selection the user
    /// cannot see is one they cannot correct - "Add 9 tracks" over a list
    /// showing none of them is the kind of thing that gets found out in a
    /// playlist a week later.
    private func choose(_ filter: GenreFilter) {
        leaveSelection()
        query = ""
        Task { await library.choose(filter) }
    }

    // MARK: Selecting

    private var selectionBar: some View {
        SelectionBar(
            isSelecting: isSelecting,
            pickedCount: picked.count,
            visibleCount: pickableIDs.count,
            allVisiblePicked: everythingVisibleIsSelected(pickableIDs, in: picked),
            onStart: { isSelecting = true },
            onDone: leaveSelection,
            onSelectAll: { picked = selectingAll(pickableIDs, keeping: picked) },
            onDeselectAll: { picked = deselectingAll(pickableIDs, from: picked) },
            onPlay: { start(shuffled: false) },
            onShuffle: { start(shuffled: true) })
    }

    /// Play what is ON SCREEN - the chip and the search box together, in the
    /// order they are listed.
    ///
    /// It replaces the ranked queue, exactly as a playlist's Play does: this is
    /// the owner saying "this, now", and when it runs out the ranked queue
    /// comes back on its own.
    private func start(shuffled: Bool) {
        let tracks = results
        guard !tracks.isEmpty else { return }
        Task { await player.playLibrary(tracks, shuffled: shuffled) }
    }

    private var actions: some View {
        SelectionAction(
            title: "Add to playlist…", icon: "text.badge.plus",
            isEnabled: !picked.isEmpty
        ) { isChoosing = true }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var chooserTitle: String {
        picked.count == 1 ? "Add 1 track to…" : "Add \(picked.count) tracks to…"
    }

    private func leaveSelection() {
        isSelecting = false
        picked = []
    }

    private func toggle(_ track: TrackRef) {
        if picked.contains(track.track_id) { picked.remove(track.track_id) } else { picked.insert(track.track_id) }
    }

    /// What a row's checkmark column says, or nil when there is no such column.
    private func mark(for track: TrackRef) -> RowSelection? {
        guard isSelecting else { return nil }
        return picked.contains(track.track_id) ? .picked : .unpicked
    }

    // MARK: Search

    /// Hand-rolled rather than `.searchable`, which needs a `NavigationStack`
    /// this app does not have and would not otherwise want - it would put a
    /// navigation bar above a screen whose whole header is already its own.
    private var searchField: some View {
        DeckSearchField(title: "Search titles and artists", query: $query)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    // MARK: States
    //
    // Four outcomes that look identical if they are all rendered as an empty
    // list, and each of which needs something different done about it.

    @ViewBuilder private var content: some View {
        switch library.state {
        case .notConfigured:
            ListNotice(
                label: "Setup",
                title: "Atlas token needed.",
                message: "Paste the bearer token from atlas in Settings and your "
                    + "whole library appears here - Spotify tracks and your own "
                    + "files in one list.",
                isError: false,
                actionTitle: "Open settings"
            ) { showSettings = true }

        case .loading where library.tracks.isEmpty:
            // A spinner, NOT an empty list. An empty list is an answer, and
            // this is the state where there is no answer yet.
            VStack(spacing: 12) {
                Spacer()
                ProgressView().tint(Deck.muted)
                Text("Reading your library…")
                    .deckLabel()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message) where library.tracks.isEmpty:
            ListNotice(
                label: "Could not read",
                title: "Your library could not be read.",
                message: message,
                isError: true,
                actionTitle: "Try again"
            ) { Task { await library.load() } }

        default:
            if library.tracks.isEmpty {
                emptyList
            } else {
                list
            }
        }
    }

    /// Reachable, answered, and holding nothing. This is not a failure and must
    /// never be dressed as one - but "nothing in this genre" and "nothing at
    /// all" send the user to two different places.
    @ViewBuilder private var emptyList: some View {
        if library.filter == .all {
            ListNotice(
                label: "Empty",
                title: "Nothing in your library yet.",
                message: "Atlas answered and knows no tracks. Sync your Spotify "
                    + "library, or add a Navidrome server, from Settings.",
                isError: false,
                actionTitle: "Open settings"
            ) { showSettings = true }
        } else {
            ListNotice(
                label: "Filtered",
                title: "Nothing under that genre.",
                message: "The count came from an earlier read of the library. Show "
                    + "everything, or pull down to refresh the counts.",
                isError: false,
                actionTitle: "Show everything"
            ) { choose(.all) }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // A refresh that failed over a list that still works. The list
                // is not thrown away for it, and the message is not silent.
                if case .failed(let message) = library.state {
                    DeckErrorText(message)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                if results.isEmpty {
                    // A search that matched nothing is not an empty library,
                    // and saying "nothing in your library" here would send the
                    // user looking for tracks that are sitting right behind the
                    // search box.
                    Text("Nothing matches “\(query)”.")
                        .font(Deck.body)
                        .foregroundStyle(Deck.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    DeckRule()
                    ForEach(results) { track in
                        Button {
                            // While picking, a tap picks. Leaving the mode puts
                            // tap-to-play back - the row is the same row, and
                            // nothing about it was rebuilt to say so.
                            if isSelecting {
                                toggle(track)
                            } else {
                                Task { await player.playNow(track: track) }
                            }
                        } label: {
                            LibraryRow(
                                track: track, isCurrent: track.track_id == playingID,
                                selection: mark(for: track),
                                separator: track.track_id != results.first?.track_id)
                        }
                        .buttonStyle(.plain)
                        // The single-track menu is off while picking: a long
                        // press that acted on one row in the middle of choosing
                        // nine would be a second, quieter answer to the same
                        // question.
                        .addToPlaylistMenu(for: isSelecting ? nil : track)
                    }
                    DeckRule()
                }
                Color.clear.frame(height: 12)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await library.load() }
    }
}

/// How many genres get a chip of their own. The rest live behind "More…".
let genreChipLimit = 12

// MARK: - Chips

/// One genre chip: a `DeckChip`, and the selected one is the inverted ink
/// chip - the same "this one is on" the segmented control and the nav use.
/// Deliberately not the accent: that belongs to what is PLAYING.
///
/// The chip is drawn small but the button around it is 44pt tall, so the tap
/// target is the full height of the row rather than the height of the text.
struct GenreChipView: View {
    let chip: GenreChip
    let isSelected: Bool
    var isOverflow = false
    let action: () -> Void

    private var text: String {
        guard let count = chip.count else { return chip.label }
        return "\(chip.label) \(count)"
    }

    var body: some View {
        Button(action: action) {
            DeckChip(text, kind: isSelected ? .ink : .plain)
                .lineLimit(1)
                .padding(.trailing, Deck.shadowSmall)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// VoiceOver has no capsule to look at, so the count and the state are
    /// said instead of shown.
    private var accessibilityLabel: String {
        if isOverflow { return "More genres" }
        guard let count = chip.count else { return chip.label }
        return "\(chip.label), \(count) track\(count == 1 ? "" : "s")"
    }
}

/// Every genre, searchable, behind "More…".
///
/// The whole list rather than the leftovers: someone who opens this is looking
/// for a name, and a list that starts at the thirteenth is one they have to
/// know the top twelve of first.
struct GenrePicker: View {
    let summary: GenreSummary
    let selected: GenreFilter
    let onChoose: (GenreFilter) -> Void

    @State private var query = ""

    private var results: [GenreCount] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return summary.genres }
        return summary.genres.filter {
            $0.genre.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Genres")
                    .font(Deck.title)
                    .textCase(.uppercase)
                    .foregroundStyle(Deck.ink)
                Text("\(summary.genres.count) IN YOUR LIBRARY")
                    .deckLabel()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .deckBar(.top)

            DeckSearchField(title: "Search genres", query: $query, submitsSearch: false)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DeckRule()
                    row(label: "All", count: nil, filter: .all, separator: false)
                    if summary.untagged > 0 {
                        row(label: "No genre", count: summary.untagged, filter: .untagged)
                    }
                    ForEach(results) { genre in
                        row(
                            label: genre.genre, count: genre.track_count,
                            filter: .genre(genre.genre))
                    }
                    DeckRule()
                    if results.isEmpty && !query.isEmpty {
                        Text("No genre matches “\(query)”.")
                            .font(Deck.body)
                            .foregroundStyle(Deck.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 30)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Deck.ground)
    }

    private func row(
        label: String, count: Int?, filter: GenreFilter,
        separator: Bool = true
    ) -> some View {
        Button {
            onChoose(filter)
        } label: {
            HStack(spacing: 12) {
                Text(label)
                    .font(Deck.sans(15, filter == selected ? .bold : .medium))
                    .foregroundStyle(Deck.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let count {
                    Text("\(count)")
                        .font(Theme.rowSubtitle)
                        .foregroundStyle(Deck.muted)
                }
                if filter == selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Deck.ink)
                }
            }
            .deckRow(selected: filter == selected, separator: separator)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == selected ? .isSelected : [])
    }
}

// MARK: - Row

/// One track, at the same proportions and type as a queue row - because it is
/// the same kind of thing, and two lists of tracks in one app that do not line
/// up read as two apps.
///
/// The artwork is asked for by `source_ref`, exactly as the queue asks: for a
/// Spotify track that is the URI the Web API is keyed on, and for a file it is
/// the Navidrome id, which `getCoverArt` resolves to the album's art itself.
struct LibraryRow: View {
    let track: TrackRef
    let isCurrent: Bool
    /// Nil unless the screen is picking rows, and then the column is the same
    /// width on every row - so the artwork, the two lines and the marked-row
    /// treatment stay exactly where they are and only the whole list shifts.
    var selection: RowSelection?
    /// The hair above the row. Off for the first row, which sits on the
    /// table's own ruled edge.
    var separator = true

    /// VoiceOver has no checkmark to look at, so the state is said instead.
    private var selectionLabel: String {
        switch selection {
        case .none: return ""
        case .picked: return ", selected"
        case .unpicked: return ", not selected"
        case .unavailable: return ", cannot be added to a playlist"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if let selection { SelectionMark(state: selection) }
            ArtworkView(ref: track.source_ref, size: Theme.rowArt)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(Theme.rowTitle)
                    .foregroundStyle(isCurrent ? Deck.accentInk : Deck.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .accessibilityLabel(
            "\(track.title), \(track.artist)\(isCurrent ? ", now playing" : "")"
                + selectionLabel
        )
        .accessibilityHint(selection == nil ? "Plays this track now" : "")
        .accessibilityAddTraits(selection == .picked ? .isSelected : [])
    }
}

// MARK: - Notice

/// A full-height "here is why this list is not a list" state.
///
/// Shaped like the queue's own empty state so the two read as the same KIND of
/// thing, and marked as a failure ONLY when something actually failed - the
/// difference between "your server is unreachable" and "your server is empty"
/// is the whole reason these are four states instead of one.
///
/// Two different Deck shapes for those two cases, not one box in two colours:
/// the dashed `DeckEmpty` means "nothing here yet", and a failure is a
/// `DeckAlert` with the crit edge and the ■ - distinguishable in greyscale.
///
/// Shared with the playlist screens rather than copied for them: three lists
/// that state their empty and failed cases in three different shapes read as
/// three different apps, and it is the same distinction being drawn each time.
struct ListNotice: View {
    /// The mono label over an empty state - what KIND of nothing this is.
    let label: String
    let title: String
    let message: String
    let isError: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            if isError {
                DeckAlert(.crit, title: title, message: message) {
                    Button(actionTitle, action: action)
                        .buttonStyle(.deckPrimary)
                        .padding(.top, 6)
                }
            } else {
                DeckEmpty(label: label, title: title, message: message) {
                    Button(actionTitle, action: action)
                        .buttonStyle(.deckPrimary)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The search box over a list: a `DeckFieldStyle` field, the prompt in the
/// muted token (the system placeholder grey is not one), and a clear button
/// beside it rather than inside it, so it is a full 44pt target.
///
/// Hand-rolled rather than `.searchable`, which needs a `NavigationStack`
/// this app does not have and would not otherwise want.
struct DeckSearchField: View {
    let title: String
    @Binding var query: String
    var submitsSearch = true

    var body: some View {
        HStack(spacing: 8) {
            TextField(
                title, text: $query,
                prompt: Text("\(Image(systemName: "magnifyingglass"))  \(title)")
                    .foregroundStyle(Deck.muted)
            )
            .textFieldStyle(DeckFieldStyle())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitsSearch ? .search : .return)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(DeckIconButtonStyle())
                .accessibilityLabel("Clear search")
            }
        }
    }
}
