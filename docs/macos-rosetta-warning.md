# Investigating the macOS 28 compatibility warning

Apple's warning about an app or component not opening in macOS 28 concerns
Rosetta usage. Notifications began in macOS 26.4; general Rosetta support ends
after macOS 27. See [Apple Support](https://support.apple.com/en-us/102527)
and the [macOS 26.4 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-26_4-release-notes).

The presence of an x86_64 slice does not itself make a universal app dependent
on Rosetta. macOS can select its arm64 slice. A process explicitly launched
with `arch -x86_64` does require Rosetta on Apple Silicon. See
[Apple's universal binary documentation](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary).

## Findings on 11 October 2026

- Installed OpenRamble 0.31.2 (74) and the official 0.32.0 (75) DMG contain
  arm64 and x86_64 slices in all eight Mach-O components: app, CLI, inference
  runtime and five Sparkle executables/libraries.
- The 0.32.0 DMG passed strict recursive signature verification. Its CLI
  successfully recognized a public speech sample when explicitly launched
  as arm64 with network access denied.
- A sample of the running 0.31.2 GUI process reported `Code Type: ARM64`.
  Sparkle and CTranscribe were present in its loaded-image list.
- On the available M4 / macOS 26.4 (25E246) host, the installed CLI's arm64
  `--help` succeeded. The same CLI forced to x86_64 failed with `Bad CPU type
  in executable`; Intel translation is not available for that test on this
  host. The Rosetta package receipt was also absent.
- Seven days of retained system events, the readable notification database
  and inspected LaunchServices preferences did not identify the original
  warning. Absence in these stores does not establish that it never appeared.

The attached user screenshot's exact executable, version and launch host have
not been established. These results do **not** constitute a test on macOS 28
or a confirmed fix for that screenshot.

## Release smoke is an intentional Intel execution path

`scripts/smoke-installed-artifact.sh` runs the CLI's `--help` and actual offline
recognition under both architectures. On an Apple Silicon release host with
Rosetta this deliberately executes Intel code. It is a plausible source of a
warning during release testing, but was not established as the source of the
reported screenshot. It cannot be claimed as a reproduced trigger on the host
above, where the Intel launch failed before the CLI ran.

Retain both release checks. Do not remove the Intel slice, re-sign the bundle,
or suppress the system's warning merely to make the alert disappear.

## Evidence needed when the warning recurs

Record the host's macOS version, the exact app/CLI path and version, warning
time, and whether the launch was normal or part of the release smoke. Check
each embedded Mach-O with `lipo -archs` and sample the running app to distinguish
ARM64 from translated Intel execution. Check Finder's existing “Open using
Rosetta” choice and any external plug-ins on that host.

If a normal launch actually chooses Intel code, fix that particular dependency
or architecture selection and repeat the same launch. If only the intentional
Intel smoke produces the warning, report it as test execution of Rosetta and
verify the native path independently. Do not label an uncorrelated warning a
false positive or claim compatibility with an OS that has not been tested.
