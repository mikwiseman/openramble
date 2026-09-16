import Darwin
import DictationCore
import Foundation

public enum TranscriptFormat: String, Sendable, CaseIterable {
    case txt, json, srt, vtt

    public func render(_ transcript: FileTranscript) throws -> Data {
        switch self {
        case .txt: return Data((transcript.text + "\n").utf8)
        case .json:
            let words: [[String: Any]] = transcript.words.map { word in
                var row: [String: Any] = ["text": word.text, "start": word.start, "end": word.end]
                if let confidence = word.confidence { row["confidence"] = confidence }
                return row
            }
            var data = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "text": transcript.text, "duration": transcript.duration, "words": words,
            ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0a)
            return data
        case .srt, .vtt:
            var groups: [[ASRResult.Word]] = []
            var current: [ASRResult.Word] = []
            var characters = 0
            for word in transcript.words {
                if let first = current.first, let last = current.last,
                   characters + word.text.count + 1 > 84 || word.end - first.start > 6
                    || word.start - last.end > 0.8 {
                    groups.append(current)
                    current = []
                    characters = 0
                }
                current.append(word)
                characters += word.text.count + 1
            }
            if !current.isEmpty { groups.append(current) }
            var output = self == .vtt ? "WEBVTT\n\n" : ""
            for (index, group) in groups.enumerated() {
                guard let first = group.first, let last = group.last, transcript.duration >= 0.001 else { continue }
                let start = min(first.start, max(0, transcript.duration - 0.001))
                let next = index + 1 < groups.count ? groups[index + 1][0].start : transcript.duration
                let end = min(transcript.duration, max(start + 0.001, min(next, max(last.end, last.start + 0.08))))
                if self == .srt { output += "\(index + 1)\n" }
                output += "\(stamp(start)) --> \(stamp(end))\n"
                var lines: [String] = []
                var line = ""
                for word in group {
                    if !line.isEmpty, line.count + word.text.count + 1 > 42 {
                        lines.append(line)
                        line = ""
                    }
                    if !line.isEmpty { line += " " }
                    line += word.text
                }
                if !line.isEmpty { lines.append(line) }
                output += lines.joined(separator: "\n") + "\n\n"
            }
            return Data(output.utf8)
        }
    }

    private func stamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded(.down)))
        return String(format: "%02d:%02d:%02d%@%03d", milliseconds / 3_600_000,
                      milliseconds / 60_000 % 60, milliseconds / 1000 % 60,
                      self == .srt ? "," : ".", milliseconds % 1000)
    }

    /// Publish only a completed transcript. RENAME_EXCL atomically refuses an
    /// existing destination, including one created after the CLI's preflight.
    public func write(_ transcript: FileTranscript, to destination: URL) throws {
        let data = try render(transcript)
        let temporary = destination.deletingLastPathComponent().appending(path: ".openramble-\(UUID()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.close()
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
