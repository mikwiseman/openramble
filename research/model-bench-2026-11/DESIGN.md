# Replay and Slop

Mik asked on 22 November 2026 for two benchmarks of the AI models that change
OpenRamble. Replay measures whether a model makes a change that this
repository needed. Slop measures how much more a model writes than the job
needed. Neither is about the speech model inside the app.

The unit under test is a model inside its command-line tool, e.g., Claude
Fable 5.2 inside Claude Code. A model cannot be separated from the tool that
gives it files and a shell, so every result names both.

Nothing here ships. The folder adds no code under `apps/` or `Packages/`, and
`scripts/check-network-surface.sh` does not scan it.

## What both benchmarks compare

Every item has what was needed and what a model made. For a change, what was
needed is the change that shipped. For a piece of writing it is the text that
shipped, or for a question the short right answer. A model gets these figures.

- **Passed.** How many of its changes passed the tests of the real change and
  every further check.
- **Code.** How many times more lines of code it added than the real change
  added. It is counted only on the changes that every model got right,
  because a small change that is not right is not a tidy one.
- **Words.** How many times more words it wrote than was needed.

The results page, `results/index.html`, is a scoreboard. It shows one ranked
board at a time, and it draws every figure in blocks. The first block is what
was needed, and a pink block is what a model made on top of it. Under the
board, the answer or the change of one model stands next to what was needed.

## What we take from Theo's benchmarks

Theo Browne (t3.gg) publishes SnitchBench, SkateBench and Quipslop. I read
their repositories on 22 November 2026, and we copy these habits.

- One question per benchmark, and the name is the question.
- The page is one ranked board with a name on it, and nothing else. Tabs
  change the question.
- The result is something a reader can open and read, e.g., the email a model
  sent, and not only a score.
- The author's own subject is the answer key. Here it is this repository's
  history and Mik's written instructions.
- Every cell is run many times, 20 to 30 in his benchmarks.

EQ-Bench's slop score adds one more habit, a row for the human baseline. Here
the baseline is the row "Needed", which is one block.

## Replay

### Where the tasks come from

The repository's history is the source. On 22 November 2026 `main` held 83
merged pull requests as squash commits. Each has a parent commit, a
description that says what was wrong, a reference change, and usually tests.
The project began in August 2026, after the training data of the models under
test ends.

The history is usable as a source, with limits.

- About 30 of the 83 are one theme, under 600 lines, and carry tests.
- A reference test is usable only when it calls code that exists at the
  parent. `bench replay check` proves the property for each task.
- Small script fixes rarely come with a test of behaviour. For such a task the
  grader's test is written for the task, and the task file says so.
- No task's check builds the Mac app yet. See "What is not solved".

A task is one of these kinds.

1. **Replay.** The checkout is the parent of a merged pull request, and the
   request asks for what that pull request delivered.
2. **Follow.** The checkout is a merged pull request with the Rust half taken
   out. The request says only that the check is red. None is built yet.
3. **Trap.** The correct result is to change nothing, or to refuse.

### The tasks

| Task | Kind | Area | Lines of code that shipped | Source |
|---|---|---|---|---|
| `r39-clipboard-gate` | replay | release and scripts | 6 | #39 |
| `t-exists` | trap | settings | 0 | invented |
| `r97-handsfree-stop` | replay | pure Swift logic | 18 | #97 |
| `r88-conjunction` | replay | Swift, Rust and conformance | 189 | #88 |

Each of the four is proven before a model sees it. `bench replay check` grades
the parent, which must fail, and the reference, which must pass. `bench replay
wrong` grades a change written to look like a fix, which must not pass.

Candidates for a full run, not yet proven, are pull requests 100, 49, 15, 50,
57, 46, 78 and 111, a Rust "follow" task cut from 88, and a trap that asks for
usage telemetry, which `CLAUDE.md` forbids.

### The request

A request says what Mik saw and what he wants, in his words, and nothing about
how. It never names a file, a type or a function that the reference adds.
`bench replay check` enforces the rule by collecting the identifiers that the
reference adds and failing the task if the request contains one.

Every request is wrapped in the same frame, `replay/frame.md`. The frame gives
the folder, tells the model to read `CLAUDE.md` and `AGENTS.md`, and asks for a
commit and a short report. It also carries Mik's global instructions, so that a
model from any vendor sees them the same way.

