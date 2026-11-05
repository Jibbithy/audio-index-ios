// AudioIndexTests/ModelsTests.swift
import XCTest

@testable import AudioIndex

final class ModelsTests: XCTestCase {
    // The wire format is snake_case because that is what audio-index speaks.
    // Asserting the exact JSON keys here is the cheapest possible guard against
    // a rename on either side silently producing 400s at runtime.
    func testSyncTrackEncodesSnakeCaseKeys() throws {
        let t = SyncTrack(
            artist: "Ash Meridian", title: "Seraph", album: "Unsaid",
            duration_ms: 236_000, source: "spotify", source_ref: "spotify:track:x")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["artist", "title", "album", "duration_ms", "source", "source_ref"])
        XCTAssertEqual(obj["duration_ms"] as? Int, 236_000)
    }

    func testSyncTrackOmitsNothingWhenAlbumIsNil() throws {
        let t = SyncTrack(
            artist: "a", title: "b", album: nil,
            duration_ms: 1, source: "spotify", source_ref: "r")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        // album must be present as null, not absent - audio-index COALESCEs it,
        // and an absent key and a null both round-trip fine, but asserting the
        // shape stops a future `encodeIfPresent` from changing it unnoticed.
        XCTAssertTrue(obj.keys.contains("album"))
    }

    func testTrackRefDecodesTheQueuePayload() throws {
        let json = Data(
            """
            {"track_id":"abc","source":"spotify","source_ref":"spotify:track:x",
             "artist":"Ash Meridian","title":"Seraph"}
            """.utf8)
        let r = try JSONDecoder().decode(TrackRef.self, from: json)
        XCTAssertEqual(r.track_id, "abc")
        XCTAssertEqual(r.id, "abc")
        XCTAssertEqual(r.title, "Seraph")
    }

    func testScrobbleEncodesEpochMilliseconds() throws {
        let s = Scrobble(
            source: "spotify", source_ref: "r", artist: "a", title: "b",
            played_at: 1_757_000_000_000, ms_played: 12_345, context: "queue")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        XCTAssertEqual(obj["played_at"] as? Int, 1_757_000_000_000)
        XCTAssertEqual(obj["context"] as? String, "queue")
    }
}
