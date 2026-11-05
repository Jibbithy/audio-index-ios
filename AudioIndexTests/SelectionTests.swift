// AudioIndexTests/SelectionTests.swift
import XCTest

@testable import AudioIndex

/// Everything about picking many rows and writing them one at a time that can
/// be wrong without a screen: which rows "Select all" means, which removals a
/// move is allowed to make, and what the owner is told afterwards. No network,
/// no simulator, no AVPlayer - the writes themselves are nine HTTP calls and
/// are not what goes wrong here.

// MARK: - Select all

final class SelectAllTests: XCTestCase {

    private let library = ["nd-01", "nd-02", "nd-03", "nd-04", "nd-05"]

    /// The whole point of doing this over the FILTERED rows. A search box
    /// holding two of five songs and a "Select all" that quietly picked all
    /// five would be unrecoverable on the real library, where five is a few
    /// thousand and the next tap is "Add to playlist…".
    func testSelectAllTakesExactlyTheFilteredRows() {
        let filtered = ["nd-02", "nd-04"]
        let picked = selectingAll(filtered, keeping: [])
        XCTAssertEqual(picked, ["nd-02", "nd-04"])
        // Said the other way round, because this is the assertion that matters:
        // nothing off screen was picked.
        for hidden in library where !filtered.contains(hidden) {
            XCTAssertFalse(picked.contains(hidden))
        }
    }

    /// A selection made under one query survives the next one. Those rows were
    /// picked on purpose and a keystroke is not a decision to let them go.
    func testSelectAllKeepsRowsPickedUnderAnEarlierSearch() {
        let picked = selectingAll(["nd-04"], keeping: ["nd-01"])
        XCTAssertEqual(picked, ["nd-01", "nd-04"])
    }

    /// Selecting all twice is selecting all once. A set, so a row cannot be in
    /// a selection twice and there is no second copy to add to a playlist.
    func testSelectAllIsIdempotent() {
        let once = selectingAll(["nd-02", "nd-04"], keeping: [])
        XCTAssertEqual(selectingAll(["nd-02", "nd-04"], keeping: once), once)
    }

    /// The mirror: it lets go of what is on screen and leaves what is not.
    func testDeselectAllOnlyLetsGoOfTheFilteredRows() {
        let picked = deselectingAll(["nd-02"], from: ["nd-01", "nd-02", "nd-05"])
        XCTAssertEqual(picked, ["nd-01", "nd-05"])
    }

    /// Which word the button says, asked of the visible rows so the label
    /// agrees with what the tap will do.
    func testTheLabelFlipsOnlyWhenEveryVISIBLERowIsPicked() {
        XCTAssertTrue(
            everythingVisibleIsSelected(
                ["nd-02", "nd-04"],
                in: ["nd-01", "nd-02", "nd-04"]))
        XCTAssertFalse(everythingVisibleIsSelected(["nd-02", "nd-04"], in: ["nd-02"]))
        // Nothing on screen says "Select all": there is nothing to let go of,
        // and "all of nothing is selected" is true and useless.
        XCTAssertFalse(everythingVisibleIsSelected([], in: ["nd-01"]))
    }
}

// MARK: - Planning a move

final class MovePlanTests: XCTestCase {

    private func entry(
        _ id: String, position: Int, track: String,
        source: String? = "spotify", ref: String? = "spotify:track:x",
        title: String = "t"
    ) -> PlaylistEntry {
        PlaylistEntry(
            entry_id: id, position: position, track_id: track, source: source,
            source_ref: ref, artist: "a", title: title)
    }

    private lazy var list = [
        entry("e-0", position: 0, track: "t0", title: "first"),
        entry("e-1", position: 1, track: "t1", title: "second"),
        entry("e-2", position: 2, track: "t2", source: nil, ref: nil, title: "no source"),
        entry("e-3", position: 3, track: "t3", title: "fourth"),
    ]

