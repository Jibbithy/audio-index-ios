import XCTest

@testable import AudioIndex

private func scrobble(_ ref: String) -> Scrobble {
    Scrobble(
        source: "spotify", source_ref: ref, artist: "a", title: "b",
        played_at: 1, ms_played: 2, context: "queue")
}

final class ScrobbleBufferTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testStartsEmptyWhenNoFileExists() {
        XCTAssertTrue(ScrobbleBuffer(url: url).pending.isEmpty)
    }

    func testAppendPersistsAcrossInstances() {
        let a = ScrobbleBuffer(url: url)
        a.append(scrobble("r1"))
        XCTAssertEqual(ScrobbleBuffer(url: url).pending.map(\.source_ref), ["r1"])
    }

    func testDrainSendsEachAndEmptiesOnSuccess() async {
        let b = ScrobbleBuffer(url: url)
        b.append(scrobble("r1"))
        b.append(scrobble("r2"))
        var sent: [String] = []
        await b.drain { sent.append($0.source_ref) }
        XCTAssertEqual(sent, ["r1", "r2"])
        XCTAssertTrue(b.pending.isEmpty)
        XCTAssertTrue(ScrobbleBuffer(url: url).pending.isEmpty)
    }

    // A failing send must LEAVE the entry queued. Dropping it would lose the
    // play permanently, which is the exact failure this buffer exists to stop.
    func testAFailedSendKeepsTheEntry() async {
        let b = ScrobbleBuffer(url: url)
        b.append(scrobble("r1"))
        await b.drain { _ in throw IndexError.unauthorized }
        XCTAssertEqual(b.pending.map(\.source_ref), ["r1"])
        XCTAssertEqual(ScrobbleBuffer(url: url).pending.map(\.source_ref), ["r1"])
    }

    // One bad entry must not block the ones behind it forever.
    func testAPartialFailureKeepsOnlyTheFailures() async {
        let b = ScrobbleBuffer(url: url)
        b.append(scrobble("bad"))
        b.append(scrobble("good"))
        await b.drain { s in if s.source_ref == "bad" { throw IndexError.unauthorized } }
        XCTAssertEqual(b.pending.map(\.source_ref), ["bad"])
    }

    // Unbounded growth on a long offline stretch would eventually be a problem;
    // the oldest plays are the least valuable, so they go first.
    func testCapsAtTheLimitAndDropsOldestFirst() {
        let b = ScrobbleBuffer(url: url, limit: 3)
        for i in 1...5 { b.append(scrobble("r\(i)")) }
        XCTAssertEqual(b.pending.map(\.source_ref), ["r3", "r4", "r5"])
    }

    func testCorruptFileIsTreatedAsEmptyRatherThanCrashing() {
        try! Data("not json".utf8).write(to: url)
        XCTAssertTrue(ScrobbleBuffer(url: url).pending.isEmpty)
    }
}
