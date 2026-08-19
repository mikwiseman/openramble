# OpenRamble for Windows and Linux 0.1.0

Hold a key, speak, release it, and the text appears in whatever you were typing
in. Recognition runs on your machine; nothing you say leaves it.

This is the first release outside macOS, and it shares its logic with the Mac
rather than reimplementing it — the same session rules, the same text pipeline,
the same dictionary, checked against recordings of what the Mac actually
produces so the two cannot quietly diverge.

## What works

- Hold-to-talk on a modifier key. Right Ctrl by default, because right-hand
  modifiers collide with nothing people already press.
- The developer dictionary is on from the start, and you can add your own terms.
- Recent dictations are kept with the audio that produced them, so you can hear
  what was actually said when the text is wrong.
- The model downloads with progress and can be stopped; nothing is installed
  until every byte verifies.

## What to know before installing

**Recognition runs on the processor.** On macOS OpenRamble uses the graphics
card; here it does not yet, so transcription is slower. It is stated in Settings
rather than left for you to discover.

**Windows builds are not signed yet.** SmartScreen will warn on first launch.
Choose "More info" and then "Run anyway" if you are willing to; if you would
rather wait for a signed build, that is a reasonable thing to wait for.

**Wayland limits what any application may do.** If your desktop does not allow
OpenRamble to type into other windows, it says so in Settings and puts the text
on the clipboard instead — one keystroke away rather than silently lost.
Installing `ydotool` lets it insert the text for you.

## Privacy

Recognition is local. The only network access is downloading the model you asked
for, from one module, checked in CI by filename. Dictated text is written to the
clipboard with the formats that keep it out of Windows Clipboard History and
Cloud Clipboard, and your previous clipboard is restored afterwards unless you
copied something newer yourself.

## Installing

- **Windows**: `OpenRamble_0.1.0_x64_en-US.msi`, or the `-setup.exe` installer.
- **Linux**: `.AppImage` to run without installing, or `.deb` / `.rpm`.
