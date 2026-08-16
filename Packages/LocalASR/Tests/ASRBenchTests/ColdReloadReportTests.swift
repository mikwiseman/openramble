import Foundation
import XCTest

@testable import asr_bench

final class ColdReloadReportTests: XCTestCase {
    func testJSONLineIsStableAndParseable() throws {
        let report = ColdReloadReport(
            scenario: "warm-reload",
            placement: "automatic",
            pressure: "none",
            iteration: 2,
            prepareSeconds: 13.5478,
            warmSeconds: 0.39,
            totalSeconds: 13.9378,
            modelPathKind: "installed",
            peakRSSBytes: 2_414_000_000
        )

        let line = report.jsonLine()
        XCTAssertEqual(
            line,
            "{\"scenario\":\"warm-reload\",\"placement\":\"automatic\","
                + "\"pressure\":\"none\",\"iteration\":2,\"prepare_s\":13.548,"
                + "\"warm_s\":0.390,\"total_s\":13.938,"
                + "\"model_path_kind\":\"installed\",\"peak_rss_bytes\":2414000000}"
        )

        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed["iteration"] as? Int, 2)
        XCTAssertEqual(parsed["prepare_s"] as? Double ?? 0, 13.548, accuracy: 0.0005)
    }

    func testOmitsWarmFieldWhenAbsentAndEscapesQuotes() throws {
        let report = ColdReloadReport(
            scenario: "single-load",
            placement: "gpu",
            pressure: "warn \"simulated\"",
            iteration: 0,
            prepareSeconds: 0.1,
            warmSeconds: nil,
            totalSeconds: 0.1,
            modelPathKind: "explicit",
            peakRSSBytes: 0
        )

        let line = report.jsonLine()
        XCTAssertFalse(line.contains("warm_s"))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed["pressure"] as? String, "warn \"simulated\"")
    }
}
