import XCTest

/// Edit observer: rereads the field after insertion and submits the edit.
@MainActor
final class EditLearningWatcherTests: XCTestCase {
    /// Dummy field: the value changes as the test progresses, just as a human would change it.
    private final class FakeField: FocusedFieldReading {
        var value: String?
        var captured = 0

        func captureFocusedField() -> FocusedFieldHandle? {
            captured += 1
            return FocusedFieldHandle { [weak self] in self?.value }
        }
    }

    func testScenario001() async throws {
        let field = FakeField()
        field.value = "Hello! Open poust girls."
        let watcher = EditLearningWatcher(
            reader: field,
            checkDelays: [.milliseconds(30), .milliseconds(60)]
        )

        var learned: (String, String)?
        watcher.beginWatching(inserted: "Open poust girls.") { original, edited in
            learned = (original, edited)
        }
        // The person corrected the term while the observation was waiting.
        field.value = "Hello! Open Postgres."

        for _ in 0..<100 where learned == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(learned?.0, "Open poust girls.")
        XCTAssertEqual(learned?.1, "Open Postgres.")
    }

    func testScenario002() {
        let field = FakeField()
        field.value = "Completely different text"
        let watcher = EditLearningWatcher(reader: field, checkDelays: [.milliseconds(20)])

        var fired = false
        watcher.beginWatching(inserted: "Open the post gerz.") { _, _ in fired = true }

        XCTAssertEqual(field.captured, 1)
        XCTAssertFalse(fired)
    }

    func testScenario003() async throws {
        let field = FakeField()
        field.value = "First text"
        let watcher = EditLearningWatcher(
            reader: field,
            checkDelays: [.milliseconds(50)]
        )

        var firstFired = false
        watcher.beginWatching(inserted: "First text") { _, _ in firstFired = true }
        // New dictation before the first check is triggered.
        field.value = "Second text"
        watcher.beginWatching(inserted: "Second text") { _, _ in }
        // Editing the “first” no longer concerns anyone.
        field.value = "First text corrected"

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(firstFired, "A canceled observation is not eligible to teach")
    }
}
