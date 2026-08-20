import Foundation

/// A plain text log a person can find, open, and send to someone.
///
/// The system log already has everything, but it is not a file: reading it
/// takes a terminal and the right flags, and there is nothing to attach to a
/// message. Someone testing this app and hitting a slow dictation should be
/// able to open a folder and send what they see.
///
/// Off unless asked for. When off nothing is opened, nothing is written, and
/// no file exists — a log that appears without being asked for is a file
/// someone did not consent to.
///
/// Never contains dictated text. Numbers, stages and reasons only, exactly
/// like the system log line it mirrors. That is not a policy this class is
/// free to relax: it is written down in CLAUDE.md and checked in review.
final class DictationLogFile: @unchecked Sendable {
    static let shared = DictationLogFile()

    /// Where a person would look, and the same place Handy uses for its own.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/is.waiwai.dictation", directoryHint: .isDirectory)
    }

    /// One file per day. A single growing file is impossible to send once it is
    /// large, and rotating by size loses the day someone wants to talk about.
    private var currentURL: URL {
        let day = Self.dayFormatter.string(from: Date())
        return Self.directory.appending(path: "dictation-\(day).log", directoryHint: .notDirectory)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Set from the setting; read on every line so the switch takes effect at
    /// once rather than at the next launch.
    var isEnabled = false

    /// Its own queue: appending to a file is blocking work, and this app has
    /// spent a long time learning not to do that on the pool a dictation waits
    /// on. Logging that slows dictation would be a poor way to study why
    /// dictation is slow.
    private let queue = DispatchQueue(label: "is.waiwai.dictation.log-file", qos: .utility)

    func write(_ line: String) {
        guard isEnabled else { return }
        let stamped = "\(Self.stampFormatter.string(from: Date()))  \(line)\n"
        queue.async { [currentURL] in
            guard let data = stamped.data(using: .utf8) else { return }
            let manager = FileManager.default
            try? manager.createDirectory(
                at: Self.directory,
                withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: currentURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: currentURL, options: .atomic)
            }
        }
    }

    /// Delete every log this app has written.
    ///
    /// Offered because the person who turned this on should be able to take it
    /// back, and "off" that leaves files behind is not off.
    func removeAll() {
        queue.async {
            try? FileManager.default.removeItem(at: Self.directory)
        }
    }
}

extension Double {
    /// Short enough to read at a glance in a shared log.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

/// Lets one level update reach the main actor at a time.
///
/// The audio callback offers a peak per frame; the main actor consumes them.
/// Without this the callback queued about twenty hops a second for the whole
/// dictation, and the recognition path — which is main-actor bound — waited
/// behind them.
///
/// Dropping the ones that arrive while another is in flight costs nothing
/// visible: the waveform holds 24 samples and a screen cannot show more than
/// it is given.
final class LevelUpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    /// `true` if this caller may proceed.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }
}
