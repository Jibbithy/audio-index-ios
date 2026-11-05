import Foundation

// MARK: - Which rows are picked
//
// A selection is a set of ids and nothing else. A set rather than an array
// because a row is picked or it is not - an order over a selection would be a
// second opinion about the order the list is already in, and the two would
// disagree the moment a search reordered nothing and the taps did.

/// The selection after "Select all" over the rows CURRENTLY on screen.
///
/// Over the rows the filter kept, never the whole library. "Select all" under a
/// search box that is showing four of a few thousand songs has to mean those
/// four: that is what it looks like it means, and it is the only reading the
/// user can check by looking. The other reading is unrecoverable - there is no
/// undo for "add three thousand tracks to Late drive" - while this one costs
/// one visible tap to widen, by clearing the search first.
///
/// Additive, so a selection made before the search survives it. Rows picked
/// while another query was in the box were picked on purpose and are not
/// un-picked by a keystroke. Nothing here can pick a row the user cannot see,
/// which is the property that actually matters.
func selectingAll(_ visible: [String], keeping selection: Set<String>) -> Set<String> {
    selection.union(visible)
}

/// The selection after "Deselect all" over the rows currently on screen.
///
/// The mirror of the above, and for the same reason: it lets go of what is in
/// front of the user and leaves alone what is not.
func deselectingAll(_ visible: [String], from selection: Set<String>) -> Set<String> {
    selection.subtracting(visible)
}

/// Whether the control should be offering "Deselect all" rather than
/// "Select all".
///
/// Asked of the visible rows only, so the label agrees with what the button
/// will do. An empty list says "Select all": there is nothing to let go of, and
/// "all of nothing is already selected" is true and useless.
func everythingVisibleIsSelected(_ visible: [String], in selection: Set<String>) -> Bool {
    !visible.isEmpty && visible.allSatisfy(selection.contains)
}

// MARK: - Moving a selection between playlists
//
// There is no batch endpoint on atlas. A move of nine rows is nine `POST
// /playlists/:id/tracks` and up to nine `DELETE /playlists/:id/entries/:id`,
// one after another, each of which can fail on its own - so the interesting
// part of this feature is not the writing, it is deciding what is allowed to
// happen next after one of them did not work.

/// One selected row, as a move has to do it: an add to the target, and then -
/// only then - a removal from the source.
struct MoveStep: Equatable {
    /// The entry in the SOURCE playlist. What gets deleted, by its id and never
    /// by its position: the server closes the gap after every removal, so by
    /// the third one a position names whatever has since slid into that slot.
    let entryId: String

    /// What is posted to the target, or nil for an entry atlas has no source
    /// for. `PlaylistAddition` is a source ref with an artist and a title and
    /// there is nothing here to build one from, so a dead row cannot be moved.
    /// It can still be REMOVED - that is how such a row gets cleaned up - and
    /// the move counts it as an add that did not happen rather than deleting it
    /// out of a playlist and into nowhere.
    let track: TrackRef?
}

/// How one step's add turned out.
enum AddResult: Equatable {
    case landed
    /// Atlas refused it.
    case refused
    /// Never sent: the entry had no source to build an addition from.
    case noSource
}

/// The steps a move over a selection will attempt, in the playlist's own order.
///
/// Keyed on the ENTRY, never on the track. A playlist may legitimately hold one
/// track twice - two entries, one `track_id`, two rows the user can see and
/// pick separately - and collapsing them into a single add would put one copy
/// in the target and then take two out of the source. That is a track quietly
/// lost, in a feature whose entire job is not to lose one.
///
/// The playlist's order, not the order the rows were tapped in, so what lands
/// in the target reads the way the source read.
func plannedMove(of entries: [PlaylistEntry], selected: Set<String>) -> [MoveStep] {
    entries
        .filter { selected.contains($0.entry_id) }
        .map { MoveStep(entryId: $0.entry_id, track: movableTrack(of: $0)) }
}

/// What a move would post for this entry, if anything.
///
/// The same rule `playableTracks` applies, and deliberately so: an entry with a
/// source and no ref is as unusable to an add as it is to a player, and half of
/// one would go up as an empty `source_ref` for atlas to reject.
private func movableTrack(of entry: PlaylistEntry) -> TrackRef? {
    guard let source = entry.source, !source.isEmpty,
        let ref = entry.source_ref, !ref.isEmpty
    else { return nil }
    return TrackRef(
        track_id: entry.track_id, source: source, source_ref: ref,
        artist: entry.artist, title: entry.title)
}

/// The entries a move is PERMITTED to remove, given how their adds went.
///
/// The whole safety of the feature is this one filter. A removal is allowed
/// only where that row's own add landed on the target: if an add failed and the
/// removal went ahead regardless, the track would be gone from the source and
/// would never have arrived anywhere - a delete wearing a move's name, and the
/// one outcome here that cannot be undone from this app.
///
/// The opposite accident - an add that landed and a removal that did not -
/// leaves a duplicate across two playlists. That is visible, it is two swipes
/// to fix, and `batchSummary` says it out loud rather than reporting a move.
func permittedRemovals(of steps: [MoveStep], given adds: [String: AddResult]) -> [String] {
    steps.map(\.entryId).filter { adds[$0] == .landed }
}

// MARK: - Saying what happened

