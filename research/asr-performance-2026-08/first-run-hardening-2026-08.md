# First-run preparation: adversarial root-cause report (2026-08-16)

Produced by an 8-agent adversarial workflow after v0.8.1. The two reproduced
failure paths are closed in 0.8.2 (PR #33/#34); sections 2-5 below are the
remaining hardening proposal, not shipped.

## 1. ROOT CAUSE

`rescheduleIdleUnload()` treated the setup screen as idleness — at v0.8.1 its guards were `dictationState == .idle, isEngineReady, let policyDelay` with no notion of onboarding (`apps/macos/OpenRamble/AppState.swift:1351-1356` @ `v0.8.1`), so the five-minute timer ran to completion while the person was in System Settings granting microphone and Accessibility, and `performIdleUnload()` then set `isEngineReady = false` and `enginePreparation = .make(phase: .idle, elapsed: 0)` (`AppState.swift:1383-1384` @ `v0.8.1`). The comeback it left behind is `rewarmEngineIfCold`, reachable only from a key press or an app activation — neither happens on the setup screen — so the card sat on `ModelStatus`'s "files ready, engine cold" branch rendering the `.idle` title **"Model not prepared"** forever.

Proof: `apps/macos/OpenRambleTests/FirstRunPreparationTests.swift::testFirstRunSurvivesTheTripToSystemSettings` fails at `1babf91` (v0.8.1 `AppState`) with `modelState.isReady=true isEngineReady=false isPreparingEngine=false preparation=idle "Model not prepared"` — character-for-character the reported card — and never recovers over a 5 s window.

**Note on repo state:** `main` has moved. `6a83843` (PR #33) already landed the `hasCompletedOnboarding` guard, `prepareEngineIfIdleAndCold`, the `.skipped where wantsEngineReady` retry, and the "Step N of 3" card. Everything below is written **against `HEAD` (`979b148`)**, not v0.8.1. Observation (4) — worker never in `ps` — is explained by `unloadIfIdle`'s kill fallback (`System/ASRWorkerSupervisor.swift:450-456`: in-place `.unloadModels` fails → `invalidateCurrentGeneration` + `reapKilledProcesses`), but the plan does not depend on winning that argument: the reconciler in commit 4 restarts preparation regardless of which event was missed.

---

## 2. THE FIX

### The invariant

> **The interface shows "preparing" if and only if a preparation task is alive.**
> Enforced by making the presentation *be* the task's existence, not a flag that mirrors it:
> `enginePreparation != nil` ⟺ `engineWarmupTask != nil || engineWarmupRetryTask != nil`,
> written in exactly one function, from exactly one read of those two pointers.

Today `isPreparingEngine` is a stored `@Published` Bool assigned in five places (`AppState.swift:2253, 2262, 2418, 2426, 2463`) and `enginePreparation` is a separate non-optional assigned in six. Two mirrors of one fact is the bug class. Collapse them into one optional.

```swift
// AppState.swift — replaces both :256 and :262-264
/// What preparation is doing right now, or nil when nothing is preparing.
///
/// Optional on purpose. `nil` is the only way the app can say "no preparation
/// is running", and it is written in exactly one place — the reconciler, from
/// the presence of a task. There is no flag left to forget to clear, so the
/// card can no longer narrate work that does not exist.
@Published public private(set) var enginePreparation: EnginePreparationState?

public var isPreparingEngine: Bool { enginePreparation != nil }
```

### The reconciler (replaces the event chain)

`prepareEngineIfIdleAndCold()` is called from two events (`:828`, `:2140`) — the same event shape that failed. Make it a standing rule driven by `didSet`:

```swift
/// The one place that answers both preparation questions from the same read of
/// the world: is preparation running, and should it be.
///
/// Presentation follows the tasks; it is never set by hand. Then, if the app
/// still owes a ready engine and nothing is doing it, an attempt starts. Called
/// from every write that can change either answer, so preparation is a standing
/// rule about state rather than a chain of events any one of which can be missed.
private func reconcileEnginePreparation() {
    let alive = engineWarmupTask != nil || engineWarmupRetryTask != nil
    if alive, enginePreparation == nil {
        beginPreparationCountdown()
    } else if !alive, enginePreparation != nil {
        endPreparationCountdown()
    }
    guard !alive, wantsEngineReady, transcriber != nil,
          !isRecyclingEngine, !isInstalling
    else { return }
    engineLog.info("engine preparation resumed: ready model, cold engine, nothing running")
    startEngineWarmup()
}

/// Does the app owe a ready engine right now?
///
/// The files are usable and this process has never had one. After the first
/// ready engine every loss of readiness has its own owner — an idle unload and
/// a pressure eviction are decisions whose comeback is the next key press, a
/// failed attempt is owned by the retry ladder — so the standing rule is
/// exactly the first-run promise and nothing more.
private var wantsEngineReady: Bool {
    modelState.isReady && !isEngineReady && !hasEngineBeenReady
}
```

Hooks — `didSet` on the two published facts it reads:

```swift
@Published public private(set) var modelState: ModelState = .notInstalled {
    didSet { reconcileEnginePreparation() }
}
@Published public private(set) var isEngineReady = false {
    didSet {
        if isEngineReady { hasEngineBeenReady = true }
        reconcileEnginePreparation()
    }
}
```

### Synchronous task installation (kills the spawn window)

`warmUpEngine` currently creates its task *inside* an `async` function, so two reconcile calls in the same actor turn can each enqueue a starter. Split it:

```swift
/// Start preparation and return immediately. The pointer is installed in this
/// same actor turn, so a second caller in the same turn joins the attempt
/// instead of starting another.
@discardableResult
private func startEngineWarmup(allowAutomaticRetry: Bool = true) -> Task<EngineWarmupOutcome, Never> {
    if let engineWarmupTask { return engineWarmupTask }
    guard transcriber != nil, modelState.isReady else { return Task { .abandoned } }

    engineWarmupTaskRevision &+= 1
    let revision = engineWarmupTaskRevision
    let task = Task { @MainActor [weak self] in
        guard let self else { return EngineWarmupOutcome.abandoned }
        let outcome = await self.performEngineWarmup()
        if self.engineWarmupTaskRevision == revision { self.engineWarmupTask = nil }
        if allowAutomaticRetry {
            switch outcome {
            case let .retryable(detail):
                self.scheduleEngineWarmupRetry(after: detail)
            case .abandoned where self.wantsEngineReady:
                // An interrupted attempt is not a decision about the world.
                // Retrying on the backoff ladder rather than instantly is what
                // keeps a cancel storm from becoming a spin.
                self.scheduleEngineWarmupRetry(after: "preparation was interrupted")
            case .ready, .repairRequired, .abandoned:
                break
            }
        }
        self.reconcileEnginePreparation()
        return outcome
    }
    engineWarmupTask = task
    reconcileEnginePreparation()
    return task
}

@discardableResult
private func warmUpEngine(allowAutomaticRetry: Bool = true) async -> EngineWarmupOutcome {
    await startEngineWarmup(allowAutomaticRetry: allowAutomaticRetry).value
}
```

`scheduleEngineWarmupRetry` and `finishRetryPresentation` lose every `isPreparingEngine = …` / `beginPreparationCountdown` / `endPreparationCountdown` line and each end with `reconcileEnginePreparation()`.

### The card can no longer be lied to

`ModelStatus.make` loses `isPreparingEngine:` entirely — the optional *is* the signal, so the two can never disagree:

```swift
case .ready:
    if !isEngineReady, let preparation {
        let total = EnginePreparationState.stepCount
        return ModelStatus(
            title: "Preparing the model",
            detail: preparation.detail,
            progress: Double(preparation.step - 1) / Double(total),
            progressLabel: "Step \(preparation.step) of \(total) · \(preparation.title)",
            actions: place == .settings ? [.delete] : [],
            tone: .neutral,
            announcement: "Preparing the model, step \(preparation.step) of \(total)"
        )
    }
    if !isEngineReady { /* the existing "Model ready … rests until your next dictation" branch */ }
```

`OnboardingGate.blockReason` likewise takes `preparation: EnginePreparationState?` instead of the `engineReady`/`enginePreparing` pair:

```swift
case .ready:
    if engineReady { return nil }
    if preparation != nil {
        return "The model is getting ready for this Mac — this happens once."
    }
    // Cold with nothing running can only be a deliberate rest, and the next
    // dictation loads it under the voice. There is nothing to wait for.
    return nil
```

### The field fix, completed

`6a83843` added the `hasCompletedOnboarding` guard to `rescheduleIdleUnload` (`AppState.swift:1371`) but nothing re-arms the timer when onboarding ends — the engine then stays resident until the first dictation-state change. Add:

```swift
// AppState.swift
/// Setup is over: idle unload becomes a courtesy again, starting now.
func onboardingDidComplete() { rescheduleIdleUnload() }
```
```swift
// OpenRambleApp.swift:52
OnboardingView(state: state) { onboardingCompleted = true; state.onboardingDidComplete() }
```

---

## 3. THE PROGRESS UX

**Choice: determinate step progress.** The bar measures *completed milestones*, which is a fact the app observes; it is never a percentage of time, which nobody knows. Aliveness comes from the 1 Hz seconds in the label directly under the bar — the same shape as the download's `120 of 483 MB`.

`EnginePreparationState.Phase` becomes exactly the three steps (`CaseIterable`), and `stepCount` derives from it so the enum and the count cannot drift:

```swift
public enum Phase: String, Equatable, CaseIterable {
    case loadingRecognizer
    case loadingVocabulary
    case warmingUp
}
public static let stepCount = Phase.allCases.count   // 3

public var step: Int {
    switch phase {
    case .loadingRecognizer: return 1
    case .loadingVocabulary: return 2
    case .warmingUp:         return 3
    }
}
```

**Exact strings** (`EnginePreparationState.make`, `elapsed` rounded to whole seconds):

| step | `title` | `detail` |
|---|---|---|
| 1 | `Loading the recognizer… 7 s` | `macOS is compiling the model for this Mac. Up to about 20 seconds the first time after install, a fraction of a second afterwards.` |
| 2 | `Loading the term booster… 3 s` | `A second, smaller model. Same one-time compile.` |
| 3 | `Warming up recognition… 18 s` | `One silent recognition, so your first real dictation is fast.` |

**Exact `ModelStatus` fields while preparing** (`state == .ready`, `preparation != nil`, `isEngineReady == false`):

| field | value |
|---|---|
| `title` | `"Preparing the model"` — static, so the heading never flickers |
| `progress` | `Double(step - 1) / 3.0` → `0.0`, `0.333…`, `0.667` — completed milestones only; **never reaches 1.0 while work is running** |
| `progressLabel` | `"Step 1 of 3 · Loading the recognizer… 7 s"` |
| `detail` | the phase `detail` above |
| `tone` | `.neutral` |
| `actions` | `[]` in onboarding, `[.delete]` in settings |
| `announcement` | `"Preparing the model, step 1 of 3"` — changes 3 times total, so VoiceOver speaks milestones, not the 1 Hz tick |

**`ModelStatusView`: no change.** It already renders `ProgressView(value: progress)` → `Text(progressLabel).font(.caption)` → `Text(detail).font(.caption)` (`ModelStatusView.swift:21-38`), with `.accessibilityLabel(status.title)` / `.accessibilityValue(status.progressLabel)`. That is exactly the download's layout, so preparation inherits its weight for free.

**The one lie to fix:** during the retry ladder, `beginPreparationCountdown(phase: .loadingRecognizer)` runs once at ladder start (`:2419`) and subsequent attempts skip it because `engineWarmupRetryTask != nil` — so attempt #2 shows `Warming up recognition… 47 s` while it is actually loading the recognizer. `performEngineWarmup` must open with `setPreparationPhase(.loadingRecognizer)` unconditionally; only the *elapsed* clock is owned by the ladder.

---

## 4. COMMIT-BY-COMMIT PLAN

### 1 — `test: the first run, in the order it actually happens`
**Files:** `apps/macos/OpenRambleTests/FirstRunPreparationTests.swift` (new, already drafted in the working tree), `apps/macos/OpenRambleTests/Fakes.swift` (already modified: `AppHarness.modelDownloaderOverride`, `ReadinessControlledRecognizer.prepares`).

Every existing test calls `installModelMarker()` *before* `makeState()`, and `BlockingModelDownloader` always ends in `throw terminalError` — so no test has ever driven `installModel()` to a ready model, and the real first-run ordering (launch cold → install) was never executed. `InstalledModelMirrorDownloader` hard-links the manifest's own bytes from an already-installed model, which is required because `ModelStore` verifies SHA-256 twice (`ModelStore.swift:632`, `:707-719`).

**Additional required change:** that test `XCTSkip`s on a machine with no installed model, so CI never runs it. Keep it as the honest end-to-end, but the *locking* assertion must be marker-based and always run — `AppStateTests.testIdleUnloadNeverStrandsSetupBeforeOnboardingIsFinished` (already present) is that test. Verify it **fails** when the `hasCompletedOnboarding` guard at `AppState.swift:1371` is deleted; if it passes without the guard, it is not locking anything.

Tests: `testFirstRunInstallActuallyPreparesTheEngine`, `testFirstRunSurvivesTheTripToSystemSettings`.

### 2 — `fix: idle unload becomes a courtesy again when setup ends`
**Files:** `AppState.swift` (`onboardingDidComplete()`), `OpenRambleApp.swift:52`.

Tests: `AppStateTests.testFinishingOnboardingArmsTheIdleUnloadTimer` — marker-installed, `idleUnloadDelayOverride = .milliseconds(30)`, assert the engine survives while onboarding is open, then call `state.onboardingDidComplete()` after setting the default and assert it goes cold without touching `modelUnloadTimeout` (which is how the existing test cheats the reschedule).

### 3 — `refactor: preparation is the task, not a flag`
**Files:** `AppState.swift`, `UI/EnginePreparationState.swift`, `UI/ModelStatus.swift`, `UI/OnboardingStep.swift`, `UI/OnboardingView.swift`, `UI/SettingsView.swift`, `UI/MenuContent.swift`.

`enginePreparation` → optional; `isPreparingEngine` → computed; `Phase` → three cases, `CaseIterable`, `stepCount` derived; `beginPreparationCountdown()` drops its phase argument; `endPreparationCountdown()` sets `nil`; `setPreparationPhase`/`tickPreparation` guard on `enginePreparation != nil` instead of `preparationTimer != nil`; `ModelStatus.make` and `OnboardingGate.blockReason` lose their `isPreparingEngine`/`enginePreparing` booleans in favour of the optional.

Tests:
- `ModelStatusTests.testPreparingCardExistsOnlyWithLivePreparation` — `preparation: nil, isEngineReady: false` → `"Model ready"` / `.success` / rests-copy; non-nil → `"Preparing the model"`.
- `ModelStatusTests` update to `testScenario006` (drop the `preparing:` parameter).
- `SpeedReadoutTests` — delete the `.idle`/`.ready` iterations; `testScenario011` asserts `state.enginePreparation == nil` at rest; `testScenario014` (`phase: .ready`) is replaced by `preparation: nil`.
- `OnboardingStepTests.testScenario013` — long sentence with a live `preparation`, `nil` reason without one.
- New `AppStateTests.testPreparationIndicatorMatchesTaskPresence` — assert `state.enginePreparation != nil` for the whole span between the first `prepare` call and `isEngineReady`, and `nil` on both sides.

### 4 — `refactor: one reconciler instead of a chain of events`
**Files:** `AppState.swift`.

`reconcileEnginePreparation()` + `startEngineWarmup()` + `wantsEngineReady` from `hasEngineBeenReady`; `didSet` on `modelState` and `isEngineReady`; `deleteModel` adds `hasEngineBeenReady = false` (a re-install must get the standing rule back); `EngineWarmupOutcome.skipped` → `.abandoned`.

Tests:
- `AppStateTests.testReadyModelWithColdEngineStartsPreparingWithoutAnyEvent` — rewrite: build state with a marker and a recognizer whose first `prepare` throws `CancellationError`, assert the engine still reaches ready without any key press, activation, or install.
- `AppStateTests.testDeliberateIdleUnloadIsNotUndoneByTheStandingRule` — after a completed onboarding + idle unload, assert `isEngineReady` stays false and `enginePreparation == nil` for 500 ms.
- `AppStateTests.testDeleteThenReinstallGetsTheStandingRuleBack` — `deleteModel()` → marker → assert `wantsEngineReady` behaviour via a fresh `prepares` increment.
- Existing `testEngineWarmupKeepsRetryingPastAnyBudget` (`AppStateTests.swift:1024`) still asserts `state.isPreparingEngine` — now computed, must stay green.

### 5 — `fix: the progress never lies about which step it is on`
**Files:** `AppState.swift` (`performEngineWarmup` opens with `setPreparationPhase(.loadingRecognizer)`), `UI/ModelStatus.swift` (progress/label/announcement exactly as specified above).

Tests:
- `AppStateTests.testEachRetryAttemptRestartsAtStepOne` — engine failing twice; assert `enginePreparation?.step == 1` at the start of the second attempt, not 3.
- `EnginePreparationWiringTests` — `progress` is `0.0` / `1/3` / `2/3` for the three phases and **never** `1.0`; `progressLabel` is `"Step 3 of 3 · Warming up recognition… 18 s"`.
- `EnginePreparationStateTests` — no `%` in any title or detail across `Phase.allCases`; `stepCount == Phase.allCases.count`.

**Gate:** `./scripts/check.sh` green before each commit; do not commit.

---

## 5. WHAT TO DELETE

| # | Thing | Where |
|---|---|---|
| 1 | `@Published public private(set) var isPreparingEngine` and its five write sites | `AppState.swift:256, 2253, 2262, 2418, 2426, 2463` |
| 2 | `EnginePreparationState.Phase.idle` and its `.make` branch — **the string `"Model not prepared"` ceases to exist in the codebase** | `UI/EnginePreparationState.swift:22, 53-58` |
| 3 | `EnginePreparationState.Phase.ready` and its `.make` branch (`"Ready to dictate"` is never rendered — `ModelStatus` uses `isEngineReady`) | `UI/EnginePreparationState.swift:26, 81-87` |
| 4 | The `.idle`/`.ready` clamping cases in `step` and the comment explaining them | `UI/EnginePreparationState.swift:37-48` |
| 5 | `isCountingEnginePreparation` — tests read `enginePreparation == nil` | `AppState.swift:267-268` |
| 6 | The three `enginePreparation = .make(phase: .idle, elapsed: 0)` assignments | `AppState.swift:1401, 1467, 2659` |
| 7 | `shouldStayUnloadedUntilUse` and all five sites — derived from `hasEngineBeenReady` | `AppState.swift:1319, 1400, 1465, 1557, 1581` |
| 8 | `prepareEngineIfIdleAndCold()` and its two event call sites — the reconciler replaces it | `AppState.swift:1546-1561, 828, 2140` |
| 9 | `EngineWarmupOutcome.skipped`'s dual meaning ("I declined" vs "I was abandoned") — renamed `.abandoned`, one meaning | `AppState.swift:2195, 2214, 2250-2251, 2361` |
| 10 | The `isPreparingEngine:` parameter from `ModelStatus.make` / `makeStatus` and its four call sites | `UI/ModelStatus.swift:84, 92, 104, 155`; `OnboardingView.swift:214`, `SettingsView.swift:233`, `MenuContent.swift:154` |
| 11 | The `enginePreparing:` parameter pair from `OnboardingGate.blockReason`/`isSatisfied` and the string `"Getting the model ready…"` — a placeholder for a state that can no longer exist | `UI/OnboardingStep.swift:51, 76-82, 99, 108`; `OnboardingView.swift:406` |
| 12 | `beginPreparationCountdown`'s `phase:` parameter (always `.loadingRecognizer`) | `AppState.swift:2631` |

Already deleted by `6a83843`, keep deleted: the redundant `guard case .ready = await store.currentState() else { return .skipped }` second readiness source in `performEngineWarmup`.

**Not deleted, deliberately:** `hasCompletedOnboarding` / `onboardingCompletedKey`. It is the field fix and cannot be derived — "idle since it became ready" is the right clock everywhere except during setup, and starting the clock at first *use* instead would leave 586 MB resident forever for someone who launches at login and never dictates.