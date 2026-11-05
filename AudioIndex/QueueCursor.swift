import Foundation

/// Where we are in the queue atlas handed us. A plain value type with no
/// dependency on the SDK, a clock or the network, so the playback order can be
/// tested without any of them.
struct QueueCursor: Equatable {
    private(set) var tracks: [TrackRef]
    private(set) var index: Int

    init(tracks: [TrackRef] = []) {
        self.tracks = tracks
        self.index = 0
    }

    var current: TrackRef? {
        tracks.indices.contains(index) ? tracks[index] : nil
    }

    var isExhausted: Bool { current == nil }

    /// Move to the next track. Returns it, or nil if the queue just ran out.
    /// Clamps rather than running away: an exhausted cursor advanced again must
    /// stay exhausted, not walk further past the end.
    @discardableResult
    mutating func advance() -> TrackRef? {
        guard index < tracks.count else { return nil }
        index += 1
        return current
    }

    /// Replace the queue outright and rewind.
    ///
    /// Replace, never append: atlas has already excluded everything played
    /// inside the cooldown window, so a fresh queue is authoritative and
    /// concatenating would replay exactly what it deliberately left out.
    mutating func refill(with newTracks: [TrackRef]) {
        tracks = newTracks
        index = 0
    }
}
