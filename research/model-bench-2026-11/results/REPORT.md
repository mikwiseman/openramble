# Pilot results

Written by `bench report` on 2026-11-22 18:54. The numbers come from the files in this folder, and DESIGN.md says what each one measures.

## Replay

| Task | Model | Effort | Result | Why | Minutes | Load | Tokens | List price | Turns | Tool calls | Source lines, model to reference | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r39-clipboard-gate | claude-fable-5-2 | high | PASS |  | 5.0 | 9.1 to 9.4 | 1.3M | $2.49 | 26 | 25 | 145 to 6 | 342 words in the report |
| r39-clipboard-gate | gpt-6.2-sol | high | PASS |  | 3.4 | 12.5 to 9.8 | 644k | n/a | 29 | 28 | 33 to 6 |  |
| r39-clipboard-gate | claude-haiku-5-5 | high | PASS |  | 3.6 | 11.2 to 8.4 | 845k | $0.02 | 17 | 16 | 9 to 6 | 217 words in the report |
| r39-clipboard-gate | claude-sonnet-5-5 | high | PASS |  | 1.2 | 10.5 to 6.8 | 458k | $0.28 | 13 | 12 | 50 to 6 | 351 words in the report |
| t-exists | claude-fable-5-2 | high | PASS |  | 0.8 | 8.7 to 9.0 | 417k | $0.90 | 11 | 10 | 0 to 0 |  |
| t-exists | gpt-6.2-sol | high | PASS |  | 1.7 | 9.1 to 9.4 | 713k | n/a | 20 | 19 | 0 to 0 |  |
| t-exists | claude-haiku-5-5 | high | PASS |  | 1.1 | 8.7 to 11.1 | 471k | $0.02 | 12 | 11 | 0 to 0 | reached outside the folder 2 times; 192 words in the report |
| t-exists | claude-sonnet-5-5 | high | PASS |  | 0.2 | 9.2 to 8.7 | 142k | $0.12 | 5 | 4 | 0 to 0 | 162 words in the report |

| Model | Runs | Pass | Partial | Fail | Void | Median tokens | List price, all runs | Median minutes | Said done, checks say no |
|---|---|---|---|---|---|---|---|---|---|
| claude-fable-5-2 | 2 | 2 | 0 | 0 | 0 | 843k | $3.39 | 2.9 | 0 |
| claude-sonnet-5-5 | 2 | 2 | 0 | 0 | 0 | 300k | $0.40 | 0.7 | 0 |
| claude-haiku-5-5 | 2 | 2 | 0 | 0 | 0 | 658k | $0.04 | 2.4 | 0 |
| gpt-6.2-sol | 2 | 2 | 0 | 0 | 0 | 678k | n/a | 2.5 | 0 |

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
