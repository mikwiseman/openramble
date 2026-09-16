import Foundation
import XCTest
@testable import LocalASR

final class DictationPriorityTests: XCTestCase {
    func testAnotherProcessIsVisibleAndTerminationReleasesPriority() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "priority.lock")
        let priority = try DictationPriority(url: path)
        XCTAssertFalse(try priority.isActive())
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.lockf(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read()", path.path]
        let output = Pipe()
        let input = Pipe()
        child.standardOutput = output
        child.standardInput = input
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 6), Data("ready\n".utf8))
        XCTAssertTrue(try priority.isActive())
        child.terminate()
        child.waitUntilExit()
        XCTAssertFalse(try priority.isActive())
        try priority.setActive(true)
        XCTAssertTrue(try priority.isActive())
        try priority.setActive(false)
        XCTAssertFalse(try priority.isActive())
    }
}
