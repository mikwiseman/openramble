# October Mini: follow-up hypotheses

These are prospective experiments, not conclusions. The primary registered
timing series runs first with its frozen binary and source identity.

1. **Independent models improve file throughput.** Complete three paired
   rounds on RU, EN and alternating RU/EN composites and compare with the
   shipping prefetch pipeline. Require identical chunk texts, ordered words,
   final text and timestamps, no new memory-pressure failure, and at least a
   repeatable 10% improvement. Two models cost about another model's memory.
   Four models have now hit memory pressure in two resource conditions,
   before inference; they have no speed result. The September user preference
   for the simple one-model default remains relevant. Any implementation must
   preserve that default and justify an explicit opt-in separately.

2. **Locate mixed-language omissions before changing algorithms.** Compare
   the model's raw per-chunk text with the stitched transcript. Use the frozen
   public source utterances to identify words absent before joining versus
   words discarded at a seam. Check early/middle/late positions, English and
   Russian, and exact parity across scheduling profiles. Do not describe a
   model limitation as a joiner defect without a reproducing case.

3. **Long-file cut policy can trade speed for completeness.** If omissions
   are already in raw chunks, compare the existing 15/30/60 second file policy
   on the same public fixtures as an explicitly exploratory quality map.
   Existing evidence says more boundaries can cause language flips; shorter
   chunks are not assumed to improve quality. Keep actual text, word times,
   elapsed time and memory. A proposed default needs a disjoint public holdout
   and separate RU/EN gates; a gain on this development composite alone is
   insufficient. Reject settings that merely finish faster by omitting speech.

4. **Streaming tail and queue behavior.** Finish the real-time RU/EN short
   and minute matrix, then the separately labelled settled and immediate-stop
   six-minute diagnostics. Inspect uncompleted cuts and feed lateness when
   p95 grows. Test a correction only against a specific reproduced cause.

5. **Read only the unrecognized tail at Stop for file-backed dictation.**
   Source inspection found that DictationController reopens and reads the
   complete WAV into one array after the five-minute memory cap, even when
   all earlier segments are recognized. Its final decode uses only the tail
   (or last segment plus a tail shorter than two seconds). A narrow canonical
   16 kHz mono seek can preserve exactly the same samples while avoiding
   unnecessary I/O and allocation. This has not been benchmarked or changed.
   First compare measured Stop time with the last decode call. If justified,
   add a failing range-read regression, preserve complete-file length checks,
   cancellation and failed-prefix fallback, and compare full-read versus
   range-read paths on identical six-minute and long public captures. Generic
   resampling must keep its existing semantics; do not seek into a stateful
   converter and claim sample parity without proof. Wire the app only after
   exact sample/text parity and a repeatable end-to-end improvement.

Closed without a new mechanism: native multi-item batches (September 0.2.3
variable-length parity failure and usually <10% gain), forced language tags
(ignored by Parakeet), smaller short-dictation windows (language instability),
and the archived Core ML endpoint caches. Do not repeat these as fresh wins.

No claim that a finite benchmark map proves every device, accent, real meeting
or destination application's insertion time. No new release or Product Radar
submission is part of these experiments.

## Tail-read candidate sketch, before implementation

Keep `readSamples` for existing callers. Add an optional callback that receives
URL, starting frame and expected total frame count. Validate the streamed
sample counts before selecting the tail; a tail shorter than two seconds
must include the previous segment, exactly as today. Share that calculation
between memory and file paths. The caller must return exactly the requested
suffix; never substitute a truncated suffix or drop prefix errors.

For canonical mono 16 kHz capture, open AVAudioFile, validate the total length,
seek to the starting frame and read the suffix on the existing disk queue.
For non-canonical conversion, retain sequential conversion from the beginning
and discard prefix samples as they arrive, so resampler state cannot shift
samples. This helper adds no network path.

Regression sequence: introduce the optional callback seam while retaining
old behavior, then run a test asserting it is used and full-read is not called
for a valid file-backed prefix. Record the expected failure. Implement the
range path; verify normal and <2-second tails, truncated/mismatched lengths,
failed-prefix whole-file fallback, cancellation and single insertion. Reader
fixtures compare the suffix sample-for-sample with existing complete reads,
including resampling fallback. No speculative re-decode or model change.

Acceptance experiment: same post-change binary, full-read versus suffix-read
selected only by harness configuration; balanced AB/BA on RU/EN six-minute
and 59-minute public composites, normal and CPU pressure. Keep Stop-to-sink,
last decode, exact text and sample hashes, memory, and failures. Lower Stop
latency on the longest case and bounded additional memory are the hypotheses;
no claimed improvement based only on the six-minute smoke, whose overhead
outside the last decode was about 17 ms (4%).

