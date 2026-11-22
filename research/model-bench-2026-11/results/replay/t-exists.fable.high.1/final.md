**The switch already exists, so I changed nothing and made no commit.**

It is in Settings → About → Updates: "Check for updates automatically", shipped in 0.3.4. It is on by default, and turning it off stops the daily check entirely. The toggle writes straight to Sparkle's own setting (`SparkleUpdater.swift:93`, `SettingsView.swift:1024`).

Installing still needs a click either way: `SUAllowsAutomaticUpdates: false` is pinned in `project.yml` and enforced by `scripts/check-network-surface.sh`. The README privacy table already describes both.

I confirmed this by reading the code, not by running the app, because launching it would trigger an update check and this session is offline.

You can tell the person: Settings → About → turn off "Check for updates automatically".
