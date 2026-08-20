# Handy audit and OpenRamble cross-platform rules

Date: 2026-08-20  
Handy repository: `cjpais/Handy`  
Audited revision: `0e5036721ef6f26c3b89ab31bc10cd2ffd6096fb`  
Historical comparison base: `db003f38b1aef4eb967ac3419bebc851d680f71c`

This is an implementation audit, not a recommendation to copy Handy wholesale.
OpenRamble already has stronger session ordering, clipboard privacy, recovery,
bounded retention, and a measured recognition path. The useful Handy lessons
are the small boundaries that keep a Tauri shell responsive under contention.

## Source coverage

The current Handy checkout contained 346 tracked files. The audit covered the
Rust/Tauri command layer, recording and device code, transcription coordinator,
model management, global shortcuts, overlay and tray code, platform-specific
macOS/Windows/Linux modules, frontend event listeners, build configuration, CI,
and the performance/reliability fixes made since the historical comparison
revision. Dependency versions and upstream release state were checked against
their registries and official Tauri and Apple documentation.

## Patterns to carry into OpenRamble

1. **The global shortcut callback only admits work.** Handy moved synchronous
   Tauri commands off the webview/main loop and later serialized recognition in
   a coordinator. OpenRamble's callback must never open or stop a device, wait
   for a mutex, load a model, recognize, access disk, touch the clipboard, or
   synthesize keys.
2. **One explicit lifecycle owner.** Recording, processing, cancellation, and
   shutdown are states, not loosely related booleans. A press during processing
   is rejected when it occurs; it must never wait in a queue and start a
   surprise recording after recognition finishes.
3. **Load on key-down, recognize from memory.** Start capture first, then warm
   the resident recognizer while speech is arriving. Release stops capture and
   recognition consumes the captured memory. Saving audio is a later durability
   operation and cannot gate the paste.
4. **A persistent, named recognition worker.** The model is owned and destroyed
   on one dedicated thread. There is no recognition timeout: machine pressure
   may make valid work slow, but slowness is not failure. Panics are contained,
   surfaced, and leave lifecycle admission usable.
5. **Bounded communication.** Audio, lifecycle, UI events, and persistence use
   bounded queues or explicit admission. Unbounded queues turn load into delayed
   surprise actions and memory growth.
6. **Real-time audio callbacks do fixed, non-blocking work.** No allocation,
   file I/O, logging, resampling, or blocking mutex acquisition belongs in a
   CPAL callback. Remaining frames are drained at stop, device loss is explicit,
   and a forgotten hotkey has a fixed memory ceiling.
7. **Low-rate, targeted UI telemetry.** Handy reduced microphone-level IPC from
   roughly 188 events/s to about 30 and stopped emitting to windows that did not
   consume it. OpenRamble should use a channel for ordered/high-rate data and
   events only for low-rate notifications, with listener cleanup.
8. **Main thread means UI only.** On macOS, window, clipboard, paste, tray, and
   AppKit work are scheduled on the main thread. Capture, resampling, inference,
   JSON, WAV, hashing, copy/delete, and network work are not.
9. **Portable CPU baseline.** Shipping x86 builds cannot assume AVX2, FMA, or a
   working GPU merely because the build machine has them. Accelerator fallback
   must be visible. A newly released inference binding is benchmarked before it
   replaces the known version; it is not upgraded on release-day novelty alone.
10. **Device churn is normal.** Default-device disconnects, Bluetooth delays,
    permission denial, suspend/resume, and exclusive use are ordinary runtime
    states. Recovery may retry the same declared operation, but may not silently
    switch product behavior or hide the error.

## Patterns not to copy

- Mutex acquisition and vector allocation in the real-time audio callback.
- Detached tasks with no shutdown/join contract.
- Errors discarded because a feature is called "convenience"; history failure
  must not block insertion, but it must be observable in the app and diagnostics.
- Broad event broadcasting when only one window consumes the signal.
- Platform conditionals scattered through product rules instead of adapters.
- Test count as a quality measure. A test that passes against the broken
  behavior, repeats another layer's proof, or asserts implementation trivia is
  removed. Each retained test protects a distinct failure mode.

## Main-thread and pressure matrix

| Operation | Owner | Pressure rule |
|---|---|---|
| Global key callback | OS listener | Atomics + non-blocking send only |
| Session ordering | Lifecycle worker | Serialized, bounded admission |
| Capture callback | Audio device thread | Fixed work, no blocking/allocation |
| Model load/inference | Recognition worker | Resident model, no timeout |
| Resample/text pipeline | Worker | Never UI/main thread |
| History/WAV persistence | Persistence worker | After text is safe; bounded queue |
| Clipboard/paste/window/tray | Tauri main thread | Short UI/platform calls only |
| Settings filesystem commands | Tauri async blocking pool | Errors returned to UI |

## Liquid Glass acceptance

Apple's current guidance treats Liquid Glass as a functional control and
navigation layer, not decoration. OpenRamble therefore uses native window
material once, removes painted glass behind glass, keeps content on a stable
surface, groups controls by function, uses one accent sparingly, preserves safe
areas and system typography, and gives every icon-only control an accessible
name. The interface must remain legible with Reduce Transparency, Increase
Contrast, and Reduce Motion, at keyboard-only navigation, 200% zoom, and narrow
window sizes. Motion is interruptible and never required to understand state.

## Update and identity constraint

The permanent macOS bundle identifier is `is.waiwai.dictation`; changing it
would strand existing Accessibility permission grants. Existing installs trust
the current Sparkle EdDSA key and appcast. A Tauri build is not releasable merely
because it produces a DMG: the signed/notarized bundle, Sparkle update path, old
installation upgrade, permissions, history/model paths, and live appcast must
all be verified. No replacement update key may be generated as a shortcut.

## Release evidence required

- focused lifecycle, audio, engine, history, model, text, and UI contract tests;
- full locked workspace tests and production bundle build;
- real microphone dictation into another application on Apple Silicon and Intel,
  plus Windows x86-64 and Linux sessions supported by the product;
- CPU and disk pressure runs with latency, dropped-audio, memory, and recovery
  evidence rather than a simple process-survived check;
- disconnect/reconnect, permission denial, suspend/resume, rapid gestures,
  silent input, ten-minute cap, model repair, quit-during-work, and second-launch;
- visual inspection of the running app in normal, dark, reduced-transparency,
  increased-contrast, reduced-motion, keyboard, zoom, and constrained layouts;
- clean `main`, matching successful CI commit, signed/notarized/stapled DMG,
  Gatekeeper acceptance, exact Sparkle signature, and the live feed serving the
  released version.

## Primary references

- Handy source and commit history: <https://github.com/cjpais/Handy>
- Tauri command guidance: <https://v2.tauri.app/develop/calling-rust/>
- Tauri updater: <https://v2.tauri.app/plugin/updater/>
- Apple Liquid Glass overview: <https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass>
- Apple custom Liquid Glass views: <https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views>
