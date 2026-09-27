import Foundation
import XCTest

final class CrashReportSanitizerTests: XCTestCase {
    static let binaryUUID = "24F3E555-3FAC-3158-95C2-A7609FC7F3C8"

    static func report(bundleID: String = "is.waiwai.dictation") throws -> Data {
        let header: [String: Any] = ["app_name": "OpenRamble", "bundleID": bundleID,
            "app_version": "0.30.3", "build_version": "70", "bug_type": "309",
            "incident_id": "PRIVATE_CANARY", "timestamp": "2026-09-27 18:54:45.00 +0300"]
        let body: [String: Any] = [
            "procName": "OpenRamble", "procPath": "/Users/PRIVATE_CANARY/Downloads/OpenRamble.app/Contents/MacOS/OpenRamble",
            "bundleInfo": ["CFBundleIdentifier": bundleID, "CFBundleVersion": "70", "CFBundleShortVersionString": "0.30.3"],
            "crashReporterKey": "PRIVATE_CANARY", "bootSessionUUID": "PRIVATE_CANARY", "userID": 501,
            "captureTime": "2026-09-27 18:53:20.7999 +0300", "cpuType": "ARM-64", "translated": false,
            "osVersion": ["train": "macOS 27.0", "build": "26A428", "releaseType": "User"],
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "rawCodes": [1, 104], "message": "PRIVATE_CANARY"],
            "termination": ["namespace": "SIGNAL", "code": 11, "details": ["PRIVATE_CANARY"]],
            "asi": ["some-library": ["PRIVATE_CANARY"]], "reportNotes": ["PRIVATE_CANARY"], "faultingThread": 0,
            "threads": [["id": 44, "triggered": true, "name": "PRIVATE_CANARY", "queue": "PRIVATE_CANARY",
                "threadState": ["flavor": "ARM_THREAD_STATE64", "pc": ["value": 104, "symbol": "PRIVATE_CANARY"], "lr": ["value": 200]],
                "frames": [["imageIndex": 0, "imageOffset": 104, "symbolLocation": 36, "symbol": "CAImageQueueInvalidate"],
                           ["imageIndex": 1, "imageOffset": 208]]]],
            "usedImages": [["base": 1000, "size": 4096, "uuid": binaryUUID, "arch": "arm64", "source": "P",
                "name": "OpenRamble", "path": "/Users/PRIVATE_CANARY/Downloads/OpenRamble.app/Contents/MacOS/OpenRamble"],
                ["base": 5000, "size": 4096, "uuid": binaryUUID, "arch": "arm64", "source": "P",
                 "name": "PRIVATE_CANARY", "path": "/Users/PRIVATE_CANARY/private-plugin.dylib"]]
        ]
        var result = try JSONSerialization.data(withJSONObject: header)
        result.append(10)
        result.append(try JSONSerialization.data(withJSONObject: body))
        return result
    }

    func testRedactsPersonalFieldsWithoutLosingStackOrImageIndices() throws {
        let data = try XCTUnwrap(CrashReportSanitizer.sanitize(Self.report()))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_CANARY"))
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertTrue(text.contains(Self.binaryUUID))
        XCTAssertTrue(text.contains("CAImageQueueInvalidate"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data.dropFirst(data.firstIndex(of: 10)! + 1)) as? [String: Any])
        let threads = try XCTUnwrap(body["threads"] as? [[String: Any]])
        let frames = try XCTUnwrap(threads[0]["frames"] as? [[String: Any]])
        XCTAssertEqual(frames[1]["imageIndex"] as? Int, 1)
        XCTAssertEqual(frames[1]["imageOffset"] as? Int, 208)
        let images = try XCTUnwrap(body["usedImages"] as? [[String: Any]])
        XCTAssertEqual(images.count, 2)
        // Apple's crashlog synthesizes missing images using this basename.
        // An omitted/empty path makes that tool fail before showing the stack.
        XCTAssertTrue(images.allSatisfy { ($0["path"] as? String)?.isEmpty == false })
        XCTAssertEqual(body["faultingThread"] as? Int, 0)
        let registers = try XCTUnwrap(threads[0]["threadState"] as? [String: Any])
        XCTAssertEqual((registers["pc"] as? [String: Int])?["value"], 104)
    }

    func testRejectsOtherAppsEvenIfFileIsNamedOpenRamble() throws {
        XCTAssertNil(try CrashReportSanitizer.sanitize(Self.report(bundleID: "another.app")))
    }

    func testMalformedAndFutureReportsAreNotCopiedRaw() {
        XCTAssertThrowsError(try CrashReportSanitizer.sanitize(Data("private text".utf8)))
    }
}
