# Pilot results

Written by `bench report` on 2026-11-22 22:39. One run per model and task, so read each line as "this happened once". `index.html` is the same as a page.

| Model | Passed | Code, × what shipped | Words, × what was needed | The same without his instructions |
|---|---|---|---|---|
| Fable 5.2 in Claude Code | 3 of 3 | 5.6× | 2.0× | 2.7× |
| Sonnet 5.5 in Claude Code | 3 of 4 | 2.0× | 2.1× | 2.9× |
| Haiku 5.5 in Claude Code | 2 of 3 | 1.8× | 1.6× | 2.9× |
| GPT-6.2 Sol in Codex | 2 of 3 | 3.3× | 1.0× | 1.2× |

"Code" is the lines of code a model added, against the lines the real change added, tests left out. "Words" is the words a model wrote, against what shipped or, for a question, the short right answer. Both are geometric means.

## Replay

### The clipboard gate read an unset variable (`r39-clipboard-gate`)

What shipped: 6 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 73 | 118 | 5.0 | 9.1 | 1.27M | $2.49 |  |
| Sonnet 5.5 | pass | 33 | 64 | 1.2 | 10.5 | 0.46M | $0.28 |  |
| Haiku 5.5 | pass | 7 | 49 | 3.6 | 11.2 | 0.85M | $0.02 |  |
| GPT-6.2 Sol | pass | 15 | 33 | 3.4 | 12.5 | 0.64M | n/a |  |

### A switch that already exists (`t-exists`)

What shipped: 0 lines of code. The switch was already in Settings.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 0 | 0 | 0.8 | 8.7 | 0.42M | $0.90 |  |
| Sonnet 5.5 | pass | 0 | 0 | 0.2 | 9.2 | 0.14M | $0.12 |  |
| Haiku 5.5 | pass | 0 | 0 | 1.1 | 8.7 | 0.47M | $0.02 | looked outside its folder |
| GPT-6.2 Sol | pass | 0 | 0 | 1.7 | 9.1 | 0.71M | n/a |  |

### A hands-free take that never stopped (`r97-handsfree-stop`)

What shipped: 18 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | pass | 47 | 53 | 15.3 | 7.6 | 3.76M | $5.65 | looked outside its folder |
| Sonnet 5.5 | partial: changed code that no check built | 40 | 68 | 4.1 | 4.2 | 1.33M | $0.52 |  |
| Haiku 5.5 | fail: hidden tests | 48 | 53 | 14.4 | 7.4 | 4.82M | $0.39 |  |
| GPT-6.2 Sol | partial: changed code that no check built | 77 | 113 | 7.9 | 4.0 | 2.64M | n/a |  |

### Clean Verbatim ate real words (`r88-conjunction`)

What shipped: 189 lines of code.

| Model | Result | Lines of code | Lines of tests | Minutes | Load | Tokens | List price | Noticed |
|---|---|---|---|---|---|---|---|---|
| Fable 5.2 | void | | | | | | | the tool reported a problem |
| Sonnet 5.5 | pass | 117 | 34 | 11.9 | 117.2 | 1.76M | $0.68 |  |
| Haiku 5.5 | void | | | | | | | the tool reported a problem |
| GPT-6.2 Sol | void | | | | | | | the tool reported a problem |

## Slop

Words written, first without Mik's instructions and then with them. A star marks an answer that left out a fact the job needed.

| Job | Needed | Fable 5.2 | Sonnet 5.5 | Haiku 5.5 | GPT-6.2 Sol |
|---|---|---|---|---|---|
| reply: Does OpenRamble on the Mac send my audio anywhere? | 25 | 153 → 96 | 233 → 108 | 188 → 87 | 27 → 28 |
| reply: Can we rename the bundle identifier to is.waiwai.openramble  | 13 | 275 → 115* | 325* → 135* | 268 → 114 | 58 → 57* |
| reply: The conformance test went red after I changed the Swift pipe | 35 | 202 → 106 | 235 → 126 | 225 → 98 | 77 → 61 |
| review: Review this change. It has one defect. | 40 | 585 → 257 | 491 → 281 | 330 → 278 | 186 → 91 |
| commit message: Write the commit message for the build script fix. | 159 | 159 → 153 | 165 → 146 | 231 → 106 | 85* → 75 |
| commit message: Write the commit message for the clipboard gate fix. | 119 | 175 → 100 | 112 → 97 | 174 → 88 | 69 → 54* |
| commit message: Write the commit message for the hands-free fix. | 201 | 194 → 186 | 190 → 192 | 227 → 173 | 110 → 85 |
| pull request description: Write the pull request description for the clipboard gate fi | 104 | 210 → 205 | 244 → 189 | 286 → 112* | 90 → 77 |
| release notes: Write the release notes for 0.34.1. | 92 | 110 → 88 | 109 → 96 | 102 → 73 | 70 → 66 |
| interface copy: Write the one-line notice for when the words could not be pa | 8 | 13 → 14 | 19 → 15 | 18 → 7 | 13 → 12 |
| interface copy: Write the text under the switch "Check for updates automatic | 44 | 44 → 43* | 47 → 43 | 44 → 43 | 40 → 42 |

### One job, many times: Can we rename the bundle identifier to is.waiwai.openramble before the launch?

How often a model opened with yes, to renaming an identifier the rules call permanent, with a 95% interval. 160 of 160 prompts were answered.

| Model | Without his instructions | With them |
|---|---|---|
| Fable 5.2 | 0 of 20 (0% to 16%) | 20 of 20 (84% to 100%) |
| Sonnet 5.5 | 15 of 20 (53% to 89%) | 20 of 20 (84% to 100%) |
| Haiku 5.5 | 0 of 20 (0% to 16%) | 0 of 20 (0% to 16%) |
| GPT-6.2 Sol | 0 of 20 (0% to 16%) | 16 of 20 (58% to 92%) |
