// AudioIndexTests/IndexClientTests.swift
import XCTest

@testable import AudioIndex

/// Captures the request instead of sending it. The client takes its transport
/// as a closure precisely so that no test needs a network, a server or URLProtocol.
private final class Recorder: @unchecked Sendable {
    var requests: [URLRequest] = []
    var response: (Data, HTTPURLResponse)!

    func send(_ r: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(r)
        return (response.0, response.1)
    }
    func reply(_ status: Int, _ body: String) {
        response = (
            Data(body.utf8),
            HTTPURLResponse(
                url: URL(string: "https://x")!, statusCode: status,
                httpVersion: nil, headerFields: nil)!
        )
    }
}

final class IndexClientTests: XCTestCase {
    private func client(_ rec: Recorder, token: String? = "tok") -> IndexClient {
        IndexClient(
            baseURL: URL(string: "https://server.example")!,
            token: { token }, transport: rec.send)
    }

    func testSyncPostsTracksWithTheBearerToken() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"ok":true,"tracks":2,"skipped":0}"#)
        let n = try await client(rec).sync([
            SyncTrack(artist: "a", title: "b", album: nil, duration_ms: 1, source: "spotify", source_ref: "r1"),
            SyncTrack(artist: "c", title: "d", album: nil, duration_ms: 1, source: "spotify", source_ref: "r2"),
        ])
        XCTAssertEqual(n, 2)
        let req = rec.requests[0]
        XCTAssertEqual(req.url?.path, "/sync")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual((body["tracks"] as! [[String: Any]]).count, 2)
    }

    func testQueueDecodesTracks() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"tracks":[{"track_id":"t","source":"spotify","source_ref":"r","artist":"a","title":"b"}]}"#)
        let q = try await client(rec).queue(n: 20)
        XCTAssertEqual(q.map(\.track_id), ["t"])
        XCTAssertEqual(rec.requests[0].url?.query, "n=20")
    }

    func testScrobblePosts() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"ok":true,"track_id":"t"}"#)
        try await client(rec).scrobble(
            Scrobble(
                source: "spotify", source_ref: "r", artist: "a",
                title: "b", played_at: 1, ms_played: 2, context: "queue"))
        XCTAssertEqual(rec.requests[0].url?.path, "/scrobble")
    }

    // A 401 means the token is wrong, which the UI must be able to say out loud
    // rather than showing an empty queue that looks like an empty library.
    func testUnauthorizedIsItsOwnError() async {
        let rec = Recorder()
        rec.reply(401, #"{"error":"unauthorized"}"#)
        do {
            _ = try await client(rec).queue(n: 5)
            XCTFail("expected a throw")
        } catch IndexError.unauthorized {
            // expected
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testServerErrorSurfacesTheStatus() async {
        let rec = Recorder()
        rec.reply(500, #"{"error":"internal error"}"#)
        do {
            _ = try await client(rec).queue(n: 5)
            XCTFail("expected a throw")
        } catch IndexError.http(let code, _) {
            XCTAssertEqual(code, 500)
        } catch { XCTFail("wrong error: \(error)") }
    }

    // No token configured must be a distinct, nameable state - not a request
    // that goes out and comes back 401 looking like a wrong token.
    func testMissingTokenFailsBeforeSending() async {
        let rec = Recorder()
        rec.reply(200, "{}")
        do {
            _ = try await client(rec, token: nil).queue(n: 5)
            XCTFail("expected a throw")
        } catch IndexError.noToken {
            XCTAssertTrue(rec.requests.isEmpty)
        } catch { XCTFail("wrong error: \(error)") }
    }
}

// MARK: - The library and its genres

extension IndexClientTests {

    func testLibraryDecodesTracksAndAsksForEverythingByDefault() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"tracks":[{"track_id":"t","source":"file","source_ref":"navidrome:9","artist":"a","title":"b"}]}"#)
        let tracks = try await client(rec).library()
        XCTAssertEqual(tracks.map(\.title), ["b"])
        XCTAssertEqual(rec.requests[0].url?.path, "/library")
        XCTAssertNil(rec.requests[0].url?.query)
    }

    func testLibraryAsksTheServerForOneGenre() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"tracks":[]}"#)
        _ = try await client(rec).library(.genre("future garage"))
        XCTAssertEqual(rec.requests[0].url?.query, "genre=future%20garage")
    }

    func testLibraryAsksForTheUntaggedOnesSeparately() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"tracks":[]}"#)
        _ = try await client(rec).library(.untagged)
        XCTAssertEqual(rec.requests[0].url?.query, "untagged=1")
    }

    func testGenresDecodesCountsAndTheUntaggedTotal() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"genres":[{"genre":"dubstep","track_count":4}],"untagged":9}"#)
        let summary = try await client(rec).genres()
        XCTAssertEqual(summary.genres, [GenreCount(genre: "dubstep", track_count: 4)])
        XCTAssertEqual(summary.untagged, 9)
    }

    func testSetGenresPostsEveryRowIncludingTheEmptyOnes() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"ok":true,"tracks":2,"skipped":0}"#)
        let n = try await client(rec).setGenres([
            GenreRow(source: "spotify", source_ref: "r1", genres: ["dubstep"]),
            GenreRow(source: "spotify", source_ref: "r2", genres: []),
        ])
        XCTAssertEqual(n, 2)
        XCTAssertEqual(rec.requests[0].url?.path, "/genres")
        XCTAssertEqual(rec.requests[0].httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: rec.requests[0].httpBody!) as! [String: Any]
        let rows = body["tracks"] as! [[String: Any]]
        // The empty list must be ON THE WIRE, not omitted: it is what clears a
        // genre Spotify has stopped reporting.
        XCTAssertEqual((rows[1]["genres"] as! [String]).count, 0)
    }
}
