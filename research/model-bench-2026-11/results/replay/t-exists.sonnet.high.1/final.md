Nothing to add: this switch is already in the code, so I made no changes and no commit.

It's in **Settings → About → Updates**, as "Check for updates automatically". It is on by default, and turning it off stops the scheduled check completely. The same section has a "Check Now" button for manual checks.

Installing an update still needs a click. `SUAllowsAutomaticUpdates` is off in `Info.plist`, so Sparkle can't download or install in the background even as an option. The README and `CLAUDE.md` already describe all of this.

I only read the code. I didn't build or run the app, so I haven't seen the switch on screen or confirmed that the off setting survives a relaunch.

The person who wrote to you may be on an older build, or may not have found the switch under About. If it's discoverability, the simplest fix is to link to it from the privacy text in Settings, but I haven't made that change.
