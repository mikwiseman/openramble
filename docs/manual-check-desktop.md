# Manual verification — Windows and Linux

Use an installed package, not a `cargo run` build: half of what this list covers
is what installation and the operating system do to the app, and neither is
present in a development build.

Record each row as pass, fail, blocked, or not applicable; never infer a pass
from an automated test. Restore every system setting and clipboard value changed
for the check.

## Both platforms

1. Install from the package, launch, and confirm the tray icon appears and its
   menu opens. Close the settings window; dictation must keep working, because
   this is a tray application and a stray window close is not a quit.
2. On a machine with no model, confirm the settings window says so without
   colouring it as a fault, states the download size before asking for it, and
   downloads with visible progress. Cancel mid-download, confirm nothing is
   left behind, and download again to completion.
3. With the model installed, pull the network cable or disable Wi-Fi entirely
   and dictate. It must work: recognition is local, and this is the check that
   proves the claim on the settings window is true.
4. Hold the key, speak, release, and confirm the text lands in a plain text
   editor, a browser field, and a code editor. Then repeat while the target
   application is slow to accept a paste (a large document, a busy editor) and
   confirm nothing is lost.
5. Copy something of your own, dictate, and confirm your clipboard is back
   afterwards. Then copy something *during* the second after a dictation and
   confirm yours wins — the restore must never overwrite what a person did
   more recently than the dictation.
6. Copy an image, dictate, and confirm the image is not replaced by an empty
   clipboard. The dictation staying on the clipboard is recoverable; a
   destroyed image is not.
7. Hold the key and press a letter mid-hold (the Ctrl+C shape). Confirm no text
   is inserted and no message appears: that was a shortcut, not a dictation.
8. Hold the dictation key while the *other* key of the same kind is also held,
   release only the dictation key, and confirm recording stops. This is the
   failure that leaves a microphone live forever, and it cannot be caught any
   other way from outside.
9. Tap the key and release it immediately without speaking. Nothing should
   appear and nothing should be said. Then hold it for two seconds in silence
   and confirm the app says the microphone gave nothing.
10. Quit from the tray while a dictation is being transcribed. The process must
    exit cleanly — no crash dialog, no report. ggml aborts the process if the
    model is still loaded at exit, so this is the check for that.
11. Dictate into a password field and confirm the text does not appear in the
    system clipboard history afterwards.

## Windows

12. Confirm the app does not open a console window at launch.
13. Open Clipboard History (Win+V) after a dictation and confirm the dictated
    text is absent. Then confirm it has not appeared on another device signed
    into the same Microsoft account — this is the promise the exclusion formats
    exist to keep, and it is the one that matters most.
14. Install over an existing version and confirm the model is not downloaded
    again.
15. Note the SmartScreen warning shown for an unsigned build and confirm the
    documented path past it still works.

## Linux

16. Check X11 and Wayland separately; they are different code paths and one
    passing says nothing about the other.
17. On Wayland, confirm that whatever cannot work is stated in the settings
    window rather than failing silently. A dictation tool that quietly does
    nothing is worse than one that says it cannot.
18. Confirm the AppImage runs on a distribution older than the build machine.
    Packages link against the glibc that built them, which is why they are built
    on the oldest supported runner.