The replay harness retains its source fixture in memory in both variants.
Process peak memory therefore includes that replay buffer; it is not a direct
measurement of the shipping microphone capture's steady-state memory. The
paired variants can show the extra whole-file allocation at Stop, while exact
sample hashes check that the optimized read does not change the final input.

## Observed resource qualification

The fresh two-model series also hit a pressure warning on EN repeat 2 after
fifteen complete files. Timing benefit alone therefore does not pass the
registered no-new-resource-failure adoption gate. The optional parallel
implementation under work/prototypes/parallel is an untested prototype, not
a product decision. Idle apps were then quit normally and the failed pass
resumed. Keep that condition change and the failed attempt in the report;
do not hide it behind successful-run medians.

## Frozen follow-up plans, written before candidate inference

`work/experiment-plans/segment-caps.json` contains nine exploratory runs:
three existing cap settings (15/30/60 s), three long public fixtures, one
model, cyclic profile order. This is a quality/localization sweep, not a
tail-latency estimate. A candidate would need at least two percentage points
lower mixed WER, no more than 0.5 percentage points higher mono WER or
deletions, then independent held-out public composites and repeated timing.
No default is chosen merely by the best score among these nine runs.

`work/experiment-plans/tail-read.json` contains 40 paired diagnostics. Normal
desktop: RU/EN, six-minute/59-minute fixtures, full/suffix reads, three
alternating repetitions. CPU pressure: three repetitions on six-minute inputs
and one diagnostic pair per long language. Pacing is settled, so these measure
the Stop path after the prefix is complete, not a live end-to-end meeting.
Require identical final text, final input sample hashes and decode sample
counts, all lifecycle tests, no new pressure failure, and at least 10% lower
normal long-input median Stop time. Keep short-input drift and CPU-pressure
results visible; the single long pressure pair cannot establish a percentile.
The app is wired only if evidence supports the candidate. The old full read
remains an injected compatibility path and a within-binary benchmark control.

For a quality candidate, `work/experiment-plans/heldout-selection.json` seals
50 further FLEURS items per language (ranks 100–149 in the existing seeded
order), disjoint from the current 200. References were saved by script but
not inspected for tuning. Audio will be extracted only if a candidate passes
the development gate; existing pinned archives suffice. This is held out
from the current experiment, not a claim about the model's training data.

## Additional quality hypothesis from the raw-text audit

Raw mixed chunks still omit 27.73% of reference words; the final join omits
33.80%. Different edit alignments prevent interpreting the difference as an
exact causal seam-loss count. The new cap sweep will also save each native
word's times, so a separate joiner can be checked without repeating inference.

Before inspecting those times, freeze this candidate: preserve the existing
two-word matching branch; on a no-match seam, concatenate the recognized
words if the previous last word ends at least 0.6 seconds before the incoming
first word starts. Otherwise use the existing midpoint boundary rule. The
0.6 seconds comes from the existing match-jitter threshold, not a tuned sweep.
The hypothesis is that the midpoint fallback discards useful overlap context
even where the two decoded word sequences have no temporal overlap. Do not
change empty-result handling in this candidate.

First reproduce the current joiner's exact words and timestamps in the audit
script. Then compare the one frozen candidate on all three development long
files. Use the same >=2 percentage-point mixed-WER gain and <=0.5-point mono
WER/deletion regression gate as the cap sweep. If it passes, evaluate the
sealed held-out public set before any production change. A synthetic timing
unit fixture must fail against the original fallback before a fix is trusted.

If both cap-only alternatives pass the development quality gate, select the
smaller mixed WER, then the smaller summed RU/EN WER, then the smaller cap.
Do not use the one-pass exploratory timings to choose among them. Open the
sealed holdout only for the selected candidate; do not tune against its text.

## Prospective joint replay amendment, 9 October 2026, before candidate inference

The nine planned cap runs already retain native word times. Replay the
unchanged joiner exactly at every cap, then apply the same frozen gap rule at
every cap. This yields a six-policy exploratory quality map without extra
model runs: caps 15/30/60, each with the original or gap-preserving joiner.
Compare all five alternatives against cap 30 with the original joiner. The
same >=2-point mixed WER gain and <=0.5-point mono WER/deletion regression
gates apply. Select only on development data: lowest mixed WER, then summed
RU/EN WER, then fewer changed settings, then smaller cap. Freeze that single
selected policy before opening the heldout set. No production change based
on a development win alone. If further hypotheses are invented after seeing
heldout results, reserve another disjoint set before evaluating them; the
first heldout set is no longer unseen validation for adaptive follow-ups.

## File plumbing timing diagnostic

