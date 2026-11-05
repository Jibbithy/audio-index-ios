import SwiftUI

/// "Add to playlist…" on any row that is a track, wherever that row lives.
///
/// A long press rather than a button on the row: the queue and the library are
/// lists of things to LISTEN to, and a per-row control would put a second tap
/// target on every one of them for something done occasionally. The gesture is
/// also the one iOS already teaches for "more about this row".
///
/// The playlists come from the store rather than a fetch of their own, so the
/// menu opens instantly and cannot fail while it is open. What is sent is the
/// full `{artist, title, source, source_ref}` - see `PlaylistAddition` - so a
/// track atlas has never seen registers itself instead of the add bouncing.
struct AddToPlaylistMenu: ViewModifier {
    let track: TrackRef

    @EnvironmentObject private var playlists: PlaylistStore

    @State private var isNaming = false
    @State private var nameDraft = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                // Nested, so the menu says whose track it is before it asks
                // where to put it - and so a long press on the wrong row can
                // be abandoned without having chosen anything.
                Section(track.title) {
                    ForEach(playlists.playlists) { playlist in
                        Button {
                            Task { await playlists.add(track, to: playlist) }
                        } label: {
                            Text(playlist.name)
                        }
                    }
                    Button {
                        nameDraft = ""
                        isNaming = true
                    } label: {
                        Label("New playlist…", systemImage: "plus")
                    }
                }
            }
            // Attached to the ROW, not to the screen: the row is what is still
            // in the hierarchy when the context menu closes, and hoisting this
            // to the list would need every row to report back up to it.
            .alert("New playlist", isPresented: $isNaming) {
                TextField("Name", text: $nameDraft)
                    .textInputAutocapitalization(.words)
                Button("Create and add") {
                    let name = nameDraft
                    nameDraft = ""
                    Task { await playlists.createAndAdd(name: name, track: track) }
                }
                Button("Cancel", role: .cancel) { nameDraft = "" }
            } message: {
                Text("“\(track.title)” goes in as its first track.")
            }
    }
}

/// "…and into which playlist?", asked of a whole selection at once.
///
/// A confirmation dialog rather than the long-press menu above, because there
/// is no row to press: the gesture already happened, on a button, and what it
/// applies to is a set of rows rather than the one under the finger. It offers
/// the same two things that menu does - the playlists that exist, and a new one
/// - so "add" and "move" ask their question the same way.
///
/// The playlists come from the store rather than a fetch of their own, so the
/// sheet opens instantly and cannot fail while it is open.
struct PlaylistChooser: ViewModifier {
    @Binding var isPresented: Bool
    /// What the sheet is called, which is where the count goes: "Move 3 tracks
    /// to…" is the last chance to notice that three is not what was meant.
    let title: String
    /// The playlist these rows are already in, which must not be offered.
    /// Moving a selection into the list it is already in is either nothing at
    /// all or nine duplicates, and neither is worth a tap.
    var excluding: String?
    let onChoose: (Playlist) -> Void
    let onCreate: (String) -> Void

    @EnvironmentObject private var playlists: PlaylistStore

    @State private var isNaming = false
    @State private var nameDraft = ""

    private var choices: [Playlist] {
        playlists.playlists.filter { $0.id != excluding }
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) {
                ForEach(choices) { playlist in
                    Button(playlist.name) { onChoose(playlist) }
                }
                Button("New playlist…") {
                    nameDraft = ""
                    isNaming = true
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New playlist", isPresented: $isNaming) {
                TextField("Name", text: $nameDraft)
                    .textInputAutocapitalization(.words)
                Button("Create and add") {
                    let name = nameDraft
                    nameDraft = ""
                    onCreate(name)
                }
                Button("Cancel", role: .cancel) { nameDraft = "" }
            } message: {
                Text("The tracks you picked go in, in the order they are listed on screen.")
            }
    }
}

extension View {
    /// The "which playlist?" sheet, for a selection.
    func playlistChooser(
        isPresented: Binding<Bool>, title: String, excluding: String? = nil,
        onChoose: @escaping (Playlist) -> Void,
        onCreate: @escaping (String) -> Void
    ) -> some View {
        modifier(
            PlaylistChooser(
                isPresented: isPresented, title: title, excluding: excluding,
                onChoose: onChoose, onCreate: onCreate))
    }

    /// The long-press menu, for a row whose track is known.
    ///
    /// Takes an Optional because the library browser's rows are Navidrome songs
    /// and a song with no id or no title cannot be made into a `TrackRef` at
    /// all. Such a row simply has no menu, which is the truth about it - there
    /// is nothing to put in a playlist.
    @ViewBuilder
    func addToPlaylistMenu(for track: TrackRef?) -> some View {
        if let track {
            modifier(AddToPlaylistMenu(track: track))
        } else {
            self
        }
    }
}
