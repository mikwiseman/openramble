# Manual application verification

Use an installed, notarized build for these checks. Automated tests cover the
logic; this list covers macOS permissions and interaction with other apps.

1. Launch OpenRamble from Finder and confirm the onboarding window appears.
2. Grant Microphone and Accessibility access. Confirm the app never requests
   Input Monitoring.
3. Download both models and restart the app. Confirm they remain ready.
4. Dictate into TextEdit, Safari, and a code editor using hold-to-talk.
5. Double-press the hotkey to start hands-free recording, then press once to
   stop. Confirm Escape cancels without inserting text.
6. Confirm clipboard contents are restored after insertion and do not appear on
   another device through Universal Clipboard.
7. Enable correction learning, correct an inserted term in the same field, and
   verify the learned replacement. Disable the setting and confirm the field is
   no longer re-read.
8. Trigger Check for Updates and verify that Sparkle offers the latest English
   release from `https://mikwiseman.github.io/openramble/appcast.xml`.

Do not attach recordings or dictated text to bug reports. Record only the app
version, macOS version, hardware, step number, and observed behavior.
