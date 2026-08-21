import DictationCore
import Darwin
import Foundation
import os

/// A durable, per-take record of where a dictation's time went — and of what
/// the machine was doing around it.
///
/// This exists because the shipping signal is not enough to diagnose the
/// symptom it is aimed at. `os_log` on this Mac rotates `info` entries within
/// hours, so a rare slow take is already unreadable by the time it is
/// reported; and a single "stop → text" number cannot separate a cold model
/// from a resident model whose pages the system reclaimed between two takes.
/// The first needs durability, the second needs page-fault counters.
///
/// **It is compiled only into a diagnostics build.** Public releases are built
/// without `OPENRAMBLE_DIAGNOSTICS`, every entry point below is an empty
/// inlined no-op there, and `scripts/check-diagnostics-surface.sh` fails the
/// release if the marker reaches an artifact. See `docs/diagnostics.md`.
///
/// Privacy is not relaxed for diagnostics: no dictated text, no words, no user
/// file names, no audio ever reach this record. Durations, counters, and
/// lengths only — the same rule the rest of the product follows.
enum DictationDiagnostics {
    #if OPENRAMBLE_DIAGNOSTICS
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    /// The person stopped speaking. Samples the machine before the take's
    /// remaining work runs, so the closing sample can be differenced against it.
    @MainActor
    static func noteStop(
        engineWasReady: Bool,
        unloadPolicy: IdleUnloadPolicy
    ) {
        #if OPENRAMBLE_DIAGNOSTICS
        pendingStop = PendingStop(
            engineWasReady: engineWasReady,
            unloadPolicy: unloadPolicy.rawValue,
            sample: MachineSample.current()
        )
        #endif
    }

    /// The text landed. Closes the record opened at stop and writes it out.
    ///
    /// `characterCount` is a length, never content.
    @MainActor
    static func noteCompleted(
        report: DictationSpeedReport,
        characterCount: Int
    ) {
        #if OPENRAMBLE_DIAGNOSTICS
        guard let opened = pendingStop else { return }
        pendingStop = nil
        let closing = MachineSample.current()
        let record = Record(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            engineWasReady: opened.engineWasReady,
            unloadPolicy: opened.unloadPolicy,
            characterCount: characterCount,
            audioSeconds: report.phases?.audioDuration.diagnosticSeconds,
            stopToTextSeconds: report.toRecognizedText.diagnosticSeconds,
            stopToPasteSeconds: report.toPasteDispatched?.diagnosticSeconds,
            microphoneStartupSeconds: report.microphoneStartup?.diagnosticSeconds,
            captureFreezeSeconds: report.phases?.captureFreeze.diagnosticSeconds,
            enginePreparationSeconds: report.phases?.enginePreparation?.diagnosticSeconds,
            recognitionSeconds: report.phases?.recognition.diagnosticSeconds,
            engineProcessingSeconds: report.phases?.engineProcessing?.diagnosticSeconds,
            engineDispatchSeconds: report.phases?.engineDispatch?.diagnosticSeconds,
            poolReturnSeconds: report.phases?.poolReturn?.diagnosticSeconds,
            mainActorReturnSeconds: report.phases?.mainActorReturn?.diagnosticSeconds,
            machineAtStop: opened.sample,
            machineAtText: closing,
            delta: MachineDelta(from: opened.sample, to: closing)
        )
        write(record)
        #endif
    }

    #if OPENRAMBLE_DIAGNOSTICS

    private static let log = Logger(subsystem: "is.waiwai.dictation", category: "diagnostics")

    private struct PendingStop {
        let engineWasReady: Bool
        let unloadPolicy: String
        let sample: MachineSample
    }

    /// At most one open take: dictation is strictly sequential, and a record
    /// that outlived its take would attribute the next one's counters.
    @MainActor private static var pendingStop: PendingStop?

    private static func write(_ record: Record) {
        // Encoding and file I/O never belong on the actor that also owns the
        // hotkey and the overlay. The record is a value; nothing here can be
        // observed by the take it describes.
        Task.detached(priority: .utility) {
            do {
                let directory = try AppPaths.standard().support()
                    .appending(path: "Diagnostics", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let day = ISO8601DateFormatter()
                day.formatOptions = [.withFullDate]
                let file = directory.appending(
                    path: "dictation-\(day.string(from: Date())).jsonl",
                    directoryHint: .notDirectory
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var line = try encoder.encode(record)
                line.append(0x0A)

                if let handle = try? FileHandle(forWritingTo: file) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: file, options: .atomic)
                }
            } catch {
                // A diagnostics build that cannot write its evidence must say
                // so; silently losing the record would be the same blindness
                // this file exists to remove.
                log.error("diagnostics record not written")
            }
        }
    }

    // MARK: - Machine state

    /// What the machine looked like at one instant.
    ///
    /// The counters are cumulative, so a single sample is nearly meaningless;
    /// the pair around a take is the measurement. `pageins` on the worker and
    /// `decompressions`/`swapins` system-wide are the ones that answer "was the
    /// resident engine actually resident when the person needed it".
    struct MachineSample: Codable, Sendable {
        let freePages: UInt64
        let activePages: UInt64
        let inactivePages: UInt64
        let wiredPages: UInt64
        let compressorPages: UInt64
        let pageins: UInt64
        let pageouts: UInt64
        let swapins: UInt64
        let swapouts: UInt64
        let compressions: UInt64
        let decompressions: UInt64
        let swapUsedBytes: UInt64
        let workerProcessIdentifier: Int32?
        let workerResidentBytes: UInt64?
        let workerFootprintBytes: UInt64?
        let workerPageins: UInt64?

