import DictationCore
import Foundation

/// The one place a dictation's numbers are turned into text.
///
/// Two emitters existed briefly — the system log and the shareable file — with
/// their own formats, which is two parsers to keep correct and two chances for
/// one of them to be quietly wrong. There has already been a parser in this
/// repository reading the word "path" as a duration.
///
/// `key=value`, always, including for stages that did not run: `absent` says so
/// outright, because a stage nobody measured must never read as `0.00`.
enum DictationSpeedLine {
    static func text(for report: DictationSpeedReport, paging: TakePaging? = nil) -> String {
        let phases = report.phases
        var parts = ["dictation", field("total", report.toRecognizedText)]
        parts.append(field("paste", report.toPasteDispatched))
        // When the target read the paste. Earlier than `paste` means something
        // else read the dictation first.
        parts.append(field("read", report.toFirstRead))
        // Capture accepted the start → first committed frame. Not key-down →
        // speech: the device's own ~180 ms warm-up comes after it. An I/O
        // proc leaves no AUHAL lines in the system log, so this is where the
        // microphone start can still be read after a release.
        parts.append(field("mic", report.microphoneStartup))
        parts.append(field("freeze", phases?.captureFreeze))
        parts.append(field("prepare", phases?.enginePreparation))
        parts.append(field("recognize", phases?.recognition))
        // Which branch the take took. Without it a zero cannot be told from a
        // measurement of code that never ran — the mistake that cost four
        // rounds of this investigation.
        parts.append("path=" + (phases?.recordingReadable == nil ? "memory" : "file"))
        parts.append(field("readable", phases?.recordingReadable))
        parts.append(field("decode", phases?.audioDecoding))
        // Reaching the engine, engine time removed. A large number here means
        // the take was waiting to run rather than running.
        // Split, because the two halves need different fixes.
        parts.append(field("handover", phases?.executorHandover))
        parts.append(field("transport", phases?.engineTransport))
        parts.append(field("poolreturn", phases?.poolReturn))
        parts.append(field("mainreturn", phases?.mainActorReturn))
        parts.append(field("enginedispatch", phases?.engineDispatch))
        if let frameWasMain = phases?.returnFrameWasMainThread {
            parts.append("frame=" + (frameWasMain ? "main" : "pool"))
        } else {
            parts.append("frame=absent")
        }
        parts.append(field("queued", phases?.engineQueueing))
        parts.append(field("engine", phases?.engineProcessing))
        // The tail above, plus the pieces recognized while the person spoke.
        parts.append(field("enginetotal", phases?.engineProcessingTotal))
        parts.append(field("audio", phases?.audioDuration))
        // How much of the take was already recognized before the key came up.
        // `0` is an ordinary answer: a short take has nothing to stream.
        parts.append("streamed=\(phases?.streamedSegments ?? 0)")
        // Device cycles the capture never received: audio no take contains.
        parts.append(field("lost", phases?.lostAudio))
        // Hundreds of megabytes here, after a long `idle`, is an engine paged
        // back in from swap; a few is an engine that was resident.
        parts.append(paging?.diskReadBytes.map { "diskread=" + String(format: "%.1fMB", Double($0) / 1e6) }
            ?? "diskread=absent")
        parts.append(paging?.engineIdle.map { "idle=\(Int($0.components.seconds))s" } ?? "idle=absent")
        return parts.joined(separator: " ")
    }

    private static func field(_ name: String, _ duration: Duration?) -> String {
        guard let duration else { return "\(name)=absent" }
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return "\(name)=\(String(format: "%.2f", seconds))s"
    }
}

/// Whether a take had to page the engine back in.
///
/// Neither number is a duration. Without them, a take whose weights came back
/// from swap read as a slow engine and nothing more — or, when a piece
/// recognized during speech paid for it, as no engine at all.
struct TakePaging: Equatable {
    /// What this process read from disk between key-down and the text.
    var diskReadBytes: UInt64?
    /// How long the engine had gone without running when the key went down.
    var engineIdle: Duration?
}
