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
    static func text(for report: DictationSpeedReport) -> String {
        let phases = report.phases
        var parts = ["dictation", field("total", report.toRecognizedText)]
        parts.append(field("paste", report.toPasteDispatched))
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
        parts.append(field("audio", phases?.audioDuration))
        // How much of the take was already recognized before the key came up.
        // `0` is an ordinary answer: a short take has nothing to stream.
        parts.append("streamed=\(phases?.streamedSegments ?? 0)")
        return parts.joined(separator: " ")
    }

    private static func field(_ name: String, _ duration: Duration?) -> String {
        guard let duration else { return "\(name)=absent" }
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return "\(name)=\(String(format: "%.2f", seconds))s"
    }
}
