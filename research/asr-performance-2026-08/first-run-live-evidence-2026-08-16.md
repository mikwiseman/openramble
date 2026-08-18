# First-run stall: live evidence from the photographed failure

Captured 2026-08-16 from the user's own stuck OpenRamble 0.8.2 (build 24, pid
44437) before it was quit. This is the only direct observation of the failure we
have; everything else in this directory is inference.

## What the machine showed

| Fact | Value |
| --- | --- |
| App uptime while stuck | 3 h 50 min |
| App CPU, sustained | ~35 % of a core |
| Worker process | alive (pid 44439), 0.0 % CPU, 9.7 MB RSS — no model loaded |
| Model files | complete: `parakeet-tdt-0.6b-v3` + `parakeet-ctc-110m`, 559 MB |
| `onboardingCompleted` | `0` — onboarding never finished |
| Saved takes / recovered audio | 0 files in both directories |
| Audio engine | live (`com.apple.audio.toolbox`, caulk threads) on the setup screen |
| Audible symptom | the `Submarine` attention sound repeating, with no saved take behind it |

On screen at that moment: model card green, "Model ready", subtitle "The model
rests until your next dictation, then loads in a moment"; Microphone and
Accessibility both granted; footer "Getting the model ready…"; Continue disabled.

## The mechanism

`shouldStayUnloadedUntilUse` has **two** writers in `AppState.swift` @ origin/main
5b1586d, and 0.8.2 only closed one of them against onboarding:

* line ~1400 — the idle-unload timer. 0.8.2 gated this on `hasCompletedOnboarding`.
* line ~1465 — **the memory-pressure unload. It knows nothing about onboarding.**

Under pressure the second one runs `unloadIfIdle()`, then sets `isEngineReady =
false`, `shouldStayUnloadedUntilUse = true` and `enginePreparation = .idle`.

`wantsEngineReady` (line ~1535) is
`modelState.isReady && !isEngineReady && !shouldStayUnloadedUntilUse`,
so it is now false and preparation will never restart on its own. The only writer
that clears the flag (line ~1581) sits in `rewarmEngineIfCold`, reachable from a
hotkey press or an app activation — **neither of which happens while the person is
sitting on the setup screen**. The setup gate meanwhile blocks on `engineReady`.
Two policies hold each other, and only a relaunch clears the flag.

Memory pressure was overwhelmingly likely here: a 586 MB download had just landed,
the model was being specialised for the Neural Engine, and the machine was also
running several parallel Xcode builds.

## Why 0.8.2 did not fix it

0.8.2 fixed the readiness seam and gated the *idle* unload on onboarding. The
pressure unload was left ungated, so the same dead end is reachable by a different
door. This is the third face of the same bug (0.8.1, 0.8.2, now this): each fix
closed one path into a state whose *exit* was the real problem.

The lesson for the fix: do not keep closing entrances. Either the resting decision
cannot be taken before onboarding completes at all, or the exit from it must not
depend on events that the setup screen never produces.

## Two loose ends worth their own tests

1. **~35 % CPU while idle-stuck.** A stalled app should be quiet. Something —
   most likely a timer-driven redraw of the elapsed-seconds label, or the pressure
   gauge re-firing — spins for hours. No test covers CPU burn while stalled.
2. **The attention sound repeated with zero saved takes.** `playAttention` is
   documented as "what happened is recoverable — the text is still offered in the
   menu", but there was no take to offer. Either notices are raised without a take,
   or the sound outlives the notice. Either way a person hears a failure chime for
   something they cannot act on.

## Open: three app tests fail on this Mac and pass on CI

`AppStateTests/testScenario013`, `testScenario014` and
`AppStateIdleTests/testScenario014` — all asserting that a take interrupted by a
revoked Accessibility grant reaches disk — fail on this machine and pass on CI
(0.15 s there). They fail identically on `origin/main` @ 5b1586d, so they are not
caused by the first-run change; they also passed here during the 0.8.2 release
run at 17:37 on 2026-08-16.

Instrumented result: `stops=1 aborts=0 inserted=[] files=[] recoveredCount=0
faulted=false`. The capture was stopped correctly, nothing was inserted, and
nothing reached the recovery directory — the take simply disappears.

Ruled out, each tested: wall-clock budget (still empty after 10 s of polling),
free disk (50 GB reclaimed, no change), `TMPDIR`, a TCC denial recorded against
`is.waiwai.dictation.dev` (reset, no change), the installed 559 MB model (moved
aside, no change), 8 500 stale entries in the Darwin temp namespace (cleaned, no
change), leftover test UserDefaults suites (none exist), and the installed
`/Applications/OpenRamble.app` (moved aside, no change).

Leads not yet closed: `RecoveryStore.swift:702` deletes a take shorter than the
recognition minimum as "an accidental key press" — the fake writes a 15-byte
payload, so any path that judges the file rather than the reported duration would
drop it; the 60 s `compatibilityGrace` should protect a fresh file from the
maintenance sweep, so if the take is being dropped it is by the main dictation
path, not by maintenance.

**Best explanation so far.** `DictationController.preserveWithinForegroundGrace`
(`DictationController.swift:818`) races the save against `recoveryForegroundGrace`
and, when the grace expires, returns no URL while the background save continues.
The three tests poll the recovery directory for one second and assert on what is
there. So the take is very likely not lost at all — it simply has not landed yet
when the assertion runs, on a machine whose data volume is 93 % full after a night
of parallel builds. The tests measure a deadline while claiming to measure
survival; on CI the write wins the race, here it does not. If confirmed, the fix
belongs in the tests: wait for the take with a runaway backstop measured in
seconds, and assert only that it arrives.
