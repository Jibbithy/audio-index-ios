import Foundation

/// Where the current track is, as a value.
///
/// The SDK reports a position only when something CHANGES - there is no tick.
/// A progress bar driven straight off `playbackPosition` therefore freezes for
/// the length of a song. This carries the last reported position plus the
/// instant it was reported, so the bar can be interpolated forward from it
/// without anybody pretending the SDK is sending updates it is not.
struct PlaybackProgress: Equatable {
    /// Position the player last reported.
    var positionMs: Int
    /// Track length. Zero when unknown - the bar renders empty rather than
    /// dividing by it.
    var durationMs: Int
    var isPaused: Bool
    /// When `positionMs` was reported.
    var anchor: Date

    static let none = PlaybackProgress(
        positionMs: 0, durationMs: 0,
        isPaused: true, anchor: .distantPast)

    /// Position now, extrapolated. A paused track does not advance, and no
    /// track runs past its own end - both would otherwise let the bar overrun
    /// while the app is in the background.
    func estimatedMs(at now: Date) -> Int {
        guard !isPaused else { return clamped(positionMs) }
        let elapsed = max(0, Int(now.timeIntervalSince(anchor) * 1000))
        return clamped(positionMs + elapsed)
    }

    /// 0...1, for the bar. Zero-length tracks give 0, never NaN.
    func fraction(at now: Date) -> Double {
        guard durationMs > 0 else { return 0 }
        return Double(estimatedMs(at: now)) / Double(durationMs)
    }

    func remainingMs(at now: Date) -> Int {
        guard durationMs > 0 else { return 0 }
        return max(0, durationMs - estimatedMs(at: now))
    }

    private func clamped(_ ms: Int) -> Int {
        guard durationMs > 0 else { return max(0, ms) }
        return min(max(0, ms), durationMs)
    }
}

/// Milliseconds as `m:ss`, or `h:mm:ss` past an hour.
///
/// Truncates rather than rounds: a bar reading 3:00 while the track still has
/// 400ms to run is what every other player does, and rounding up would show a
/// time one second beyond the track's own length.
func clockString(_ ms: Int) -> String {
    let total = max(0, ms) / 1000
    let seconds = total % 60
    let minutes = (total / 60) % 60
    let hours = total / 3600
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}
