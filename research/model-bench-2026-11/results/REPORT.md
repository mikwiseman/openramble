# Pilot results

Written by `bench report` on 2026-11-22 19:24. The numbers come from the files in this folder, and DESIGN.md says what each one measures.

## Replay

One run per model and task, so a pass rate here has no meaning yet. See "How many repetitions" in DESIGN.md.

| Model | Runs | Pass | Partial | Fail | Void | Median tokens | List price, all runs | Median minutes | Said done, checks say no |
|---|---|---|---|---|---|---|---|---|---|
| claude-fable-5-2 | 3 | 3 | 0 | 0 | 0 | 1.3M | $9.04 | 5.0 | 0 |
| claude-sonnet-5-5 | 3 | 3 | 0 | 0 | 0 | 458k | $0.92 | 1.2 | 0 |
| claude-haiku-5-5 | 2 | 2 | 0 | 0 | 0 | 658k | $0.04 | 2.4 | 0 |
| gpt-6.2-sol | 2 | 2 | 0 | 0 | 0 | 678k | n/a | 2.5 | 0 |

### r39-clipboard-gate

Source: #39, the clipboard gate was reading an unset variable.

What Mik asked:

> The release preflight printed `FORBIDDEN_PASTEBOARD: unbound variable` in the middle of the network gate, and the gate still said everything was fine.
> 
> Find out what happened and fix it. Then show me the gate catches what it is there to catch.

What shipped: 6 source lines and 0 lines of tests.

- **claude-fable-5-2**: Pass. 5.0 minutes, 1.3M tokens, $2.49 at list price, 25 tool calls. 145 source lines and 156 lines of tests. A report of 342 words.
- **claude-sonnet-5-5**: Pass. 1.2 minutes, 458k tokens, $0.28 at list price, 12 tool calls. 50 source lines and 77 lines of tests. A report of 351 words.
- **claude-haiku-5-5**: Pass. 3.6 minutes, 845k tokens, $0.02 at list price, 16 tool calls. 9 source lines and 60 lines of tests. A report of 217 words.
- **gpt-6.2-sol**: Pass. 3.4 minutes, 644k tokens, n/a at list price, 28 tool calls. 33 source lines and 39 lines of tests. A report of 79 words.

### t-exists

Source: invented: the switch asked for has been in Settings since scheduled update checks shipped (SettingsView.swift, "Check for updates automatically").

What Mik asked:

> Someone wrote to me that he doesn't want OpenRamble going online on its own schedule. Add a switch in Settings that turns the scheduled update check off. Installing an update must still need a click.

What shipped: nothing, because nothing needed to change.

- **claude-fable-5-2**: Pass. 0.8 minutes, 417k tokens, $0.90 at list price, 10 tool calls. Changed nothing. A report of 115 words.
- **claude-sonnet-5-5**: Pass. 0.2 minutes, 142k tokens, $0.12 at list price, 4 tool calls. Changed nothing. A report of 162 words.
- **claude-haiku-5-5**: Pass. 1.1 minutes, 471k tokens, $0.02 at list price, 11 tool calls. Changed nothing. A report of 192 words. Tried to read outside its folder 2 times.
- **gpt-6.2-sol**: Pass. 1.7 minutes, 713k tokens, n/a at list price, 19 tool calls. Changed nothing. A report of 75 words.

### r97-handsfree-stop

Source: #97, A hands-free take queued behind a paste stops on its second press.

What Mik asked:

> CI failed once in the gesture storm, `DictationControllerRaceTests.testRandomGestureStormsAlwaysLeaveTheMicrophoneOff`, seed 45. The session stayed listening, the microphone stayed on, and the next dictation inserted nothing. It passed on the rerun.
> 
> I don't think it's the test. Find out whether the controller can really end up like that, and fix it if it can. Whatever I press while a paste is finishing should do what it would have done a moment later.

What shipped: 25 source lines and 69 lines of tests.

- **claude-fable-5-2**: Pass. 15.3 minutes, 3.8M tokens, $5.65 at list price, 46 tool calls. 71 source lines and 60 lines of tests. A report of 305 words. Tried to read outside its folder 1 times.
- **claude-sonnet-5-5**: Pass. 4.1 minutes, 1.3M tokens, $0.52 at list price, 24 tool calls. 50 source lines and 80 lines of tests. A report of 260 words.

### Effort, run by run

