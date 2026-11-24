Fixed and committed as `fda1ee5`. The unset `FORBIDDEN_PASTEBOARD` variable killed the clipboard scan in a subshell. The gate treated the empty result as a pass.

I fed both versions the same shipping `pasteboard.clearContents()` call. The old gate exited `0`. The fixed gate exited `1` and printed the file and line. CI now checks that host-only writes pass and that forbidden calls and scan errors fail.

All 89 DictationCore tests passed. The LocalASR binary was unavailable offline.
