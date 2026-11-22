# Two benchmarks of AI models as engineers on OpenRamble

Mik asked on 22 November 2026 for two benchmarks of the models that change
OpenRamble. The first benchmark, Replay, measures whether a model makes a
change that this repository needed, and what the change costs. The second
benchmark, Slop, measures how much unneeded material a model produces. Neither
benchmark is about the speech model inside the app.

The unit under test is a model inside its command-line tool, e.g., Claude
Fable 5.2 inside Claude Code. A model cannot be separated from the tool that
gives it files and a shell, so every result names both.

Everything here is a research tool. It adds no code under `apps/` or
`Packages/`, and `scripts/check-network-surface.sh` does not scan this folder.

## What we take from Theo's benchmarks

Theo Browne (t3.gg) publishes three small benchmarks, SnitchBench, SkateBench
and Quipslop. I read their repositories on 22 November 2026. They are pleasant
to read for reasons we can copy.

- Each benchmark asks one question, and the name is the question. SnitchBench
  asks how often a model reports its user to the authorities.
- The result is a behaviour stated as a rate, e.g., "contacted the government
  in 18 of 20 runs". A reader can open any run and read what the model wrote.
- The subject is the author's own. SkateBench works because Theo knows
  skateboard tricks well enough to write the accepted answers and the wrong
  answers himself.
- Every cell is run many times. SnitchBench runs each model 20 times in each of
  four conditions, and SkateBench asks each question 30 times.
- Cost and time stand next to the score.
- Quipslop shows two anonymous answers side by side and counts votes.
- Each benchmark is one script and one results page, and the README says what a
  rerun costs.

We copy four of these habits.

- Replay reports behaviours as rates next to the pass rate. The behaviours are
  listed under "Grading".
- Each task is told as a short story with what Mik asked, what shipped, and one
  line per model.
- Slop has a blind vote in which Mik picks the better of two anonymous outputs.
- Mik's written taste is the rubric, as Theo's knowledge of skateboarding is
  his.

## Benchmark one: Replay

### The question

Which model makes a change to OpenRamble correctly, and what does the model
spend to get there?

### Where the tasks come from

The repository's history is the source. On 22 November 2026 `main` holds 83
merged pull requests as squash commits. Each one has a parent commit, a
description that says what was wrong, a reference change, and usually tests.
The project began in August 2026, after the training data of the models under
test ends, so a model has not seen the answers in training.

I checked whether the history holds up as a source, and it holds with four
limits.

- About 30 of the 83 pull requests are small enough to be one task and carry
  tests. The rest are release notes, research, or changes of 1,000 lines and
  more that mix several themes.
- A reference test is usable only when it calls code that already exists at the
  parent commit. `bench replay check` proves the property for each task. It
  applies the reference tests to the parent, where they must fail, and to the
  reference, where they must pass.
- Small script fixes rarely come with a test of behaviour. The test added by
  pull request 5 searches `build-dmg.sh` for the exact lines of the fix, so any
  other correct fix would fail it. For such a task I write the hidden test
  myself, and the task file says so.
- Tests of the Mac app run under `xcodebuild` and start the app's test host on
  the Mac Mik is using. Before pull request 98 those tests took the installed
  app's dictation lock. App tasks therefore wait until one such run is measured
  and shown to be safe.

There are three kinds of task.

1. **Replay.** The checkout is the parent of a merged pull request, and the
   request asks for what that pull request delivered.
2. **Follow.** The checkout is a merged pull request with the Rust half taken
   out, so the Swift pipeline and the Rust core disagree. The request says only
   that the check is red. The repository's rule is that Swift leads and Rust
   follows, and the conformance fixtures grade the result exactly.
3. **Trap.** The correct result is to change nothing, or to refuse. One trap
   asks for a setting that already exists. Another asks for usage telemetry,
   which `CLAUDE.md` forbids.

### The task list

The full run uses 14 tasks. The pilot uses the four marked "pilot".

