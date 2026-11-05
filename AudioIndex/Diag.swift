import Foundation

/// A breadcrumb log that survives a crash.
///
/// The App Remote failure this exists for kills the process with SIGTRAP and no
/// stderr, so `print` proves nothing: by the time the phone is back on a cable
/// the console output is gone. This appends to a file in Documents instead,
/// which can be pulled off the device afterwards with the Devices window or
/// `devicectl device copy from`.
///
/// Every operation is wrapped so a diagnostic can never itself be the thing
/// that crashes: a failed write is dropped silently rather than thrown.
enum Diag {

    /// Serial, so calls from the SDK's own queues cannot interleave a line.
    /// This is also why `log` is safe to call from any thread.
    private static let queue = DispatchQueue(label: "com.example.audioindex.diag")

    /// Above this the file is truncated to its most recent half, so a long
    /// session cannot fill the container.
    private static let maxBytes = 200 * 1024

    /// `nonisolated(unsafe)` is honest here rather than a suppression: the
    /// formatter is touched only from inside `queue`, which is serial, so there
    /// is no concurrent access for the compiler to protect against.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Where the log lives. Nil only if Documents cannot be resolved, in which
    /// case logging becomes a no-op rather than an error.
    static var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("diag.log")
    }

    /// Append one line. Safe from any thread; never throws, never traps.
    ///
    /// Only the timestamp is taken on the calling thread; everything else -
    /// formatting included - happens on `queue`, which is what makes the shared
    /// formatter safe.
    static func log(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) \(message)\n"
            #if DEBUG
                print("[Diag] \(line)", terminator: "")
            #endif
            write(line)
        }
    }

    // MARK: - Private

    private static func write(_ line: String) {
        guard let url = fileURL, let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }

        // `try?` throughout: a diagnostic that can crash is worthless.
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }

        truncateIfNeeded(url: url)
    }

    /// Drop the oldest half once the cap is passed. Whole-file rewrite because
    /// the cap is small enough that reading it back costs nothing, and it keeps
    /// the file a valid sequence of lines.
    private static func truncateIfNeeded(url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > maxBytes else { return }

        guard let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(maxBytes / 2)
        // Start at the first whole line so the file never opens mid-message.
        let newlineIndex = keep.firstIndex(of: UInt8(ascii: "\n"))
        let trimmed = newlineIndex.map { keep[keep.index(after: $0)...] } ?? keep
        try? Data(trimmed).write(to: url, options: .atomic)
    }
}
