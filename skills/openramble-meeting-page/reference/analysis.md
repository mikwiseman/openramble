# analysis.json

You write `analysis.json` from `transcript.json`. The renderer checks it
against [analysis.schema.json](analysis.schema.json) and against the
transcript, and refuses to write a page until every problem is fixed. All text
is plain text, without Markdown or HTML, and the renderer escapes it.

Every claim has `evidence`, a list of segment ids such as `"s0049"`. The first
id is the main moment, ideally the sentence where people confirmed the point.
The page shows its time on the item and lists all the evidence in time order
when the item is opened. A segment marked silent (text recognised in silence)
or failed can never be cited.

The full synthetic example is [../example/analysis.json](../example/analysis.json),
written for [../example/transcript.json](../example/transcript.json), a planning
meeting of the fictional family budget app «Грошик». The rendered page is
[../example/grosik-release.html](../example/grosik-release.html).

## Fields

R is required and O is optional.

| Field | | What it holds |
|---|---|---|
| `schemaVersion` | R | `1` |
| `language` | R | The meeting's language, e.g. `"ru"` or `"en"`. The page interface is Russian for `ru` and English otherwise. |
| `synthetic` | O | `true` shows a "synthetic sample" badge. |
| `meeting.title` | R | At most 60 characters. The topic as people named it in the meeting, or as the user named it. |
| `meeting.kind`, `meeting.date`, `meeting.timezone` | O | The date only from file metadata (`recordedAt` in a Recordings transcript), the user, or the words of the meeting. |
| `lead` | R | 1 to 4 sentences, at most 60 words, with the outcome and not the agenda. Each is `{text, evidence}`. |
| `participants` | O | `{speaker, short, aliases, role, evidence}` for speakers in the transcript, e.g. `"p2"`. A role only when someone said it (cite it) or the user gave it. A mixed recording has no participants. |
| `mentioned` | O | `{name, aliases, note, evidence}` for people named in the meeting. In a tracks or labelled transcript they were not present. In a mixed recording or a Recordings folder, `mentioned` is how you name people the words name. |
| `dates` | O | `{date, said, text, evidence}` for dates people said. `said` is the spoken words and must appear in the evidence. |
| `decisions` | R items | `{id, text, detail, evidence, disagreement, cautions}`. `disagreement` links the debate that ended in this decision. |
| `actions` | R items | `{id, owner, task, detail, due, dueSaid, blocker, taken, evidence, cautions}`. `owner` is a speaker id, a `mentioned` name, or `null`. |
| `questions` | R items | `{id, text, status, evidence, cautions}`. |
| `risks` | R items | `{id, text, detail, mitigation, evidence, cautions}`. A mitigation only if someone said it. |
| `disagreements` | R items | `{id, topic, decision, positions, resolution}`. Each position is `{speaker, name, view, evidence}`. `resolution` is `{text, evidence}`, or `null` while it is unresolved. |
| `facts` | R items | `{id, text, evidence}` for numbers and facts people will want later. |
| `chapters` | R | At least one `{title, start, gist, aside}`. The first starts at the first segment, and the rest follow in order. `aside: true` marks small talk. |
| `quotes` | O | At most 6 `{segment, text}`. `text` is an exact substring of the segment. The page shows each quote inside its chapter. |
| `cautions` | O | `{id, segment, heard, meant, why, evidence}` where the recognized text breaks the meaning. `heard` is an exact substring of the segment. |
| `glossary` | O | `{meant, heard}`, e.g. `{"meant": "paywall", "heard": ["Payval", "PVAL"]}`. Every `heard` spelling occurs in the transcript, and search on the page finds all of them. |

"R items" means the list is optional, but each item in it needs `id`, its text
and `evidence`. Ids are short lower case words such as `d1`, `a3` or `x1`, and
no two items share one.

## Owners and dates

- `owner: null` shows the task under "Никто не взял" (nobody took it).
- `owner: null` with `taken: true` means someone took the task but the words do not say who. It happens in a mixed recording when a person says "I'll do it", and the page groups such tasks as taken by a person whose name was not said.
- In a mixed recording, an owner must be named in the task's own evidence, e.g. "Дима, тогда этот фикс на тебе" for the owner "Дима".
- `due` is an ISO date, and `dueSaid` is the spoken words, e.g. `"до вторника, 24 ноября"`. The renderer looks for `dueSaid` in the task's evidence after ignoring case, ё and punctuation, and fails if the words are not there. Without a meeting date you cannot resolve "by Friday", so keep only `dueSaid`.

## Example

Here is a part of the example, for the transcript lines below it.

```text
s0063 04:58 [Анна Белова] Отлично, тогда решение оффлайн моут в релизе за выключенным флагом, только внутреннее бета.
s0076 06:04 [Екатерина Миронова] Я успею до вторника, 24 ноября.
s0078 06:10 [Анна Белова] отлично Катя это на тебе до вторника 24
s0080 06:17 [Анна Белова] и раскатываем постепенно стейдж троллау 10 процентов в четверг, потом 50, потом 100, каждый следующий шаг, только если крэшфрини ниже 99,5.
s0093 07:17 [Анна Белова] Понятно, тогда пока повисает, я подумаю, кого из дизайнеров попросить, не сегодня.
```

```json
{
  "schemaVersion": 1,
  "language": "ru",
  "synthetic": true,
  "meeting": {"title": "Релиз «Грошика» 2.4", "kind": "Планёрка релиза", "date": "2026-11-19"},
  "lead": [
    {"text": "Пуши уезжают в 2.5, offline mode едет за выключенным флагом — только для внутренней беты.", "evidence": ["s0063", "s0025"]}
  ],
  "participants": [{"speaker": "p3", "short": "Катя", "aliases": ["Екатерина"]}],
  "decisions": [
    {"id": "d4", "text": "Раскатка 10 → 50 → 100 % по цифрам, не по дням", "evidence": ["s0080", "s0082"], "cautions": ["c1"]}
  ],
  "actions": [
    {"id": "a3", "owner": "p3", "task": "Полный регресс на Android 15, iOS 18 и слабом устройстве", "due": "2026-11-24",
     "dueSaid": "до вторника, 24 ноября", "evidence": ["s0078", "s0076"]},
    {"id": "a8", "owner": null, "task": "Обновить скриншоты в сторе под новый onboarding", "evidence": ["s0093"]}
  ],
  "chapters": [{"title": "Пока все подключаются", "start": "s0001", "aside": true}],
  "cautions": [
    {"id": "c1", "segment": "s0080", "heard": "ниже 99,5", "meant": "не ниже 99,5",
     "why": "Порог релиза — 99,5 %; распознавание, похоже, потеряло «не».", "evidence": ["s0033"]}
  ],
  "glossary": [{"meant": "staged rollout", "heard": ["стейдж троллау"]}]
}
```

The screenshots task has `owner: null` because Анна only said she would think
about whom to ask, and a remark like that is not a task. The rollout decision
carries a caution because the transcript says "ниже 99,5", while the threshold
the team agreed on earlier means "не ниже 99,5".