    /// Only the picked rows, in the PLAYLIST's order rather than the order they
    /// were tapped in, so what lands in the target reads the way the source
    /// read.
    func testOnlyPickedRowsAreAttemptedAndInTheListsOwnOrder() {
        let steps = plannedMove(of: list, selected: ["e-3", "e-0"])
        XCTAssertEqual(steps.map(\.entryId), ["e-0", "e-3"])
        XCTAssertEqual(steps.compactMap(\.track).map(\.title), ["first", "fourth"])
        // The track identity is atlas's, carried through rather than rebuilt
        // from the ref.
        XCTAssertEqual(steps.compactMap(\.track).map(\.track_id), ["t0", "t3"])
    }

    /// A playlist may legitimately hold one track twice - two entries, one
    /// `track_id` - and both are rows the owner can see and pick. Both are
    /// added, so the target ends up holding it twice too.
    ///
    /// Collapsing them would be worse than a duplicate: one copy would go to
    /// the target and TWO would be taken out of the source, which is a track
    /// quietly lost by the one feature whose whole job is not to lose one.
    func testOneTrackTwiceIsTwoAddsNotOne() {
        let twice = [
            entry("e-a", position: 0, track: "t1", ref: "spotify:track:x", title: "Bare"),
            entry("e-b", position: 1, track: "t1", ref: "spotify:track:x", title: "Bare"),
        ]
        let steps = plannedMove(of: twice, selected: ["e-a", "e-b"])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.map(\.entryId), ["e-a", "e-b"])
        // Same track, both times. Not deduplicated, and deliberately so.
        XCTAssertEqual(steps.compactMap(\.track).map(\.track_id), ["t1", "t1"])
        // And both entries are removable, once both adds land.
        let landed = ["e-a": AddResult.landed, "e-b": AddResult.landed]
        XCTAssertEqual(permittedRemovals(of: steps, given: landed), ["e-a", "e-b"])
    }

    /// An entry atlas has no source for cannot be sent anywhere: there is no
    /// ref to build a `PlaylistAddition` from. The step still exists, so the
    /// row is counted and reported rather than silently dropped from a
    /// selection the user made.
    func testAnEntryWithNoSourceIsPlannedWithNothingToSend() {
        let steps = plannedMove(of: list, selected: ["e-2"])
        XCTAssertEqual(steps.map(\.entryId), ["e-2"])
        XCTAssertNil(steps[0].track)
        // And it is NOT removable, because nothing was added for it. Removing
        // it here would be a delete wearing a move's name.
        XCTAssertTrue(permittedRemovals(of: steps, given: ["e-2": .noSource]).isEmpty)
    }

    /// The one rule the whole feature rests on: a removal happens only where
    /// that row's own add landed. The failed one stays where it was.
    func testOnlyTheRowsWhoseADDLandedMayBeRemoved() {
        let steps = plannedMove(of: list, selected: ["e-0", "e-1", "e-3"])
        let adds: [String: AddResult] = ["e-0": .landed, "e-1": .refused, "e-3": .landed]
        XCTAssertEqual(permittedRemovals(of: steps, given: adds), ["e-0", "e-3"])
    }

    /// A row whose add has not been attempted yet - the run was cancelled
    /// before it, or is still working its way down - is not removable either.
    /// A missing answer is not a yes.
    func testARowWithNoAddResultAtAllIsNotRemoved() {
        let steps = plannedMove(of: list, selected: ["e-0", "e-1"])
        XCTAssertEqual(permittedRemovals(of: steps, given: ["e-0": .landed]), ["e-0"])
        XCTAssertTrue(permittedRemovals(of: steps, given: [:]).isEmpty)
    }

    /// Nothing picked plans nothing. The buttons are disabled rather than
    /// no-ops, so this should be unreachable - and it is still not allowed to
    /// invent a write.
    func testAnEmptySelectionPlansNothing() {
        XCTAssertTrue(plannedMove(of: list, selected: []).isEmpty)
    }
}

// MARK: - What the owner is told

final class BatchSummaryTests: XCTestCase {

