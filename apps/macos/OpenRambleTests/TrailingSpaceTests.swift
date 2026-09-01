import DictationCore
import XCTest

/// The space at the end, and the places it must not appear.
final class TrailingSpaceTests: XCTestCase {
    private func pipeline(_ appendsSpace: Bool) -> TrailingSpacePipeline {
        TrailingSpacePipeline(wrapped: TextPipeline(), appendsSpace: appendsSpace)
    }

    func testScenario001() {
        XCTAssertEqual(pipeline(true).run("hello there").output.text, "Hello there ")
        XCTAssertEqual(pipeline(false).run("hello there").output.text, "Hello there")
    }

    /// Nothing was recognized, so there is nothing to put a space after. A lone
    /// space inserted into someone's document is worse than silence.
    func testScenario002() {
        XCTAssertEqual(pipeline(true).run("   ").output.text, "")
    }

    /// "New line" already ended the text where the person wanted it, and a
    /// space after the break is an indent nobody asked for.
    func testScenario003() {
        let run = pipeline(true).run("first thought new line")
        XCTAssertTrue(run.output.text.hasSuffix("\n"), "got \(run.output.text.debugDescription)")
    }

    /// Provenance describes the text that was inserted, or "copy as spoken"
    /// and the edit watcher would be comparing against something that never
    /// reached the screen.
    func testScenario004() {
        let run = pipeline(true).run("hello there")
        XCTAssertEqual(run.provenance.finalText, run.output.text)
    }
}