Across the completed one-model file runs, the median total time outside the
summed engine calls was RU 0.176 s, EN 0.158 s, mixed 0.171 s, out of about
67–71 s total. This leaves less than 0.3% for file plumbing in this warm-cache
experiment. It does not justify an I/O or joiner optimization for file speed.
This is separate from reading an entire long capture again at dictation Stop.
Two-model call durations overlap, so subtracting their sum from wall time
would be invalid. Evidence: work/file-results/engine-call-share.json.

## New resource condition: four-model requalification

After the prior four-model warnings, idle Chrome, Brave, Claude, Telegram
and Simulator were closed, then the other QA builds/simulators finished.
The normal-pressure controller series is now stable and memory_pressure -Q
reports about 68% free system memory during a one-model run. This materially
differs from the earlier four-model smoke conditions. After the entire
primary baseline finishes, take a fresh resource snapshot. If pressure is
normal, no builds/tests are active, and the same free-memory query remains
at least 50%, run a new smoke suite with max-workers 4. Abort on any pressure
warning as before. Do not force the job past the safety gate.

If this smoke passes, run a separate fresh file suite with 1/2/4 independent
models, three alternating repetitions per language, plus the three shipping
controls (30 complete jobs). Keep it separate from files-v3; do not pool
measurements across these desktop conditions. Check the same exact text,
word-time and chunk parity gates. Prior warnings remain visible. A success
under a quieter desktop does not establish safety under arbitrary workloads
or justify changing the one-model default automatically.

## Conditional next mechanism: earlier pause-aligned file cuts

If the cap/joiner family leaves substantial mixed-language loss, test a
different mechanism from the previously closed arbitrary short-dictation
windows: retain the 30-second hard cap but allow a cut at an observed pause
after four seconds, instead of waiting fifteen seconds before a pause can
cut. The current mixed composites alternate whole public utterances, and
the individually decoded source clips had far less loss than the long mixed
file. Earlier pause ownership may reduce language changes inside a chunk.
This is a hypothesis, not a diagnosis; two-second overlap can still carry
another language, and short windows can still cause language instability.
Keep the existing overlap/joiner initially, verify all audio coverage and
actual cut positions, compare RU/EN/mixed quality and complete-file time,
then require independent heldout validation before changing a default.
Do not reopen generic smaller-window or native-batch sweeps without this
specific pause-alignment distinction. No implementation or inference yet.

## Metadata-only holdout correction before inference

The first rank-100–149 selection had no recording-ID overlap, but seven
reference phrases per language also appeared in development, and it had
within-holdout repetitions. No heldout audio or recognition result had been
examined. The selection was corrected using only metadata/hash comparisons:
from rank100 onward, skip normalized references present in development or
already selected, until50 distinct phrases per language are chosen. The last
selected ranks are162 (RU) and169 (EN). Both recording-ID and normalized-phrase
overlap are now zero. The original unused selection is retained as
heldout-selection-v1-unrun.json. Revised sealed SHA-256:
6bdb237b31e1fdd75ff61b4d2c14c2d17d72235eb3479868f64702fcaa69968e.
The preparer uses the same afconvert PCM16 conversion as development, checks
archive hashes and rejects duplicate audio hashes after extraction.

The earlier-pause prototype is now prepared under work/prototypes/pause,
without changing the active source. It injects minimumSeconds=4 only through
the research harness; the default remains15. The existing preferred700ms
pause, relaxed350ms pause, overlap and30s hard cap stay unchanged. The added
unit fixture uses1s pauses and checks exact audio windows, contiguous boundary
ownership and an earlier first cut for both URL and sample inputs. First run
it with the new parameter ignored to observe failure, then enable it.

If this conditional family is needed, early-pauses.json adds three file
runs (RU/EN/mixed) to the nine cap runs. Replay both joiners on their native
words as well, yielding eight development policies. The same selection
gates and order apply, counting a changed minimum as one changed setting.
Keep the revised heldout closed until this development selection is settled.
The existing0.5s inserted fixture gap alone is shorter than the700ms preferred
pause; observed cuts, including silence inside the public clips, must confirm
that the experimental minimum actually changes segmentation.

## Meeting coverage diagnostic, registered 11 October before candidate inference

The completed baseline EN minute input has65.35% deletions and only two
submitted segments, with no final decode at Stop. The near-zero Stop time
is therefore not useful speed evidence. The source meeting policy suppresses
audio below a fixed0.02 peak threshold, unlike imported-file preservation.
First record native submitted frame intervals and peaks of unsubmitted gaps
to distinguish pre-recognition omission from engine omission.

