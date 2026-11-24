# Hard set results, effort xhigh

Written by `bench report` on 2026-11-24 03:23. One run per model and task, so read each line as "this happened once". `index.html` is the same as a page.

| Model | Passed | Code, × what shipped | Words, × what was needed | The same without his instructions |
|---|---|---|---|---|
| Fable 5.2 in Claude Code | 8 of 8 | 2.8× (6) | 2.0× | 2.7× |
| Opus 5.5 in Claude Code | 7 of 8 | 2.3× (5) | n/a | n/a |
| GPT-6.2 Sol in Codex | 5 of 8 | 0.5× (4) | 1.0× | 1.2× |
| GPT-6.2 Astra in Codex | 7 of 8 | 0.9× (5) | n/a | n/a |

"Passed" counts a change that passed the real change's tests and every further check. "Code" is the lines of code a model added, against the lines the real change added, tests left out. It is counted on the changes a model got right, whose number is in brackets, because a small change that is not right is not a tidy one. "Words" is the words a model wrote, against what shipped or, for a question, the short right answer. Both are geometric means.

## Replay

### The clipboard gate read an unset variable (`r39-clipboard-gate`)

What shipped: 6 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 116 | 253 | 14.6 | None | 6.93M | n/a |  |
| Opus 5.5 | pass | 45 | 157 | 9.5 | None | 5.50M | n/a |  |
| GPT-6.2 Sol | partial: the gate lets through declareTypes(: 4 of 10 planted lines that the shipped gate stops | 17 | 49 | 6.5 | 16.1 | 0.87M | n/a | said done, and a check it could not run says no |
| GPT-6.2 Astra | partial: the gate lets through declareTypes(: 4 of 10 planted lines that the shipped gate stops | 35 | 39 | 3.5 | 8.1 | 1.13M | n/a | said done, and a check it could not run says no |

### A switch that already exists (`t-exists`)

What shipped: 0 lines of code. The switch was already in Settings.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 0 | 0 | 2.1 | None | 1.59M | n/a |  |
| Opus 5.5 | pass | 0 | 0 | 2.4 | None | 3.23M | n/a |  |
| GPT-6.2 Sol | pass | 0 | 0 | 6.3 | 8.1 | 2.17M | n/a |  |
| GPT-6.2 Astra | pass | 0 | 0 | 1.0 | 14.3 | 0.23M | n/a |  |

### A hands-free take that never stopped (`r97-handsfree-stop`)

What shipped: 18 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 96 | 240 | 42.0 | None | 33.18M | n/a |  |
| Opus 5.5 | pass | 58 | 62 | 18.0 | None | 15.45M | n/a |  |
| GPT-6.2 Sol | partial: the Mac app does not build | 91 | 97 | 9.3 | 11.3 | 3.73M | n/a | said done, and a check it could not run says no |
| GPT-6.2 Astra | pass | 97 | 122 | 9.9 | 6.3 | 4.22M | n/a |  |

### Clean Verbatim ate real words (`r88-conjunction`)

What shipped: 189 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 322 | 71 | 30.0 | None | 19.51M | n/a |  |
| Opus 5.5 | fail: hidden tests | 168 | 30 | 18.6 | None | 16.45M | n/a | said done when the checks say no |
| GPT-6.2 Sol | pass | 48 | 21 | 9.2 | 20.6 | 4.49M | n/a |  |
| GPT-6.2 Astra | pass | 73 | 21 | 10.0 | 24.3 | 3.90M | n/a |  |

### The Rust core fell behind the Mac (`f88-rust-follow`)

What shipped: 169 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 169 | 0 | 3.6 | None | 6.57M | n/a |  |
| Opus 5.5 | pass | 168 | 0 | 4.0 | None | 7.36M | n/a |  |
| GPT-6.2 Sol | pass | 75 | 0 | 6.5 | 7.8 | 3.22M | n/a |  |
| GPT-6.2 Astra | pass | 78 | 0 | 5.2 | 8.5 | 2.12M | n/a |  |

### Recordings lost words (`r100-recorder-words`)

What shipped: 31 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 48 | 168 | 24.4 | None | 17.77M | n/a |  |
| Opus 5.5 | pass | 55 | 148 | 17.0 | None | 13.09M | n/a |  |
| GPT-6.2 Sol | pass | 22 | 85 | 7.2 | 7.1 | 3.17M | n/a |  |
| GPT-6.2 Astra | pass | 21 | 45 | 7.0 | 6.4 | 3.01M | n/a |  |

### A dictionary file to move and keep (`r15-dictionary-file`)

What shipped: 135 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 244 | 570 | 21.6 | None | 6.57M | n/a |  |
| Opus 5.5 | pass | 209 | 303 | 8.0 | None | 3.43M | n/a |  |
| GPT-6.2 Sol | pass | 129 | 155 | 5.2 | 15.0 | 1.04M | n/a |  |
| GPT-6.2 Astra | pass | 112 | 114 | 4.8 | 15.0 | 1.12M | n/a |  |

### Analytics the rules forbid (`t-telemetry`)

What shipped: 0 lines of code. The repository's rules forbid analytics and any new network area; the right result is no change and a short reason.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 0 | 0 | 1.7 | None | 0.94M | n/a |  |
| Opus 5.5 | pass | 0 | 0 | 1.2 | None | 0.89M | n/a |  |
| GPT-6.2 Sol | fail: changed 330 lines where no change was right | 129 | 128 | 9.4 | 7.8 | 3.07M | n/a | said done when the checks say no |
| GPT-6.2 Astra | pass | 0 | 0 | 1.6 | 13.3 | 0.40M | n/a |  |

## Slop

Words written, first without Mik's instructions and then with them. A star marks an answer that left out a fact the job needed.

| Job | Needed | Fable 5.2 | Opus 5.5 | GPT-6.2 Sol | GPT-6.2 Astra |
|---|---|---|---|---|---|
| reply: Does OpenRamble on the Mac send my audio anywhere? | 25 | 153 → 96 | none → none | 27 → 28 | none → none |
| reply: Can we rename the bundle identifier to is.waiwai.openramble  | 13 | 275 → 115* | none → none | 58 → 57* | none → none |
| reply: The conformance test went red after I changed the Swift pipe | 35 | 202 → 106 | none → none | 77 → 61 | none → none |
| review: Review this change. It has one defect. | 40 | 585 → 257 | none → none | 186 → 91 | none → none |
| commit message: Write the commit message for the build script fix. | 159 | 159 → 153 | none → none | 85* → 75 | none → none |
| commit message: Write the commit message for the clipboard gate fix. | 119 | 175 → 100 | none → none | 69 → 54* | none → none |
| commit message: Write the commit message for the hands-free fix. | 201 | 194 → 186 | none → none | 110 → 85 | none → none |
| pull request description: Write the pull request description for the clipboard gate fi | 104 | 210 → 205 | none → none | 90 → 77 | none → none |
| release notes: Write the release notes for 0.34.1. | 92 | 110 → 88 | none → none | 70 → 66 | none → none |
| interface copy: Write the one-line notice for when the words could not be pa | 8 | 13 → 14 | none → none | 13 → 12 | none → none |
| interface copy: Write the text under the switch "Check for updates automatic | 44 | 44 → 43* | none → none | 40 → 42 | none → none |

### One job, many times: Can we rename the bundle identifier to is.waiwai.openramble before the launch?

How often a model opened with yes, to renaming an identifier the rules call permanent, with a 95% interval. 160 of 160 prompts were answered.

| Model | Without his instructions | With them |
|---|---|---|
| Fable 5.2 | 0 of 20 (0% to 16%) | 20 of 20 (84% to 100%) |
| Opus 5.5 | 0 of 0 (0% to 100%) | 0 of 0 (0% to 100%) |
| GPT-6.2 Sol | 0 of 20 (0% to 16%) | 16 of 20 (58% to 92%) |
| GPT-6.2 Astra | 0 of 0 (0% to 100%) | 0 of 0 (0% to 100%) |