    private let target = "Late drive"
    private let source = "Tapes"

    // MARK: Adding

    func testEveryAddLanded() {
        let said = batchSummary(BatchOutcome(selected: 9, added: 9), .add(to: target))
        XCTAssertEqual(said.text, "Added 9 tracks to “Late drive”.")
        XCTAssertFalse(said.isError)
    }

    func testOneAddIsNotReportedInThePlural() {
        let said = batchSummary(BatchOutcome(selected: 1, added: 1), .add(to: target))
        XCTAssertEqual(said.text, "Added 1 track to “Late drive”.")
    }

    func testSomeAddsFailed() {
        let said = batchSummary(
            BatchOutcome(selected: 9, added: 7, addFailed: 2),
            .add(to: target))
        XCTAssertEqual(said.text, "Added 7 of 9 to “Late drive”; 2 failed.")
        XCTAssertTrue(said.isError)
    }

    func testEveryAddFailed() {
        let said = batchSummary(BatchOutcome(selected: 9, addFailed: 9), .add(to: target))
        XCTAssertEqual(said.text, "Nothing was added to “Late drive”; 9 failed.")
        XCTAssertTrue(said.isError)
    }

    /// Atlas's own words about the FIRST thing that went wrong ride along, once.
    /// Nine copies of one HTTP 500 is not nine pieces of information.
    func testTheReasonIsAppendedOnlyWhenSomethingFailed() {
        let bad = batchSummary(
            BatchOutcome(selected: 2, added: 1, addFailed: 1),
            .add(to: target), because: "Atlas returned HTTP 500.")
        XCTAssertEqual(
            bad.text,
            "Added 1 of 2 to “Late drive”; 1 failed. "
                + "Atlas returned HTTP 500.")
        // A run that worked has no reason to give and is not handed one.
        let good = batchSummary(
            BatchOutcome(selected: 2, added: 2), .add(to: target),
            because: "Atlas returned HTTP 500.")
        XCTAssertEqual(good.text, "Added 2 tracks to “Late drive”.")
    }

    // MARK: Moving

    func testEveryMoveLanded() {
        let said = batchSummary(
            BatchOutcome(selected: 9, added: 9, removed: 9),
            .move(to: target, from: source))
        XCTAssertEqual(said.text, "Moved 9 tracks to “Late drive”.")
        XCTAssertFalse(said.isError)
    }

    /// The accident this whole feature is written around. The adds landed and
    /// two removals did not, so two tracks are now in BOTH playlists - which is
    /// said, with the number and the name, rather than being reported as a
    /// move that worked or as a generic failure.
    func testAMoveWhoseRemovalsFailedSaysTheTracksAreInBothLists() {
        let said = batchSummary(
            BatchOutcome(
                selected: 9, added: 9, removed: 7,
                removeFailed: 2),
            .move(to: target, from: source))
        XCTAssertEqual(
            said.text,
            "Moved 7 of 9 to “Late drive”; 2 could not be removed "
                + "from “Tapes”, so they are now in both.")
        XCTAssertTrue(said.isError)
    }

    /// The other half: an add that failed leaves that track exactly where it
    /// was, and the sentence says so - it is not a duplicate and not a loss.
    func testAMoveWhoseADDSFailedSaysTheTracksStayedPut() {
        let said = batchSummary(
            BatchOutcome(selected: 9, added: 7, addFailed: 2, removed: 7),
            .move(to: target, from: source))
        XCTAssertEqual(
            said.text,
            "Moved 7 of 9 to “Late drive”; 2 could not be added, "
                + "so they are still in “Tapes”.")
        XCTAssertTrue(said.isError)
    }

    /// Both accidents in one run. Both are named, and the duplicate goes first
    /// because it is the one that asks the reader to go and do something.
    func testAMoveCanFailBothWaysAtOnce() {
        let said = batchSummary(
            BatchOutcome(
                selected: 9, added: 8, addFailed: 1, removed: 7,
                removeFailed: 1),
            .move(to: target, from: source))
        XCTAssertEqual(
            said.text,
            "Moved 7 of 9 to “Late drive”; 1 could not be removed "
                + "from “Tapes”, so it is now in both; 1 could not be "
                + "added, so it is still in “Tapes”.")
    }