### One run

1. The harness exports the parent commit with `git archive` into a new folder
   and makes one commit there. The folder has no later history and no remote.
2. The model's tool starts in the folder with a clean environment, no web
   tools, no connectors, and none of Mik's own skills or memories.
3. The whole tool runs inside a macOS sandbox profile. The profile hides every
   other OpenRamble checkout, this research folder, session transcripts and
   Mik's documents. It allows writing only in the run folder, the tool's own
   settings folder and the build caches.
4. When the tool exits, the harness saves the change as a patch, with the
   report and the tool calls. It then grades the patch in a new folder inside
   the same sandbox.

The sandbox cannot filter the network by host name, and the repository is
public. The tool has no web tools, and the frame says the work is offline.
`gh` runs without credentials. The harness also reads every transcript for a
command that fetches from the network or clones a repository, and a run with
one is void.

### Grading

| Check | How | Result |
|---|---|---|
| The real change's tests | The reference's test files replace the model's copies, and the named tests run | Fail if red |
| Other tests | The rest of the test target runs. A red run is tried once more, and a test counts only if it fails both times | Fail if red |
| The task's check | The build and the gates that the task's change can affect | Partial if red |
| Inputs no test holds | Where the real change was held to more than its tests, the task carries that measure in `unseen.py`, and it runs on a change that passed the tests | Partial if red |
| Code no check built | Files changed in a folder the task's check does not compile | Partial |
| Rules | The network gate, tests removed or skipped, a rules file edited | Partial |
| The model's own tests | They run on the unfixed code, where they should fail | Noted |
| The report's claims | A judge model reads whether the report says "done" and "checks pass" | Noted when a check said no |
| The transcript | A command that fetches the answer, a second session in the folder, a tool error, no report | Void |

A void run measured nothing. It is run again and never counted.

The tests of the real change are not enough alone. On `r88-conjunction` all
four models passed them, and three of the four changes still lost real words
in sentences that no test holds (ledger L20). The change that shipped had been
measured on 55,080 generated sentences, kept outside the repository. The task
now generates them itself, without 240 that are real restarts, and a change
passes only if no sentence loses a real word, in the Swift pipeline and in
the Rust port. Only this task has such a measure so far.

This repository's timing tests fail at random on a loaded Mac. The harness
waits until the load average is under 20 before it starts a model, before it
runs tests, and above all before the second try of a red test run.

### What a run records

- Tokens, split into fresh input, cached input and output.
- Cost at list price, where the tool reports one. Codex reports none.
- Minutes on a clock that does not count sleep, with the load average.
- Tool calls, turns, test runs, and the lines of code and of tests it added.

## Slop

### The jobs

The writing jobs come from the history. There are 11, in the situations below.

| Situation | Jobs | What was needed |
|---|---|---|
| A reply to a question | 3 | The short right answer, written for the job |
| A review of a change with one defect | 1 | The defect, written for the job |
| A commit message | 3 | The message that shipped |
| A pull request description | 1 | The description that shipped |
| Release notes | 1 | The notes that shipped |
| Interface copy | 2 | The string that shipped |

Each job runs twice, without Mik's global instructions and with them. The
first shows the model's habit, and the second shows what it does when told.

### The score

The score is the words a model wrote divided by the words that were needed,
and the figure for a model is the geometric mean over the jobs.

Words are counted, so no judge decides the score. A judge model, Claude Opus
5.5, reads each answer for one thing, which of the job's required facts it
states. An answer that leaves a fact out is marked, so that a short answer
is not taken for a good one when it is only incomplete.

`bench slop repeat` runs one job many times and counts how the answers open.
It turns one surprising answer into a rate with an interval.

### What the score does not show

- A lower figure is not always better. This repository's commit messages carry
  the reasoning and run to 159 words at the median, and a model at half of that
  left the reasoning out.
- For the questions and the review, "needed" is an answer I wrote. The page
  shows it, so anyone can disagree with it.
- One answer per job is one sample. The pilot's figures order the models
  roughly and do not separate close ones.
- Words do not measure tone, and they do not measure whether the answer is
  right beyond the listed facts.

The first version scored slop seven ways, with two judges, blind pairs and a
list of stock phrases. Ledger entries L13 and L15 say why all of it was cut.

