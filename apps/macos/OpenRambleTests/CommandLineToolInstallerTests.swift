import Foundation
import XCTest

final class CommandLineToolInstallerTests: XCTestCase {
    private var root: URL!
    private var app: URL!
    private var home: URL!
    private var executable: URL!
    private var link: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        app = root.appendingPathComponent("Applications/Open Ramble.app")
        home = root.appendingPathComponent("home")
        executable = app.appendingPathComponent("Contents/MacOS/openramble-cli")
        link = home.appendingPathComponent(".local/bin/openramble")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func createLinkDirectory() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func testInstallsLinkAndCanBeRepeated() throws {
        XCTAssertNil(CommandLineToolInstaller.installedLink(bundleURL: app, homeDirectory: home))
        let installed = try CommandLineToolInstaller.install(bundleURL: app, homeDirectory: home)
        XCTAssertEqual(installed.path, link.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), executable.path)
        XCTAssertEqual(try CommandLineToolInstaller.install(bundleURL: app, homeDirectory: home), installed)
        XCTAssertEqual(CommandLineToolInstaller.installedLink(bundleURL: app, homeDirectory: home), installed)
    }

    func testBundleURLWithTrailingSlashProducesCleanLink() throws {
        let bundle = URL(fileURLWithPath: app.path, isDirectory: true)
        XCTAssertTrue(bundle.absoluteString.hasSuffix("/"))
        let installed = try CommandLineToolInstaller.install(bundleURL: bundle, homeDirectory: home)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), executable.path)
        XCTAssertEqual(CommandLineToolInstaller.installedLink(bundleURL: bundle, homeDirectory: home), installed)
    }

    func testReplacesLinkToPreviousAppLocation() throws {
        try createLinkDirectory()
        let stale = "/Volumes/OpenRamble/OpenRamble.app/Contents/MacOS/openramble-cli"
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: stale)
        XCTAssertNil(CommandLineToolInstaller.installedLink(bundleURL: app, homeDirectory: home))
        _ = try CommandLineToolInstaller.install(bundleURL: app, homeDirectory: home)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), executable.path)
    }

    func testPreservesExistingFile() throws {
        try createLinkDirectory()
        let contents = Data("existing tool".utf8)
        try contents.write(to: link)
        XCTAssertThrowsError(try CommandLineToolInstaller.install(bundleURL: app, homeDirectory: home))
        let handle = try FileHandle(forReadingFrom: link)
        defer { try? handle.close() }
        XCTAssertEqual(try handle.readToEnd(), contents)
    }

    func testPreservesUnrelatedBrokenSymlink() throws {
        try createLinkDirectory()
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/missing/tool")
        XCTAssertThrowsError(try CommandLineToolInstaller.install(bundleURL: app, homeDirectory: home))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "/missing/tool")
    }

    func testRefusesUnstableAppLocation() throws {
        for unstable in ["/Volumes/OpenRamble/OpenRamble.app",
                         "/private/var/folders/x/AppTranslocation/1234/d/OpenRamble.app"] {
            let bundle = URL(fileURLWithPath: unstable, isDirectory: true)
            XCTAssertThrowsError(try CommandLineToolInstaller.install(bundleURL: bundle, homeDirectory: home)) { error in
                guard case CommandLineToolInstaller.Failure.unstableLocation = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testMissingExecutableDoesNotCreateInstallDirectory() throws {
        try FileManager.default.removeItem(at: executable)
        XCTAssertThrowsError(try CommandLineToolInstaller.install(bundleURL: app, homeDirectory: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }
}
