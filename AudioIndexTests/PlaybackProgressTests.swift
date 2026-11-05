import XCTest

@testable import AudioIndex

/// App Remote reports a playback position only when something CHANGES, so the
/// progress bar is extrapolated between reports. These are the rules for that
/// extrapolation - the place a progress bar most easily lies.
final class PlaybackProgressTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_000)

    private func progress(position: Int, duration: Int, paused: Bool) -> PlaybackProgress {
        PlaybackProgress(
            positionMs: position, durationMs: duration,
            isPaused: paused, anchor: anchor)
    }

    func testPlayingAdvancesWithWallClock() {
        let p = progress(position: 10_000, duration: 200_000, paused: false)
        XCTAssertEqual(p.estimatedMs(at: anchor.addingTimeInterval(5)), 15_000)
    }

    /// A paused track that kept advancing would run the bar off the end while
    /// the phone sat in a pocket.
    func testPausedDoesNotAdvance() {
        let p = progress(position: 10_000, duration: 200_000, paused: true)
        XCTAssertEqual(p.estimatedMs(at: anchor.addingTimeInterval(600)), 10_000)
    }

    /// The app can be backgrounded for longer than the track. The bar clamps at
    /// the end rather than reporting a position past the duration.
    func testNeverRunsPastTheEnd() {
        let p = progress(position: 190_000, duration: 200_000, paused: false)
        XCTAssertEqual(p.estimatedMs(at: anchor.addingTimeInterval(600)), 200_000)
        XCTAssertEqual(p.remainingMs(at: anchor.addingTimeInterval(600)), 0)
        XCTAssertEqual(p.fraction(at: anchor.addingTimeInterval(600)), 1)
    }

    /// An unknown duration is the state at launch, before any player state has
    /// arrived. It must give 0, not NaN - a NaN width crashes layout.
    func testUnknownDurationGivesZeroFractionNotNaN() {
        let p = progress(position: 5_000, duration: 0, paused: false)
        XCTAssertEqual(p.fraction(at: anchor.addingTimeInterval(10)), 0)
        XCTAssertEqual(p.remainingMs(at: anchor.addingTimeInterval(10)), 0)
        XCTAssertEqual(PlaybackProgress.none.fraction(at: Date()), 0)
    }

    /// A clock jump backwards (NTP, timezone edit) must not produce a negative
    /// position and a bar drawn to the left of its own track.
    func testClockGoingBackwardsDoesNotRewind() {
        let p = progress(position: 10_000, duration: 200_000, paused: false)
        XCTAssertEqual(p.estimatedMs(at: anchor.addingTimeInterval(-30)), 10_000)
    }

    func testFractionIsPositionOverDuration() {
        let p = progress(position: 50_000, duration: 200_000, paused: true)
        XCTAssertEqual(p.fraction(at: anchor), 0.25, accuracy: 0.0001)
    }

    // MARK: clockString

    func testClockFormatsMinutesAndSeconds() {
        XCTAssertEqual(clockString(0), "0:00")
        XCTAssertEqual(clockString(7_000), "0:07")
        XCTAssertEqual(clockString(67_000), "1:07")
        XCTAssertEqual(clockString(187_000), "3:07")
    }

    /// Truncates. A track with 400ms to run still reads its full length, never
    /// one second more than it has.
    func testClockTruncatesRatherThanRounds() {
        XCTAssertEqual(clockString(59_900), "0:59")
    }

    func testClockGrowsAnHoursFieldForLongEpisodes() {
        XCTAssertEqual(clockString(3_723_000), "1:02:03")
    }

    func testClockNeverShowsANegativeTime() {
        XCTAssertEqual(clockString(-5_000), "0:00")
    }
}
