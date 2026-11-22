# Model benchmark ledger, November 2026

Mik's request on 22 November 2026: benchmark the models that change
OpenRamble, and benchmark how much slop they produce. Each entry records the
question, what was measured, and the decision. Negative results stay.

Checkouts with builds and the full transcripts are outside the repository, in
`~/.openramble/model-bench/`. Each run's change, final message, trace of tool
calls, measurements and grade are in `results/`.

## L1. Is the history a usable source of tasks?

**Measured.** `git log --first-parent` on `cc81ce2` gives 83 squash commits
titled "Title (#N)". I listed each one's size and test files, and read the
descriptions of 97, 88, 39 and 5.

**Result.** The history is usable, with limits.

- About 30 pull requests are one theme, under 600 lines, and carry tests.
- 18 are release notes or version bumps, and about 20 are 1,000 lines and more
  with several themes.
- The descriptions say what was wrong before they say what was done, so a
  request can be written from the first paragraph alone.
- The test added by #5 searches `build-dmg.sh` for the literal lines of the
  fix. A different correct fix would fail it. #39, #41 and #78 have no test.
- The Rust core is changed inside large pull requests and almost never alone.

**Decision.** Three kinds of task. A replay task starts at the parent of a pull
request. A follow task starts at a pull request with the Rust half removed,
which gives Rust tasks that the conformance fixtures grade exactly. A trap task
has "change nothing" as the right answer. Where the history has no test of
behaviour, the grader's test is written for the task and the task file says so.

## L2. Which tools can run a model headless on this Mac?

**Measured.** One-word prompts on 22 November.

| Tool | Result |
|---|---|
| Claude Code 2.1.318 with the OpenAccs profile "Lisichka Personal" | Works. `claude-fable-5-2` and `claude-haiku-5-5` answered. The result record carries tokens and cost at list price. |
| Claude Code with the default `~/.claude` profile | Not signed in. |
| The `claude` wrapper inside a desktop session | Refuses, because the desktop app sets `ANTHROPIC_BASE_URL`. A clean environment fixes it. |
| Codex CLI 0.169, `codex exec --json` | Works. `gpt-6.2-sol` answered. The record carries tokens and no cost. |
| `openaccs-agent run` | Not usable as the runner. It denies shell commands in write mode and records no tokens. |

One prompt with an 18,000-token system prompt cost $0.107 on Fable 5.2 and
$0.0014 on Haiku 5.5 at list price, a factor of 75.

**Decision.** The harness starts the native tools itself, with the sign-in that
OpenAccs reports as selected. The pilot uses Claude Code and Codex. Kimi,
Cursor Agent, OpenCode, Gemini, Amp and Droid are installed and untried.

## L3. Can a run be isolated and still build?

**Hypothesis.** A macOS sandbox profile around the whole tool can hide the
other checkouts and confine writes, without breaking the Swift and Rust builds.

**Measured.** In an export of `cc81ce2`, inside a profile that denies reading
the other checkouts and writing outside the folder and the build caches, at a
load of 7 to 9:

| Step | Result |
|---|---|
| `cat` of the main checkout's README | "Operation not permitted" |
| `swift build` | Fails. SwiftPM applies its own sandbox, and a sandboxed process may not. |
| `swift build --disable-sandbox`, through a wrapper on the path | Works |
| DictationCore, cold build with tests | 19 s, 245 MB |
| DictationCore tests | 99 s |
| LocalASR, cold build with tests | 17 s, 255 MB |
| LocalASR tests | 54 s |
| `cargo test -p ramble-text -p ramble-core` | 5 s |
| Network gate | 2 s |
| `./scripts/check.sh --fast` | green, 365 s, and the folder grows to 2.5 GB |

**Decision.** Every run and every grading step runs inside the profile, with
the `swift` wrapper. Cold builds are cheap enough that no prepared build is
kept, which also suits a disk with 7 GB free. The harness refuses to start a
run with less than 4 GB free, and deletes each folder when its run is graded. Each task names the parts of the
repository's check that its change can affect, because the whole fast check
takes too long to run for every grade and contains timing tests that fail at
random on a loaded Mac.

**Not solved.** The profile cannot filter the network by host name. The
transcript audit voids a run that fetches the repository. A proxy that allows
only the model's API host is the next step if that ever happens.

## L4. What makes Theo's benchmarks pleasant to read?

**Measured.** I read the repositories `T3-Content/SnitchBench`,
`T3-Content/skatebench` and `T3-Content/quipslop` on 22 November.

**Result.** One question per benchmark, a behaviour stated as a rate, the
author's own subject as the answer key, 20 to 30 runs per cell, cost next to
score, and anonymous votes between two outputs. `DESIGN.md` lists what we copy.

## L5. Does each tool give its model the same instructions?

**Hypothesis.** With settings turned off, neither tool adds anything of Mik's
to the prompt, so the two conditions of Slop mean the same for every model.

**Measured.** I asked each model which instructions, memories and skills it was
given, with a prompt that contained nothing else.

| Tool | Before | After the fix |
|---|---|---|
| Claude Code, `--setting-sources ''`, `~/.claude` hidden | No project document, no skills, no memory files. A memory folder for the working folder is offered. | The same. The harness deletes the folder's memory before and after every run. |
| Codex, `--ignore-user-config`, `project_doc_max_bytes=0` | It quoted the first words of Mik's global `AGENTS.md` and had the skills catalog. 25,900 input tokens. | No instructions, no skills, no memories. 16,400 input tokens. |

**Result.** The hypothesis was false for Codex. The flags do not stop Codex
from reading `AGENTS.md`, `skills` and the memories in its home folder.