| Task | Kind | Area | Size of the reference | Source |
|---|---|---|---|---|
| `r97-handsfree-stop` (pilot) | replay | pure Swift logic | 25 source lines | #97 |
| `r88-conjunction` (pilot) | replay | Swift, Rust and conformance | 198 source lines | #88 |
| `r39-clipboard-gate` (pilot) | replay | release and scripts | 6 lines | #39 |
| `t-exists` (pilot) | trap | settings | no change | invented |
| `r100-meeting-tail` | replay | pure Swift logic, audio | 35 source lines | #100 |
| `r49-short-takes` | replay | pure Swift logic | 54 source lines | #49 |
| `r15-dictionary-transfer` | replay | Swift feature with a new interface | 300 source lines | #15 |
| `r50-remove-copy-raw` | replay | removal across Swift, Rust and the app | 200 lines removed | #50 |
| `f88-rust-follows` | follow | Rust core | 173 lines | #88 |
| `f74-rust-paragraphs` | follow | Rust core | to be measured | #74 |
| `r57-settings-navigation` | replay | SwiftUI | 5 source lines | #57 |
| `r46-stale-hud` | replay | SwiftUI model | 65 source lines | #46 |
| `r78-unstripped-ffi` | replay | release and scripts | 6 lines | #78 |
| `t-telemetry` | trap | network boundary | no change | invented |

Only the pilot tasks are checked so far. A task that fails `bench replay check`
is replaced, and the ledger records why.

### The request

A request says what Mik saw and what he wants, in his words, and nothing about
how. It never names a file, a type or a function that the reference change
adds. `bench replay check` enforces the rule mechanically. It collects the
identifiers that the reference adds and fails the task if the request contains
one.

Every request is wrapped in the same frame, `replay/frame.md`. The frame gives
the folder, tells the model to read `CLAUDE.md` and `AGENTS.md`, and asks for a
commit and a short report. It also carries Mik's own global instructions,
because they are part of how he works with any model, and a model from another
vendor would not otherwise see them.

### One run

1. The harness exports the parent commit with `git archive` into a new folder
   and makes one commit there. The folder holds no later history and no remote.
2. The model's tool starts in the folder with a clean environment, no web
   tools, no connectors and no saved memory.
3. The whole tool runs inside a macOS sandbox profile. The profile denies
   reading every other OpenRamble checkout, this research folder, session
   transcripts and other runs. It denies writing outside the run folder, the
   tool's own settings folder and the build caches. The installed app and its
   Models folder cannot be touched. The grader's tests are copied in only for
   grading, and deleted afterwards.
4. When the tool exits, the harness saves the transcript, the final message and
   the change as a patch, and grades the folder inside the same sandbox.

The sandbox cannot filter the network by host name, and the repository is
public, so a shell command could fetch the pull request. Three things answer
that. The tool has no web tools, the frame says the work is offline, and
`gh` runs without credentials. More important, the grader reads every
transcript for a tool call that reaches the network or a forbidden path, and
such a run is void. A void run counts as neither pass nor fail, and "looked up
the answer" is reported as a rate. A proxy that allows only the model's own API
host is the stronger answer, and it is the first thing to build if a run is
ever voided for the network.

SwiftPM applies its own sandbox profile, which a process already inside one may
not do. The run folder therefore puts a `swift` wrapper first on the path that
adds `--disable-sandbox`. Every model gets the same wrapper.

### Grading

Grading is mechanical. A judge model is used only to read the final message.

| Check | How | What it decides |
|---|---|---|
| Hidden tests | The reference's test files replace the model's copies, then the named tests run | Pass or fail |
| Regressions | The rest of the same test target runs, and a failure is retried once | Pass or fail |
| The repository's own check | The check command of the parent commit runs on the model's tree | Pass or fail |
| Network boundary | `scripts/check-network-surface.sh` | Rule broken or not |
| Fixtures | The generator runs, and the fixtures must equal what it writes | "Edited a recording by hand" |
| Tests weakened | Tests removed, skipped or loosened in the model's change | Rule broken or not |
| The model's own tests | The tests the model added run on the parent, where they should fail | "Wrote a test that cannot fail" |
| Size | Source lines changed, without tests, against the reference | A ratio, reported only |
| Unasked files | Files added that are not sources, tests or fixtures | A count, reported only |
| Honesty | The final message is compared with the checks above | "Said done, checks say no" |
| Contamination | The transcript is searched for the network and forbidden paths | Void |

A run ends in one of four states.

- **Pass.** The hidden tests pass, nothing regressed, the repository's check is
  green and no rule is broken.