/// What a batch of one-at-a-time writes was trying to do.
enum BatchKind: Equatable {
    /// A library selection into a playlist. Nothing is removed from anywhere,
    /// so there is only one way for it to go wrong.
    case add(to: String)
    /// Out of one playlist and into another: an add, and then a removal.
    case move(to: String, from: String)
    /// Out of one playlist, full stop.
    case remove(from: String)
}

/// How a batch ended, counted rather than accumulated as prose.
///
/// Counted, because the sentence at the end has to say numbers. "Some tracks
/// could not be moved" is the sentence that makes the owner open the other
/// playlist and count the rows by hand, which is exactly the work this feature
/// exists to save.
///
/// The add half and the remove half are counted separately because they are
/// different accidents with different consequences: an add that failed leaves
/// the track where it already was, and a removal that failed leaves it in BOTH
/// lists. Rolled into one "failed" count the two would be indistinguishable,
/// and only one of them means "go and tidy something up".
struct BatchOutcome: Equatable {
    /// How many rows the user picked. The denominator of every sentence below.
    var selected: Int
    /// Adds that landed on the target.
    var added = 0
    /// Adds atlas refused, plus the rows there was nothing to send for.
    var addFailed = 0
    /// Removals from the source that landed.
    var removed = 0
    /// Removals refused AFTER their own add landed - the duplicate case.
    var removeFailed = 0
    /// Stopped by the user partway. Not a failure, and never dressed as one:
    /// the writes that had already happened are real and are reported as such.
    var cancelled = false
}

/// The one line the notice bar shows when a batch finishes, and whether it is
/// red.
///
/// Specific on purpose, and longer than a generic failure would be. "Could not
/// move those tracks" leaves the owner with two playlists in an unknown state;
/// "moved 7 of 9; 2 could not be removed from Tapes, so they are now in both"
/// tells them what to go and look at. Every branch here names the numbers and,
/// where a track ended up somewhere it was not asked to be, says where.
///
/// `reason` is atlas's own words about the FIRST thing that went wrong. Only
/// the first: nine copies of one HTTP 500 is not nine pieces of information.
func batchSummary(
    _ outcome: BatchOutcome, _ kind: BatchKind,
    because reason: String? = nil
) -> (text: String, isError: Bool) {
    let isError = outcome.addFailed > 0 || outcome.removeFailed > 0
    var text = base(outcome, kind)
    for clause in clauses(outcome, kind) { text += "; " + clause }
    text += "."
    if isError, let reason, !reason.isEmpty { text += " " + reason }
    return (text, isError)
}

/// The sentence before any clause about what went wrong: what the batch DID.
private func base(_ o: BatchOutcome, _ kind: BatchKind) -> String {
    switch kind {
    case .add(let target):
        if o.cancelled { return "Stopped after adding \(o.added) of \(o.selected) to “\(target)”" }
        if !anythingFailed(o) { return "Added \(tracks(o.added)) to “\(target)”" }
        if o.added == 0 { return "Nothing was added to “\(target)”" }
        return "Added \(o.added) of \(o.selected) to “\(target)”"

    case .move(let target, _):
        // A track that was added and NOT removed has not been moved - it has
        // been copied. Only the removals count as moves, which is why the
        // duplicate clause below has a number to report at all.
        if o.cancelled { return "Stopped after moving \(o.removed) of \(o.selected) to “\(target)”" }
        if !anythingFailed(o) { return "Moved \(tracks(o.removed)) to “\(target)”" }
        if o.removed == 0 { return "Nothing was moved to “\(target)”" }
        return "Moved \(o.removed) of \(o.selected) to “\(target)”"

    case .remove(let source):
        if o.cancelled {
            return "Stopped after removing \(o.removed) of \(o.selected) from “\(source)”"
        }
        if !anythingFailed(o) { return "Removed \(tracks(o.removed)) from “\(source)”" }
        if o.removed == 0 { return "Nothing was removed from “\(source)”" }
        return "Removed \(o.removed) of \(o.selected) from “\(source)”"
    }
}

/// What went wrong, and - the part that matters - where those tracks are now.
///
/// The duplicate clause comes first because it is the one that asks the reader
/// to do something.
private func clauses(_ o: BatchOutcome, _ kind: BatchKind) -> [String] {
    var out: [String] = []
    switch kind {
    case .add:
        if o.addFailed > 0 { out.append("\(o.addFailed) failed") }

    case .move(_, let source):
        if o.removeFailed > 0 {
            out.append(
                "\(o.removeFailed) could not be removed from “\(source)”, "
                    + "so \(they(o.removeFailed)) now in both")
        }
        if o.addFailed > 0 {
            out.append(
                "\(o.addFailed) could not be added, "
                    + "so \(they(o.addFailed)) still in “\(source)”")
        }

    case .remove:
        if o.removeFailed > 0 { out.append("\(o.removeFailed) failed") }
    }
    return out
}

private func anythingFailed(_ o: BatchOutcome) -> Bool {
    o.addFailed > 0 || o.removeFailed > 0
}

/// "1 track" / "9 tracks". Said in full only where the count IS the whole
/// story - a batch that worked - so the good case reads as a sentence rather
/// than as a score.
private func tracks(_ n: Int) -> String { n == 1 ? "1 track" : "\(n) tracks" }

/// "it is" / "they are", so a one-track failure is not reported in the plural.
private func they(_ n: Int) -> String { n == 1 ? "it is" : "they are" }
