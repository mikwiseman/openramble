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