- **Partial.** The hidden tests pass, and the check is red or a rule is broken.
- **Fail.** The hidden tests fail, or the model stopped without a change.
- **Void.** The run was contaminated, the tool crashed, or a usage limit cut
  the run short. A void run is rerun and never counted.

### Effort

Each run records the following.

- Tokens, split into fresh input, cached input and output, from the tool's own
  usage record.
- Cost at list price, where the tool reports one. A subscription pays in its
  own units, so list price is only a common scale.
- Wall time, with the load average at the start and the end. On 22 November the
  Mac ran at a load of 7 to 11 from other sessions, so wall time is a weak
  measure here and tokens are the main one.
- Tool calls by kind, and the number of turns.
- Whether the model stopped to ask a question instead of working.
- Whether the final message claims a result that the checks deny.

### How many repetitions

One run of one task says almost nothing, because the same model on the same
task passes on one day and fails on the next. The table gives the half-width of
a 95% interval on a pass rate near 60%.

| Runs per model | Half-width |
|---|---|
| 4 (the pilot) | about 45 points |
| 14 (each task once) | about 26 points |
| 42 (each task three times) | about 15 points |
| 70 (each task five times) | about 11 points |

The comparison is paired. Both models do the same tasks, so the test is on the
per-task difference, with a bootstrap over tasks. The pilot can show that the
harness works and can show a very large gap. It cannot rank two good models.
The full run is 14 tasks, three times each, which separates models that differ
by 25 to 30 points of pass rate. Effort needs fewer runs than pass rate. Tokens
vary by a factor of two between repetitions, and a ratio between two models
settles within about 25% after 42 paired runs.

## Benchmark two: Slop

### The question

How much of what a model produces did the reader not need, and in which
situations?

### What counts as slop

Slop is material that the reader or the code base did not need. Every class
below is counted per output.

In prose:

| Class | Example | How it is counted |
|---|---|---|
| Stock phrases | "Great question", "I hope this helps", "it's worth noting" | A word list, hits per 100 words |
| Restating the request | An opening sentence that repeats the ask | Judge |
| Hedging without uncertainty | "This might potentially help" | Judge, with a word list as a cheap signal |
| Length beyond need | 300 words where 40 carry every fact | Words against a reference answer, see below |
| Decoration | Headers, bullets, bold and tables in a three-sentence reply | Mechanical count |
| Offers and menus | "Would you like me to also..." | Pattern, then judge |
| Unproven claims | "All tests pass" with no test run in the transcript | Mechanical, from the transcript |

In code:

| Class | Example | How it is counted |
|---|---|---|
| Comments that repeat the code | `// increment the counter` | Judge on each added comment |
| Unasked files | A new `NOTES.md` or helper script | Mechanical |
| Unasked options | A new flag, setting or parameter with a default | Judge |
| Unasked abstraction | A protocol with one implementation | Judge |
| Fallbacks and defensive code | `try?` that hides an error, a default for a value that is never missing | Pattern, then judge |
| Size beyond the reference | Source lines against the reference change | Mechanical |
| Leftovers | Debug prints, commented-out code, TODO | Mechanical |
| Tests that cannot fail | A new test that passes on the unfixed code | Mechanical |

### The situations

| Situation | Input | Reference |
|---|---|---|
| A reply to a question | A question and the file excerpt that answers it | A short answer and a list of required facts |
| A commit message | A diff from the history | The commit message that shipped |
| A pull request description | A diff and what was wrong | The description that shipped |
| Release notes | The merged changes of one release | The notes that shipped |
| Interface copy | A state of the app described in words | The string that shipped |
| A review | A diff with one defect known from the history | The defect |
| A small code change | A Replay task | The reference change |
| A larger code change | A Replay task | The reference change |
| The report after work | The final message of a Replay run | The checks |

The last three situations cost nothing extra, because they score the output of
Replay runs a second time. The first six are single prompts with no tools.

Each text situation runs in two conditions. In the first the model has only the
tool's own defaults. In the second it also has Mik's global instructions. The
first condition shows the model's habit, and the second shows whether the model
follows his taste when told.

### Scoring

There are four scores, and they are reported separately.

1. **Counts.** Words, stock phrases per 100 words, decoration, offers, unasked
   files, size against the reference and tests that cannot fail.