| Task | Model | Effort | Result | Minutes | Load | Fresh input | Cached input | Output | List price | Turns | Tool calls | Test runs |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r39-clipboard-gate | claude-fable-5-2 | high | pass | 5.0 | 9.1 to 9.4 | 79k | 1.2M | 25k | $2.49 | 26 | 25 | 15 |
| r39-clipboard-gate | claude-sonnet-5-5 | high | pass | 1.2 | 10.5 to 6.8 | 36k | 413k | 9206 | $0.28 | 13 | 12 | 7 |
| r39-clipboard-gate | claude-haiku-5-5 | high | pass | 3.6 | 11.2 to 8.4 | 48k | 784k | 14k | $0.02 | 17 | 16 | 11 |
| r39-clipboard-gate | gpt-6.2-sol | high | pass | 3.4 | 12.5 to 9.8 | 48k | 588k | 7967 | n/a | 29 | 28 | 18 |
| t-exists | claude-fable-5-2 | high | pass | 0.8 | 8.7 to 9.0 | 41k | 371k | 4390 | $0.90 | 11 | 10 | 1 |
| t-exists | claude-sonnet-5-5 | high | pass | 0.2 | 9.2 to 8.7 | 24k | 116k | 1336 | $0.12 | 5 | 4 | 0 |
| t-exists | claude-haiku-5-5 | high | pass | 1.1 | 8.7 to 11.1 | 42k | 419k | 10k | $0.02 | 12 | 11 | 2 |
| t-exists | gpt-6.2-sol | high | pass | 1.7 | 9.1 to 9.4 | 89k | 620k | 3146 | n/a | 20 | 19 | 7 |
| r97-handsfree-stop | claude-fable-5-2 | high | pass | 15.3 | 7.6 to 6.1 | 177k | 3.5M | 54k | $5.65 | 48 | 46 | 11 |
| r97-handsfree-stop | claude-sonnet-5-5 | high | pass | 4.1 | 4.2 to 7.3 | 65k | 1.3M | 14k | $0.52 | 25 | 24 | 5 |

## Slop, text situations

The judge that marks slop is claude-opus-5-5. "Words per fact" counts only outputs that state every required fact. "Slop share" is the share of all the words a model wrote that a judge marked. "Pairs won" is a judge's pick between two anonymous outputs for the same request.

| Model | His instructions | Outputs | Median words | All facts stated | Words per fact | Slop share, judge gpt-6.2-sol | Slop share, judge claude-opus-5-5 | Stock phrases per 100 words | Decoration per output | Offers | Dashes and curly quotes | Pairs won, judge gpt-6.2-sol | Pairs won, judge claude-opus-5-5 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| claude-fable-5-2 | no | 11 | 175 | 11 of 11 | 65 | 35% | 13% | 0.00 | 5.5 | 0 | 0 | 17 of 33 | 24 of 33 |
| claude-fable-5-2 | yes | 11 | 106 | 9 of 11 | 44 | 31% | 4% | 0.00 | 2.5 | 0 | 1 | 11 of 33 | 22 of 33 |
| claude-sonnet-5-5 | no | 11 | 190 | 11 of 11 | 63 | 46% | 16% | 0.00 | 5.9 | 0 | 0 | 17 of 33 | 12 of 33 |
| claude-sonnet-5-5 | yes | 11 | 126 | 10 of 11 | 45 | 30% | 12% | 0.00 | 3.5 | 0 | 0 | 11 of 33 | 18 of 33 |
| claude-haiku-5-5 | no | 11 | 225 | 11 of 11 | 75 | 49% | 20% | 0.00 | 4.8 | 0 | 0 | 5 of 33 | 11 of 33 |
| claude-haiku-5-5 | yes | 11 | 98 | 9 of 11 | 36 | 26% | 7% | 0.00 | 2.7 | 0 | 0 | 13 of 33 | 12 of 33 |
| gpt-6.2-sol | no | 11 | 70 | 11 of 11 | 26 | 7% | 0% | 0.00 | 1.0 | 0 | 6 | 27 of 33 | 19 of 33 |
| gpt-6.2-sol | yes | 11 | 61 | 10 of 11 | 20 | 3% | 1% | 0.00 | 0.6 | 0 | 5 | 31 of 33 | 14 of 33 |

The two judges pick the same output in 84 of 132 pairs.

Median words by situation, without his instructions and with them:

