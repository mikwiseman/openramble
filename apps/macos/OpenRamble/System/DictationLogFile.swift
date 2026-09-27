import Foundation

/// An allowlist, not a free-text logger. No user content can be passed here.
enum DiagnosticEvent: String, Codable, Sendable {
    case appLaunched, appTerminating, appTerminationReady
    case dictationIdle, dictationPreparing, dictationListening, dictationTranscribing, dictationInserting
    case dictationCompleted, dictationWarning, dictationFailed, transcriptionStalled
    case enginePreparing, engineReady, engineUnavailable, engineFailed
    case audioConfigurationChanged, audioCaptureFailed
    case recordingIdle, recordingStarting, recordingActive, recordingPaused, recordingStopping, recordingFailed
    case cameraChanging, cameraChanged, cameraFailed, cameraEnabled, cameraDisabled
    case screenSetupOpened, screenSetupClosed, systemSleeping, systemWoke
}

/// Local support history: at most seven UTC dates and 5 MB in total.
/// A serial utility queue keeps disk I/O off the audio and UI threads. Closing
/// each append makes completed writes survive a process crash; no signal handler.
final class DictationLogFile: @unchecked Sendable {
    struct Entry: Codable, Sendable {
        let time: Date
        let event: DiagnosticEvent
        let version: String
        let build: String
        let milliseconds: Int?
        let errorCode: Int?
    }

    let directory: URL
    private let maxBytes: Int
    private let version: String
    private let build: String
    private let queue = DispatchQueue(label: "is.waiwai.dictation.support-log", qos: .utility)
    private var enabled: Bool
    private var writeFailed = false

    init(directory: URL, enabled: Bool, maxBytes: Int = 5_000_000,
         version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
         build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown") {
        self.directory = directory
        self.enabled = enabled
        self.maxBytes = maxBytes
        self.version = Self.safeVersion(version)
        self.build = Self.safeVersion(build)
        queue.async { self.maintain(at: Date()) }
    }

    func flush() { queue.sync {} }

    var isEnabled: Bool {
        get { queue.sync { enabled } }
        set {
            queue.sync {
                enabled = newValue
                // Turning the existing switch off also clears the local history.
                if !newValue { clear() }
            }
        }
    }

    func record(_ event: DiagnosticEvent, milliseconds: Int? = nil, errorCode: Int? = nil, at time: Date = Date()) {
        queue.async {
            guard self.enabled else { return }
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                let entry = Entry(time: time, event: event, version: self.version, build: self.build,
                                  milliseconds: milliseconds, errorCode: errorCode)
                var data = try Self.encoder().encode(entry)
                data.append(10)
                let url = self.directory.appending(path: "events-\(Self.day(time)).jsonl")
                if !manager.fileExists(atPath: url.path) {
                    try data.write(to: url, options: .withoutOverwriting)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } else {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        self.writeFailed = true
                        return
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
                self.maintain(at: time)
            } catch { self.writeFailed = true }
        }
    }

    /// A queue barrier for export and normal termination. Invalid/truncated
    /// lines are skipped and unknown JSON fields are never copied to the ZIP.
    func snapshot(at now: Date = Date()) -> (data: Data, enabled: Bool, incomplete: Bool) {
        queue.sync {
            maintain(at: now)
            var output = Data()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for url in files() {
                guard let data = FileManager.default.contents(atPath: url.path) else { writeFailed = true; continue }
                for line in data.split(separator: 10) {
                    guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                          entry.time <= now, entry.time > now.addingTimeInterval(-7 * 86400),
                          entry.version == Self.safeVersion(entry.version), entry.build == Self.safeVersion(entry.build),
                          let safe = try? Self.encoder().encode(entry) else { writeFailed = true; continue }
                    output.append(safe)
                    output.append(10)
                }
            }
            return (output, enabled, writeFailed)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func safeVersion(_ value: String) -> String {
        value.range(of: #"^[0-9A-Za-z.-]{1,32}$"#, options: .regularExpression) != nil ? value : "unknown"
    }

    private static func day(_ date: Date) -> String {
        String(ISO8601DateFormatter().string(from: date).prefix(10))
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? [])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values?.isRegularFile == true && values?.isSymbolicLink != true
                    && $0.lastPathComponent.range(of: #"^events-\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func clear() {
        for file in files() { do { try FileManager.default.removeItem(at: file) } catch { writeFailed = true } }
    }

    private func maintain(at now: Date) {
        guard enabled else { clear(); return }
        let oldest = "events-\(Self.day(now.addingTimeInterval(-6 * 86400))).jsonl"
        do {
            for file in files() where file.lastPathComponent < oldest {
                try FileManager.default.removeItem(at: file)
            }
            // Keep complete newest lines, even if a single day exceeds the limit.
            var remaining = maxBytes
            for file in files().reversed() {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if size <= remaining { remaining -= size; continue }
                if remaining <= 0 { try FileManager.default.removeItem(at: file); continue }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(size - remaining))
                let tail = try handle.readToEnd() ?? Data()
                let kept = tail.firstIndex(of: 10).map { Data(tail.suffix(from: $0 + 1)) } ?? Data()
                try kept.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                remaining = 0
            }
        } catch { writeFailed = true }
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