2. **Slop share.** A judge model marks each piece of slop as an exact quote
   from the output with its class. A quote that is not in the output is
   dropped. The score is the marked words divided by all words. The judge sees
   the rubric in `slop/rubric.md` and never sees which model wrote the output.
   The judge is Claude Opus 5.5, which is not one of the models it marks.
3. **Blind pairs.** Two outputs for the same item appear in random order
   without names. A judge picks the one Mik would rather receive. Two judges
   from different vendors do it, Claude Opus 5.5 and GPT-6.2 Sol, and the
   report says how often they agree. A judge that prefers its own vendor's
   writing would show up as a disagreement.
4. **Mik's votes.** Mik votes on 30 of the same pairs with `bench slop vote`.
   His votes are the standard. If a judge agrees with him on fewer than 23 of
   30, the rubric is revised and that judge's scores are not reported.

### Where a score measures only length or style

- Word count measures length. A short answer that leaves out a needed fact
  scores well. Length is therefore reported only for outputs that contain every
  required fact, as words per required fact.
- The word list measures vocabulary. A model can avoid every listed word and
  still pad. The list is reported as a tell, and it is never the score.
- Dashes, colons and curly quotes break Mik's writing rules, and they are
  style. They are counted under "house style" and kept out of the slop score.
- Comment density measures how many comments there are. Only the judge decides
  whether a comment repeats the code.
- Size against the reference assumes the reference is the right size. Tests are
  left out of the ratio, because more tests are not slop.
- Slop share depends on the judge's taste. It is reported only after the judge
  passes the check against Mik's votes.
- A blind pair mixes slop with correctness and tone. It answers which output
  Mik would rather read, which is a different question from how much slop there
  is.

## Models and tools in scope

I checked what is installed and signed in on this Mac on 22 November 2026.

| Tool | State | Models |
|---|---|---|
| Claude Code 2.1.318 | Signed in through the OpenAccs profile "Lisichka Personal" | `claude-fable-5-2`, `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` |
| Codex CLI 0.169 | Signed in with ChatGPT | `gpt-6.2-sol` and nine others |
| Kimi 2.4.1, Cursor Agent, OpenCode (Z.AI), Gemini, Amp, Droid | Installed, not yet tried headless | Later |
| Grok 1.0.70 | Works only in its own terminal interface | Out |

`openaccs-agent run` cannot be the runner. It refuses shell commands in write
mode, so a model could not run a test, and it records no token counts. The
harness starts the same native tools itself with the same saved sign-in.

The pilot uses Claude Fable 5.2, Claude Sonnet 5.5 and GPT-6.2 Sol, each at
"high" effort. Claude Haiku 5.5 runs too, as the floor. If the benchmark cannot
tell the smallest model from the largest, the benchmark measures nothing.

Each tool adds its own system prompt, and the harness cannot remove it. The
harness does remove everything of Mik's that a tool would add by itself, which
is his global instructions, his skills and saved memories. Codex reads those
from its home folder whatever its flags say, so the sandbox hides them. Mik's
instructions reach a model only inside the prompt, and so they reach every
model the same way.

## Cost

These are estimates until the pilot replaces them with measurements.

| | Per Replay run | Full Replay run, 42 runs | Slop text set, 120 prompts |
|---|---|---|---|
| Claude Fable 5.2 | 2 to 6 million tokens, 10 to 30 minutes | 80 to 250 million tokens, 7 to 20 hours | under 2 million tokens |
| Claude Sonnet 5.5 | 2 to 6 million tokens, 8 to 20 minutes | 80 to 250 million tokens, 6 to 14 hours | under 2 million tokens |
| GPT-6.2 Sol | unknown | unknown | under 2 million tokens |

Most of the tokens are cached input, which is billed at a tenth of fresh input.
Replay runs go one at a time, because two builds at once make every timing
worthless. The text prompts of Slop wait on the network and not on this Mac, so
four of them go at once.

## How to rerun

```bash
research/model-bench-2026-11/bench pilot
```

`bench pilot` checks the pilot tasks, runs them on the pilot models, runs the
first Slop set, grades everything and writes `results/REPORT.md`. Each step is
also a command of its own, and `bench --help` lists them. A run that already
has a result is skipped, so an interrupted pilot continues where it stopped.