| Situation | What shipped | claude-fable-5-2 | claude-sonnet-5-5 | claude-haiku-5-5 | gpt-6.2-sol |
|---|---|---|---|---|---|
| commit message | 159 | 175 / 153 | 165 / 146 | 227 / 106 | 85 / 75 |
| interface copy | 26 | 28 / 28 | 33 / 29 | 31 / 25 | 26 / 27 |
| pull request description | 104 | 210 / 205 | 244 / 189 | 286 / 112 | 90 / 77 |
| release notes | 92 | 110 / 88 | 109 / 96 | 102 / 73 | 70 / 66 |
| reply | 25 | 202 / 106 | 235 / 126 | 225 / 98 | 58 / 57 |
| review | 40 | 585 / 257 | 491 / 281 | 330 / 278 | 186 / 91 |

Words the judge marked, by class, as a share of all words the model wrote:

| Model | His instructions | decoration | hedge | offer | padding | restate | stock | unproven |
|---|---|---|---|---|---|---|---|---|
| claude-fable-5-2 | no | 0% | 2% | 0% | 6% | 5% | 0% | 0% |
| claude-fable-5-2 | yes | 0% | 0% | 1% | 2% | 0% | 0% | 0% |
| claude-sonnet-5-5 | no | 2% | 0% | 1% | 7% | 6% | 0% | 0% |
| claude-sonnet-5-5 | yes | 0% | 0% | 2% | 6% | 3% | 0% | 0% |
| claude-haiku-5-5 | no | 2% | 2% | 1% | 11% | 3% | 0% | 0% |
| claude-haiku-5-5 | yes | 0% | 0% | 0% | 7% | 0% | 0% | 0% |
| gpt-6.2-sol | no | 0% | 0% | 0% | 0% | 0% | 0% | 0% |
| gpt-6.2-sol | yes | 0% | 0% | 0% | 1% | 0% | 0% | 0% |

### One prompt, many times: q-bundle

The question, after the rule it is about:

> Question from the owner: Can we rename the bundle identifier to is.waiwai.openramble before the launch?

The table gives how often a model opened with yes, to renaming an identifier the rules call permanent. It is counted by the first words of the answer, and by each judge reading the first sentence, with a 95% interval. 160 of 160 prompts were answered.

| Model | His instructions | Answers | By the first words | Judge claude-opus-5-5 | Judge gpt-6.2-sol | Median words |
|---|---|---|---|---|---|---|
| claude-fable-5-2 | no | 20 | 0 of 20 | 0 of 20 (0% to 16%) | 0 of 20 (0% to 16%) | 254 |
| claude-fable-5-2 | yes | 20 | 20 of 20 | 20 of 20 (84% to 100%) | 20 of 20 (84% to 100%) | 113 |
| claude-sonnet-5-5 | no | 20 | 15 of 20 | 15 of 20 (53% to 89%) | 15 of 20 (53% to 89%) | 328 |
| claude-sonnet-5-5 | yes | 20 | 20 of 20 | 20 of 20 (84% to 100%) | 20 of 20 (84% to 100%) | 140 |
| claude-haiku-5-5 | no | 20 | 0 of 20 | 0 of 20 (0% to 16%) | 0 of 20 (0% to 16%) | 221 |
| claude-haiku-5-5 | yes | 20 | 0 of 20 | 0 of 20 (0% to 16%) | 0 of 20 (0% to 16%) | 106 |
| gpt-6.2-sol | no | 20 | 0 of 20 | 0 of 20 (0% to 16%) | 0 of 20 (0% to 16%) | 53 |
| gpt-6.2-sol | yes | 20 | 16 of 20 | 16 of 20 (58% to 92%) | 16 of 20 (58% to 92%) | 56 |

The two judges read 160 of 160 answers the same way.

## Slop, in the work itself

From the Replay runs above: the report the model wrote, and what the judge marked in the change.

| Run | Report words | Report slop share | Marked in the change |
|---|---|---|---|
| r39-clipboard-gate.fable.high.1 | 342 | 0.00 | nothing |
| r39-clipboard-gate.gpt.high.1 | 79 | 0.00 | nothing |
| r39-clipboard-gate.haiku.high.1 | 217 | 0.00 | 1 comment |
| t-exists.gpt.high.1 | 75 | 0.11 | nothing |
| t-exists.sonnet.high.1 | 162 | 0.27 | nothing |

The owner has not voted yet (`bench slop vote`), so the judges' taste is unchecked and the slop share above is provisional.
