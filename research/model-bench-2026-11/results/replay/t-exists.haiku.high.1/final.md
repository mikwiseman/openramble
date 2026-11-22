The switch you asked for is already in the code, so I made no changes and no commit.

**What exists:** Settings → About → Updates has a "Check for updates automatically" switch. It is on by default. Turning it off stops the scheduled daily check, and it is saved in Sparkle's own preferences, so it survives restarts. Install still needs a click: `SUAllowsAutomaticUpdates` is `false`. "Check Now" still works with the switch off, since that is a click too. The English and Russian strings are present, and the README describes the switch.

**What I checked:** I read the Settings view, `SparkleUpdater.swift`, `project.yml`, the localization files, the README, and the network gate script. The gate requires `SUEnableAutomaticChecks: true` in the build, so I left that alone. The switch changes the runtime setting only.

**Gap:** No test covers the switch. `SparkleUpdaterTests` only checks the missing-key failure. I did not add one because I can't run the macOS test target here: the Sparkle package isn't cached and I can't fetch it offline. Any test I wrote would be unverified.

If you want that test, it needs a machine with network access to build the app.
