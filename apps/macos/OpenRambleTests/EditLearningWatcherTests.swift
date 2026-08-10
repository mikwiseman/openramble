import ApplicationServices
import XCTest

/// Edit observer: rereads the field after insertion and submits the edit.
@MainActor
final class EditLearningWatcherTests: XCTestCase {
    /// Dummy field: the value changes as the test progresses, just as a human would change it.
    private final class FakeField: FocusedFieldReading {
        var value: String?
        var captured = 0
        /// When the field was read. The first entry is the baseline inside
        /// `beginWatching`, the rest are the scheduled checks: it is their timing that
        /// the settings text promises to a person.
        var readAt: [ContinuousClock.Instant] = []

        func captureFocusedField() -> FocusedFieldHandle? {
            captured += 1
            return FocusedFieldHandle { [weak self] in
                self?.readAt.append(.now)
                return self?.value
            }
        }
    }

    func testScenario001() async throws {
        let field = FakeField()
        field.value = "Hello! Open poust girls."
        let watcher = EditLearningWatcher(
            reader: field,
            checkOffsets: [.milliseconds(30), .milliseconds(60)]
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
        let watcher = EditLearningWatcher(reader: field, checkOffsets: [.milliseconds(20)])

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
            checkOffsets: [.milliseconds(50)]
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

    /// The focused element is handed over by the accessibility server of ANOTHER
    /// application, and its type is that application's word, not a guarantee. Swift does
    /// not check a cast to a CoreFoundation type at all, so an unchecked one hands a
    /// foreign value straight on to the accessibility API - during dictation, in the one
    /// place where the application looks inside someone else's window.
    func testScenario004() {
        let foreign: CFTypeRef = "I am not an element" as CFString

        XCTAssertNil(SystemFocusedFieldReader.element(from: foreign))
        XCTAssertNil(SystemFocusedFieldReader.element(from: nil))
        XCTAssertNotNil(
            SystemFocusedFieldReader.element(from: AXUIElementCreateSystemWide()),
            "A real element is still an element - the check must not disable learning"
        )
    }

    /// Both reads are counted from the insertion, and not from each other.
    ///
    /// Spent as a chain of sleeps, the same two numbers read someone else's field at
    /// 8 + 25 = 33 seconds - beyond the half a minute promised by the settings.
    func testScenario005() async throws {
        let field = FakeField()
        field.value = "Hello! Open poust girls."
        let watcher = EditLearningWatcher(
            reader: field,
            checkOffsets: [.milliseconds(200), .milliseconds(300)]
        )

        let start = ContinuousClock.now
        // Nobody corrects anything: the observation must use up both checks.
        watcher.beginWatching(inserted: "Open poust girls.") { _, _ in }

        for _ in 0..<200 where field.readAt.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(field.readAt.count, 3, "baseline plus two checks")
        XCTAssertLessThan(
            start.duration(to: field.readAt[2]),
            .milliseconds(400),
            "The second check is at 300 ms from the insertion, not at 200 + 300"
        )
    }

    /// The numbers of the schedule are a promise printed in the settings.
    func testScenario006() throws {
        XCTAssertEqual(
            EditLearningSchedule.checkOffsets,
            [.seconds(8), .seconds(25)],
            "The settings say: twice - at 8 and 25 seconds"
        )
        let last = try XCTUnwrap(EditLearningSchedule.checkOffsets.last)
        XCTAssertLessThanOrEqual(
            last,
            EditLearningSchedule.limit,
            "`learnFromEdits` promises reading only in the first half a minute"
        )
    }

    func testScenario007() {
        XCTAssertEqual(
            EditLearningSchedule.waits(between: [.seconds(8), .seconds(25)]),
            [.seconds(8), .seconds(17)],
            "The second pause is the gap between the offsets, not the offset itself"
        )
        XCTAssertEqual(EditLearningSchedule.waits(between: []), [])
    }
}
