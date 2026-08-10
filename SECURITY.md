# Security policy

Report vulnerabilities privately to hi@mikwiseman.com. Please do not open a
public issue before a fix is available, and never attach voice recordings or
dictated text. A written description is sufficient.

## Security-sensitive behavior

The following are considered vulnerabilities:

- transmitting audio, recognized text, or unrelated keystrokes off the Mac;
- storing that data outside the locations and retention rules documented in
  `README.md`;
- bypassing model checksum verification;
- allowing an unsigned or incorrectly signed application update;
- using Accessibility permission to insert text or trigger actions outside the
  requested dictation flow.

Current recordings live under
`~/Library/Application Support/OpenRamble/Takes` and are deleted after
recognition. Recovery audio after a technical failure may remain under
`RecoveredAudio` within the limits documented in the README. Recognized text is
never written to disk. These directories are excluded from backups.

The app is intentionally not sandboxed because inserting text into other apps
requires Accessibility access. The presence of the global hotkey monitor and
the explicit model download from Hugging Face are documented product behavior,
not vulnerabilities by themselves.

## Release key

The Sparkle private key is stored outside the repository and CI. It is the only
key that can update existing installations and must never be regenerated. If a
compromise is suspected, stop publishing the update feed and begin an incident
response; do not create a replacement key as an automatic recovery step.
