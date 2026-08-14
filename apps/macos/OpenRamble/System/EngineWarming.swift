/// Whether a recording start should run one representative inference in
/// parallel with capture.
///
/// The recognition engine has two speeds, measured on this hardware: 0.13 s
/// warm against 16.06 s after macOS evicted its Neural Engine state. The
/// operating system does not expose a portable residency signal or a reliable
/// time-to-eviction threshold across Apple Silicon generations. A cheap warm
/// inference on every ready recording start is therefore the deterministic
/// policy: it runs under speech and prevents a hidden cold tail at key-up.
enum EngineWarming {
    static func shouldPingOnRecordingStart(engineReady: Bool) -> Bool {
        engineReady
    }
}
