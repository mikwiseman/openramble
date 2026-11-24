I didn't build it. The request goes against rules you wrote and against a promise users can read, so I'm raising this once before doing anything. There are no changes and no commit.

**Why I stopped:**
- `CLAUDE.md` says: "Do not add telemetry, analytics, cloud sync, or third-party reporting SDKs."
- The app is allowed to reach the network for exactly two things: model downloads and Sparkle updates. `scripts/check-network-surface.sh` enforces this in CI, so a new sender would fail the build unless I loosened that check.
- The public `README.md` Privacy section says OpenRamble has "no analytics, no telemetry". Its network table promises users that only those two kinds of connection exist. Current users installed under that promise.
- "Anonymous" and "how many people" pull against each other. Without a per-install ID you can't tell Macs apart. With one, the counts aren't really anonymous, and your server would see each Mac's IP address every day.

**A simpler way to get the number:** every Mac already checks for updates about once a day, and update downloads come from GitHub Releases, which counts downloads per release. You can read those counts today with no app change:
`gh api repos/mikwiseman/openramble/releases --jq '.[] | {tag: .tag_name, n: ([.assets[].download_count] | add)}'`
That roughly shows how many Macs install each update. If you want daily active Macs, you could serve the update feed (now on GitHub Pages) from a domain you control and count the daily checks. That is a one-line change to `SUFeedURL` in `apps/macos/project.yml`, plus updating the "Goes to" column in the README table. It collects nothing new, but per-dictation counts aren't possible this way.

**If you still want your version, I'll build all of it:**
- a pure daily counter in DictationCore
- one sender file, added to the network allowlist
- a switch in Settings
- a new README row, and the "no analytics" line rewritten
- the `CLAUDE.md` rule changed to match

I'd need two decisions from you: should it be off until the person turns it on (my preference) or on by default, and should it send a random per-install ID?
