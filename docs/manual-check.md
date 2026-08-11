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
   light and dark appearances at the smallest supported display scale.
5. Repeat the transient HUD check with Reduce Motion, Reduce Transparency, and
   Increase Contrast enabled. Confirm recording is identifiable without color,
   VoiceOver announces recording/transcribing/errors once, and no text is exposed
   in the HUD or screen sharing.
6. Dictate short, long, Russian, English, mixed-language, punctuation, technical
   vocabulary, silence, and immediate-release samples into TextEdit, Safari, and
   a code editor using hold-to-talk. Confirm the compact HUD disappears as soon
   as insertion starts; a successful paste must not leave a banner behind.
7. Double-press the hotkey to start hands-free recording, then press once to
   stop. Confirm Escape and a conflicting shortcut cancel without inserting text.
8. Switch focus during transcription and verify insertion returns to the field
   where dictation began. Cover rich text, a multiline field, an empty field, a
   secure field, and a destination that rejects paste.
9. Confirm clipboard text, rich content, files, and multiple items are restored
   after insertion and do not appear on another device through Universal
   Clipboard. Verify password-manager values, lazy file promises, and content
   above 16 MiB use the safe Copy/Retry recovery instead.
10. Force capture, transcription, and insertion failures. Verify recovery audio
    and uninserted text remain accessible from the menu, retry succeeds, delete
    is explicit, old recovery recordings expire, and ordinary successful audio
    is removed immediately.
11. Enable correction learning, correct an inserted term in the same field, and
    verify the learned replacement. Disable the setting and confirm the field is
    no longer re-read. Add and delete a personal replacement using keyboard and
    VoiceOver, then confirm it survives relaunch.
12. Trigger Check for Updates and verify that Sparkle offers the latest English
    release from `https://mikwiseman.github.io/openramble/appcast.xml`. Turn
    automatic checks off and confirm scheduled network access stops.

Do not attach recordings or dictated text to bug reports. Record only the app
version, macOS version, hardware, step number, and observed behavior.