**Decision.** The sandbox profile hides those paths for every run. Hiding the
`rules` or `agents` folder makes Codex exit with "Operation not permitted", so
those two stay visible. Mik's instructions now reach every model the same way,
inside the prompt, or not at all.

## L6. Can the grader say no?

**Measured.** `bench replay check` and `bench replay wrong` on each pilot task.
The wrong change is one that a careless engineer could send.

| Task | Parent | Reference | Wrong change | What the wrong change does |
|---|---|---|---|---|
| `r39-clipboard-gate` | fail | pass | fail | Gives the unset variable a default, so the error goes and the check still matches nothing |
| `r97-handsfree-stop` | fail | pass | see L8 | Replays the second press, and also lets a key release end a hands-free take |
| `r88-conjunction` | see L8 | see L8 | see L8 | Fixes Swift and leaves Rust and the fixtures behind |
| `t-exists` | pass | pass | fail | Adds a second switch for what the first switch already does |

`r39` has no test in the history, so the grader's test was written for the
task. The test plants a plain `clearContents()` in the app's sources and expects
the gate to turn red and name the file.

## L7. First run end to end

**Measured.** `bench replay run r39-clipboard-gate haiku`, Claude Haiku 5.5 at
high effort, load 11 to 8.

**Result.** Pass in 3.6 minutes, 845,000 tokens of which 784,000 were cached
input, $0.02 at list price, 16 tool calls. The model defined the missing
pattern, as the reference does. It also wrote a 60-line test script and wired
the script into `check.sh` and the CI file, which nobody asked for. The request
did say "show me the gate catches what it is there to catch", so a test is a
fair reading. The reference instead reported that the gate exits 1 on a planted
line. The report was 217 words.

**Decision.** The harness works. The size ratio counts source lines only, so
the test script does not count against the model, and the two edits to
`check.sh` and the CI file do (9 lines against 6).

## L8. The wrong changes for the two Swift tasks

**Measured.** `bench replay check` and `bench replay wrong`, at a load of 26 to
29 after the Mac restarted.

| Task | Parent | Reference | Wrong change |
|---|---|---|---|
| `r88-conjunction` | fail | pass | fail, on the hidden tests |
| `r97-handsfree-stop` | fail | pass | recorded below when the run ends |

The wrong change for `r88` is the reference's own Swift half. The Swift tests
pass, and the grade is still a fail, because the Rust core no longer reproduces
what the Swift pipeline writes. So the grader checks the rule that a change to
behaviour lands in both places.

## L9. Three faults of the harness, found by reading the logs

A missing result looked like a result three times on 22 November. Each time the
harness had marked the result as missing, and none was scored.

1. **21 of 22 Fable prompts returned nothing.** Four prompts start at once, and
   all four asked which sign-in to use. The first one was still asking OpenAccs
   when the other three read an empty answer, started Claude Code without a
   sign-in, and got "could not verify the saved Claude.ai Max or Team login".
   The lookup now happens once, behind a lock.
2. **All 22 GPT prompts were dropped.** Codex reports "Failed to read global
   AGENTS.md" as an error item, because the sandbox hides that file on purpose
   (L5). Codex then answers normally. The harness treated every error item as a
   failed run. That one message is now expected.
3. **Sonnet wrote tool calls as text in 2 of 22 prompts**, e.g., a reply that
   began "I'll check the release docs" and then a `Read` call in plain text.
   Claude Code's system prompt describes an agent with files and tools, and the
   text situations run with tools turned off. Both cases were in the condition
   without Mik's instructions. Every text prompt now begins with one sentence
   that says there are no tools and no files, and the report counts any output
   that still contains tool markup.

**Decision.** All text outputs made before these three fixes were deleted and
run again, so every model has the same prompt and the same sandbox.

## L10. Who judges

**Hypothesis.** A judge marks its own vendor's writing more kindly.

**Decision before measuring.** The judge that marks slop is Claude Opus 5.5,
which is not one of the four models it marks. Blind pairs are judged twice, by
Claude Opus 5.5 and by GPT-6.2 Sol, and the report gives how often they agree
and how many pairs each model wins under each judge. What a run's report claims
("done", "checks pass") is also read by the judge, because a word pattern for
it matched ordinary sentences.

## L11. A stopped run that kept working

**Measured.** I compared each run's time as the harness measured it with the
duration in the tool's own result record. For Sonnet on `r39` the harness said
56 s and the record said 95.6 s. The transcript held two sessions.

**Cause.** I had stopped the pilot with `pkill`. The harness died, and the
Claude Code process it had started lived on, because the tool runs in its own
process group. The next Sonnet run exported a fresh checkout to the same path
and started while the first process was still editing there. Both wrote to one
transcript.

**Decision.** That run is void and was run again. The harness now kills the
tool's process group whenever it stops, also on SIGTERM. A transcript with more
than one session makes the run void. I checked the other five runs made by
then, and each transcript has one session.

## L12. The Mac slept in the middle of the pilot

**Measured.** `pmset -g log` shows the lid closed at 17:07 and opened at 18:35,
with the Mac on battery at 19% and then 11%. A Sonnet run was open across the
sleep, and the judge calls made in that time failed with DNS errors. The
harness had marked each failed judge call as missing, and a second pass got all
of them (88 marks and 264 picks, none missing).

**Decision.** A run's time is now measured on the monotonic clock, which stops
while the Mac sleeps, and the seconds asleep are recorded beside it. The pilot
runs under `caffeinate -i`, which holds off idle sleep and cannot hold off a
closed lid. The two tasks that build Swift waited until the Mac was on power.
