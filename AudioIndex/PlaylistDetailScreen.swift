import SwiftUI

/// One playlist, in its own order.
///
/// The rows are the queue's and the library's rows again - same artwork size,
/// same two lines, same marked-row treatment - because they are the same kind
/// of thing. The two differences are both the point of the feature: a row can
/// be a Spotify track sitting directly above a file on the Navidrome server,
/// and a row can have nothing at all to play it from.
struct PlaylistDetailScreen: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var playlists: PlaylistStore
    /// Watched so the marked row follows the file player - see the note in
    /// `MiniPlayerBar`.
    @EnvironmentObject private var local: LocalPlayer

    /// The row that was tapped. Used for the name and the id until the detail
    /// arrives, so the header is never blank while it loads.
    let playlist: Playlist
    let onBack: () -> Void

    @State private var isRenaming = false
    @State private var nameDraft = ""

    /// Whether a tap picks a row or plays the list from it.
    @State private var isSelecting = false
    /// The picked rows, by ENTRY id. Never by track: this is the one list in
    /// the app that can hold the same track twice, and those are two rows the
    /// owner can see and pick apart.
    @State private var picked: Set<String> = []
    @State private var isChoosing = false
    @State private var isConfirmingRemove = false
    /// The "Add songs" picker. Owned here, not by the empty state, because the
    /// same sheet is raised from the header of a playlist that is FULL - the
    /// gesture is "add to this playlist", not "fix this empty screen".
    @State private var isAddingSongs = false
    /// Which genre of THIS playlist is on screen. Reset when the playlist is
    /// left, not remembered: a chip is a way of looking at a list, not a
    /// property of it, and coming back to a playlist showing a third of itself
    /// with no memory of why is the kind of thing that reads as data loss.
    @State private var filter: GenreFilter = .all

    private var detail: PlaylistDetail? {
        // The store holds ONE open playlist. Guarding on the id keeps a
        // previous playlist's tracks off this screen for the moment between
        // opening and the load landing.
        playlists.detail?.id == playlist.id ? playlists.detail : nil
    }

    private var name: String { detail?.name ?? playlist.name }

    /// The entries the chip keeps - what the list, the Play button, "Select
    /// all" and a tapped row all mean by "this playlist" while a genre is
    /// showing.
    private var shown: [PlaylistEntry] {
        entries(detail?.tracks ?? [], matching: filter)
    }

    /// The chip row's numbers, over the WHOLE playlist rather than what is on
    /// screen - a count that changed as you filtered would be answering a
    /// different question with every tap.
    private var summary: GenreSummary { genreSummary(of: detail?.tracks ?? []) }

    /// What the Play button would actually start. Empty is a real state - a
    /// playlist can hold nothing, and can hold only tracks atlas has no source
    /// for - and the button says so rather than being missing.
    private var playable: [TrackRef] { playableTracks(of: shown) }

    /// The rows on screen, which here is all of them - this list has no search
    /// box, so "Select all" and "everything" are the same set.
    private var visibleIDs: [String] { shown.map(\.entry_id) }

    /// What a move would attempt, in the playlist's own order.
    private var plan: [MoveStep] {
        plannedMove(of: detail?.tracks ?? [], selected: picked)
    }

    /// Narrow the list, and drop the selection with it.
    ///
    /// The picked rows are about to leave the screen, and a selection the user
    /// cannot see is one they cannot correct - "Move 9 tracks" over a list
    /// showing none of them is found out in another playlist a week later.
    private func choose(_ next: GenreFilter) {
        guard next != filter else { return }
        leaveSelection()
        filter = next
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Only where it can do something. A playlist whose tracks carry no
            // genres at all would get a row holding nothing but "All".
            if !summary.genres.isEmpty { genreChipRow }
            if canSelect {
                selectionBar
                if isSelecting { actions }
            }
            content
        }
        // `openDetail`, not `reloadDetail`: it clears whatever playlist was
        // open first, so the previous one's rows cannot show for a frame under
        // this one's name.
        .task {
            await playlists.openDetail(playlist)
            #if DEBUG
                // `simctl` cannot tap a row, so this mode is otherwise unreachable
                // from a script - see `DemoMode.opensSelection`.
                if DemoMode.opensSelection, let loaded = playlists.detail {
                    isSelecting = true
                    picked = DemoMode.selectedEntryIDs(of: loaded.tracks)
                }
                if DemoMode.opensAddSongs { isAddingSongs = true }
            #endif
        }
        .alert("Rename playlist", isPresented: $isRenaming) {
            TextField("Name", text: $nameDraft)
                .textInputAutocapitalization(.words)
            Button("Rename") {
                let wanted = nameDraft
                Task { await playlists.rename(id: playlist.id, to: wanted) }
            }
            Button("Cancel", role: .cancel) {}
        }
        // Asked, unlike the single-row swipe. That one is undone by two taps;
        // nine rows put back by hand is an evening, and the count is the whole
        // reason this gesture is worth confirming when that one is not.
        .alert(removeTitle, isPresented: $isConfirmingRemove) {
            Button("Remove", role: .destructive) {
                guard let detail else { return }
                let doomed = visibleIDs.filter(picked.contains)
                leaveSelection()
                Task { await playlists.removeMany(doomed, from: detail) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The tracks themselves and their play history are not touched — only this "
                    + "list is.")
        }
        .sheet(isPresented: $isAddingSongs) {
            AddSongsSheet(
                playlist: playlist,
                existing: trackIDs(in: detail?.tracks ?? []),
                onAdd: { tracks in
                    isAddingSongs = false
                    Task { await playlists.addMany(tracks, to: playlist) }
                },
                onCancel: { isAddingSongs = false }
            )
            .deckSheet()
        }
        .playlistChooser(
            isPresented: $isChoosing,
            title: chooserTitle,
            excluding: playlist.id,
            onChoose: { target in
                guard let detail else { return }
                let steps = plan
                leaveSelection()
                Task { await playlists.moveMany(steps, from: detail, to: target) }
            },
            onCreate: { name in
                guard let detail else { return }
                let steps = plan
                leaveSelection()
                Task {
                    await playlists.createAndMoveMany(
                        name: name, steps: steps,
                        from: detail)
                }
            })
    }

    // MARK: Genres

    /// The same chips as the library, over this playlist's own tracks.
    ///
    /// Shaped exactly like the library's row on purpose: it is the same control
    /// answering the same question, and giving it a second appearance here
    /// would make two screens of one app read as two apps.
    private var genreChipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(genreChips(summary)) { chip in
                    GenreChipView(chip: chip, isSelected: chip.filter == filter) {
                        choose(chip.filter)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 2)
    }

    // MARK: Selecting

    /// Nothing to pick in a playlist that has not loaded or holds nothing, and
    /// a "Select" over an empty list is a control with no answer.
    private var canSelect: Bool { !(detail?.tracks.isEmpty ?? true) }

    private var selectionBar: some View {
        SelectionBar(
            isSelecting: isSelecting,
            pickedCount: picked.count,
            visibleCount: visibleIDs.count,
            allVisiblePicked: everythingVisibleIsSelected(visibleIDs, in: picked),
            onStart: { isSelecting = true },
            onDone: leaveSelection,
            onSelectAll: { picked = selectingAll(visibleIDs, keeping: picked) },
            onDeselectAll: { picked = deselectingAll(visibleIDs, from: picked) })
    }

    private var actions: some View {
        HStack(spacing: 10) {
            SelectionAction(
                title: "Move to…", icon: "arrow.right.circle",
                isEnabled: !picked.isEmpty
            ) { isChoosing = true }
            SelectionAction(
                title: "Remove", icon: "minus.circle",
                isEnabled: !picked.isEmpty, isDestructive: true
            ) {
                isConfirmingRemove = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var chooserTitle: String {
        picked.count == 1 ? "Move 1 track to…" : "Move \(picked.count) tracks to…"
    }

    private var removeTitle: String {
        picked.count == 1
            ? "Remove 1 track from “\(name)”?"
            : "Remove \(picked.count) tracks from “\(name)”?"
    }

    private func leaveSelection() {
        isSelecting = false
        picked = []
    }

    private func toggle(_ entry: PlaylistEntry) {
        if picked.contains(entry.entry_id) {
            picked.remove(entry.entry_id)
        } else {
            picked.insert(entry.entry_id)
        }
    }

    /// What a row's checkmark column says, or nil when there is no such column.
    ///
    /// A dead row IS pickable here, unlike in the library: it cannot be moved -
    /// there is no source to send - but removing it is the only way it ever
    /// leaves the playlist, and it is exactly the row someone would want to
    /// clear out in a batch.
    private func mark(for entry: PlaylistEntry) -> RowSelection? {
        guard isSelecting else { return nil }
        return picked.contains(entry.entry_id) ? .picked : .unpicked
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                        Text("Playlists")
                    }
                }
                .buttonStyle(.deckGhost)
                .accessibilityLabel("Back to playlists")
                Spacer()
                // Adding songs lives HERE, on the playlist being added to,
                // rather than only on a long-press three screens away.
                Button {
                    isAddingSongs = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(DeckIconButtonStyle())
                .accessibilityLabel("Add songs to this playlist")
                Button {
                    nameDraft = name
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(DeckIconButtonStyle())
                .accessibilityLabel("Rename playlist")
            }
            .padding(.leading, -15)

            Text(name)
                .font(Deck.title)
                .textCase(.uppercase)
                .foregroundStyle(Deck.ink)
                .lineLimit(2)

            HStack(spacing: 12) {
                Button {
                    guard let detail else { return }
                    Task { await player.playPlaylist(detail, entries: shown) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                        Text("Play")
                    }
                }
                .buttonStyle(.deckPrimary)
                .disabled(playable.isEmpty)

                Text(countLabel)
                    .deckLabel()
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    /// Says both numbers when they differ. "12 TRACKS" over a list where two of
    /// them are dead rows is a lie the user has to count to catch.
    private var countLabel: String {
        guard let detail else { return "" }
        let total = detail.tracks.count
        let live = playable.count
        if total == 0 { return "EMPTY" }
        let tracks = total == 1 ? "1 TRACK" : "\(total) TRACKS"
        return live == total ? tracks : "\(tracks), \(total - live) UNPLAYABLE"
    }

    // MARK: States

    @ViewBuilder private var content: some View {
        switch playlists.detailState {
        case .idle,
            .loading where detail == nil:
            VStack(spacing: 12) {
                Spacer()
                ProgressView().tint(Deck.muted)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message) where detail == nil:
            ListNotice(
                label: "Could not read",
                title: "This playlist could not be read.",
                message: message,
                isError: true,
                actionTitle: "Try again"
            ) {
                Task { await playlists.reloadDetail(id: playlist.id, name: playlist.name) }
            }

        default:
            if let detail, detail.tracks.isEmpty {
                // Empty is an ANSWER, not a failure - and the answer to it is
                // a button that FILLS it. Sending the owner to another screen
                // to long-press a row was telling them where the feature lived
                // instead of putting it where they were standing.
                ListNotice(
                    label: "Empty",
                    title: "No songs yet.",
                    message: "Add songs to “\(name)” — your whole library, Spotify "
                        + "tracks and your own files, in one searchable list.",
                    isError: false,
                    actionTitle: "Add songs"
                ) { isAddingSongs = true }
            } else if let detail, shown.isEmpty {
                // Reachable only from a stale chip - the counts come from the
                // same load as the rows - but a blank screen under a chip the
                // user just tapped needs a way back rather than a scroll.
                ListNotice(
                    label: "Filtered",
                    title: "Nothing under that genre.",
                    message: "No track in “\(name)” carries it any more.",
                    isError: false,
                    actionTitle: "Show everything"
                ) { choose(.all) }
            } else if let detail {
                list(detail)
            }
        }
    }

    // MARK: List

    /// A `List` for the same one reason the playlists screen is one: the swipe.
    private func list(_ detail: PlaylistDetail) -> some View {
        List {
            if case .failed(let message) = playlists.detailState {
                DeckErrorText(message)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            DeckTableEdgeRow()
            ForEach(shown) { entry in
                Button {
                    if isSelecting {
                        toggle(entry)
                    } else {
                        // From HERE, not from the top: tapping row nine and
                        // being given row one is the surprise every music app
                        // has taught people not to expect.
                        Task {
                            await player.playPlaylist(
                                detail, entries: shown,
                                startingAt: entry.position)
                        }
                    }
                } label: {
                    PlaylistTrackRow(
                        entry: entry, isCurrent: isCurrent(entry),
                        selection: mark(for: entry),
                        separator: entry.entry_id != shown.first?.entry_id)
                }
                .buttonStyle(.plain)
                // Only the PLAY is refused on a dead row. Picking one is how it
                // gets removed, and a row that cannot be picked cannot be tidied
                // away in the batch it belongs to.
                .disabled(entry.source == nil && !isSelecting)
                .listRowBackground(Deck.surface)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    // No confirmation, unlike deleting a playlist: one entry
                    // is two taps to put back, and the whole list is not.
                    Button(role: .destructive) {
                        Task { await playlists.removeEntry(entry.entry_id, from: detail) }
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
            DeckTableEdgeRow()
        }
        .listStyle(.plain)
        // A `List` row is 44pt tall before its content is measured, which would
        // space these further apart than the identical rows on the other two
        // screens. Nothing about a swipe needs that minimum.
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Deck.ground)
        .scrollIndicators(.hidden)
        .refreshable { await playlists.reloadDetail(id: detail.id, name: detail.name) }
    }

    /// Whether this entry is what is coming out of the speaker. Compared on the
    /// REF as well as the track, because a playlist may hold one track twice
    /// and only one of the two rows is playing.
    private func isCurrent(_ entry: PlaylistEntry) -> Bool {
        guard let playing = player.playingTrack else { return false }
        return playing.track_id == entry.track_id && playing.source_ref == entry.source_ref
    }
}

// MARK: - Row

/// One playlist entry.
///
/// The dead row - `source: null`, nothing to play it from - is rendered rather
/// than hidden. It is greyed, it does not respond to a tap, and it says why:
/// atlas holds the track but has no source for it, which is a sync away from
/// being fixed and impossible to fix if the row is invisible.
struct PlaylistTrackRow: View {
    let entry: PlaylistEntry
    let isCurrent: Bool
    /// Nil unless the screen is picking rows - see `LibraryRow`, which carries
    /// the same column for the same reason.
    var selection: RowSelection?
    /// The hair above the row - off for the first one, on the table's edge.
    var separator = true

    private var isPlayable: Bool { entry.source != nil }

    var body: some View {
        HStack(spacing: 12) {
            if let selection { SelectionMark(state: selection) }
            if isPlayable {
                ArtworkView(ref: entry.source_ref ?? entry.track_id, size: Theme.rowArt)
            } else {
                // Deck's disabled look - rail fill, dashed muted edge - rather
                // than a faded cover: "nothing to play" said by shape.
                Rectangle()
                    .fill(Deck.rail)
                    .frame(width: Theme.rowArt, height: Theme.rowArt)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: Theme.rowArt * 0.3, weight: .bold))
                            .foregroundStyle(Deck.muted)
                    )
                    .overlay(
                        Rectangle().strokeBorder(
                            Deck.muted, style: StrokeStyle(lineWidth: Deck.borderWidth, dash: [5, 4])))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Theme.rowTitle)
                    .foregroundStyle(
                        isCurrent
                            ? Deck.accentInk
                            : (isPlayable ? Deck.ink : Deck.muted)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isPlayable ? entry.artist : "\(entry.artist) — no source to play it from")
                    .font(Theme.rowSubtitle)
                    .foregroundStyle(Deck.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent {
                EqualiserBars()
            } else if !isPlayable {
                Image(systemName: "slash.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Deck.muted)
            }
        }
        .deckRow(selected: isCurrent, separator: separator)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.title), \(entry.artist)"
                + (isPlayable ? "" : ", not playable")
                + (isCurrent ? ", now playing" : "")
                + (selection == .picked
                    ? ", selected"
                    : selection == .unpicked ? ", not selected" : "")
        )
        .accessibilityHint(
            selection == nil && isPlayable
                ? "Plays the playlist from this track" : ""
        )
        .accessibilityAddTraits(selection == .picked ? .isSelected : [])
    }
}
