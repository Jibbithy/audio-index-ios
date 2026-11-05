import XCTest

@testable import AudioIndex

/// Scripted replies for `SpotifyWebAPI.transport`, plus the requests it made.
/// A class because the transport closure has to mutate state across calls.
private final class Responder {
    var replies: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [(Int, String)]) { self.replies = replies }

    func transport(_ req: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(req)
        guard !replies.isEmpty else {
            XCTFail("transport called more times than the test scripted")
            return (Data(), URLResponse())
        }
        let (code, body) = replies.removeFirst()
        let resp = HTTPURLResponse(
            url: req.url!, statusCode: code,
            httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), resp)
    }
}

private func page(_ uri: String, next: String?) -> String {
    let nextField = next.map { "\"\($0)\"" } ?? "null"
    return """
        {"items":[{"track":{"uri":"\(uri)","name":"\(uri)","duration_ms":1000,
          "artists":[{"name":"A"}],"album":{"name":"B"}}}],"next":\(nextField)}
        """
}

final class SpotifyWebAPITests: XCTestCase {

    func testFollowsTheNextURLToExhaustion() async throws {
        let r = Responder([
            (200, page("spotify:track:1", next: "https://api.spotify.com/v1/me/tracks?offset=50&limit=50")),
            (200, page("spotify:track:2", next: nil)),
        ])
        var api = SpotifyWebAPI()
        api.transport = r.transport

        let out = try await api.savedTracks(accessToken: "t")

        XCTAssertEqual(out.map(\.source_ref), ["spotify:track:1", "spotify:track:2"])
        XCTAssertEqual(r.requests.count, 2)
        XCTAssertEqual(r.requests[0].url?.absoluteString, SpotifyWebAPI.firstPage)
        XCTAssertEqual(
            r.requests[1].url?.absoluteString,
            "https://api.spotify.com/v1/me/tracks?offset=50&limit=50")
    }

    func testSendsTheBearerTokenOnEveryPage() async throws {
        let r = Responder([
            (200, page("spotify:track:1", next: "https://api.spotify.com/v1/me/tracks?offset=50&limit=50")),
            (200, page("spotify:track:2", next: nil)),
        ])
        var api = SpotifyWebAPI()
        api.transport = r.transport

        _ = try await api.savedTracks(accessToken: "abc")

        for req in r.requests {
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        }
    }

    // A 401 here means the Spotify session expired, not that atlas rejected us.
    // Surfacing it as its own error is what keeps the UI from telling the user
    // to re-paste an atlas token that is perfectly fine.
    func testUnauthorizedIsItsOwnError() async {
        let r = Responder([(401, "{}")])
        var api = SpotifyWebAPI()
        api.transport = r.transport

        do {
            _ = try await api.savedTracks(accessToken: "stale")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? SpotifyAPIError, .unauthorized)
        }
    }

    func testNonSuccessStatusThrowsWithTheBody() async {
        let r = Responder([(500, "boom")])
        var api = SpotifyWebAPI()
        api.transport = r.transport

        do {
            _ = try await api.savedTracks(accessToken: "t")
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? SpotifyAPIError, .http(500, "boom"))
        }
    }

    // A `next` pointing back at a page already fetched would otherwise spin
    // forever inside a call the UI is awaiting - no error, no way out.
    func testASelfReferentialNextStopsInsteadOfLooping() async throws {
        let selfLink = SpotifyWebAPI.firstPage
        let r = Responder([(200, page("spotify:track:1", next: selfLink))])
        var api = SpotifyWebAPI()
        api.transport = r.transport

        let out = try await api.savedTracks(accessToken: "t")

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(r.requests.count, 1)
    }

    func testStopsAtMaxPages() async throws {
        let links = (0..<5).map { "https://api.spotify.com/v1/me/tracks?offset=\($0)&limit=50" }
        let r = Responder(links.map { (200, page("spotify:track:x", next: $0)) })
        var api = SpotifyWebAPI()
        api.transport = r.transport

        let out = try await api.savedTracks(accessToken: "t", maxPages: 2)

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(r.requests.count, 2)
    }

    // Unplayable rows are dropped by syncTracks(from:) mid-walk, not after -
    // a page of nothing but local files must not end the paging early.
    func testAPageThatMapsToNothingDoesNotStopThePaging() async throws {
        let empty = """
            {"items":[{"track":{"uri":null,"name":"Local","duration_ms":1,
              "artists":[{"name":"A"}],"album":{"name":"B"}}}],
             "next":"https://api.spotify.com/v1/me/tracks?offset=50&limit=50"}
            """
        let r = Responder([
            (200, empty),
            (200, page("spotify:track:2", next: nil)),
        ])
        var api = SpotifyWebAPI()
        api.transport = r.transport

        let out = try await api.savedTracks(accessToken: "t")

        XCTAssertEqual(out.map(\.source_ref), ["spotify:track:2"])
    }
}
