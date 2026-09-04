# Manual application verification

Use an installed, notarized build for these checks. Automated tests cover the
logic; this list covers macOS permissions and interaction with other apps.

Record each row as pass, fail, blocked, or not applicable; never infer a pass
from an automated test. Restore every system setting and clipboard value changed
for the check.

1. Launch OpenRamble from Finder and confirm the three-step onboarding window
   appears, fits without clipping, and can be completed using only the keyboard.
2. Grant Microphone and Accessibility access. Confirm the state refreshes after
   returning from System Settings and the app never requests Input Monitoring.
3. Download both models, cancel and resume once, then restart the app. Confirm
   both remain ready and recognition still works with Wi-Fi off.
4. Check onboarding, every Settings tab, the menu, permission errors, model
   progress/errors, an empty/populated dictionary, and the recovery menu in
   light and dark appearances at the smallest supported display scale. Repeat
   at 200%/the largest macOS Text Size and confirm content remains reachable
   without clipped labels or controls.
5. Repeat the transient HUD check with Reduce Motion, Reduce Transparency, and
   Increase Contrast enabled. Confirm recording is identifiable without color,
   VoiceOver announces recording/transcribing/errors once, and no text is exposed
   in the HUD or screen sharing. Click through the visible HUD into the app below;
   it must never intercept the click. Let an identical warning auto-hide twice
   and confirm VoiceOver announces both impressions.
6. Dictate short, long, Russian, English, mixed-language, punctuation, technical
   vocabulary, silence, and immediate-release samples into TextEdit, Safari, and
   a code editor using hold-to-talk. Confirm the compact HUD disappears as soon
   as insertion starts; a successful paste must not leave a banner behind. In
   the dictionary form, confirm Return submits a populated pair and does not add
   an empty or half-filled replacement.
7. Double-press the hotkey to start hands-free recording, then press once to
   stop. Confirm Escape and a conflicting shortcut cancel without inserting text.
8. Switch focus during transcription and verify insertion returns to the field
   where dictation began. Cover rich text, a multiline field, an empty field, a
   secure field, and a destination that rejects paste.
   With two displays, repeat while the keyboard focus and pointer are on different
   screens; verify insertion still targets the original field and the HUD stays
   visible without stealing focus.
9. Confirm clipboard text, rich content, files, and multiple items are restored
   after insertion and do not appear on another device through Universal
   Clipboard. Verify password-manager values, lazy file promises, and content
   above 16 MiB use the safe Copy/Retry recovery instead.
10. Force capture, transcription, insertion, and kill/relaunch failures. Verify
    uninserted recognized text offers `Insert Last Dictation`; retained voice is
    disclosed once and appears as `Recovered Recordings (N)…`, which opens the
    exact Finder folder for Preview/Delete. Verify the count, explicit Finder
    deletion, seven-day/count/size expiry, and bounded-background removal of
    ordinary successful audio. The app must not transcribe retained voice in the
    background. Inject a delete-intent storage failure and confirm automatic
    recovery fails closed: ambiguous WAVs remain byte-for-byte untouched and
    the idle menu persistently offers `Recording Support Files — Recovery
    Disabled…` rather than importing or deleting them.
11. Enable correction learning, correct an inserted term in the same field, and
    verify the learned replacement. Disable the setting and confirm the field is
    no longer re-read. Add and delete a personal replacement using keyboard and
    VoiceOver, then confirm it survives relaunch.
12. Trigger Check for Updates and verify that Sparkle offers the latest English
    release from `https://mikwiseman.github.io/openramble/appcast.xml`. Turn
    automatic checks off and confirm scheduled network access stops.
13. Press Record for the first time on a build that has never asked. Confirm the
    intro sheet appears once, that macOS then shows OpenRamble's own System Audio
    Recording prompt with the string from `project.yml`, and that recording
    starts whichever button is pressed. Confirm the sheet never appears again.
14. Record a meeting on built-in speakers with something playing. Confirm the
    other side is transcribed as Others, that the same words do not also appear
    as You, and that the headphone line is shown. Repeat on headphones and
    confirm both sides are attributed with nothing suppressed.
15. Record with the output on AirPods or AirPlay, the case where a tap returns
    silence. Confirm the orange strip, the menu-bar badge, the flat Others meter,
    and the VoiceOver announcement after a minute; the recording must continue
    and file as degraded rather than stop.
16. Deny System Audio Recording, then grant it in System Settings while the app
    runs. Confirm the app says a relaunch is needed rather than claiming to
    capture, and that it captures after relaunching. On macOS 14.0 or 14.1
    confirm the app says system audio needs 14.2 and records the microphone.
17. Record for ninety minutes. Confirm memory stays flat, disk grows at about
    230 MB an hour, the transcript keeps up or says how far behind it is, and
    that dictating mid-recording wins the engine without stopping the recording.
18. Save a transcript and an audio file from a finished recording. Confirm the
    names come from the recording's title, that the m4a plays in QuickTime with
    you on the left and the other side on the right, that a degraded recording
    says so inside the Markdown, and that cancelling a long export leaves no
    file behind. There is no Share — copy and save are the ways a recording
    leaves the app.
19. Force-quit during a recording. Confirm the next launch repairs the file,
    publishes it as recovered, plays it, and transcribes the untranscribed tail.
    Repeat with Command-Q and confirm the dialog and a sealed, playable file.

Do not attach recordings or dictated text to bug reports. Record only the app
version, macOS version, hardware, step number, and observed behavior.
