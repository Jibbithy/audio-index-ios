import XCTest

@testable import AudioIndex

/// The parts of artwork loading that can actually be wrong are all pure: which
/// refs have an id, how ids are grouped for the API's 50-per-call cap, which of
/// the sizes Spotify offers is picked, and whether a placeholder colour is
/// stable. None of them needs a network.
final class ArtworkTests: XCTestCase {

    // MARK: spotifyTrackID

    func testExtractsIDFromTrackURI() {
        XCTAssertEqual(
            spotifyTrackID(from: "spotify:track:4PTG3Z6ehGkBFwjybzWkR8"),
            "4PTG3Z6ehGkBFwjybzWkR8")
    }

    /// A saved local file, an episode and a playlist all reach this function in
    /// a real queue. Each must be a placeholder, not an id that 404s a batch.
    func testRejectsNonTrackRefs() {
        XCTAssertNil(spotifyTrackID(from: "spotify:local:::Tape 04:0"))
        XCTAssertNil(spotifyTrackID(from: "spotify:episode:abc123"))
        XCTAssertNil(spotifyTrackID(from: "spotify:user:me:playlist:abc"))
        XCTAssertNil(spotifyTrackID(from: "https://open.spotify.com/track/abc"))
        XCTAssertNil(spotifyTrackID(from: ""))
        XCTAssertNil(spotifyTrackID(from: "spotify:track:"))
    }

    // MARK: batched

    func testBatchesUpToFifty() {
        let ids = (0..<120).map(String.init)
        let batches = batched(ids, size: 50)
        XCTAssertEqual(batches.map(\.count), [50, 50, 20])
        XCTAssertEqual(batches.flatMap { $0 }, ids, "batching must not reorder or drop ids")
    }

    func testBatchExactlyFillsWithNoEmptyTail() {
        XCTAssertEqual(batched(Array(0..<100), size: 50).count, 2)
    }

    func testBatchingEmptyGivesNoCalls() {
        XCTAssertTrue(batched([Int](), size: 50).isEmpty)
    }

    /// A typical queue is twenty tracks: exactly ONE call, never twenty.
    func testTypicalQueueIsOneBatch() {
        XCTAssertEqual(batched(Array(0..<20), size: 50).count, 1)
    }

    // MARK: artworkURLs

    private func reply(_ json: String) throws -> TracksReply {
        try JSONDecoder().decode(TracksReply.self, from: Data(json.utf8))
    }

    func testPicksSmallestImageAtOrAboveTheTargetWidth() throws {
        let parsed = try reply(
            """
            {"tracks":[{"id":"a","album":{"images":[
              {"url":"https://i/640","width":640,"height":640},
              {"url":"https://i/300","width":300,"height":300},
              {"url":"https://i/64","width":64,"height":64}]}}]}
            """)
        XCTAssertEqual(
            artworkURLs(from: parsed, atLeast: 300)["a"],
            URL(string: "https://i/300"))
    }

    func testFallsBackToLargestWhenNothingIsBigEnough() throws {
        let parsed = try reply(
            """
            {"tracks":[{"id":"a","album":{"images":[
              {"url":"https://i/64","width":64,"height":64}]}}]}
            """)
        XCTAssertEqual(
            artworkURLs(from: parsed, atLeast: 300)["a"],
            URL(string: "https://i/64"))
    }

