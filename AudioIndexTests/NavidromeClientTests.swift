// AudioIndexTests/NavidromeClientTests.swift
import XCTest

@testable import AudioIndex

/// Answers with a canned reply per call and keeps the requests. Like
/// `IndexClientTests`'s recorder, this exists because the client takes its
/// transport as a closure - no network, no server, no URLProtocol.
private final class SubsonicRecorder: @unchecked Sendable {
    var requests: [URLRequest] = []
    /// Consumed front to back, so one test can script a multi-page walk. The
    /// last reply repeats if the client asks for more than were scripted.
    var replies: [(Int, String)] = []

    func send(_ r: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(r)
        let (status, body) = replies.count > 1 ? replies.removeFirst() : replies[0]
        let resp = HTTPURLResponse(
            url: r.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), resp)
    }

    var queries: [[String: String]] {
        requests.map { req in
            let items =
                URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, b in b }
        }
    }
}

final class NavidromeClientTests: XCTestCase {
    // Obviously fake, and nothing here ever reaches a server.
    private let creds = NavidromeCredentials(
        baseURL: URL(string: "http://music.example")!,
        username: "tester",
        password: "fake-password")

    private func client(
        _ rec: SubsonicRecorder, pageSize: Int = 500,
        salt: String = "s4lt"
    ) -> NavidromeClient {
        var c = NavidromeClient(credentials: { self.creds })
        c.pageSize = pageSize
        c.salt = { salt }
        c.transport = rec.send
        return c
    }

    private func songs(_ n: Int, from start: Int = 0) -> String {
        let rows = (start..<start + n).map {
            #"{"id":"s\#($0)","title":"t\#($0)","artist":"[Unknown Artist]","duration":10}"#
        }
        return #"{"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{"song":[\#(rows.joined(separator: ","))]}}}"#
    }

    // MARK: Auth

    // The salted form, not `p=`. A raw password in a query string is the one
    // part of a request that lands verbatim in server logs, proxy logs and
    // crash reports.
    //
    // The expected digest is hardcoded rather than computed with the same
    // helper under test - md5("fake-password" + "s4lt"), taken from `md5(1)`.
    func testSignsWithASaltedToken() throws {
        let url = try client(SubsonicRecorder(), salt: "s4lt").url("ping.view")
        let q = Dictionary(
            URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") }
        ) { _, b in b }

        XCTAssertEqual(q["u"], "tester")
        XCTAssertEqual(q["s"], "s4lt")
        XCTAssertEqual(q["t"], "e2425e602b1ce8bd1b1f4e24e6905af5")
        XCTAssertEqual(q["v"], "1.16.1")
        XCTAssertEqual(q["c"], "audioindex")
        XCTAssertEqual(q["f"], "json")
        XCTAssertEqual(url.path, "/rest/ping.view")
    }

