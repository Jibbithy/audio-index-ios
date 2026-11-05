import Foundation

/// A durable retry queue for plays that failed to reach atlas.
///
/// Its whole reason to exist: losing a play to a dropped tailnet connection
/// quietly corrupts the ranking this entire system is built to produce, and
/// nothing else would notice - there is no error dialog for a background
/// scrobble. So a failed send KEEPS the entry, on disk, instead of dropping
/// it, and `drain` gets another chance at it on the next launch.
final class ScrobbleBuffer {
    private let url: URL
    private let limit: Int
    private(set) var pending: [Scrobble]

    /// Loads whatever is at `url`. A missing file and a corrupt file are both
    /// treated as an empty buffer - never a crash. The file simply not
    /// existing yet (first launch) is not an error, and a half-written or
    /// otherwise unreadable file is not worth losing the app over either;
    /// the worst case is the buffered plays it held are gone, not that the
    /// app won't start.
    init(url: URL, limit: Int = 500) {
        self.url = url
        self.limit = limit
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([Scrobble].self, from: data)
        {
            self.pending = decoded
        } else {
            self.pending = []
        }
    }

    /// Add a play and persist immediately - the whole point is surviving a
    /// crash or a kill between the play ending and the next successful drain.
    ///
    /// Trims from the FRONT when over `limit`: the oldest plays are the least
    /// valuable to the ranking, so on a long offline stretch they are the
    /// ones to drop.
    func append(_ scrobble: Scrobble) {
        pending.append(scrobble)
        if pending.count > limit {
            pending.removeFirst(pending.count - limit)
        }
        save()
    }

    /// Attempt to send every pending entry, in order. Keeps only the ones
    /// that threw, so one bad entry never blocks the ones behind it, and
    /// persists whatever remains.
    func drain(_ send: (Scrobble) async throws -> Void) async {
        var stillPending: [Scrobble] = []
        for scrobble in pending {
            do {
                try await send(scrobble)
            } catch {
                stillPending.append(scrobble)
            }
        }
        pending = stillPending
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