    /// Spotify returns a literal null in the slot of an id it does not know,
    /// rather than shortening the array. One dead id must not cost the batch.
    func testNullEntryDoesNotDiscardTheRestOfTheBatch() throws {
        let parsed = try reply(
            """
            {"tracks":[null,{"id":"b","album":{"images":[
              {"url":"https://i/300","width":300,"height":300}]}},null]}
            """)
        let urls = artworkURLs(from: parsed)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls["b"], URL(string: "https://i/300"))
    }

    func testTrackWithNoImagesIsSimplyAbsent() throws {
        let parsed = try reply(
            """
            {"tracks":[{"id":"a","album":{"images":[]}},{"id":"b"}]}
            """)
        XCTAssertTrue(artworkURLs(from: parsed).isEmpty)
    }

    // MARK: artworkSeed

    /// The placeholder colour must be a property of the track, not of the
    /// launch. `String.hashValue` is seeded per process and would repaint every
    /// row a different colour on each start.
    func testSeedIsStableForTheSameRef() {
        XCTAssertEqual(
            artworkSeed(for: "spotify:track:abc"),
            artworkSeed(for: "spotify:track:abc"))
        XCTAssertNotEqual(
            artworkSeed(for: "spotify:track:abc"),
            artworkSeed(for: "spotify:track:abd"))
    }

    // MARK: ArtworkStore

    /// The whole point of the batching: a queue of twenty rows is ONE request,
    /// not twenty. A regression here is invisible on wifi and ruinous on a
    /// tailnet.
    @MainActor
    func testWholeQueueIsFetchedInOneRequest() async {
        let recorder = RequestRecorder(body: #"{"tracks":[]}"#)
        let store = ArtworkStore()
        store.transport = recorder.transport

        let refs = (0..<20).map { "spotify:track:id\($0)" }
        await store.load(refs: refs, accessToken: "tok")

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(
            Set(recorder.idsParameter(0) ?? []).count, 20,
            "every id must be in the one call")
    }

    /// A second load of the same queue - the user reloading, or the view
    /// re-appearing - must not re-ask for art already known or already refused.
    @MainActor
    func testAlreadyRequestedIDsAreNotRefetched() async {
        let recorder = RequestRecorder(body: #"{"tracks":[]}"#)
        let store = ArtworkStore()
        store.transport = recorder.transport

        await store.load(refs: ["spotify:track:a"], accessToken: "tok")
        await store.load(refs: ["spotify:track:a"], accessToken: "tok")
        XCTAssertEqual(recorder.requests.count, 1)

        await store.load(refs: ["spotify:track:a", "spotify:track:b"], accessToken: "tok")
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.idsParameter(1), ["b"], "only the new id is asked for")
    }

    /// No Spotify session means no Web API call at all - not a call that comes
    /// back 401 and burns those ids for the rest of the launch.
    @MainActor
    func testNoAccessTokenMakesNoRequest() async {
        let recorder = RequestRecorder(body: #"{"tracks":[]}"#)
        let store = ArtworkStore()
        store.transport = recorder.transport
        await store.load(refs: ["spotify:track:a"], accessToken: nil)
        await store.load(refs: ["spotify:track:a"], accessToken: "")
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    /// A queue of only local files has nothing to ask about.
    @MainActor
    func testRefsWithNoTrackIDMakeNoRequest() async {
        let recorder = RequestRecorder(body: #"{"tracks":[]}"#)
        let store = ArtworkStore()
        store.transport = recorder.transport
        await store.load(refs: ["spotify:local:::x:0"], accessToken: "tok")
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertNil(store.url(for: "spotify:local:::x:0"))
    }

    /// An HTTP failure is swallowed: artwork is decoration, and a red banner
    /// about a JPEG would sit next to the atlas error the user must act on.
    @MainActor
    func testFailedFetchLeavesNoURLAndDoesNotThrow() async {
        let recorder = RequestRecorder(body: "nope", status: 500)
        let store = ArtworkStore()
        store.transport = recorder.transport
        await store.load(refs: ["spotify:track:a"], accessToken: "tok")
        XCTAssertNil(store.url(for: "spotify:track:a"))
    }

    @MainActor
    func testSuccessfulFetchIsLookedUpByRef() async {
        let json =
            #"{"tracks":[{"id":"a","album":{"images":"#
            + #"[{"url":"https://i/300","width":300,"height":300}]}}]}"#
        let recorder = RequestRecorder(body: json)
        let store = ArtworkStore()
        store.transport = recorder.transport
        await store.load(refs: ["spotify:track:a"], accessToken: "tok")
        XCTAssertEqual(store.url(for: "spotify:track:a"), URL(string: "https://i/300"))
    }

    /// The token rides in the header, never in the query string - a URL with a
    /// bearer token in it lands in logs and crash reports.
    @MainActor
    func testTokenIsSentAsABearerHeader() async {
        let recorder = RequestRecorder(body: #"{"tracks":[]}"#)
        let store = ArtworkStore()
        store.transport = recorder.transport
        await store.load(refs: ["spotify:track:a"], accessToken: "tok")
        XCTAssertEqual(
            recorder.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok")
        XCTAssertFalse(recorder.requests.first?.url?.absoluteString.contains("tok") ?? true)
    }
}

/// Records what `ArtworkStore` sent and replies with a canned body.
private final class RequestRecorder: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private let body: String
    private let status: Int

    init(body: String, status: Int = 200) {
        self.body = body
        self.status = status
    }

    func transport(_ req: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(req)
        let resp = HTTPURLResponse(
            url: req.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), resp)
    }

    /// The comma-separated `ids` of request `index`.
    func idsParameter(_ index: Int) -> [String]? {
        guard requests.indices.contains(index), let url = requests[index].url,
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let value = comps.queryItems?.first(where: { $0.name == "ids" })?.value
        else { return nil }
        return value.split(separator: ",").map(String.init)
    }
}
