import SwiftUI

/// The lists the owner made, as opposed to the one atlas ranks.
///
/// The third surface, and the only one whose contents are a decision rather
/// than a consequence: the queue is atlas's opinion, the library is what the
/// Navidrome server holds, and this is what the user put somewhere on purpose.
///
/// It holds the detail screen too, in place, rather than pushing it. This app
/// has no `NavigationStack` on purpose - one would put a navigation bar above a
/// header that is already the screen's own - so opening a playlist swaps the
/// body under that header and a back button brings it back.
struct PlaylistsScreen: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var playlists: PlaylistStore

    @Binding var showSettings: Bool
    /// Driven by the "+" in the shell's header, which is where the gear already
    /// is - a second create button inside the list would be a second piece of
    /// chrome saying the same thing.
    @Binding var isCreating: Bool

    @State private var open: Playlist?
    @State private var pendingDelete: Playlist?
    @State private var nameDraft = ""

    var body: some View {
        Group {
            if let open {
                PlaylistDetailScreen(playlist: open) {
                    self.open = nil
                    playlists.closeDetail()
                }
            } else {
                content
            }
        }
        .task {
            await playlists.loadIfNeeded()
            #if DEBUG
                // `simctl` cannot tap a row, so the detail screen would otherwise
                // be unreachable in the simulator.
                if DemoMode.opensPlaylistDetail { open = playlists.playlists.first }
                // The empty one, whose whole point is the state it shows.
                if DemoMode.opensEmptyPlaylist {
                    open = playlists.playlists.first { $0.track_count == 0 }
                }
            #endif
        }
        .alert("New playlist", isPresented: $isCreating) {
            TextField("Name", text: $nameDraft)
                .textInputAutocapitalization(.words)
            Button("Create") {
                let name = nameDraft
                nameDraft = ""
                Task { _ = await playlists.create(name: name) }
            }
            Button("Cancel", role: .cancel) { nameDraft = "" }
        } message: {
            Text(
                "Playlists live on atlas, so one list can hold Spotify tracks and your own "
                    + "files together.")
        }
        // A confirmation, because there is no undo here and none on the server
        // either: the entries go with the playlist.
        .alert("Delete “\(pendingDelete?.name ?? "")”?", isPresented: deleteConfirmation) {
            Button("Delete", role: .destructive) {
                guard let doomed = pendingDelete else { return }
                pendingDelete = nil
                Task { await playlists.delete(doomed) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(
                "This cannot be undone from this app. The tracks themselves and their play "
                    + "history are not touched — only the list is.")
        }
    }

    private var deleteConfirmation: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: States
    //
    // The same four the library screen draws, for the same reason: rendered as
    // one empty list they are indistinguishable, and each needs something
    // different done about it. "Atlas rejected that token" in particular must
    // never appear as "you have no playlists yet".

    @ViewBuilder private var content: some View {
        switch playlists.state {
        case .idle,
            .loading where playlists.playlists.isEmpty:
            VStack(spacing: 12) {
                Spacer()
                ProgressView().tint(Deck.muted)
                Text("Reading your playlists…")
                    .deckLabel()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message) where playlists.playlists.isEmpty:
            ListNotice(
                label: "Could not read",
                title: "Atlas could not be read.",
                message: message,
                isError: true,
                actionTitle: "Try again"
            ) { Task { await playlists.load() } }

        default:
            if playlists.playlists.isEmpty {
                // Answered, and holding nothing. Not a failure, and never to be
                // dressed as one.
                ListNotice(
                    label: "Empty",
                    title: "No playlists yet.",
                    message: "Make one with the + above, or long-press any track in the "
                        + "queue or your library and add it to a new list.",
                    isError: false,
                    actionTitle: "New playlist"
                ) { isCreating = true }
            } else {
                list
            }
        }
    }

    // MARK: List

    /// A `List`, unlike the other two screens, and only because of the swipe:
    /// `swipeActions` exists nowhere else, and hand-rolling a swipe would be a
    /// second, worse delete gesture in an app whose other lists have none. It
    /// is styled back down to the same Deck table and the same row metrics.
    private var list: some View {
        List {
            // A refresh that failed over a list that still works - said out
            // loud, above the rows, without throwing them away.
            if case .failed(let message) = playlists.state {
                DeckErrorText(message)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            DeckTableEdgeRow()
            ForEach(playlists.playlists) { playlist in
                Button {
                    // The load belongs to the detail screen's own `.task`, not
                    // to this tap: two of them would be two GETs for one open.
                    open = playlist
                } label: {
                    PlaylistListRow(
                        playlist: playlist,
                        separator: playlist.id != playlists.playlists.first?.id)
                }
                .buttonStyle(.plain)
                .listRowBackground(Deck.surface)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = playlist
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            DeckTableEdgeRow()
        }
        .listStyle(.plain)
        // Clear of the header's 3px edge, so the table's own top rule does
        // not merge into it as one thick bar.
        .contentMargins(.top, 14, for: .scrollContent)
        // A `List` row is 44pt tall before its content is measured, which would
        // space these further apart than the identical rows on the other two
        // screens. Nothing about a swipe needs that minimum.
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Deck.ground)
        .scrollIndicators(.hidden)
        .refreshable { await playlists.load() }
    }
}

// MARK: - Row

/// One playlist, at the proportions of a track row - it sits in the same place
/// in the same app, and a list of playlists that does not line up with the list
/// of tracks reads as a different screen.
struct PlaylistListRow: View {
    let playlist: Playlist
    /// The hair above the row - off for the first one, on the table's edge.
    var separator = true

    private var count: String {
        playlist.track_count == 1 ? "1 track" : "\(playlist.track_count) tracks"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Where the artwork is on every other row. A playlist has none, and
            // leaving the space empty would break the column the whole app
            // reads down.
            Rectangle()
                .fill(Deck.rail)
                .frame(width: Theme.rowArt, height: Theme.rowArt)
                .overlay(
                    Image(systemName: "music.note.list")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Deck.muted)
                )
                .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(Theme.rowTitle)
                    .foregroundStyle(Deck.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(count)
                    .font(Theme.rowSubtitle)
                    .foregroundStyle(Deck.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Deck.muted)
        }
        .deckRow(separator: separator)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.name), \(count)")
        .accessibilityHint("Opens this playlist")
    }
}

