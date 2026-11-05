// AudioIndexTests/PlaylistClientTests.swift
import XCTest

@testable import AudioIndex

/// The seven playlist calls, as REQUESTS. Captures each one instead of sending
/// it, for the reason the client takes its transport as a closure at all: none
/// of this needs a network, a server or a URLProtocol.
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

final class PlaylistClientTests: XCTestCase {
    private func client(_ rec: Recorder, token: String? = "tok") -> IndexClient {
        IndexClient(
            baseURL: URL(string: "https://server.example")!,
            token: { token }, transport: rec.send)
    }

    private func body(_ req: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
    }

    // MARK: Reads

    func testListingPlaylistsGetsTheCollection() async throws {
        let rec = Recorder()
        rec.reply(
            200,
            #"""
            {"playlists":[{"id":"p1","name":"Late drive","track_count":3,"updated_at":1757300000000}]}
            """#)
        let list = try await client(rec).playlists()
        XCTAssertEqual(list.map(\.id), ["p1"])
        XCTAssertEqual(list[0].track_count, 3)
        XCTAssertEqual(list[0].updated_at, 1_757_300_000_000)
        XCTAssertEqual(rec.requests[0].url?.path, "/playlists")
        XCTAssertEqual(rec.requests[0].httpMethod, "GET")
        XCTAssertEqual(rec.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    /// Atlas orders the list by name, case insensitively, and the client hands
    /// it on untouched. Nothing here re-sorts: a second opinion in the client
    /// is one more thing that can disagree with the server, and the old sort
    /// existed only because the list used to arrive most-recently-touched
    /// first and slid under the reader's finger on every add.
    func testTheServersOrderIsKept() async throws {
        let rec = Recorder()
        rec.reply(
            200,
            #"""
            {"playlists":[
              {"id":"p1","name":"anthems","track_count":1,"updated_at":1},
              {"id":"p2","name":"Bright","track_count":2,"updated_at":9000},
              {"id":"p3","name":"cellar","track_count":0,"updated_at":50}
            ]}
            """#)
        let list = try await client(rec).playlists()
        XCTAssertEqual(list.map(\.name), ["anthems", "Bright", "cellar"])
    }

    func testReadingOnePlaylistPutsTheIdInThePath() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"id":"p1","name":"Late drive","created_at":1,"updated_at":2,"tracks":[]}"#)
        let detail = try await client(rec).playlist(id: "p1")
        XCTAssertEqual(detail.name, "Late drive")
        XCTAssertEqual(rec.requests[0].url?.path, "/playlists/p1")
        XCTAssertEqual(rec.requests[0].httpMethod, "GET")
    }

    // MARK: Writes

    func testCreatePostsTheName() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"id":"p9","name":"Sunday morning","created_at":1,"updated_at":1}"#)
        let made = try await client(rec).createPlaylist(name: "Sunday morning")
        XCTAssertEqual(made.id, "p9")
        // The create reply is the playlist ROW and carries no count. Zero is
        // the truth about a playlist that has just been made.
        XCTAssertEqual(made.track_count, 0)
        XCTAssertEqual(rec.requests[0].url?.path, "/playlists")
        XCTAssertEqual(rec.requests[0].httpMethod, "POST")
        XCTAssertEqual(try body(rec.requests[0])["name"] as? String, "Sunday morning")
    }

    func testRenamePatchesTheName() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"id":"p1","name":"Later drive","created_at":1,"updated_at":3}"#)
        let renamed = try await client(rec).renamePlaylist(id: "p1", name: "Later drive")
        XCTAssertEqual(renamed.name, "Later drive")
        XCTAssertEqual(rec.requests[0].url?.path, "/playlists/p1")
        XCTAssertEqual(rec.requests[0].httpMethod, "PATCH")
        XCTAssertEqual(try body(rec.requests[0])["name"] as? String, "Later drive")
    }

    func testDeleteSendsNoBody() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"ok":true}"#)
        try await client(rec).deletePlaylist(id: "p1")
        XCTAssertEqual(rec.requests[0].url?.path, "/playlists/p1")
        XCTAssertEqual(rec.requests[0].httpMethod, "DELETE")
        XCTAssertNil(rec.requests[0].httpBody)
    }

    /// The full four fields go up, never just the ref: that is what lets a
    /// track atlas has never seen register itself instead of the add bouncing
    /// with a 404, and it is why the app never has to sync first.
    func testAddingATrackSendsArtistAndTitleSoItCanSelfRegister() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"ok":true,"entry_id":"e-4c1a","position":4,"track_id":"t7"}"#)
        let track = TrackRef(
            track_id: "t7", source: "file", source_ref: "navidrome:nd-01",
            artist: "[Unknown Artist]", title: "01 - Lumenfall - Harbor.mp3")
        let added = try await client(rec).addToPlaylist(
            id: "p1",
            track: PlaylistAddition(track: track))
        // The whole reply, not just where it landed: the entry_id is what lets
        // the caller act on the new row without re-reading the playlist.
        XCTAssertEqual(added.entry_id, "e-4c1a")
        XCTAssertEqual(added.position, 4)
        XCTAssertEqual(added.track_id, "t7")
        XCTAssertEqual(rec.requests[0].url?.path, "/playlists/p1/tracks")
        XCTAssertEqual(rec.requests[0].httpMethod, "POST")
        let sent = try body(rec.requests[0])
        XCTAssertEqual(Set(sent.keys), ["source", "source_ref", "artist", "title"])
        XCTAssertEqual(sent["source"] as? String, "file")
        XCTAssertEqual(sent["source_ref"] as? String, "navidrome:nd-01")
        XCTAssertEqual(sent["artist"] as? String, "[Unknown Artist]")
        XCTAssertEqual(sent["title"] as? String, "01 - Lumenfall - Harbor.mp3")
    }

    /// The ENTRY_ID is the last path segment, under `/entries/`, and it is
    /// neither a query nor a body. Two things are pinned here: the id, because
    /// a position names whatever moved into that slot after the last removal,
    /// and the shape, because a removal aimed one segment short is
    /// `DELETE /playlists/p1` - which destroys the whole playlist and is the
    /// one mistake here that cannot be undone.
    func testRemovingAnEntryPutsTheEntryIdInThePath() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"ok":true}"#)
        try await client(rec).removeFromPlaylist(id: "p1", entryId: "e-4c1a")
        XCTAssertEqual(rec.requests[0].url?.path, "/playlists/p1/entries/e-4c1a")
        XCTAssertNotEqual(rec.requests[0].url?.path, "/playlists/p1")
        XCTAssertEqual(rec.requests[0].httpMethod, "DELETE")
        XCTAssertNil(rec.requests[0].url?.query)
        XCTAssertNil(rec.requests[0].httpBody)
    }

    /// The old route is gone from the server and must be gone from here: an
    /// entry the client believes is at position 0 is addressed by its id, so
    /// nothing this client sends can contain `/tracks/`.
    func testRemovingAnEntryNeverUsesTheOldTracksRoute() async throws {
        let rec = Recorder()
        rec.reply(200, #"{"ok":true}"#)
        try await client(rec).removeFromPlaylist(id: "p1", entryId: "0")
        XCTAssertEqual(rec.requests[0].url?.path, "/playlists/p1/entries/0")
        XCTAssertFalse(rec.requests[0].url?.path.contains("/tracks/") ?? true)
    }

    // MARK: Failures

    // A 401 on a playlist read must not surface as "you have no playlists":
    // the token is wrong, and only this error can say so.
    func testUnauthorizedIsItsOwnErrorOnPlaylists() async {
        let rec = Recorder()
        rec.reply(401, #"{"error":"unauthorized"}"#)
        do {
            _ = try await client(rec).playlists()
            XCTFail("expected a throw")
        } catch IndexError.unauthorized {
            // expected
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testMissingPlaylistSurfacesTheStatus() async {
        let rec = Recorder()
        rec.reply(404, #"{"error":"no such playlist"}"#)
        do {
            _ = try await client(rec).playlist(id: "gone")
            XCTFail("expected a throw")
        } catch IndexError.http(let code, let body) {
            XCTAssertEqual(code, 404)
            XCTAssertTrue(body.contains("no such playlist"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testAddWithNoTokenNeverLeaves() async {
        let rec = Recorder()
        rec.reply(200, "{}")
        let track = TrackRef(
            track_id: "t", source: "spotify", source_ref: "spotify:track:x",
            artist: "a", title: "b")
        do {
            _ = try await client(rec, token: nil)
                .addToPlaylist(id: "p1", track: PlaylistAddition(track: track))
            XCTFail("expected a throw")
        } catch IndexError.noToken {
            XCTAssertTrue(rec.requests.isEmpty)
        } catch { XCTFail("wrong error: \(error)") }
    }
}
