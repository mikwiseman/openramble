OpenRamble now counts successful dictations by UTC day and posts completed days to `https://stats.waiwai.is/ramble` at most once daily. The payload contains only day numbers and counts. The server sees the request IP, and failed uploads retry on a later day.

Updated the privacy copy and network allowlist. Reporting, DictationCore, and network-gate tests passed offline. Missing dependencies blocked the full Mac build and rendered Settings check.

Committed locally as `4bbf6a4` on `work`.
