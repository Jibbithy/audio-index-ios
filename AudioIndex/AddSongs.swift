import SwiftUI

// MARK: - Pure helpers

/// The track_ids a playlist already holds.
///
/// Used to MARK rows, not to hide them: this app lets a playlist hold the same
/// track twice on purpose, and a picker that silently dropped what was already
/// in the list would be answering a question the owner did not ask. Saying "in
/// this playlist" and letting them add it anyway is the honest version.
func trackIDs(in entries: [PlaylistEntry]) -> Set<String> {
    Set(entries.map(\.track_id))
}

// MARK: - Sheet

/// Add songs to a playlist, from inside that playlist.
///
/// This is where adding BELONGS. The long-press menu on a library row still
/// works and is the right gesture for one track you happen to be looking at -
/// but "I want to fill this playlist" starts at the playlist, and before this
/// existed the only answer an empty one could give was "go somewhere else and
/// come back".
///
/// The whole library, both sources, searched locally: the list is already in
/// memory, so typing filters instantly and cannot fail on a dropped tailnet.
struct AddSongsSheet: View {
    let playlist: Playlist
    /// What the playlist already holds, for the marks.
    let existing: Set<String>
    let onAdd: ([TrackRef]) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var library: LibraryStore

    @State private var query = ""
    @State private var picked: Set<String> = []

    private var results: [TrackRef] { librarySearch(library.everything, matching: query) }

    private var pickedTracks: [TrackRef] {
        library.everything.filter { picked.contains($0.track_id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            content
            addBar
        }
        .background(Deck.ground)
        .task { await library.loadEverything() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add songs")
                    .font(Deck.title)
                    .textCase(.uppercase)
                    .foregroundStyle(Deck.ink)
                Text("TO “\(playlist.name.uppercased())”")
                    .deckLabel()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Cancel", action: onCancel)
                .buttonStyle(.deck)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .deckBar(.top)
    }

    private var searchField: some View {
        DeckSearchField(title: "Search titles and artists", query: $query)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        if library.everything.isEmpty {
            // Two different nothings, and they send the owner to two different
            // places - one to Settings, one nowhere at all.
            VStack(spacing: 12) {
                Spacer()
                ProgressView().tint(Deck.muted)
                Text("Reading your library…")
                    .deckLabel()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack {
                Spacer()
                Text("Nothing matches “\(query)”.")
                    .font(Deck.body)
                    .foregroundStyle(Deck.muted)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DeckRule()
                    ForEach(results) { track in
                        Button {
                            toggle(track)
                        } label: {
                            AddSongRow(
                                track: track,
                                isPicked: picked.contains(track.track_id),
                                isAlreadyIn: existing.contains(track.track_id),
                                separator: track.track_id != results.first?.track_id)
                        }
                        .buttonStyle(.plain)
                    }
                    DeckRule()
                    Color.clear.frame(height: 12)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The one button, always present and disabled until something is picked -
    /// a control that appears when the selection becomes non-empty makes the
    /// list jump under the finger that just tapped a row.
    private var addBar: some View {
        Button {
            onAdd(pickedTracks)
        } label: {
            Text(
                picked.isEmpty
                    ? "Add songs"
                    : picked.count == 1 ? "Add 1 song" : "Add \(picked.count) songs"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.deckPrimary)
        .disabled(picked.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        // Opaque, and over the list rather than beside it: the rows scroll
        // UNDER this bar, and without a background the row that happens to be
        // halfway behind it reads as a button drawn on top of a track.
        .deckBar(.bottom)
    }

    private func toggle(_ track: TrackRef) {
        if picked.contains(track.track_id) { picked.remove(track.track_id) } else { picked.insert(track.track_id) }
    }
}

/// One pickable row. The same proportions as every other track row in the app,
/// plus the one thing this screen knows that the others do not: whether it is
/// already in the playlist being added to.
struct AddSongRow: View {
    let track: TrackRef
    let isPicked: Bool
    let isAlreadyIn: Bool
    /// The hair above the row - off for the first one, on the table's edge.
    var separator = true

    var body: some View {
        HStack(spacing: 12) {
            SelectionMark(state: isPicked ? .picked : .unpicked)
            ArtworkView(ref: track.source_ref, size: Theme.rowArt)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(Theme.rowTitle)
                    .foregroundStyle(Deck.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(track.artist)
                        .font(Theme.rowSubtitle)
                        .foregroundStyle(Deck.muted)
                        .lineLimit(1)
                    if isAlreadyIn {
                        // A flat tag, not a full chip: it rides on the text
                        // line and must not make this row taller than the rest.
                        Text("In this playlist")
                            .font(Deck.mono(9.5, .semibold, relativeTo: .caption2))
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(Deck.ink)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: 1))
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .deckRow(separator: separator)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(track.title), \(track.artist)"
                + (isAlreadyIn ? ", already in this playlist" : "")
                + (isPicked ? ", selected" : ", not selected")
        )
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
