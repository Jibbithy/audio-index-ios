import Foundation

// MARK: - Pure helpers
//
// The one part of a playlist that can actually be wrong without a screen is
// which of its entries something can play, so it is a plain function over plain
// values and is tested without a server, an AVPlayer or a tap.

/// The entries something can actually play, as the `TrackRef`s the rest of the
/// app already speaks.
///
/// An entry with a null `source` is dropped HERE and nowhere else. The row
/// stays on screen - greyed, and not playable - because atlas returning it is
/// information: that track is in the playlist and there is currently nothing to
/// play it from. Filtering it out of the LIST as well would leave a playlist
/// that quietly holds more than it shows.
///
/// `startingAt` is how a tapped row plays "from here": the cursor has no seek,
/// so the list handed to it simply begins at that position. Ordering is all a
/// position is good for - an entry is IDENTIFIED by its `entry_id` - and even
/// here it compares rather than indexes, so a stale detail load cannot
/// silently start the wrong track.
func playableTracks(of entries: [PlaylistEntry], startingAt position: Int? = nil) -> [TrackRef] {
    entries
        .filter { position == nil || $0.position >= position! }
        .compactMap { entry in
            guard let source = entry.source, !source.isEmpty,
                let ref = entry.source_ref, !ref.isEmpty
            else { return nil }
            return TrackRef(
                track_id: entry.track_id, source: source, source_ref: ref,
                artist: entry.artist, title: entry.title)
        }
}

// MARK: - Store

/// Every playlist, the one that is open, and which state each of those is in.
///
/// Its own object rather than more `@Published` state on `Player`, for the same
/// reason `LibraryStore` is one: a failure to READ the playlists is not a
/// failure of the queue, and putting it in `player.error` would show a browsing
/// problem underneath the ranked list.
@MainActor
final class PlaylistStore: ObservableObject {

    /// One value rather than three booleans - the same rule, and the same bugs
    /// avoided, as `LibraryStore.State`. An empty list while loading reads
    /// as "you have no playlists"; an empty list after a 401 reads as it too,
    /// and the truth is that the token is wrong.
    enum State: Equatable {
        /// Nothing has been asked for yet.
        case idle
        case loading
        /// Atlas answered. The list may be empty, and an empty list IS this
        /// state rather than an error.
        case loaded
        case failed(String)
    }

    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var state: State = .idle

    /// The playlist currently open, and its own state. Separate from the list's
    /// because the two load independently: a detail that fails must not blank
    /// the list behind it.
    @Published private(set) var detail: PlaylistDetail?
    @Published private(set) var detailState: State = .idle

    /// The last thing a write did, in words, for the transient line above the
    /// mini player. Both halves go here: an add that worked is worth one line,
    /// and an add that failed is worth the same line in red - silence after a
    /// long-press is indistinguishable from a menu that did nothing.
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false

    /// Where atlas is and the token to reach it, read at the moment of use and
    /// never held: same rule as `Player.atlasToken`, and it matters for the
    /// same reason. Nil in demo mode, which must never touch the Keychain.
    var connection: () -> (baseURL: URL, token: String?)? = { nil }

    /// The clock the notice fades on. Injectable only so nothing in a test has
    /// to wait four seconds for it.
    var noticeSeconds: Double = 4

    private var noticeWork: Task<Void, Never>?

    // MARK: Reading

    /// Fill the list the first time the screen is looked at, and after a
    /// failure, but not on every return to the tab.
    func loadIfNeeded() async {
        switch state {
        case .loading, .loaded: return
        case .idle, .failed: await load()
        }
    }

    func load() async {
        #if DEBUG
            if DemoMode.isActive {
                playlists = DemoMode.playlists
                state = .loaded
                return
            }
        #endif
        guard let conn = connection() else {
            state = .failed(Player.describe(IndexError.noToken))
            return
        }
        state = .loading
        do {
            playlists = try await Self.fetchPlaylists(conn)
            state = .loaded
        } catch {
            // The last good list is KEPT, like the library's: a refresh that
            // failed on a dropped tailnet belongs above a list that still
            // works, not instead of it.
            state = .failed(Player.describe(error))
        }
    }

