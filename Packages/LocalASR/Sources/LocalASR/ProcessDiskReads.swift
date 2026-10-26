import Darwin

/// Bytes this process has read from disk since it started.
///
/// The counter that tells an engine paged back in from swap apart from one
/// that was simply slow: a take on resident weights reads a few megabytes, a
/// take after the weights went to swap reads hundreds. The kernel charges a
/// swap-in to the process that faulted, so it lands here. Two readings around
/// a take are the measurement; one alone means nothing.
public enum ProcessDiskReads {
    public static func bytesRead() -> UInt64? {
        var info = rusage_info_current()
        let succeeded = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) == 0
            }
        }
        return succeeded ? info.ri_diskio_bytesread : nil
    }
}