    func testTheRawPasswordNeverAppearsInTheURL() throws {
        let url = try client(SubsonicRecorder()).url("ping.view")
        XCTAssertFalse(url.absoluteString.contains("fake-password"))
        XCTAssertNil(
            URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "p" })
    }

    // A fixed salt would make one captured token reusable forever.
    func testEachRequestGetsAFreshSalt() {
        let a = NavidromeClient.randomSalt()
        let b = NavidromeClient.randomSalt()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 6)
    }

    func testNoCredentialsFailsBeforeSending() async {
        let rec = SubsonicRecorder()
        rec.replies = [(200, "{}")]
        var c = NavidromeClient(credentials: { nil })
        c.transport = rec.send
        do {
            _ = try await c.ping()
            XCTFail("expected a throw")
        } catch NavidromeError.notConfigured {
            XCTAssertTrue(rec.requests.isEmpty)
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: Failure inside a 200

    // Subsonic answers a wrong password with HTTP 200 and "status":"failed".
    // Reading only the status line would hand back an empty library, which
    // looks exactly like a library that is genuinely empty - and the user would
    // go hunting for their missing files instead of their typo.
    func testFailedStatusInA200Throws() async {
        let rec = SubsonicRecorder()
        rec.replies = [(200, #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#)]
        do {
            _ = try await client(rec).allSongs()
            XCTFail("expected a throw")
        } catch NavidromeError.subsonic(let code, _) {
            XCTAssertEqual(code, 40)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testPingReturnsTrueOnOk() async throws {
        let rec = SubsonicRecorder()
        rec.replies = [(200, #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome"}}"#)]
        let ok = try await client(rec).ping()
        XCTAssertTrue(ok)
        XCTAssertEqual(rec.requests[0].url?.path, "/rest/ping.view")
    }

    func testHttpErrorSurfacesTheStatus() async {
        let rec = SubsonicRecorder()
        rec.replies = [(502, "bad gateway")]
        do {
            _ = try await client(rec).ping()
            XCTFail("expected a throw")
        } catch NavidromeError.http(let code, _) {
            XCTAssertEqual(code, 502)
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: Paging

    func testAShortPageEndsTheWalk() async throws {
        let rec = SubsonicRecorder()
        rec.replies = [(200, songs(2)), (200, songs(1, from: 2))]
        let out = try await client(rec, pageSize: 2).allSongs()

        XCTAssertEqual(out.map(\.id), ["s0", "s1", "s2"])
        XCTAssertEqual(rec.requests.count, 2)
        XCTAssertEqual(rec.queries[0]["songOffset"], "0")
        XCTAssertEqual(rec.queries[1]["songOffset"], "2")
        XCTAssertEqual(rec.queries[0]["songCount"], "2")
        XCTAssertEqual(rec.queries[0]["query"], "")
    }

    // A page exactly the size asked for could be the last one or could not be.
    // Stopping there would silently truncate a library at a round number.
    func testAFullPageContinuesTheWalk() async throws {
        let rec = SubsonicRecorder()
        rec.replies = [(200, songs(2)), (200, songs(2, from: 2)), (200, songs(0))]
        let out = try await client(rec, pageSize: 2).allSongs()

        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(rec.requests.count, 3)
        XCTAssertEqual(rec.queries[2]["songOffset"], "4")
    }

    // An empty library is `searchResult3` with no `song` key at all, not an
    // empty array.
    func testAnEmptyLibraryIsOnePageAndNoSongs() async throws {
        let rec = SubsonicRecorder()
        rec.replies = [(200, #"{"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{}}}"#)]
        let out = try await client(rec).allSongs()
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(rec.requests.count, 1)
    }

    // A server that ignored songOffset would otherwise return the same full
    // page forever, inside a call the UI is awaiting.
    func testMaxPagesStopsARunawayWalk() async throws {
        let rec = SubsonicRecorder()
        rec.replies = [(200, songs(2))]
        let out = try await client(rec, pageSize: 2).allSongs(maxPages: 3)
        XCTAssertEqual(rec.requests.count, 3)
        XCTAssertEqual(out.count, 6)
    }

    // MARK: Decoding

    /// Shaped like a real `search3.view` reply from Navidrome 0.63, extra keys
    /// and all - the point is that the unused ones are ignored rather than
    /// breaking the decode.
    func testDecodesARealShapedSearchResponse() async throws {
        let rec = SubsonicRecorder()
        rec.replies = [
            (
                200,
                """
                {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome",
                  "serverVersion":"0.63.2","openSubsonic":true,
                  "searchResult3":{"song":[
                    {"id":"al-0a1b","parent":"a1","isDir":false,
                     "title":"01 - Lumenfall - Harbor.mp3","album":"Unknown Album",
                     "artist":"[Unknown Artist]","track":1,"year":0,"genre":"","size":8123456,
                     "contentType":"audio/mpeg","suffix":"mp3","duration":247,"bitRate":320,
                     "path":"Unknown Artist/Unknown Album/01 - Lumenfall - Harbor.mp3",
                     "created":"2020-01-01T00:00:00Z","type":"music","isVideo":false}]}}}
                """
            )
        ]
        let out = try await client(rec).allSongs()

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "al-0a1b")
        XCTAssertEqual(out[0].title, "01 - Lumenfall - Harbor.mp3")
        XCTAssertEqual(out[0].artist, "[Unknown Artist]")
        XCTAssertEqual(out[0].album, "Unknown Album")
        XCTAssertEqual(out[0].duration, 247)
    }

    // MARK: Stream URL

    func testStreamURLIsSignedAndCarriesTheId() throws {
        let url = try client(SubsonicRecorder()).streamURL(for: "al-0a1b")
        XCTAssertEqual(url.path, "/rest/stream.view")
        let q = Dictionary(
            URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") }
        ) { _, b in b }
        XCTAssertEqual(q["id"], "al-0a1b")
        XCTAssertEqual(q["t"], "e2425e602b1ce8bd1b1f4e24e6905af5")
        XCTAssertFalse(url.absoluteString.contains("fake-password"))
    }
}

// MARK: - Mapping

final class NavidromeLibraryTests: XCTestCase {
    private func song(
        id: String = "s1", title: String = "A Song",
        artist: String? = "[Unknown Artist]", album: String? = "Unknown Album",
        duration: Int? = 247
    ) throws -> SubsonicSong {
        let json = """
            {"id":"\(id)","title":"\(title)",
             "artist":\(artist.map { "\"\($0)\"" } ?? "null"),
             "album":\(album.map { "\"\($0)\"" } ?? "null"),
             "duration":\(duration.map(String.init) ?? "null")}
            """
        return try JSONDecoder().decode(SubsonicSong.self, from: Data(json.utf8))
    }

    func testMapsOneSong() throws {
        let out = syncTracks(from: [try song()])
        XCTAssertEqual(
            out,
            [
                SyncTrack(
                    artist: "[Unknown Artist]", title: "A Song",
                    album: "Unknown Album", duration_ms: 247_000,
                    source: "file", source_ref: "navidrome:s1")
            ])
    }

    // Subsonic reports whole SECONDS; the index stores milliseconds. Getting
    // this backwards would put every local track at a quarter of a second and
    // make the ranking treat all of them as skips.
    func testSecondsBecomeMilliseconds() throws {
        XCTAssertEqual(syncTracks(from: [try song(duration: 90)]).first?.duration_ms, 90_000)
        XCTAssertEqual(syncTracks(from: [try song(duration: nil)]).first?.duration_ms, 0)
    }

    // The files on that server carry no ID3 tags and are not to be modified, so
    // "[Unknown Artist]" IS the truth about them. Cleaning it up here would
    // mint an identity the server can never reproduce.
    func testKeepsUnknownArtistVerbatim() throws {
        XCTAssertEqual(syncTracks(from: [try song()]).first?.artist, "[Unknown Artist]")
        XCTAssertEqual(syncTracks(from: [try song(artist: nil)]).first?.artist, "")
    }

    func testSourceIsFileAndTheRefIsPrefixed() throws {
        let track = syncTracks(from: [try song(id: "al-0a1b")]).first
        XCTAssertEqual(track?.source, "file")
        XCTAssertEqual(track?.source_ref, "navidrome:al-0a1b")
    }

    // No id is nothing to stream later; no title is nothing to identify it by,
    // and track_id is a hash of artist and title.
    func testSkipsSongsWithNoIdOrNoTitle() throws {
        let out = syncTracks(from: [
            try song(id: "", title: "Fine"),
            try song(id: "s2", title: ""),
            try song(id: "s3", title: "Kept"),
        ])
        XCTAssertEqual(out.map(\.source_ref), ["navidrome:s3"])
    }
}
