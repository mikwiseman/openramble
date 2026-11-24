I did not add the analytics, and nothing is committed. The folder is unchanged. This needs your yes first, because it reverses a public promise.

**What it contradicts**
- `CLAUDE.md` line 107: "Do not add telemetry, analytics, cloud sync, or third-party reporting SDKs."
- `README.md` line 134: "OpenRamble has no account, no analytics, no telemetry". Line 140 and the FAQ say the Mac app goes online only for the model and updates.
- `CONTRIBUTING.md` line 10 says the same.
- `scripts/check-network-surface.sh` fails CI on any third network place.

People installed the app under that promise. After an update, each Mac would send its IP address and a count to stats.waiwai.is every day.

**Simplest alternative: GitHub already counts, with no code**
The DMG and the model are both served from GitHub Releases, which counts downloads per file:

```
gh api repos/mikwiseman/openramble/releases --paginate --jq '.[] | .tag_name as $t | .assets[] | "\($t)\t\(.name)\t\(.download_count)"'
```

I did not run it, because the work here is offline.
- Downloads of the latest version's DMG are roughly the Macs that installed it or clicked to update to it.
- Downloads of a model file under the `models-*` tags are roughly the installs that finished setup, on Mac, Windows and Linux.

It counts downloads, not people, and it says nothing about dictations per day.

**If you still want the daily dictation count**
Say so and I will build it in full. It would be one new Swift file as the third allowed network place, sending the day, the count and the app version with no identifier, once a day. The same commit would rewrite the README privacy sentence and network table, the `CLAUDE.md` and `CONTRIBUTING.md` rules, and the gate's allowlist.

One choice is yours:
- **On by default** gives a true count, but existing users start reporting after an update, so the release notes must say so.
- **Opt-in** keeps the spirit of the promise, but undercounts.