        static func current() -> MachineSample {
            let vm = vmStatistics()
            let worker = workerProcess()
            let usage = worker.flatMap(processUsage)
            return MachineSample(
                freePages: UInt64(vm?.free_count ?? 0),
                activePages: UInt64(vm?.active_count ?? 0),
                inactivePages: UInt64(vm?.inactive_count ?? 0),
                wiredPages: UInt64(vm?.wire_count ?? 0),
                compressorPages: UInt64(vm?.compressor_page_count ?? 0),
                pageins: UInt64(vm?.pageins ?? 0),
                pageouts: UInt64(vm?.pageouts ?? 0),
                swapins: UInt64(vm?.swapins ?? 0),
                swapouts: UInt64(vm?.swapouts ?? 0),
                compressions: UInt64(vm?.compressions ?? 0),
                decompressions: UInt64(vm?.decompressions ?? 0),
                swapUsedBytes: swapUsedBytes(),
                workerProcessIdentifier: worker,
                workerResidentBytes: usage?.resident,
                workerFootprintBytes: usage?.footprint,
                workerPageins: usage?.pageins
            )
        }

        private static func vmStatistics() -> vm_statistics64? {
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
            )
            let result = withUnsafeMutablePointer(to: &stats) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
                }
            }
            return result == KERN_SUCCESS ? stats : nil
        }

        private static func swapUsedBytes() -> UInt64 {
            var usage = xsw_usage()
            var size = MemoryLayout<xsw_usage>.size
            guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
            return usage.xsu_used
        }

        /// The recognition worker is a direct child of this process. Asking the
        /// kernel avoids widening the shipping recognizer protocol with a pid
        /// that only a diagnostics build wants.
        ///
        /// This scans every pid and confirms the parent link rather than
        /// calling `proc_listchildpids`, which was measured reporting a
        /// capacity of 695 for a process with exactly one child and then
        /// returning no children at all. A silent `nil` here would empty the
        /// one field this file exists to record, so the sturdier call wins
        /// over the shorter one.
        private static func workerProcess() -> Int32? {
            let parent = getpid()
            let capacity = proc_listallpids(nil, 0)
            guard capacity > 0 else { return nil }
            var pids = [pid_t](repeating: 0, count: Int(capacity))
            let bytes = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
            guard bytes > 0 else { return nil }
            for candidate in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)
            where candidate > 0 && parentProcess(of: candidate) == parent {
                if executablePath(of: candidate)?.hasSuffix("openramble-asr-worker") == true {
                    return candidate
                }
            }
            return nil
        }

        private static func parentProcess(of process: pid_t) -> pid_t? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(process, PROC_PIDTBSDINFO, 0, $0, size)
            }
            guard read == size else { return nil }
            return pid_t(info.pbi_ppid)
        }

        private static func executablePath(of process: pid_t) -> String? {
            // PROC_PIDPATHINFO_MAXSIZE is not imported into Swift; it is
            // four times MAXPATHLEN in libproc.h.
            var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(process, &path, UInt32(path.count))
            guard length > 0 else { return nil }
            return String(decoding: path[0..<Int(length)], as: UTF8.self)
        }

        private static func processUsage(
            _ process: pid_t
        ) -> (resident: UInt64, footprint: UInt64, pageins: UInt64)? {
            var info = rusage_info_current()
            let succeeded = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(process, RUSAGE_INFO_CURRENT, rebound) == 0
                }
            }
            guard succeeded else { return nil }
            return (info.ri_resident_size, info.ri_phys_footprint, info.ri_pageins)
        }
    }

    /// The part of a sample pair that actually carries the answer.
    ///
    /// A take that faulted the engine back from the compressor shows it here:
    /// `workerPageins` and `decompressions` rise while the engine was
    /// nominally resident. A take slowed by anything else leaves them flat.
    struct MachineDelta: Codable, Sendable {
        let pageins: UInt64
        let swapins: UInt64
        let decompressions: UInt64
        let workerPageins: UInt64?
        let workerResidentBytesChange: Int64?

        init(from opening: MachineSample, to closing: MachineSample) {
            pageins = closing.pageins &- opening.pageins
            swapins = closing.swapins &- opening.swapins
            decompressions = closing.decompressions &- opening.decompressions
            if let before = opening.workerPageins, let after = closing.workerPageins {
                workerPageins = after &- before
            } else {
                workerPageins = nil
            }
            if let before = opening.workerResidentBytes, let after = closing.workerResidentBytes {
                workerResidentBytesChange = Int64(bitPattern: after) - Int64(bitPattern: before)
            } else {
                workerResidentBytesChange = nil
            }
        }
    }

    private struct Record: Codable, Sendable {
        let timestamp: String
        let engineWasReady: Bool
        let unloadPolicy: String
        let characterCount: Int
        let audioSeconds: Double?
        let stopToTextSeconds: Double
        let stopToPasteSeconds: Double?
        let microphoneStartupSeconds: Double?
        let captureFreezeSeconds: Double?
        let enginePreparationSeconds: Double?
        let recognitionSeconds: Double?
        let engineProcessingSeconds: Double?
        let engineDispatchSeconds: Double?
        let poolReturnSeconds: Double?
        let mainActorReturnSeconds: Double?
        let machineAtStop: MachineSample
        let machineAtText: MachineSample
        let delta: MachineDelta
    }
    #endif
}

#if OPENRAMBLE_DIAGNOSTICS
private extension Duration {
    var diagnosticSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