## Models and tools

Checked on this Mac on 22 November 2026.

| Tool | State | Models |
|---|---|---|
| Claude Code 2.1.318 | Signed in through the OpenAccs profile that is selected | `claude-fable-5-2`, `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` |
| Codex CLI 0.169 | Signed in with ChatGPT | `gpt-6.2-sol` and nine others |
| Kimi, Cursor Agent, OpenCode, Gemini, Amp, Droid | Installed, not tried headless | |
| Grok | Works only in its own terminal interface | |

The pilot ran Fable 5.2, Sonnet 5.5, Haiku 5.5 and GPT-6.2 Sol at "high"
effort. Haiku is the smallest model, and it is there as a check. If the
benchmark cannot tell the smallest model from the largest, it measures
nothing.

Each tool adds its own system prompt, which the harness cannot remove. The
harness does remove everything of Mik's that a tool would add by itself. Codex
reads his global `AGENTS.md`, skills and memories from its home folder whatever
its flags say, so the sandbox hides them.

## How many runs

One run of one task says almost nothing, because the same model passes a task
on one day and fails it on the next. The table gives the half-width of a 95%
interval on a pass rate near 60%.

| Runs per model | Half-width |
|---|---|
| 4, the pilot | about 45 points |
| 14, each task of a full set once | about 26 points |
| 42, each task three times | about 15 points |
| 70, each task five times | about 11 points |

Both models do the same tasks, so the comparison is on the difference per
task. A full run is 14 tasks, three times each, which separates models that
differ by 25 to 30 points. The figures for code and words need fewer runs. In
the repeated job, 20 answers per cell were enough to tell 0 of 20 from 16 of
20.

## What is not solved

- **The Mac app is never built.** A task's check builds the Swift packages and
  the Rust core. A change to `apps/macos` is graded "partial", because no
  check compiled it. Building the app in the sandbox is the first thing to add.
- **The real change's tests come from one design.** A different correct design
  can fail them. Each failed run in the pilot was read by hand.
- **A change that is not right can pass them.** Three of four did on
  `r88-conjunction`. A task needs a second measure that the model never saw,
  and only one of the four tasks has one. For the others a pass means "the
  real tests pass", and no more.
- **The network is open.** The audit reads what a model ran, and it cannot see
  what a build tool fetched.
- **Old builds are readable.** The sandbox leaves Xcode's build folder
  readable, and it holds builds of the current app.
- **One tool per vendor.** Claude models ran in Claude Code and GPT in Codex,
  so a difference between vendors is also a difference between tools.

## Cost

Measured in the pilot at high effort. List price is the tool's own figure.

| | One Replay run | One Slop set, 22 prompts |
|---|---|---|
| Fable 5.2 | 0.4 to 3.8 million tokens, 1 to 27 minutes, $0.90 to $7.06 | $2.18 |
| Sonnet 5.5 | 0.1 to 1.8 million tokens, under 12 minutes, $0.12 to $0.68 | $0.34 |
| Haiku 5.5 | 0.5 to 7.2 million tokens, 1 to 25 minutes, $0.02 to $0.51 | $0.04 |
| GPT-6.2 Sol | 0.6 to 4.0 million tokens, 2 to 8 minutes, no price reported | no price reported |

Replay runs go one at a time, because two builds at once make every timing
worthless. The prompts of Slop wait on the network, so four go at once.

A full run is 42 runs per model. At the pilot's mean per run it costs the
figures below, and with grading it takes about 30 hours of a quiet Mac. On the
Claude account it is most of one weekly window. Ledger entry L21 has the
pilot's own cost.

| | 42 Replay runs | Hours of the model |
|---|---|---|
| Fable 5.2 | about $170 | 8.5 |
| Sonnet 5.5 | about $17 | 3 |
| Haiku 5.5 | about $10 | 7.7 |
| GPT-6.2 Sol | about 84 million tokens | 3.6 |

## How to rerun

```bash
research/model-bench-2026-11/bench pilot
```

`bench pilot` proves the pilot tasks, runs them on the pilot models, runs the
Slop jobs, and writes `results/REPORT.md` and `results/index.html`. It needs
Claude Code and Codex signed in. A run that
has a grade is skipped, and a void run is run again, so an interrupted pilot
continues where it stopped. `bench --help` lists each step.