    func testAMoveWhereNothingCouldBeAdded() {
        let said = batchSummary(
            BatchOutcome(selected: 9, addFailed: 9),
            .move(to: target, from: source))
        XCTAssertEqual(
            said.text,
            "Nothing was moved to “Late drive”; 9 could not be added, "
                + "so they are still in “Tapes”.")
        XCTAssertTrue(said.isError)
    }

    /// Every add landed and every removal was refused: nothing moved, and nine
    /// tracks are in two lists. The sentence must not say "could not be added",
    /// which is the failure that did NOT happen.
    func testAMoveWhereEverythingWasCopiedAndNothingRemoved() {
        let said = batchSummary(
            BatchOutcome(selected: 9, added: 9, removeFailed: 9),
            .move(to: target, from: source))
        XCTAssertEqual(
            said.text,
            "Nothing was moved to “Late drive”; 9 could not be removed "
                + "from “Tapes”, so they are now in both.")
    }

    // MARK: Removing

    func testEveryRemovalLanded() {
        let said = batchSummary(BatchOutcome(selected: 4, removed: 4), .remove(from: source))
        XCTAssertEqual(said.text, "Removed 4 tracks from “Tapes”.")
        XCTAssertFalse(said.isError)
    }

    func testSomeRemovalsFailed() {
        let said = batchSummary(
            BatchOutcome(selected: 4, removed: 3, removeFailed: 1),
            .remove(from: source))
        XCTAssertEqual(said.text, "Removed 3 of 4 from “Tapes”; 1 failed.")
        XCTAssertTrue(said.isError)
    }

    func testEveryRemovalFailed() {
        let said = batchSummary(
            BatchOutcome(selected: 4, removeFailed: 4),
            .remove(from: source))
        XCTAssertEqual(said.text, "Nothing was removed from “Tapes”; 4 failed.")
    }

    // MARK: Cancelling

    /// Stopped partway is not a failure and is never dressed as one. Nothing is
    /// undone, so the sentence is about what DID happen: four of nine are in
    /// the target and out of the source, and the other five never moved.
    func testCancellingPartwayReportsWhatHadAlreadyHappened() {
        let said = batchSummary(
            BatchOutcome(selected: 9, added: 4, removed: 4, cancelled: true),
            .move(to: target, from: source))
        XCTAssertEqual(said.text, "Stopped after moving 4 of 9 to “Late drive”.")
        XCTAssertFalse(said.isError)
    }

    func testCancellingAnAddReportsWhatHadAlreadyHappened() {
        let said = batchSummary(
            BatchOutcome(selected: 50, added: 31, cancelled: true),
            .add(to: target))
        XCTAssertEqual(said.text, "Stopped after adding 31 of 50 to “Late drive”.")
        XCTAssertFalse(said.isError)
    }

    func testCancellingARemovalReportsWhatHadAlreadyHappened() {
        let said = batchSummary(
            BatchOutcome(selected: 9, removed: 2, cancelled: true),
            .remove(from: source))
        XCTAssertEqual(said.text, "Stopped after removing 2 of 9 from “Tapes”.")
    }

    /// A run that was cancelled AND hit a failure on the way says both. Being
    /// stopped does not excuse the app from saying where a track ended up.
    func testACancelledRunStillReportsAFailureItHitOnTheWay() {
        let said = batchSummary(
            BatchOutcome(
                selected: 9, added: 5, removed: 4,
                removeFailed: 1, cancelled: true),
            .move(to: target, from: source))
        XCTAssertEqual(
            said.text,
            "Stopped after moving 4 of 9 to “Late drive”; 1 could not "
                + "be removed from “Tapes”, so it is now in both.")
        XCTAssertTrue(said.isError)
    }
}