// MARK: - Notice

/// The one line a write leaves behind, above the mini player - and, while a
/// selection is being written one row at a time, how far it has got.
///
/// Both outcomes go here and neither is silent: an add that worked says so,
/// because a context menu that simply closed is indistinguishable from one that
/// did nothing, and an add that failed says why in red rather than nothing at
/// all.
struct PlaylistNoticeBar: View {
    @EnvironmentObject private var playlists: PlaylistStore

    var body: some View {
        // A run in flight outranks the last one that finished. What is
        // happening now is the more useful of the two, and `begin` has cleared
        // the old line anyway.
        if let batch = playlists.batch {
            progress(batch)
        } else if let notice = playlists.notice {
            // A `DeckAlert`: the ok edge and ● for a write that landed, the
            // crit edge and ■ for one that did not - never colour alone.
            DeckAlert(playlists.noticeIsError ? .crit : .ok, message: notice)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture { playlists.clearNotice() }
                .transition(.opacity)
        }
    }

    /// Fifty rows is fifty round trips to a box on a tailnet. A bar that says
    /// "31 of 50" is the difference between an app that is working and an app
    /// that has hung, and the Cancel next to it is the way out of a selection
    /// that turned out to be the wrong fifty.
    private func progress(_ batch: BatchProgress) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    batch.isStopping
                        ? "Stopping — finishing the track it is on"
                        : "\(batch.verb) — \(batch.done) of \(batch.total)"
                )
                .font(Deck.small)
                .foregroundStyle(Deck.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                DeckMeter(fraction: batch.fraction, height: 10)
                    .accessibilityElement()
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(batch.done) of \(batch.total)")
            }
            // Not destructive-red: cancelling undoes nothing and destroys
            // nothing. It stops at the next row and says what had already been
            // written, which is a normal way for a long job to end.
            Button("Cancel") { playlists.cancelBatch() }
                .buttonStyle(.deck)
                .disabled(batch.isStopping)
        }
        .padding(12)
        .deckTile()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.opacity)
    }
}