    /// Load one playlist's entries. Always from the server, never from a cached
    /// copy: the order of a list that another client has edited is not
    /// guessable from here.
    func openDetail(_ playlist: Playlist) async {
        detail = nil
        detailState = .loading
        await reloadDetail(id: playlist.id, name: playlist.name)
    }

    func reloadDetail(id: String, name: String) async {
        #if DEBUG
            if DemoMode.isActive {
                detail = DemoMode.playlistDetail(id: id, name: name)
                detailState = .loaded
                return
            }
        #endif
        guard let conn = connection() else {
            detailState = .failed(Player.describe(IndexError.noToken))
            return
        }
        do {
            detail = try await Self.fetchDetail(conn, id: id)
            detailState = .loaded
        } catch {
            detailState = .failed(Player.describe(error))
        }
    }

    func closeDetail() {
        detail = nil
        detailState = .idle
    }

    // MARK: Writing
    //
    // These reload afterwards rather than editing the copy in memory WHEREVER
    // the server could have changed something this client cannot derive - a
    // removal closes the gap and rewrites every position below it, and a
    // rename re-sorts the list. An append is the exception: the list is
    // ordered by name so it does not move, and the reply carries the id and
    // position of the entry that was made, so there is nothing left to guess.

    func create(name: String) async -> Playlist? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            say("A playlist needs a name.", isError: true)
            return nil
        }
        guard let conn = liveConnection() else { return nil }
        do {
            let made = try await Self.postPlaylist(conn, name: clean)
            await load()
            say("Created “\(clean)”.", isError: false)
            return made
        } catch {
            say(Player.describe(error), isError: true)
            return nil
        }
    }

    func rename(id: String, to name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            say("A playlist needs a name.", isError: true)
            return
        }
        guard let conn = liveConnection() else { return }
        do {
            try await Self.patchPlaylist(conn, id: id, name: clean)
            await reloadDetail(id: id, name: clean)
            await load()
        } catch {
            say(Player.describe(error), isError: true)
        }
    }

    /// Delete a playlist. Not recoverable from this app, which is why the only
    /// caller asks first.
    func delete(_ playlist: Playlist) async {
        guard let conn = liveConnection() else { return }
        do {
            try await Self.deletePlaylist(conn, id: playlist.id)
            if detail?.id == playlist.id { closeDetail() }
            await load()
            say("Deleted “\(playlist.name)”.", isError: false)
        } catch {
            say(Player.describe(error), isError: true)
        }
    }

    /// Add one track to an existing playlist.
    ///
    /// The full `{artist, title, source, source_ref}` goes up, so a track atlas
    /// has never seen registers itself rather than the add being refused - the
    /// app must not have to run a full library sync before it can act on the
    /// row in front of the user.
    func add(_ track: TrackRef, to playlist: Playlist) async {
        guard let conn = liveConnection() else { return }
        do {
            let added = try await Self.postTrack(
                conn, id: playlist.id,
                track: PlaylistAddition(track: track))
            // No reload. The reply says which entry was made and where it
            // landed, the append is always at the end, and the list is ordered
            // by name so this playlist's row has not moved - only its count
            // changed. The one thing taken on trust is the SOURCE: atlas
            // resolves an entry to its best-ranked source, so a track that
            // also exists as a local file shows the source it was added from
            // until the next load. It is the same track either way, and it
            // plays.
            if let open = detail, open.id == playlist.id {
                detail = PlaylistDetail(
                    id: open.id, name: open.name,
                    tracks: open.tracks + [
                        PlaylistEntry(
                            entry_id: added.entry_id,
                            position: added.position,
                            track_id: added.track_id,
                            source: track.source,
                            source_ref: track.source_ref,
                            artist: track.artist,
                            title: track.title)
                    ])
            }
            countTracks(in: playlist.id, by: 1)
            say("Added “\(track.title)” to “\(playlist.name)”.", isError: false)
        } catch {
            // A failed write is the one case where the local copy may be
            // behind: the add can have landed and the reply been lost. Ask.
            say(Player.describe(error), isError: true)
            if detail?.id == playlist.id {
                await reloadDetail(id: playlist.id, name: playlist.name)
            }
            await load()
        }
    }

    /// Move one playlist's `track_count` without re-reading the list.
    ///
    /// Safe only because the list is ordered by NAME: a count that changes
    /// cannot reorder anything, so the row updates where it already sits. A
    /// playlist the list has never loaded is simply not there, and is left
    /// alone rather than invented.
    private func countTracks(in id: String, by delta: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let p = playlists[i]
        playlists[i] = Playlist(
            id: p.id, name: p.name,
            track_count: max(0, p.track_count + delta),
            updated_at: p.updated_at)
    }

    /// Make a playlist and put this track in it, as one gesture.
    ///
    /// Two calls, and the second can fail on its own - so a failure says which
    /// half happened. An empty playlist left behind is recoverable; a silent
    /// "nothing was added" is not.
    func createAndAdd(name: String, track: TrackRef) async {
        guard let made = await create(name: name) else { return }
        await add(track, to: made)
    }

    /// Remove ONE entry of the open playlist, by its id.
    ///
    /// By id, never by position: the server closes the gap, so every entry
    /// below this one is renumbered by this very call. The reload afterwards
    /// is what brings those new positions back - it is not a guess being
    /// checked, it is the only place they exist.
    func removeEntry(_ entryId: String, from playlist: PlaylistDetail) async {
        guard let conn = liveConnection() else { return }
        do {
            try await Self.deleteEntry(conn, id: playlist.id, entryId: entryId)
            await reloadDetail(id: playlist.id, name: playlist.name)
            await load()
        } catch {
            say(Player.describe(error), isError: true)
        }
    }

    // MARK: Writing a whole selection
    //
    // Atlas has no batch endpoint: nine tracks is nine POSTs, and a move is
    // those nine plus up to nine DELETEs. Three things follow, and all three
    // are the reason these are not just loops around the single-track calls.
    //
    // One at a time, sequentially, never a task group. This is one server in a
    // cupboard; nine parallel writes buy nothing a person can perceive and cost
    // the one thing that matters here - a run whose writes happened in a known
    // order, so "it stopped after four" is a true sentence about a real state.
    //
    // Cancellable, because fifty rows over a tailnet is long enough to regret.
    // A cancel stops cleanly at the next ROW boundary and never between an add
    // and the removal that pairs with it; nothing is undone, and what already
    // happened is reported rather than swallowed.
    //
    // And each one ends by re-reading both playlists. Every removal rewrites
    // the positions below it on the server, so the source's order after nine of
    // them is not derivable from here at all.

    /// A batch write in flight, for the bar above the mini player. Nil when
    /// nothing is running, which is almost always.
    @Published private(set) var batch: BatchProgress?

    /// Set by the Cancel in that bar and read at the TOP of each row's turn.
    /// At the top, so a cancel can never land between an add and its removal:
    /// the duplicate that would leave behind is precisely the accident this
    /// whole feature is built not to cause.
    private var cancelRequested = false

    func cancelBatch() {
        guard batch != nil else { return }
        cancelRequested = true
        batch?.isStopping = true
    }

    /// Put a whole selection into an existing playlist.
    ///
    /// Nothing is removed from anywhere, so the only failure is an add that did
    /// not land - and the track is still wherever it was, which is what the
    /// summary says.
    func addMany(_ tracks: [TrackRef], to playlist: Playlist) async {
        guard !tracks.isEmpty else { return }
        guard let conn = liveConnection() else { return }
        var outcome = BatchOutcome(selected: tracks.count)
        var reason: String?
        begin("Adding to “\(playlist.name)”", total: tracks.count)
        for track in tracks {
            if cancelRequested {
                outcome.cancelled = true
                break
            }
            do {
                _ = try await Self.postTrack(
                    conn, id: playlist.id,
                    track: PlaylistAddition(track: track))
                outcome.added += 1
            } catch {
                outcome.addFailed += 1
                reason = reason ?? Player.describe(error)
            }
            batch?.done += 1
        }
        end()
        // Not `countTracks(in:by:)`: a run that partly failed leaves a count
        // this client can only guess at, and the guess would sit on screen
        // until something else happened to reload it.
        await load()
        if let open = detail, open.id == playlist.id {
            await reloadDetail(id: open.id, name: open.name)
        }
        report(outcome, .add(to: playlist.name), reason)
    }

    /// Make a playlist and put a whole selection in it, as one gesture.
    ///
    /// Two calls, and the second can fail on its own - so an empty playlist
    /// left behind is possible and is recoverable. A silent "nothing was
    /// added" is neither.
    func createAndAddMany(name: String, tracks: [TrackRef]) async {
        guard let made = await create(name: name) else { return }
        await addMany(tracks, to: made)
    }

    /// Move a whole selection out of one playlist and into another.
    ///
    /// The add goes first for every row and the removal is asked of
    /// `permittedRemovals` rather than decided inline, so the rule that a
    /// removal never outruns its own add is a tested function instead of the
    /// shape of an `if` in the middle of a network loop.
    func moveMany(
        _ steps: [MoveStep], from source: PlaylistDetail,
        to target: Playlist
    ) async {
        guard !steps.isEmpty else { return }
        guard let conn = liveConnection() else { return }
        var outcome = BatchOutcome(selected: steps.count)
        var adds: [String: AddResult] = [:]
        var reason: String?
        begin("Moving to “\(target.name)”", total: steps.count)
        for step in steps {
            if cancelRequested {
                outcome.cancelled = true
                break
            }
            if let track = step.track {
                do {
                    _ = try await Self.postTrack(
                        conn, id: target.id,
                        track: PlaylistAddition(track: track))
                    adds[step.entryId] = .landed
                    outcome.added += 1
                } catch {
                    adds[step.entryId] = .refused
                    outcome.addFailed += 1
                    reason = reason ?? Player.describe(error)
                }
            } else {
                adds[step.entryId] = .noSource
                outcome.addFailed += 1
                reason =
                    reason ?? "Atlas has no source for some of those, so there was "
                    + "nothing to send."
            }
            for doomed in permittedRemovals(of: [step], given: adds) {
                do {
                    try await Self.deleteEntry(conn, id: source.id, entryId: doomed)
                    outcome.removed += 1
                } catch {
                    outcome.removeFailed += 1
                    reason = reason ?? Player.describe(error)
                }
            }
            batch?.done += 1
        }
        end()
        await reloadDetail(id: source.id, name: source.name)
        await load()
        report(outcome, .move(to: target.name, from: source.name), reason)
    }

    /// Make a playlist and move a whole selection into it.
    func createAndMoveMany(
        name: String, steps: [MoveStep],
        from source: PlaylistDetail
    ) async {
        guard let made = await create(name: name) else { return }
        await moveMany(steps, from: source, to: made)
    }

    /// Take a whole selection out of the open playlist.
    ///
    /// By entry id, one at a time, for the reason `removeEntry` gives: the
    /// server closes the gap after each one, so the positions this client is
    /// looking at are stale from the first DELETE onwards.
    func removeMany(_ entryIds: [String], from source: PlaylistDetail) async {
        guard !entryIds.isEmpty else { return }
        guard let conn = liveConnection() else { return }
        var outcome = BatchOutcome(selected: entryIds.count)
        var reason: String?
        begin("Removing from “\(source.name)”", total: entryIds.count)
        for entryId in entryIds {
            if cancelRequested {
                outcome.cancelled = true
                break
            }
            do {
                try await Self.deleteEntry(conn, id: source.id, entryId: entryId)
                outcome.removed += 1
            } catch {
                outcome.removeFailed += 1
                reason = reason ?? Player.describe(error)
            }
            batch?.done += 1
        }
        end()
        await reloadDetail(id: source.id, name: source.name)
        await load()
        report(outcome, .remove(from: source.name), reason)
    }

    private func begin(_ verb: String, total: Int) {
        cancelRequested = false
        clearNotice()
        batch = BatchProgress(verb: verb, total: total)
    }

    private func end() {
        batch = nil
        cancelRequested = false
    }

    private func report(_ outcome: BatchOutcome, _ kind: BatchKind, _ reason: String?) {
        let said = batchSummary(outcome, kind, because: reason)
        say(said.text, isError: said.isError)
    }

    // MARK: Notice

    func say(_ message: String, isError: Bool) {
        notice = message
        noticeIsError = isError
        noticeWork?.cancel()
        let seconds = noticeSeconds
        noticeWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func clearNotice() {
        noticeWork?.cancel()
        notice = nil
    }

    /// The connection, or a notice saying why there is not one. Every write
    /// goes through this so that a missing token cannot fail silently behind a
    /// context menu that simply closed.
    private func liveConnection() -> (baseURL: URL, token: String?)? {
        #if DEBUG
            if DemoMode.isActive {
                say("Demo mode: playlists here are not saved anywhere.", isError: false)
                return nil
            }
        #endif
        guard let conn = connection() else {
            say(Player.describe(IndexError.noToken), isError: true)
            return nil
        }
        return conn
    }

    // MARK: Workers
    //
    // Nonisolated, each building its own `IndexClient` from plain values, for
    // the reason spelled out on `Player`: `IndexClient` is not Sendable, so one
    // built on the main actor cannot legally be handed to its own nonisolated
    // `async` methods.

    private typealias Conn = (baseURL: URL, token: String?)

    private nonisolated static func client(_ conn: Conn) -> IndexClient {
        IndexClient(baseURL: conn.baseURL, token: { conn.token })
    }

    private nonisolated static func fetchPlaylists(_ conn: Conn) async throws -> [Playlist] {
        try await client(conn).playlists()
    }

    private nonisolated static func fetchDetail(
        _ conn: Conn,
        id: String
    ) async throws -> PlaylistDetail {
        try await client(conn).playlist(id: id)
    }

    private nonisolated static func postPlaylist(
        _ conn: Conn,
        name: String
    ) async throws -> Playlist {
        try await client(conn).createPlaylist(name: name)
    }

    private nonisolated static func patchPlaylist(
        _ conn: Conn, id: String,
        name: String
    ) async throws {
        try await client(conn).renamePlaylist(id: id, name: name)
    }

    private nonisolated static func deletePlaylist(_ conn: Conn, id: String) async throws {
        try await client(conn).deletePlaylist(id: id)
    }

    private nonisolated static func postTrack(
        _ conn: Conn, id: String,
        track: PlaylistAddition
    ) async throws
        -> PlaylistAdded
    {
        try await client(conn).addToPlaylist(id: id, track: track)
    }

    private nonisolated static func deleteEntry(
        _ conn: Conn, id: String,
        entryId: String
    ) async throws {
        try await client(conn).removeFromPlaylist(id: id, entryId: entryId)
    }
}

// MARK: - Progress

/// A batch write while it is happening.
///
/// It exists because a selection of fifty is fifty round trips to a box on a
/// tailnet, and a spinner that says nothing over a list that cannot be touched
/// is indistinguishable from an app that has hung. The count is the useful
/// half: "31 of 50" says both that it is working and roughly how long is left.
struct BatchProgress: Equatable {
    /// What is happening, in the words of the button that started it.
    let verb: String
    /// Rows finished. One row is an add, or an add and the removal that pairs
    /// with it - it advances when that row is entirely done, so the number can
    /// never claim a move that is only half made.
    var done = 0
    let total: Int
    /// A cancel has been asked for and the current row is still finishing.
    /// Shown, because a Cancel that appears to do nothing for one round trip is
    /// a Cancel the user presses again.
    var isStopping = false

    /// 0...1 for the bar. A total of zero cannot be reached - the callers
    /// refuse an empty selection - but it would divide by zero if it were.
    var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }
}
