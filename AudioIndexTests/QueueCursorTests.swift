// AudioIndexTests/QueueCursorTests.swift
import XCTest

@testable import AudioIndex

private func ref(_ id: String) -> TrackRef {
    TrackRef(
        track_id: id, source: "spotify", source_ref: "spotify:track:\(id)",
        artist: "a", title: id)
}

final class QueueCursorTests: XCTestCase {
    func testStartsOnTheFirstTrack() {
        let c = QueueCursor(tracks: [ref("1"), ref("2")])
        XCTAssertEqual(c.current?.track_id, "1")
    }

    func testAdvanceMovesForwardAndReturnsTheNewTrack() {
        var c = QueueCursor(tracks: [ref("1"), ref("2")])
        XCTAssertEqual(c.advance()?.track_id, "2")
        XCTAssertEqual(c.current?.track_id, "2")
    }

    func testAdvancingPastTheEndYieldsNilAndExhausts() {
        var c = QueueCursor(tracks: [ref("1")])
        XCTAssertNil(c.advance())
        XCTAssertTrue(c.isExhausted)
        XCTAssertNil(c.current)
    }

    // Advancing an already-exhausted cursor must stay nil rather than walking
    // the index further and further past the end.
    func testAdvancingAnExhaustedCursorIsStable() {
        var c = QueueCursor(tracks: [ref("1")])
        _ = c.advance()
        XCTAssertNil(c.advance())
        XCTAssertTrue(c.isExhausted)
    }

    func testAnEmptyQueueIsExhaustedImmediately() {
        let c = QueueCursor(tracks: [])
        XCTAssertTrue(c.isExhausted)
        XCTAssertNil(c.current)
    }

    // Refilling replaces the queue outright rather than appending: atlas has
    // already excluded everything played inside the cooldown, so the new list
    // is authoritative and concatenating would replay what it deliberately left out.
    func testRefillReplacesAndRewinds() {
        var c = QueueCursor(tracks: [ref("1")])
        _ = c.advance()
        c.refill(with: [ref("9"), ref("8")])
        XCTAssertEqual(c.current?.track_id, "9")
        XCTAssertFalse(c.isExhausted)
    }
}
