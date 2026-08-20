import XCTest

/// The log a tester can send — and the promise that it does not exist unasked.
final class DictationLogFileTests: XCTestCase {
    /// Off means nothing is written, not "written but hidden".
    ///
    /// A file that appears without being asked for is a file nobody consented
    /// to, and this one is going to strangers' machines.
    func testWritingIsOffUntilAskedFor() {
        XCTAssertFalse(SettingsDefaults.detailedLogging)
        let log = DictationLogFile.shared
        let wasEnabled = log.isEnabled
        defer { log.isEnabled = wasEnabled }

        log.isEnabled = false
        log.write("this must not reach disk")
        // The write is queued, so give the queue a turn before looking.
        let settled = expectation(description: "queue drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        let files = (try? FileManager.default.contentsOfDirectory(
            at: DictationLogFile.directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "log" {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            XCTAssertFalse(
                text.contains("this must not reach disk"),
                "a disabled log wrote to \(file.lastPathComponent)"
            )
        }
    }

    /// It goes where a person would look for it, and where Handy puts its own.
    func testItLivesSomewhereAPersonWouldLook() {
        let path = DictationLogFile.directory.path
        XCTAssertTrue(path.hasSuffix("Library/Logs/is.waiwai.dictation"), path)
    }
}
