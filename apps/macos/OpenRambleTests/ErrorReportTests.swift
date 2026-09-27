import XCTest

final class ErrorReportTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testZIPIncludesOnlySanitizedAppDiagnostics() throws {
        let reports = root.appending(path: "Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try CrashReportSanitizerTests.report().write(to: reports.appending(path: "OpenRamble-PRIVATE_CANARY.ips"))
        try CrashReportSanitizerTests.report(bundleID: "another.app").write(to: reports.appending(path: "OpenRamble-other.ips"))
        try Data("PRIVATE_CANARY".utf8).write(to: reports.appending(path: "OpenRamble-broken.ips"))
        try Data("PRIVATE_CANARY".utf8).write(to: reports.appending(path: "voice.wav"))
        let log = DictationLogFile(directory: root.appending(path: "SupportLogs"), enabled: true)
        log.record(.dictationListening)
        let zip = root.appending(path: "report.zip")
        try ErrorReport.save(to: zip, journal: log, directories: [reports])
        let folder = try extract(zip)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["events.jsonl", "README.txt", "system.json", "crash-1.ips"])
        for file in files {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("PRIVATE_CANARY"))
        }
        XCTAssertTrue(try String(contentsOf: folder.appending(path: "events.jsonl"), encoding: .utf8).contains("dictationListening"))
        let permissions = try FileManager.default.attributesOfItem(atPath: zip.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testNoCrashAndDisabledJournalStillProduceAnHonestReport() throws {
        let log = DictationLogFile(directory: root.appending(path: "Logs"), enabled: false)
        let zip = root.appending(path: "report.zip")
        try ErrorReport.save(to: zip, journal: log, directories: [])
        let folder = try extract(zip)
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "events.jsonl")).count, 0)
        let readme = try String(contentsOf: folder.appending(path: "README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("No available Apple crash report"))
        XCTAssertTrue(readme.contains("Local journal: disabled"))
    }

    func testSymlinksAndOldReportsAreExcluded() throws {
        let reports = root.appending(path: "Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let old = reports.appending(path: "OpenRamble-old.ips")
        try CrashReportSanitizerTests.report().write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 86400)], ofItemAtPath: old.path)
        try FileManager.default.createSymbolicLink(at: reports.appending(path: "OpenRamble-link.ips"), withDestinationURL: old)
        let zip = root.appending(path: "report.zip")
        try ErrorReport.save(to: zip, journal: DictationLogFile(directory: root.appending(path: "Logs"), enabled: true), directories: [reports])
        let folder = try extract(zip)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains("crash-1.ips"))
    }

    private func extract(_ zip: URL) throws -> URL {
        let output = root.appending(path: "Extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output.appending(path: "OpenRamble-Error-Report")
    }
}