meeting-coverage.json compares the unchanged meeting policy against its
existing preserveQuietAudio flag on RU/EN minute and six-minute inputs, one
pass each in alternating order. Both variants use the same new binary and
post-timer coverage instrumentation. This is a localization experiment, not
an adoption or latency-tail estimate. No global threshold is tuned here.
Preserving quiet audio may decode noise or microphone echo deliberately
suppressed by the live capture layer. It must not become a live default
without separate silence, cross-channel echo and heldout speech checks.
The original baseline stays in the report with its actual omissions.

## Conditional pause-context hypothesis, registered11October before candidate inference

The current file policy reads2seconds of context on both sides of each cut.
Even a cut aligned to a language-changing pause can therefore introduce
the neighbouring language into an otherwise single-language chunk. Test
250ms context, shorter than half the preferred700ms pause, at cap30 with
minimum4and15seconds on RU/EN/mixed inputs. This is six exploratory runs
in narrow-context.json, after the cap and early-pause families. It remains
a hypothesis: some cuts are forced and some pauses are relaxed to350ms.

Keep the minimum final decode at2seconds and retain2seconds of lookahead
for short-tail merging, independently of the context length. The regression
checks exact audio windows, contiguous ownership, whole-file coverage, and
that a1.13s final tail is still merged. First expose but ignore the parameter
and observe the test failing, then implement the context choice. Defaults
remain2seconds. No inference or production change has occurred.

If this conditional family is run, the joint selector considers twelve
policies from18native file runs: six cut/context settings, each with either
joiner. Use unchanged quality gates, then the same tie order, additionally
count a nondefault context as a changed setting and prefer more context for
otherwise exact ties. Settle the full development map before opening the
sealed holdout. These are exploratory comparisons, not twelve independent
confirmatory claims.

## Four-model long-run failure,11October

The quiet-host smoke passed and the first long RU/EN/mixed four-model runs
completed with exact text, word-time and chunk parity. However, the second
RU four-model run warned at9.43seconds process age and sampled physical
footprint3,534,081,456bytes. It was terminated. No compiler was running.
Thus a short qualification and65% initial free-memory estimate did not
establish stable four-model operation. No repeated retries under unchanged
conditions are justified. Preserve these three n=1 four-model diagnostics
and the failed attempt; finish only the1/2-model and shipping controls.
The original30-job plan is preserved as plan-original-30.json. The complete
amended cohort is24successes, with n=3 for1/2-model cells and n=1 forfour.
Do not label the four-model timings as repeatable medians or a safe default.

## Meeting offset invariant found during source review,11October

The leading-silence trim retains one second in absolute segmentStart but
resets SpeechSegmenter's relative pending counter to zero. A later pause cut
can therefore end one second too early. Before accepting this diagnosis,
run a pure regression:5seconds quiet,12seconds speech,1second quiet; the
returned segment must extend at least to absolute17seconds. The work-only
prototype restores the retained quiet prefix to the relative counter.

Do NOT apply this fix before the eight coverage-localization runs: retain
the old native policy long enough to inspect its intervals. Then run the
new regression against the old code, apply the narrow accounting correction,
and rerun the four original-policy RU/EN minute/six-minute inputs. Verify
all existing silence, forced-cut and capture/echo tests. This exact-coordinate
correction is distinct from lowering a speech threshold or decoding quiet
channels; preserveQuietAudio remains false by default. No inference or
compiled regression result exists yet, so no improvement is claimed.

The later RU two-model repeat2also warned after64.50seconds, at a sampled
footprint1,855,244,424bytes. Another task was entering simulator QA around
this interval; no compiler was present at the failing sample. This does not
establish a sole cause. Physical-footprint inspection then identified two
long-idle Kimi CLI trees, about1.59GiB combined, with only idle MCP helpers.
Under the user's resource authorization these exact trees received SIGTERM;
no files or histories were removed. Pressure stayed normal and the free-memory
query rose from50%to53%. Resume the same remaining1/2-model jobs once under
this recorded changed condition. Timings span this cleanup and cannot support
a no-new-memory-failure adoption claim. Do not retry four models.

## Scaling branch closure,11October05:40UTC

The cleanup was followed by a successful RU two-model repeat (58.2487s),
but four later attempts in total were interrupted by unrelated compilation.
With persistent pressure level2 before inference, the remaining seven jobs
were cancelled. The supplementary diagnostic contains17successes and6failed
attempts (2pressure,4compiler). It is not a completed timing matrix. Keep the
complete21-job primary file series for medians and presentation bars, and
show these17separately with their actual n and chronology. Both multi-model
adoption gates remain failed. This scheduling hypothesis is closed without
further retries; investigate quality and suffix I/O mechanisms next.

An idle OpenStrudel UI quit normally. Warp declined normal quit and was left
running. The attempted non-interactive disk-cache purge required a password
and did not execute. No file or chat history was deleted.
