# Runtime 0.4.0 and the next model

This folder holds the preregistered decision about transcribe.cpp 0.4.0 and
about which single model OpenRamble should ship next. The rules were committed
and pushed in [PREREGISTRATION.md](PREREGISTRATION.md) before any output of
runtime 0.4.0, Parakeet Ultra or Nemotron 3.5 existed on this Mac. Every other
hypothesis about the model and the runtime, including the ones that failed, is
in [HYPOTHESES.md](HYPOTHESES.md). The numbers come from the scorecard
(`research/scorecard/`), measured on one MacBook Pro M4 Pro, macOS 27.0.1.

## Runtime 0.4.0 against 0.2.3, both with Parakeet v3

| Rule | Measured | Verdict |
|---|---|---|
| 1. At least 99% of the 1,422 FLEURS transcripts identical; pooled WER within ±0.10 pp | 1,420 identical (99.86%); −0.003 pp, 95% interval −0.01 to 0.00 | pass |
| 2. Wrong script and invented words not more than 0.2.3 | 20 and 0, the same | pass |
| 3. Hour-file deleted words within 0.2 pp | English 4.80% and 4.80%, Russian 1.71% and 1.71% | pass |
| 4. Warm p50 and p95 within 5% + 2 ms; whole-process p50 within 10% | all inputs: warm p50 323.5 → 327.4 ms, p95 1,459 → 1,482 ms idle; 413.6 → 415.7 and 1,988 → 2,010 ms under load; whole-process p50 0.431 → 0.429 s | pass |
| 5. Peak memory within 5% | 1.02 → 1.07 GB (+4.9%) | pass |
| 6. No new end-to-end or unit test failure | end-to-end 21 run, 3 skipped, 0 failed under both; unit 163 run, 9 skipped, 0 failed | pass |
| 7. Binary audit | passes; same frameworks, same selectors | pass |

The two transcripts that differ: in one English sentence 0.4.0 replaces an
inserted "and in" with "and", which leaves the error count unchanged, and in
one Russian sentence 0.4.0 no longer prints a literal `<unk>`, which upstream
fixed in #182. A build of v0.4.0 made here from source gives byte-identical
transcripts to the upstream binary on every input.

Decision: all seven rules pass, and runtime 0.4.0 is adopted. One cost is worth watching: on short takes alone (under 15 s) 0.4.0 is about 8% slower, p50 78 against 72 ms and p95 132 against 122 ms. The rule pools all inputs, so this passes, but it is the first thing to recover in the runtime work.

## Model bake-off: v3, Parakeet Ultra and Nemotron 3.5 on runtime 0.4.0

| | v3 | Parakeet Ultra | Nemotron 3.5 |
|---|---:|---:|---:|
| Pooled WER, 1,422 FLEURS utterances (primary) | 5.51% | 4.78% | 11.91% |
| Difference from v3, 95% interval | | −0.74 pp (−0.91 to −0.56) | +6.40 pp (+5.80 to +7.02) |
| English / Russian WER | 5.45% / 5.57% | 4.91% / 4.64% | 11.42% / 12.39% |
| Gate 1: failed recognitions | 0 | 0 | 0 |
| Gate 2: words invented on noise | 0 | 0 | 0 |
| Gate 3: wrong script, private clips + FLEURS | 20 | 0 | 0 |
| Gate 4: hour deleted words English / Russian | 4.80% / 1.71% | 2.97% / 0.79% | 3.21% / 1.08% |
| Gate 4: alternating hour WER | 39.04% | 39.79% | 46.80% |
| Gate 5: warm p95 over all speed inputs, idle / 14 busy CPUs | 1,482 / 2,010 ms | 1,615 / 2,126 ms | 2,846 / 4,151 ms |
| Gate 6: peak resident memory | 1.07 GB | 1.06 GB | 1.11 GB |
| Gate 7: punctuation F1, English / Russian | 80.9% / 90.8% | 83.3% / 92.6% | 78.0% / 85.3% |
| Gate 7: capitalization F1, English / Russian | 91.4% / 90.9% | 92.9% / 92.8% | 89.0% / 88.4% |
| Warm short-take p50 / p95, idle | 78 / 132 ms | 75 / 125 ms | 144 / 242 ms |
| Whole process p50, idle | 0.429 s | 0.433 s | 0.566 s |
| Model file | 740 MB | 740 MB | 751 MB |
| License | CC-BY-4.0 | CC-BY-4.0 | OpenMDW-1.1 |

Nemotron 3.5 fails the WER rule by a wide margin in both languages, so it is
not eligible whatever its speed; its live streaming was not scored, as
preregistered. Parakeet Ultra passes the WER rule in both languages and gates
1 to 4 and 7.

The most visible difference is the wrong alphabet. On Mik's 199 preserved
English clips, v3 writes 20 decodes in Cyrillic, 17 of them in the 79-point
boundary sweep of one recording; Ultra writes none, and its transcripts there
are ordinary English (median 14 words, no Cyrillic letter at all).

Decision: Parakeet Ultra passes the WER rule and all seven gates and is recommended (`decide.py` writes `decision.json`). The follow-up H11 then compared Ultra's smaller quantizations against its Q8_0: Q5_K_M (550 MB) and Q4_K_M (486 MB) both stay within the preregistered +0.20 pp bound, invent nothing and keep warm p95 within 3%, so the recommended download is **Parakeet Ultra Q4_K_M, 486 MB**, a third smaller than today's 740 MB. On the CPU backend, which the Windows and Linux app uses, Q4_K_M is 1.29 times slower than v3 (H13), while Ultra Q8_0 is within 3% of v3 (H13b). So Windows and Linux get **Ultra Q8_0, 740 MB**, from their own manifest. Intel Macs also run on the CPU backend and are an open question (H14).

## The runtime after 0.4.0

Upstream main (`db678a03`) serves the weights straight from the model file on
Apple silicon (upstream #195). With Ultra Q4_K_M that cuts the app's memory
footprint after load from 753 MB to 269 MB and the model load from 0.19 s to
0.11 s, with all 1,422 FLEURS transcripts and all five hour transcripts
identical and no slower speed (H15). Measured with v3, two end-to-end tests
fail, because upstream #199 runs v3 with local attention on takes over 20.5 s;
with Ultra, main adds no test failure (H15b). So main is adopted together with
Ultra, once there is a published binary to pin. Running the end-to-end suite
with Ultra for the first time also found three failures that Ultra has under
either runtime, listed in HYPOTHESES.md and on #79.

## What adopting a model means for people

Ultra is a drop-in for v3 in the runtime, but it is a new 486 MB download.
The plan requires that the old model keep working until the new one verifies.
Branch `claude/parakeet-ultra` implements that: the app keeps dictating with v3,
offers Ultra in Settings, downloads it only when asked, switches once it
verifies and loads, and only then deletes v3. It also needs the model mirror
release that every shipped manifest names, which is an outward-facing step
for Mik.

## Limits

One Mac and read speech. The private clips are five takes by one speaker. The
upstream model pages report different absolute WER because they score the
full test sets with another normalizer on CUDA; only the differences here are
comparable across candidates.
