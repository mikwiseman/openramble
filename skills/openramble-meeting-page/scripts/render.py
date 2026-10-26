#!/usr/bin/env python3
"""Render a meeting page: transcript.json + analysis.json -> one self-contained HTML file.

    render.py transcript.json analysis.json [--audio FILE] [--out PAGE.html]

The analysis is validated first. Every problem is listed and nothing is written
until all of them are fixed: an unknown or silent segment, a claim without
evidence, an owner who is not a participant, a due date nobody said, a quote
that is not verbatim. Then the page is written next to the recording (next to
transcript.json when there is none) as <title>.html, never over another file,
with the audio path relative to it.

The page is static, escaped HTML: it reads with scripts off, prints, and makes
no network requests. Its one style block and one script block are pinned by
hash in the Content-Security-Policy.
"""
import argparse
import base64
import datetime as dt
import hashlib
import html
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
SCHEMA = HERE.parent / "reference" / "analysis.schema.json"
GENERATOR = "openramble-meeting-page 1"
CHUNK_TURNS = 40

L10N = {
    "ru": {
        "forms": {"decisions": ("решение", "решения", "решений"), "tasks": ("задача", "задачи", "задач"),
                  "open": ("открытый пункт", "открытых пункта", "открытых пунктов"),
                  "people": ("участник", "участника", "участников")},
        "wd": ("пн", "вт", "ср", "чт", "пт", "сб", "вс"),
        "mon": ("янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"),
        "month": ("января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября",
                  "октября", "ноября", "декабря"),
        "min": "мин", "h": "ч",
        "lead": "Итог", "dates": "Даты", "noDecisions": "Ничего не решили.", "noTasks": "Задач не назначили.",
        "noOpen": "Открытых пунктов нет.", "dueCount": "срок назван у {k} из {n}",
        "unnamed": "Взял, но имя не прозвучало", "copy": "Скопировать", "noOwner": "Никто не взял", "questions": "Вопросы", "risks": "Риски",
        "undecided": "Спор без решения", "afterDispute": "после спора", "blocker": "блокер",
        "check": "сверить с записью", "due": "до {d}", "dueSaid": "Срок сказан так: «{s}».",
        "mitigation": "Что делают:", "outcome": "Итог:", "unresolved": "Не решено.",
        "caution": "В записи «{h}», по смыслу «{m}».", "primary": "основная цитата",
        "absent": "не был на встрече", "flow": "Ход встречи", "people": "Участники", "mentioned": "Упомянуты",
        "named": "Названы в разговоре", "facts": "Цифры и факты", "aside": "отступление", "talk": "{p}\u00a0% речи",
        "transcript": "Стенограмма", "search": "Поиск по стенограмме", "searchShort": "Поиск",
        "prev": "Предыдущее совпадение", "next": "Следующее совпадение", "chapter": "Глава", "chapters": "Главы",
        "howto": "Как читать", "top": "↑ К началу", "skip": "К стенограмме",
        "src": {"tracks": "Кто говорит, известно по дорожкам: у каждого участника свой файл записи. Имена не угаданы по голосу.",
                "channels": "Кто говорит, известно по каналам записи: микрофон слышит человека за этим компьютером, системный звук — собеседников. Имена не угаданы по голосу.",
                "labelled": "Имена говорящих взяты из подписей в исходной стенограмме.",
                "mixed": "Запись одна, общая, поэтому говорящие не подписаны: угадывать их по голосу страница не станет."},
        "verbatim": "Текст стенограммы приведён так, как его распознал OpenRamble, без правки: имена, числа и термины могли записаться иначе.",
        "glossary": "В стенограмме → имелось в виду", "ear": "Проверьте на слух",
        "silent": "распознано в тишине, вероятно, не сказано; никому не приписано",
        "failed": "не распознано {a}–{b}", "speech": "Речь", "listen": "Слушать запись",
        "colophon": "Расшифровано: {asr}. {src} Итог, решения и задачи написаны моделью по стенограмме; у каждого пункта есть ссылка на момент записи, по которой его можно проверить. Страница не делает сетевых запросов.",
        "synthetic": "синтетический пример",
        "syntheticNote": "Это синтетический пример: люди, компания и продукт вымышлены, голоса синтезированы.",
        "copyTitle": "Задачи",
        "js": {"of": "из", "noHits": "нет совпадений", "short": "хотя бы 2 буквы", "play": "Слушать",
               "pause": "Пауза", "missing": "Рядом со страницей нет файла «{f}».", "track": "дорожка: {n}",
               "copied": "Скопировано", "copyFail": "Не удалось скопировать", "back": "↩ Назад",
               "inTranscript": "в стенограмме", "primary": "основная цитата"},
    },
    "en": {
        "forms": {"decisions": ("decision", "decisions"), "tasks": ("task", "tasks"),
                  "open": ("open item", "open items"), "people": ("participant", "participants")},
        "wd": ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"),
        "mon": ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"),
        "month": ("January", "February", "March", "April", "May", "June", "July", "August", "September",
                  "October", "November", "December"),
        "min": "min", "h": "h",
        "lead": "Outcome", "dates": "Dates", "noDecisions": "Nothing was decided.", "noTasks": "No tasks were taken.",
        "noOpen": "Nothing left open.", "dueCount": "due date said for {k} of {n}",
        "unnamed": "Taken; no name said", "copy": "Copy", "noOwner": "Nobody took it", "questions": "Questions", "risks": "Risks",
        "undecided": "Unresolved disagreement", "afterDispute": "after debate", "blocker": "blocker",
        "check": "check the audio", "due": "by {d}", "dueSaid": "Said as: “{s}”.",
        "mitigation": "Mitigation:", "outcome": "Outcome:", "unresolved": "Not resolved.",
        "caution": "The transcript says “{h}”; the meaning is “{m}”.", "primary": "main quote",
        "absent": "not in the meeting", "flow": "How it went", "people": "Participants", "mentioned": "Mentioned",
        "named": "Named in the conversation", "facts": "Numbers and facts", "aside": "aside", "talk": "{p}% of talk",
        "transcript": "Transcript", "search": "Search the transcript", "searchShort": "Search",
        "prev": "Previous match", "next": "Next match", "chapter": "Chapter", "chapters": "Chapters",
        "howto": "How to read", "top": "↑ Back to top", "skip": "Skip to transcript",
        "src": {"tracks": "Speakers come from tracks: every participant has their own recording file. No name is guessed from a voice.",
                "channels": "Speakers come from the recording's channels: the microphone hears the person at this computer, system audio carries everyone else. No name is guessed from a voice.",
                "labelled": "Speaker names come from the labels in the original transcript.",
                "mixed": "There is one shared recording, so speakers are not labelled: this page does not guess them from voices."},
        "verbatim": "The transcript is exactly what OpenRamble recognised, unedited: names, numbers and terms may be spelled differently.",
        "glossary": "In the transcript → meant", "ear": "Check by ear",
        "silent": "recognised in silence, probably not said; not attributed to anyone",
        "failed": "not recognised {a}–{b}", "speech": "Speech", "listen": "Play the recording",
        "colophon": "Transcribed by {asr}. {src} The outcome, decisions and tasks were written by a model from the transcript; each links to the moment it came from, so it can be checked. This page makes no network requests.",
        "synthetic": "synthetic sample",
        "syntheticNote": "This is a synthetic sample: the people, company and product are fictional and the voices are synthesised.",
        "copyTitle": "Tasks",
        "js": {"of": "of", "noHits": "no matches", "short": "type 2 letters", "play": "Play",
               "pause": "Pause", "missing": "“{f}” is not next to this page.", "track": "track: {n}",
               "copied": "Copied", "copyFail": "Could not copy", "back": "↩ Back",
               "inTranscript": "in transcript", "primary": "main quote"},
    },
}

MARKDOWN = re.compile(r"\*\*|__|`|^\s*#{1,6}\s|^\s*[-*+]\s|\[[^\]]+\]\([^)]+\)", re.M)


class Invalid(Exception):
    def __init__(self, errors):
        super().__init__("\n".join(errors))
        self.errors = errors


# ------------------------------------------------------------------ JSON Schema (the subset the schema uses)

def schema_errors(value, schema, root, path="$"):
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        return schema_errors(value, node, root, path)
    if "oneOf" in schema:
        results = [schema_errors(value, s, root, path) for s in schema["oneOf"]]
        if any(not r for r in results):
            return []
        return min(results, key=len)
    errs = []
    if "const" in schema and value != schema["const"]:
        return [f"{path}: must be {json.dumps(schema['const'])}"]
    types = schema.get("type")
    if types:
        types = [types] if isinstance(types, str) else types
        ok = {"object": isinstance(value, dict), "array": isinstance(value, list), "string": isinstance(value, str),
              "boolean": isinstance(value, bool), "null": value is None,
              "number": isinstance(value, (int, float)) and not isinstance(value, bool)}
        if not any(ok[t] for t in types):
            return [f"{path}: must be {' or '.join(types)}"]
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errs.append(f"{path}: missing \"{key}\"")
        props = schema.get("properties", {})
        for key, v in value.items():
            if key in props:
                errs += schema_errors(v, props[key], root, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                errs.append(f"{path}: unknown field \"{key}\"")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errs.append(f"{path}: needs at least {schema['minItems']} item(s)")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errs.append(f"{path}: at most {schema['maxItems']} item(s)")
        if "items" in schema:
            for i, v in enumerate(value):
                errs += schema_errors(v, schema["items"], root, f"{path}[{i}]")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errs.append(f"{path}: must not be empty")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errs.append(f"{path}: {len(value)} characters, at most {schema['maxLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errs.append(f"{path}: {value!r} does not match {schema['pattern']}")
    return errs


# ------------------------------------------------------------------ helpers

def esc(s):
    return html.escape("" if s is None else str(s), quote=True)


def norm(s):
    """For matching spoken words: lower case, ё as е, no punctuation."""
    s = str(s).lower().replace("ё", "е")
    return " ".join(re.sub(r"[^\w\s]", " ", s).split())


def plural(n, forms, lang):
    if lang == "ru":
        if n % 10 == 1 and n % 100 != 11:
            return forms[0]
        if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
            return forms[1]
        return forms[2]
    return forms[0] if n == 1 else forms[1]


def clock(t, long):
    t = max(0, int(t))
    h, m, s = t // 3600, t % 3600 // 60, t % 60
    return f"{h}:{m:02d}:{s:02d}" if long else f"{m:02d}:{s:02d}"


RU_NB = re.compile(r"(?<![\w-])(а|в|во|и|к|ко|о|об|с|со|у|я|не|ни|на|по|за|из|от|до|для|без|при|про|над|под|но|что|как)\s+",
                   re.IGNORECASE)
EN_NB = re.compile(r"(?<![\w-])(a|an|the|I|to|of|in|on|at|by|or|and)\s+")


def typo(s, lang):
    """Non-breaking spaces in model-written prose only; the transcript stays verbatim."""
    s = re.sub(r"\s+—\s+", "\u00a0— ", s)
    s = re.sub(r"\s+→\s+", "\u00a0→ ", s)
    s = re.sub(r"(\d)\s*%", "\\1\u00a0%", s) if lang == "ru" else s
    if lang == "ru":
        s = RU_NB.sub(lambda m: m.group(1) + "\u00a0", s)
        s = re.sub(r"(\d)\s+(?=[а-яё]{3})", "\\1\u00a0", s)
    else:
        s = EN_NB.sub(lambda m: m.group(1) + "\u00a0", s)
        s = re.sub(r"(\d)\s+(?=[A-Za-z])", "\\1\u00a0", s)
    return s


def slug(title):
    s = re.sub(r"[^\w]+", "-", title.lower(), flags=re.U).strip("-_")
    return (s[:60].rstrip("-") or "meeting")


WORD = re.compile(r"[^\W\d_]+")


def name_forms(part):
    """A lower case name and its Russian case forms: "дима" -> "диме", "диму", "димой", "дим"."""
    if len(part) < 3 or not re.fullmatch(r"[а-я]+", part) or part[-1] in "оеиуыэю":
        return {part}
    if part[-1] in "ая":
        stem, ends = part[:-1], ("", "ь", "а", "я", "ы", "и", "е", "у", "ю", "ой", "ей", "ою", "ею")
    elif part[-1] in "йь":
        stem, ends = part[:-1], (part[-1], "я", "ю", "ем", "е", "и")
    else:
        stem, ends = part, ("", "а", "у", "ом", "е", "ым")
    return {stem + e for e in ends}


def name_hit(name, text):
    """A person's name is said in text: the name or a case form of it ("Дима" -> "Диме", "Arjun" -> "Arjun's"),
    written with a capital, as names are, unless the text has no capitals at all ("I will", "к теме" are not names)."""
    caps = any(c.isupper() for c in text)
    said = {w.lower().replace("ё", "е") for w in WORD.findall(text) if not caps or w[0].isupper()}
    return any(said & name_forms(part) for part in WORD.findall(name.lower().replace("ё", "е")))


def who_html(name, cls):
    return f'<span class="who {cls}">{esc(name)}</span>' if name else ""


def data_json(obj):
    s = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return s.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026") \
            .replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


# ------------------------------------------------------------------ validation

def validate(tr, an, audio=None):
    """Return (errors, warnings). Nothing is dropped silently: any error stops the render."""
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    errors = schema_errors(an, schema, schema)
    for k in ("schemaVersion", "kind", "timed", "duration", "speakers", "segments"):
        if k not in tr:
            errors.append(f"transcript: missing \"{k}\" (write it with transcript.py)")
    if errors:
        return errors, []
    warnings = []
    segs = {s["id"]: s for s in tr["segments"]}
    index = {s["id"]: i for i, s in enumerate(tr["segments"])}
    speakers = {p["id"]: p for p in tr["speakers"]}
    mixed = tr["kind"] == "mixed"
    # voices are not told apart: everyone in a mixed recording, everyone on a Recordings system channel
    anonymous = tr["kind"] in ("mixed", "channels")
    unnamed = "where voices are not told apart (a mixed recording, a Recordings system channel)"

    def cite(path, ids):
        for i in ids or []:
            s = segs.get(i)
            if s is None:
                errors.append(f"{path}: unknown segment {i}")
            elif s.get("silent"):
                errors.append(f"{path}: {i} was recognised in silence and cannot be cited")
            elif s.get("failed"):
                errors.append(f"{path}: {i} was not recognised and cannot be cited")

    def ev_text(ids):
        return " ".join(segs[i]["text"] for i in ids or [] if i in segs)

    for n, x in enumerate(an.get("lead", [])):
        cite(f"lead[{n}].evidence", x["evidence"])
    seen_speakers = set()
    for n, p in enumerate(an.get("participants", [])):
        if p["speaker"] not in speakers:
            errors.append(f"participants[{n}].speaker: {p['speaker']} is not a speaker in the transcript"
                          + (" (a mixed recording has no speakers)" if mixed else ""))
        if p["speaker"] in seen_speakers:
            errors.append(f"participants[{n}].speaker: {p['speaker']} is listed twice")
        seen_speakers.add(p["speaker"])
        cite(f"participants[{n}].evidence", p.get("evidence"))
    mentioned = {}
    for n, m in enumerate(an.get("mentioned", [])):
        cite(f"mentioned[{n}].evidence", m["evidence"])
        mentioned[m["name"]] = m
        if anonymous and not any(name_hit(x, ev_text(m["evidence"])) for x in [m["name"]] + m.get("aliases", [])):
            errors.append(f"mentioned[{n}]: \"{m['name']}\" is not named in its own evidence; {unnamed} "
                          "a person is known only by the words")
    for n, d in enumerate(an.get("dates", [])):
        cite(f"dates[{n}].evidence", d["evidence"])
        if norm(d["said"]) not in norm(ev_text(d["evidence"])):
            errors.append(f"dates[{n}].said: \"{d['said']}\" is not in its evidence; quote the spoken words")
    ids = {}
    for kind in ("decisions", "actions", "questions", "risks", "disagreements", "facts", "cautions"):
        for n, x in enumerate(an.get(kind, [])):
            if x["id"] in ids:
                errors.append(f"{kind}[{n}].id: \"{x['id']}\" is already used by {ids[x['id']]}")
            ids[x["id"]] = f"{kind}[{n}]"
    by_kind = {k: {x["id"] for x in an.get(k, [])} for k in ("decisions", "disagreements", "cautions")}
    for kind in ("decisions", "actions", "questions", "risks", "facts"):
        for n, x in enumerate(an.get(kind, [])):
            cite(f"{kind}[{n}].evidence", x["evidence"])
            for c in x.get("cautions", []):
                if c not in by_kind["cautions"]:
                    errors.append(f"{kind}[{n}].cautions: no caution \"{c}\"")
    for n, d in enumerate(an.get("decisions", [])):
        if d.get("disagreement") and d["disagreement"] not in by_kind["disagreements"]:
            errors.append(f"decisions[{n}].disagreement: no disagreement \"{d['disagreement']}\"")
    for n, a in enumerate(an.get("actions", [])):
        o = a["owner"]
        if o is not None and o not in speakers and o not in mentioned:
            errors.append(f"actions[{n}].owner: \"{o}\" is not a participant id ({', '.join(speakers) or 'none'}), "
                          f"a mentioned name, or null")
        if anonymous and o is not None and o not in speakers:
            names = [o] + mentioned.get(o, {}).get("aliases", [])
            if not any(name_hit(x, ev_text(a["evidence"])) for x in names):
                errors.append(f"actions[{n}].owner: \"{o}\" is not named in the task's own evidence; "
                              f"{unnamed} an owner must be named in the words")
        if a.get("taken") and o is not None:
            errors.append(f"actions[{n}].taken: only for a task with owner null that someone took without being named")
        if a.get("due") and not a.get("dueSaid"):
            errors.append(f"actions[{n}].due: set without dueSaid, the words that named it")
        if a.get("dueSaid") and norm(a["dueSaid"]) not in norm(ev_text(a["evidence"])):
            errors.append(f"actions[{n}].dueSaid: \"{a['dueSaid']}\" is not in the task's evidence")
    for n, d in enumerate(an.get("disagreements", [])):
        if d.get("decision") and d["decision"] not in by_kind["decisions"]:
            errors.append(f"disagreements[{n}].decision: no decision \"{d['decision']}\"")
        for k, p in enumerate(d["positions"]):
            cite(f"disagreements[{n}].positions[{k}].evidence", p["evidence"])
            if p.get("speaker") and p["speaker"] not in speakers:
                errors.append(f"disagreements[{n}].positions[{k}].speaker: {p['speaker']} is not a speaker")
            if anonymous and p.get("name") and not p.get("speaker") and not name_hit(p["name"], ev_text(p["evidence"])):
                errors.append(f"disagreements[{n}].positions[{k}].name: \"{p['name']}\" is not named in its evidence; "
                              f"{unnamed} a name comes only from the words")
        if d.get("resolution"):
            cite(f"disagreements[{n}].resolution.evidence", d["resolution"]["evidence"])
    for n, q in enumerate(an.get("quotes", [])):
        cite(f"quotes[{n}].segment", [q["segment"]])
        if q["segment"] in segs and q["text"] not in segs[q["segment"]]["text"]:
            errors.append(f"quotes[{n}].text: not an exact substring of {q['segment']}; copy it verbatim")
    for n, c in enumerate(an.get("cautions", [])):
        cite(f"cautions[{n}].segment", [c["segment"]])
        cite(f"cautions[{n}].evidence", c.get("evidence"))
        if c["segment"] in segs and c["heard"] not in segs[c["segment"]]["text"]:
            errors.append(f"cautions[{n}].heard: \"{c['heard']}\" is not in {c['segment']}")
    if an.get("glossary"):
        everything = "\n".join(norm(s["text"]) for s in tr["segments"])
        for n, g in enumerate(an["glossary"]):
            for h in g["heard"]:
                if norm(h) not in everything:
                    errors.append(f"glossary[{n}].heard: \"{h}\" does not occur in the transcript")
    chapters = an.get("chapters", [])
    prev = -1
    for n, c in enumerate(chapters):
        if c["start"] not in index:
            errors.append(f"chapters[{n}].start: unknown segment {c['start']}")
            continue
        if n == 0 and index[c["start"]] != 0:
            errors.append(f"chapters[0].start: must be the first segment, {tr['segments'][0]['id']}")
        if index[c["start"]] <= prev:
            errors.append(f"chapters[{n}].start: chapters must be in ascending order")
        prev = index[c["start"]]
    for path, iso in [("meeting.date", an["meeting"].get("date"))] + \
            [(f"actions[{n}].due", a.get("due")) for n, a in enumerate(an.get("actions", []))] + \
            [(f"dates[{n}].date", d["date"]) for n, d in enumerate(an.get("dates", []))]:
        if iso:
            try:
                dt.date.fromisoformat(iso)
            except ValueError:
                errors.append(f"{path}: {iso} is not a calendar date")
    if audio is not None and not Path(audio).is_file():
        errors.append(f"--audio: {audio} does not exist")
    words = sum(len(x["text"].split()) for x in an.get("lead", []))
    if words > 60:
        warnings.append(f"lead: {words} words; keep it to 60, the outcome only")
    for path, text in model_texts(an):
        if MARKDOWN.search(text):
            warnings.append(f"{path}: looks like Markdown; the page shows plain text")
    return errors, warnings


def model_texts(an):
    out = [("meeting.title", an["meeting"]["title"])]
    for n, x in enumerate(an.get("lead", [])):
        out.append((f"lead[{n}].text", x["text"]))
    for kind, fields in (("decisions", ("text", "detail")), ("actions", ("task", "detail")),
                         ("questions", ("text", "status")), ("risks", ("text", "detail", "mitigation")),
                         ("facts", ("text",)), ("dates", ("text",)), ("disagreements", ("topic",)),
                         ("chapters", ("title", "gist")), ("mentioned", ("note",))):
        for n, x in enumerate(an.get(kind, [])):
            for f in fields:
                if x.get(f):
                    out.append((f"{kind}[{n}].{f}", x[f]))
    return out


# ------------------------------------------------------------------ page

class Page:
    def __init__(self, tr, an, page_path, audio=None):
        self.tr, self.an = tr, an
        self.warnings = []
        self.lang = "ru" if an["language"].lower().startswith("ru") else "en"
        self.L = L10N[self.lang]
        self.timed = bool(tr["timed"])
        self.kind = tr["kind"]
        self.long = tr["duration"] >= 3600
        self.D = max(float(tr["duration"]), max([s["end"] or 0 for s in tr["segments"]] or [0]), 1.0)
        self.segs = {s["id"]: s for s in tr["segments"]}
        self.index = {s["id"]: i for i, s in enumerate(tr["segments"])}
        self.page_dir = Path(page_path).resolve().parent
        self.sp = {}
        extra = {p["speaker"]: p for p in an.get("participants", [])}
        firsts = [p["name"].split()[0] if p["name"].split() else p["name"] for p in tr["speakers"]]
        for i, p in enumerate(tr["speakers"]):
            e = extra.get(p["id"], {})
            first = firsts[i]
            short = e.get("short") or (first if firsts.count(first) == 1 else p["name"])
            self.sp[p["id"]] = {"id": p["id"], "name": p["name"], "short": short, "cls": f"sp{i % 6 + 1}",
                                "role": e.get("role"), "roleEv": e.get("evidence"), "aliases": e.get("aliases", []),
                                "audio": self.rel_audio(p.get("audio"))}
        self.audio = self.rel_audio(audio or tr.get("audio"))
        self.has_audio = self.timed and (self.audio or any(p["audio"] for p in self.sp.values()))
        self.mentioned = {m["name"]: m for m in an.get("mentioned", [])}
        self.talk = {}
        for s in tr["segments"]:
            if s["speaker"] and not s["silent"] and not s["failed"] and self.timed:
                self.talk[s["speaker"]] = self.talk.get(s["speaker"], 0) + max(0.0, s["end"] - s["start"])
        self.talk_total = sum(self.talk.values()) or 1.0
        self.items = {}      # analysis id -> (dom id, symbol, number, label)
        self.backlinks = {}  # segment id -> [(token, href, title, class)]
        self.chapters = self.chapter_list()

    # ---------- basics
    def rel_audio(self, path):
        if not path:
            return None
        p = Path(path)
        if not p.is_absolute():
            p = (Path.cwd() / p)
        if not p.exists():
            self.warnings.append(f"audio {p.name} is not there now; the page will offer to choose it")
        try:
            rel = Path(os.path.relpath(p.resolve() if p.exists() else p, self.page_dir)).as_posix()
        except ValueError:  # another drive: only a chosen file can play it
            rel = p.name
        return {"src": "/".join(quote(part) for part in rel.split("/")), "name": p.name, "rel": rel}

    def t(self, sec):
        return clock(sec, self.long)

    def at(self, sid):
        s = self.segs[sid]
        return self.t(s["start"]) if self.timed else f"¶{self.index[sid] + 1}"

    def tx(self, s):
        return esc(typo(s, self.lang))

    def date_short(self, iso):
        d = dt.date.fromisoformat(iso)
        return f"{self.L['wd'][d.weekday()]} {d.day}\u00a0{self.L['mon'][d.month - 1]}"

    def date_long(self, iso):
        d = dt.date.fromisoformat(iso)
        return f"{self.L['wd'][d.weekday()]}, {d.day}\u00a0{self.L['month'][d.month - 1]} {d.year}"

    def length(self, sec):
        m = int(round(sec / 60))
        if m < 60:
            return f"{max(1, m)}\u00a0{self.L['min']}"
        return f"{m // 60}\u00a0{self.L['h']} {m % 60:02d}\u00a0{self.L['min']}"

    def ordered(self, ids):
        """Evidence in time order; the first id given stays the primary one."""
        uniq = list(dict.fromkeys(ids))
        return uniq[0], sorted(uniq, key=lambda i: self.index[i])

    def who(self, sid):
        s = self.segs[sid]
        p = self.sp.get(s["speaker"])
        return (p["short"], p["cls"]) if p else ("", "sp0")

    def register(self, kind_symbol, number, dom_id, label, evidence, cls):
        for sid in evidence:
            lst = self.backlinks.setdefault(sid, [])
            tok = f"{kind_symbol}{number}"
            if all(t[0] != tok for t in lst):
                lst.append((tok, f"#{dom_id}", label, cls))

    # ---------- evidence lists (static, inside folds)
    def evlist(self, ids):
        primary, ids = self.ordered(ids)
        rows = []
        for sid in ids:
            s = self.segs[sid]
            name, cls = self.who(sid)
            play = (f'<button type="button" class="pl" data-sid="{sid}" aria-label="{esc(self.L["js"]["play"])} '
                    f'{self.at(sid)}"></button>') if self.has_audio else ""
            pri = sid == primary and len(ids) > 1
            mark = f'<span class="sr">({esc(self.L["primary"])}) </span>' if pri else ""
            rows.append(f'<li class="evs{" pri" if pri else ""}">{play}<a class="jump" href="#{sid}">{self.at(sid)}</a>'
                        f'<span class="eq">{mark}{who_html(name, cls)}<span class="vb">{esc(s["text"])}</span></span></li>')
        return f'<ol class="evl">{"".join(rows)}</ol>'

    def ev_attr(self, ids):
        primary, ids = self.ordered(ids)
        return f'data-ev="{" ".join(ids)}" data-pri="{primary}"'

    def cautions_for(self, item):
        mine = set(item.get("cautions", []))
        ev = set(item.get("evidence", []))
        return [c for c in self.an.get("cautions", []) if c["id"] in mine or c["segment"] in ev]

    def caution_html(self, cs):
        out = []
        for c in cs:
            why = f' {self.tx(c["why"])}' if c.get("why") else ""
            out.append(f'<p class="caution">{esc(self.L["caution"].format(h=c["heard"], m=c["meant"]))}{why} '
                       f'<a class="jump" href="#{c["segment"]}">{self.at(c["segment"])}</a></p>')
        return "".join(out)

    # ---------- an item (a <details>)
    def item(self, dom_id, cls, number, text, evidence, pills="", fold="", sub=""):
        primary = evidence[0]
        chev = '<span class="chev" aria-hidden="true"></span>'
        body = self.tx(text)
        if pills:  # the fold mark stays on the line of the last pill
            k = pills.rfind(' <span class="pill')
            body += f'{pills[:k]} <span class="nw">{pills[k + 1:]}{chev}</span>'
        else:      # or of the last word
            head, _, last = body.rpartition(" ")
            body = (head + " " if head else "") + f'<span class="nw">{last}{chev}</span>'
        return (f'<li><details class="it {cls}" id="{dom_id}">'
                f'<summary><span class="mk" aria-hidden="true"></span><span class="no">{number}</span>'
                f'<span class="txt">{body}{sub}</span>'
                f'<span class="at">{self.at(primary)}</span></summary>'
                f'<div class="fold">{fold}{self.evlist(evidence)}</div></details></li>')

    def pill(self, text, cls=""):
        return f' <span class="pill {cls}">{esc(text)}</span>'

    # ---------- sections
    def masthead(self):
        an, L = self.an, self.L
        m = an["meeting"]
        kind = f' <span class="kind">· {self.tx(m["kind"])}</span>' if m.get("kind") else ""
        bits = []
        if m.get("date"):
            bits.append(f'<time datetime="{esc(m["date"])}">{esc(self.date_long(m["date"]))}</time>')
        if self.timed:
            bits.append(esc(self.length(self.D)))
        if self.kind in ("tracks", "labelled") and self.sp:
            n = len(self.sp)
            bits.append(f'{n}\u00a0{plural(n, L["forms"]["people"], self.lang)}')
        badge = f'<span class="badge">{esc(L["synthetic"])}</span>' if an.get("synthetic") else ""
        return (f'<header class="mast" id="top"><h1><span class="title">{self.tx(m["title"])}</span>{kind}</h1>'
                f'<p class="meta">{" · ".join(bits)}{badge}</p></header>')

    def lead(self):
        parts = []
        for n, x in enumerate(self.an["lead"]):
            primary = x["evidence"][0]
            self.register("¶", n + 1, "lead", self.L["lead"], x["evidence"], "lead")
            parts.append(f'<span class="ls">{self.tx(x["text"])}</span><sup><a class="ts" href="#{primary}" '
                         f'{self.ev_attr(x["evidence"])} aria-expanded="false">{self.at(primary)}</a></sup>')
        return (f'<section class="lead" id="lead" aria-label="{esc(self.L["lead"])}" data-host>'
                f'<p>{" ".join(parts)}</p></section>')

    def dates(self):
        ds = sorted(self.an.get("dates", []), key=lambda d: d["date"])
        if not ds:
            return ""
        cells = []
        for d in ds:
            primary = d["evidence"][0]
            cells.append(f'<li><time datetime="{esc(d["date"])}">{esc(self.date_short(d["date"]))}</time>'
                         f'<span class="dt">{self.tx(d["text"])}</span>'
                         f'<a class="ts" href="#{primary}" {self.ev_attr(d["evidence"])} aria-expanded="false" '
                         f'title="{esc(d["said"])}">{self.at(primary)}</a></li>')
        return (f'<section class="dates" aria-labelledby="dates-h" data-host><h2 class="lbl" id="dates-h">'
                f'{esc(self.L["dates"])}</h2><ol>{"".join(cells)}</ol></section>')

    def strip(self):
        if not self.timed:
            return ""
        D, L = self.D, self.L
        pct = lambda t: f"{100 * max(0.0, min(t, D)) / D:.3f}%"
        lanes = [p for p in self.sp.values()] if self.kind != "mixed" else [None]
        n = max(1, len(lanes))
        pitch = max(5, min(12, int(52 / n)))
        lane_h = max(3, pitch - 4)
        band_h, top = 16, 22
        ticks_y = top + n * pitch + 4
        H = ticks_y + 20
        defs = ('<defs><pattern id="hatch" width="5" height="5" patternUnits="userSpaceOnUse" '
                'patternTransform="rotate(45)"><rect width="5" height="5" class="hb"/>'
                '<line x1="0" y1="0" x2="0" y2="5" class="hl"/></pattern></defs>')
        band = []
        for c in self.chapters:
            w = 100 * (c["t1"] - c["t0"]) / D
            band.append(f'<a href="#ch{c["n"]}" tabindex="-1"><title>{c["n"]}. {esc(c["title"])} · {self.t(c["t0"])}</title>'
                        f'<rect class="cb{" aside" if c.get("aside") else ""}" x="{pct(c["t0"])}" y="0" '
                        f'width="{w:.3f}%" height="{band_h}"/>'
                        f'<text class="cn{" narrow" if w < 5 else ""}{" tiny" if w < 2.2 else ""}" x="{pct(c["t0"])}" '
                        f'dx="4" y="12">{c["n"]}</text></a>')
        rows, names, longest = [], [], 4
        for k, p in enumerate(lanes):
            y = top + k * pitch
            runs = []
            for s in self.tr["segments"]:
                if s["silent"] or s["failed"] or (p and s["speaker"] != p["id"]):
                    continue
                if runs and s["start"] - runs[-1][1] <= max(2.0, D / 1500):
                    runs[-1][1] = max(runs[-1][1], s["end"])
                else:
                    runs.append([s["start"], s["end"]])
            cls = p["cls"] if p else "sp0"
            rects = "".join(f'<rect x="{pct(a)}" y="{y}" width="{max(0.15, 100 * (b - a) / D):.3f}%" height="{lane_h}"/>'
                            for a, b in runs)
            rows.append(f'<g class="lane {cls}">{rects}</g>')
            label = (f'{esc(p["short"])}<tspan class="pc"> {round(100 * self.talk.get(p["id"], 0) / self.talk_total)}%</tspan>'
                     if p else esc(L["speech"]))
            names.append(f'<text class="ln {cls}" x="0" y="{y + lane_h}">{label}</text>')
            longest = max(longest, len(p["short"]) + 5 if p else len(L["speech"]))
        ticks = []
        for dom_id, cls, sid, label in self.tick_items():
            x = pct(self.segs[sid]["start"])
            y1 = ticks_y if cls == "dec" else ticks_y + 6
            ticks.append(f'<a href="#{dom_id}" tabindex="-1" class="tk {cls}"><title>{esc(label)} · {self.at(sid)}</title>'
                         f'<line x1="{x}" x2="{x}" y1="{y1}" y2="{ticks_y + 18}" class="tl"/>'
                         f'<line x1="{x}" x2="{x}" y1="{ticks_y}" y2="{ticks_y + 18}" class="hit"/></a>')
        play = (f'<button type="button" class="sp-play" id="sp-play" aria-label="{esc(L["listen"])}"></button>'
                if self.has_audio else '<span class="sp-play off" aria-hidden="true"></span>')
        return (f'<section class="strip" aria-label="{esc(L["listen"])}">{play}'
                f'<div class="strip-fig" aria-hidden="true">'
                f'<svg class="sn" width="{min(170, 8 + round(6.5 * longest))}" height="{H}" focusable="false">{"".join(names)}</svg>'
                f'<svg class="sl" width="100%" height="{H}" focusable="false">{defs}{"".join(band)}{"".join(rows)}'
                f'{"".join(ticks)}<line id="ph" class="ph" x1="0" x2="0" y1="0" y2="{H}" visibility="hidden"/></svg>'
                f'<span class="ax"><span>{self.t(0)}</span><span>{self.t(D)}</span></span></div></section>')

    def tick_items(self):
        out = []
        for kind, cls in (("decisions", "dec"), ("actions", None), ("questions", "opn"), ("risks", "opn")):
            for x in self.an.get(kind, []):
                c = cls or ("act" if x["owner"] is not None or x.get("taken") else "opn")
                dom_id, sym, num, label = self.items[x["id"]]
                out.append((dom_id, c, x["evidence"][0], f"{sym}{num} {x.get('text') or x.get('task')}"))
        return out

    def number_items(self):
        an, L = self.an, self.L
        for n, d in enumerate(an.get("decisions", []), 1):
            self.items[d["id"]] = (f"i-{d['id']}", "◆", n, d["text"])
        owned, unowned = self.task_groups()
        n = 0
        for _, tasks in owned + ([(None, unowned)] if unowned else []):
            for a in tasks:
                n += 1
                self.items[a["id"]] = (f"i-{a['id']}", "●", n, a["task"])
        for n, q in enumerate(an.get("questions", []), 1):
            self.items[q["id"]] = (f"i-{q['id']}", "?", n, q["text"])
        for n, r in enumerate(an.get("risks", []), 1):
            self.items[r["id"]] = (f"i-{r['id']}", "▲", n, r["text"])
        for n, x in enumerate(an.get("disagreements", []), 1):
            self.items[x["id"]] = (f"i-{x['id']}", "⇄", n, x["topic"])
        disputes = self.dispute_of()
        for kind in ("decisions", "actions", "questions", "risks"):
            for x in an.get(kind, []):
                dom_id, sym, num, label = self.items[x["id"]]
                ev = list(x["evidence"])
                if kind == "decisions" and x["id"] in disputes:
                    for p in disputes[x["id"]]["positions"]:
                        ev += p["evidence"]
                    if disputes[x["id"]].get("resolution"):
                        ev += disputes[x["id"]]["resolution"]["evidence"]
                cls = {"decisions": "dec", "questions": "opn", "risks": "opn"}.get(kind) or \
                    ("act" if x["owner"] is not None or x.get("taken") else "opn")
                self.register(sym, num, dom_id, label, ev, cls)

    def dispute_of(self):
        """decision id -> its disagreement, linked from either side."""
        by_id = {x["id"]: x for x in self.an.get("disagreements", [])}
        out = {x["decision"]: x for x in by_id.values() if x.get("decision")}
        for d in self.an.get("decisions", []):
            if d.get("disagreement") in by_id:
                out[d["id"]] = by_id[d["disagreement"]]
        return out

    def task_groups(self):
        groups, order, unowned = {}, [], []
        for a in self.an.get("actions", []):
            if a["owner"] is None and not a.get("taken"):
                unowned.append(a)
                continue
            o = a["owner"] or ""  # "" = taken by someone the words do not name
            if o not in groups:
                groups[o] = []
                order.append(o)
            groups[o].append(a)
        return [(o, groups[o]) for o in order], unowned

    def owner_name(self, o):
        if o in self.sp:
            return self.sp[o]["name"], self.sp[o]["cls"], ""
        if not o:
            return self.L["unnamed"], "sp0", ""
        return o, "sp0", self.L["absent"] if self.kind in ("tracks", "labelled") else ""

    def dispute_html(self, x):
        L = self.L
        rows = []
        for p in x["positions"]:
            if p.get("speaker") in self.sp:
                name, cls = self.sp[p["speaker"]]["short"], self.sp[p["speaker"]]["cls"]
            else:
                name, cls = p.get("name") or "", "sp0"
            primary = p["evidence"][0]
            who = f'<b class="who {cls}">{esc(name)}</b> ' if name else ""
            rows.append(f'<li>{who}{self.tx(p["view"])} '
                        f'<a class="jump" href="#{primary}">{self.at(primary)}</a></li>')
        if x.get("resolution"):
            r = x["resolution"]
            out = (f'<p class="res"><b>{esc(L["outcome"])}</b> {self.tx(r["text"])} '
                   f'<a class="jump" href="#{r["evidence"][0]}">{self.at(r["evidence"][0])}</a></p>')
        else:
            out = f'<p class="res"><b>{esc(L["unresolved"])}</b></p>'
        return f'<div class="dispute"><p class="topic">{self.tx(x["topic"])}</p><ul>{"".join(rows)}</ul>{out}</div>'

    def columns(self):
        an, L, lang = self.an, self.L, self.lang
        disputes = self.dispute_of()
        attached = {x["id"] for x in disputes.values()}

        def head(n, forms):
            return f'<h2><span class="num">{n}</span> <span class="lab">{esc(plural(n, forms, lang))}</span></h2>'

        decs = []
        for d in an.get("decisions", []):
            dom_id, _, num, _ = self.items[d["id"]]
            x = disputes.get(d["id"])
            cs = self.cautions_for(d)
            pills = (self.pill(L["afterDispute"], "warn") if x else "") + (self.pill(L["check"], "chk") if cs else "")
            fold = (f'<p class="detail">{self.tx(d["detail"])}</p>' if d.get("detail") else "") + \
                   (self.dispute_html(x) if x else "") + self.caution_html(cs)
            decs.append(self.item(dom_id, "dec", num, d["text"], d["evidence"], pills, fold))
        col1 = (f'<section class="col c-dec" aria-labelledby="h-dec"><div class="ch" id="h-dec">'
                f'{head(len(decs), L["forms"]["decisions"])}</div>'
                + (f'<ol class="items">{"".join(decs)}</ol>' if decs else f'<p class="empty">{esc(L["noDecisions"])}</p>')
                + '</section>')

        owned, unowned = self.task_groups()
        n_owned = sum(len(t) for _, t in owned)
        k_due = sum(1 for _, ts in owned for a in ts if a.get("due"))
        groups, copy = [], self.copy_text(owned, unowned)
        for o, tasks in owned:
            name, cls, note = self.owner_name(o)
            lis = [self.task_item(a) for a in tasks]
            note_html = f' <span class="note">{esc(note)}</span>' if note else ""
            groups.append(f'<div class="own"><h3 class="{cls}">{esc(name)}{note_html}</h3><ol class="items">{"".join(lis)}</ol></div>')
        sub = f'<p class="sub">{esc(L["dueCount"].format(k=k_due, n=n_owned))}</p>' if n_owned else ""
        copy_btn = (f'<button type="button" class="copy js" id="copy">{esc(L["copy"])}</button>' if copy else "")
        col2 = (f'<section class="col c-act" aria-labelledby="h-act"><div class="ch" id="h-act">'
                f'{head(n_owned, L["forms"]["tasks"])}{copy_btn}</div>{sub}'
                + ("".join(groups) if groups else f'<p class="empty">{esc(L["noTasks"])}</p>') + '</section>')

        blocks, n_open = [], 0
        qs = []
        for q in an.get("questions", []):
            dom_id, _, num, _ = self.items[q["id"]]
            cs = self.cautions_for(q)
            sub_html = f'<span class="st">{self.tx(q["status"])}</span>' if q.get("status") else ""
            qs.append(self.item(dom_id, "qst", num, q["text"], q["evidence"],
                                self.pill(L["check"], "chk") if cs else "", self.caution_html(cs), sub_html))
        uo = [self.task_item(a) for a in unowned]
        rs = []
        for r in an.get("risks", []):
            dom_id, _, num, _ = self.items[r["id"]]
            cs = self.cautions_for(r)
            fold = (f'<p class="detail">{self.tx(r["detail"])}</p>' if r.get("detail") else "") + \
                   (f'<p class="detail"><b>{esc(L["mitigation"])}</b> {self.tx(r["mitigation"])}</p>' if r.get("mitigation") else "") + \
                   self.caution_html(cs)
            rs.append(self.item(dom_id, "rsk", num, r["text"], r["evidence"], self.pill(L["check"], "chk") if cs else "", fold))
        xs = []
        for x in an.get("disagreements", []):
            if x["id"] in attached:
                continue
            dom_id, _, num, _ = self.items[x["id"]]
            ev = [e for p in x["positions"] for e in p["evidence"]] + (x["resolution"]["evidence"] if x.get("resolution") else [])
            xs.append(self.item(dom_id, "dsp", num, x["topic"], ev, "", self.dispute_html(x)))
        for label, lis in ((L["questions"], qs), (L["noOwner"], uo), (L["risks"], rs), (L["undecided"], xs)):
            if lis:
                n_open += len(lis)
                blocks.append(f'<h3 class="lbl">{esc(label)}</h3><ol class="items">{"".join(lis)}</ol>')
        col3 = (f'<section class="col c-open" aria-labelledby="h-open"><div class="ch" id="h-open">'
                f'{head(n_open, L["forms"]["open"])}</div>'
                + ("".join(blocks) if blocks else f'<p class="empty">{esc(L["noOpen"])}</p>') + '</section>')
        return f'<div class="cols">{col1}{col2}{col3}</div>', copy

    def task_item(self, a):
        L = self.L
        dom_id, _, num, _ = self.items[a["id"]]
        cs = self.cautions_for(a)
        pills = (self.pill(L["blocker"], "warn") if a.get("blocker") else "")
        if a.get("due"):
            pills += self.pill(L["due"].format(d=self.date_short(a["due"])), "due")
        if cs:
            pills += self.pill(L["check"], "chk")
        fold = (f'<p class="detail">{self.tx(a["detail"])}</p>' if a.get("detail") else "")
        if a.get("dueSaid"):
            fold += f'<p class="detail">{esc(L["dueSaid"].format(s=a["dueSaid"]))}</p>'
        fold += self.caution_html(cs)
        cls = "act" if a["owner"] is not None or a.get("taken") else "act none"
        return self.item(dom_id, cls, num, a["task"], a["evidence"], pills, fold)

    def copy_text(self, owned, unowned):
        L, an = self.L, self.an
        if not owned and not unowned:
            return ""
        title = an["meeting"]["title"]
        if an["meeting"].get("date"):
            title += f" · {self.date_long(an['meeting']['date'])}"
        lines = [f"## {L['copyTitle']}: {title}", ""]
        for o, tasks in owned + ([(None, unowned)] if unowned else []):
            lines.append(f"**{self.owner_name(o)[0] if o is not None else L['noOwner']}**")
            for a in tasks:
                bits = [a["task"]]
                if a.get("blocker"):
                    bits[0] += f" ({L['blocker']})"
                if a.get("due"):
                    bits.append(L["due"].format(d=self.date_short(a["due"])))
                bits.append(self.at(a["evidence"][0]))
                lines.append("- [ ] " + " — ".join(bits))
            lines.append("")
        return "\n".join(lines).strip() + "\n"

    def flow(self):
        an, L = self.an, self.L
        left = []
        if self.sp:
            lis = []
            for p in self.sp.values():
                role = ""
                if p["role"]:
                    link = (f' <a class="jump" href="#{p["roleEv"][0]}">{self.at(p["roleEv"][0])}</a>' if p.get("roleEv") else "")
                    role = f'<span class="role">{self.tx(p["role"])}{link}</span>'
                aka = [p["short"]] if p["short"] != p["name"] else []
                aka += [a for a in p["aliases"] if a not in aka]
                aka_html = f' <span class="aka">{esc(", ".join(aka))}</span>' if aka else ""
                share = 100 * self.talk.get(p["id"], 0) / self.talk_total
                talk = (f'<span class="talk"><svg class="bar" aria-hidden="true" focusable="false"><rect class="bt" width="100%" height="3"/>'
                        f'<rect class="bv {p["cls"]}" width="{share:.1f}%" height="3"/></svg>'
                        f'{esc(L["talk"].format(p=round(share)))}</span>') if self.timed else ""
                lis.append(f'<li><b class="{p["cls"]}">{esc(p["name"])}</b>{aka_html}{role}{talk}</li>')
            left.append(f'<h3 class="lbl">{esc(L["people"])}</h3><ul class="ppl">{"".join(lis)}</ul>')
        if an.get("mentioned"):
            lis = "".join(f'<li><b>{esc(m["name"])}</b>{" — " + self.tx(m["note"]) if m.get("note") else ""} '
                          f'<a class="jump" href="#{m["evidence"][0]}">{self.at(m["evidence"][0])}</a></li>'
                          for m in an["mentioned"])
            named = L["named"] if self.kind in ("mixed", "channels") else L["mentioned"]
            left.append(f'<h3 class="lbl">{esc(named)}</h3><ul class="men">{lis}</ul>')
        if an.get("facts"):
            lis = "".join(f'<li id="i-{f["id"]}">{self.tx(f["text"])} <a class="jump" href="#{f["evidence"][0]}">'
                          f'{self.at(f["evidence"][0])}</a></li>' for f in an["facts"])
            left.append(f'<h3 class="lbl">{esc(L["facts"])}</h3><ul class="facts">{lis}</ul>')
        quotes = {}
        for q in an.get("quotes", []):
            quotes.setdefault(self.chapter_of(q["segment"]), []).append(q)
        chs = []
        for c in self.chapters:
            meta = (f'<a class="jump" href="#ch{c["n"]}">{self.t(c["t0"])}</a> · {esc(self.length(c["t1"] - c["t0"]))}'
                    if self.timed else f'<a class="jump" href="#ch{c["n"]}">{self.at(c["start"])}</a>')
            aside = f' <span class="asl">{esc(L["aside"])}</span>' if c.get("aside") else ""
            gist = f'<p class="gist">{self.tx(c["gist"])}</p>' if c.get("gist") else ""
            qs = []
            for q in quotes.get(c["n"], []):
                name, cls = self.who(q["segment"])
                qs.append(f'<blockquote class="q"><p>{esc(q["text"])}</p><footer>'
                          f'{who_html(name, cls)} '
                          f'<a class="jump" href="#{q["segment"]}">{self.at(q["segment"])}</a></footer></blockquote>')
            chs.append(f'<li class="chap{" aside" if c.get("aside") else ""}"><p class="cm"><span class="cnum">{c["n"]}</span>'
                       f'{meta}{aside}</p><h3>{self.tx(c["title"])}</h3>{gist}{"".join(qs)}</li>')
        return (f'<section class="flow" id="flow" aria-labelledby="flow-h"><h2 id="flow-h">{esc(L["flow"])}</h2>'
                f'<div class="flow-grid"><div class="flow-side">{"".join(left)}</div>'
                f'<ol class="chapters">{"".join(chs)}</ol></div></section>')

    def chapter_list(self):
        chs = []
        segs = self.tr["segments"]
        for n, c in enumerate(self.an["chapters"], 1):
            i = self.index[c["start"]]
            chs.append(dict(c, n=n, i=i, t0=(segs[i]["start"] or 0) if self.timed else 0))
        for k, c in enumerate(chs):
            c["t1"] = chs[k + 1]["t0"] if k + 1 < len(chs) else self.D
        return chs

    def chapter_of(self, sid):
        i = self.index[sid]
        n = 1
        for c in self.chapters:
            if c["i"] <= i:
                n = c["n"]
        return n

    def howto(self):
        an, L = self.an, self.L
        parts = [f'<p>{esc(L["src"][self.kind])} {esc(L["verbatim"])}</p>']
        if an.get("cautions"):
            lis = []
            for c in an["cautions"]:
                play = (f'<button type="button" class="pl" data-sid="{c["segment"]}" aria-label="{esc(L["js"]["play"])} '
                        f'{self.at(c["segment"])}"></button>') if self.has_audio else ""
                why = f' {self.tx(c["why"])}' if c.get("why") else ""
                lis.append(f'<li>{play}<a class="jump" href="#{c["segment"]}">{self.at(c["segment"])}</a> '
                           f'{esc(L["caution"].format(h=c["heard"], m=c["meant"]))}{why}</li>')
            parts.append(f'<h4>{esc(L["ear"])}</h4><ul class="ear">{"".join(lis)}</ul>')
        if an.get("glossary"):
            rows = "".join(f'<div><dt>{esc(" · ".join(g["heard"]))}</dt><dd>{esc(g["meant"])}</dd></div>'
                           for g in an["glossary"])
            parts.append(f'<h4>{esc(L["glossary"])}</h4><dl class="gl">{rows}</dl>')
        return f'<details class="howto"><summary>{esc(L["howto"])}</summary>{"".join(parts)}</details>'

    def transcript(self):
        L = self.L
        starts = {c["start"]: c for c in self.chapters}
        out, chunk, nturns = [], [], 0
        cur_turn = None

        def flush():
            nonlocal chunk, nturns
            if chunk:
                out.append(f'<div class="chunk">{"".join(chunk)}</div>')
            chunk, nturns = [], 0

        turns = []
        for s in self.tr["segments"]:
            if s["id"] in starts or cur_turn is None or s["turn"] != cur_turn[0]["turn"]:
                cur_turn = [s]
                turns.append(cur_turn)
            else:
                cur_turn.append(s)
        for turn in turns:
            first = turn[0]
            if first["id"] in starts:
                flush()
                c = starts[first["id"]]
                out.append(f'<h3 class="chh{" aside" if c.get("aside") else ""}" id="ch{c["n"]}"><span class="n">{c["n"]}</span> '
                           f'{self.tx(c["title"])}</h3>')
            if nturns >= CHUNK_TURNS:
                flush()
            nturns += 1
            if first["failed"]:
                a, b = self.t(first["start"]), self.t(first["end"])
                chunk.append(f'<div class="turn failed"><div class="g"><span class="tt">{a}</span></div>'
                             f'<p><span class="sg" id="{first["id"]}" data-s="{first["start"]:.2f}" data-e="{first["end"]:.2f}">'
                             f'{esc(L["failed"].format(a=a, b=b))}</span></p></div>')
                continue
            if first["silent"]:
                chunk.append(f'<div class="turn silent"><div class="g"><span class="tt">{self.at(first["id"])}</span></div>'
                             f'<p><span class="sg" id="{first["id"]}"{self.times(first)}>{esc(first["text"])}</span> '
                             f'<span class="sil">{esc(L["silent"])}</span></p></div>')
                continue
            p = self.sp.get(first["speaker"])
            cls = p["cls"] if p else "sp0"
            toks = []
            for s in turn:
                for tok in self.backlinks.get(s["id"], []):
                    if tok not in toks:
                        toks.append(tok)
            bks = ("<span class=\"bks\">" + "".join(
                f'<a class="bk {cls}" href="{href}" title="{esc(title)}">{esc(tok)}</a>' for tok, href, title, cls in toks)
                + "</span>") if toks else ""
            time_link = (f'<a class="tt" href="#{first["id"]}" data-sid="{first["id"]}">{self.at(first["id"])}</a>')
            who = f'<b class="who {cls}">{esc(p["short"])}</b> ' if p else ""
            spans = " ".join(f'<span class="sg{" cited" if s["id"] in self.backlinks else ""}" id="{s["id"]}"{self.times(s)}>'
                             f'{esc(s["text"])}</span>' for s in turn)
            data_sp = f' data-sp="{p["id"]}"' if p else ""
            chunk.append(f'<div class="turn"{data_sp}><div class="g">{time_link}{bks}</div>'
                         f'<p>{who}{spans}</p></div>')
        flush()
        side = self.transcript_side()
        return (f'<section class="tx" id="transcript" aria-labelledby="tx-h"><h2 id="tx-h">{esc(L["transcript"])}</h2>'
                f'<div class="tx-grid">{side}<div class="tx-body">{"".join(out)}</div></div></section>')

    def times(self, s):
        return f' data-s="{s["start"]:.2f}" data-e="{s["end"]:.2f}"' if self.timed else ""

    def transcript_side(self):
        L = self.L
        opts = "".join(f'<option value="ch{c["n"]}">{c["n"]}. {esc(c["title"])}</option>' for c in self.chapters)
        nav = "".join(f'<li><a href="#ch{c["n"]}" data-ch="ch{c["n"]}"><span class="t">'
                      f'{self.t(c["t0"]) if self.timed else self.at(c["start"])}</span> {self.tx(c["title"])}</a></li>'
                      for c in self.chapters)
        return (f'<div class="tx-side">'
                f'<div class="tx-search js" role="search"><label class="sr" for="q">{esc(L["search"])}</label>'
                f'<input id="q" type="search" placeholder="{esc(L["search"])}" autocomplete="off" spellcheck="false">'
                f'<span id="hits" class="hits" aria-live="polite"></span>'
                f'<button type="button" class="nav" id="prev" aria-label="{esc(L["prev"])}" disabled>↑</button>'
                f'<button type="button" class="nav" id="next" aria-label="{esc(L["next"])}" disabled>↓</button>'
                f'<select id="chsel" aria-label="{esc(L["chapter"])}">{opts}</select></div>'
                f'<nav class="tx-ch" aria-label="{esc(L["chapters"])}"><ol>{nav}</ol></nav>'
                f'{self.howto()}<a class="totop" href="#top">{esc(L["top"])}</a></div>')

    def colophon(self):
        L = self.L
        syn = f' {esc(L["syntheticNote"])}' if self.an.get("synthetic") else ""
        return (f'<footer class="colophon"><p>{esc(L["colophon"].format(asr=self.tr.get("asr") or "OpenRamble", src=L["src"][self.kind]))}'
                f'{syn}</p></footer>')

    def player(self):
        if not self.has_audio:
            return ""
        js = self.L["js"]
        return (f'<div class="player" id="player" hidden><button type="button" class="pp paused" id="pp" aria-label="{esc(js["play"])}"></button>'
                f'<span class="ptime" id="pcur">00:00</span><span class="pcap"><b id="pwho"></b> <span id="ptext"></span></span>'
                f'<span class="pmiss" id="pmiss" hidden><span id="pmsg"></span> <label class="pick">'
                f'{esc("Выбрать файл…" if self.lang == "ru" else "Choose file…")}'
                f'<input type="file" id="pfile" accept="audio/*,video/*"></label></span>'
                f'<button type="button" class="px" id="px" aria-label="{esc("Закрыть плеер" if self.lang == "ru" else "Close player")}">×</button>'
                f'</div><audio id="au" preload="none"></audio>')

    def render(self):
        L, an = self.L, self.an
        self.number_items()
        cols, copy = self.columns()
        body = "".join([
            f'<a class="skip" href="#transcript">{esc(L["skip"])}</a>',
            '<div class="page">', self.masthead(), '<main>', self.lead(), self.dates(), self.strip(), cols,
            self.flow(), self.transcript(), '</main>', self.colophon(), '</div>',
            f'<button type="button" class="back" id="back" hidden>{esc(L["js"]["back"])}</button>',
            self.player()])
        data = {"lang": self.lang, "long": self.long, "timed": self.timed, "kind": self.kind, "t": L["js"],
                "duration": self.D,
                "audio": self.audio, "speakers": {k: {"name": v["name"], "short": v["short"], "cls": v["cls"],
                                                      "audio": v["audio"]} for k, v in self.sp.items()},
                "glossary": an.get("glossary", []), "copy": copy}
        # the page's copy of its sources names audio relative to the page, never by a path on this computer
        tr = dict(self.tr, speakers=[dict(p, audio=(self.sp[p["id"]]["audio"] or {}).get("rel")) for p in self.tr["speakers"]])
        if tr.get("audio"):
            tr["audio"] = self.audio["rel"]
        source = {"generator": GENERATOR, "analysis": an, "transcript": tr}
        css = (HERE / "page.css").read_text(encoding="utf-8")
        js = (HERE / "page.js").read_text(encoding="utf-8")
        h = lambda s: "'sha256-" + base64.b64encode(hashlib.sha256(s.encode("utf-8")).digest()).decode() + "'"
        csp = (f"default-src 'none'; style-src {h(css)}; script-src {h(js)}; media-src 'self' file: blob:; "
               f"img-src data:; base-uri 'none'; form-action 'none'")
        title = typo(an["meeting"]["title"], self.lang)
        if an["meeting"].get("date"):
            d = dt.date.fromisoformat(an["meeting"]["date"])
            title += f" · {d.day}\u00a0{L['month'][d.month - 1]} {d.year}"
        return (f'<!doctype html>\n<html lang="{esc(self.lang)}" class="no-js">\n<head>\n<meta charset="utf-8">\n'
                f'<meta name="viewport" content="width=device-width, initial-scale=1">\n'
                f'<meta http-equiv="Content-Security-Policy" content="{esc(csp)}">\n'
                f'<meta name="referrer" content="no-referrer">\n<meta name="robots" content="noindex, nofollow">\n'
                f'<meta name="color-scheme" content="light dark">\n<meta name="generator" content="{GENERATOR}">\n'
                f'<title>{esc(title)}</title>\n<style>{css}</style>\n</head>\n<body>\n{body}\n'
                f'<script type="application/json" id="data">{data_json(data)}</script>\n'
                f'<script type="application/json" id="source">{data_json(source)}</script>\n'
                f'<script>{js}</script>\n</body>\n</html>\n')


# ------------------------------------------------------------------ output

def default_out(tr, title, audio, transcript_dir):
    """Next to the recording; for a transcript with no audio (VTT, SRT, TXT), next to transcript.json.
    Never the working directory, which may be a repository."""
    for cand in [audio, tr.get("audio")] + [p.get("audio") for p in tr["speakers"]]:
        if cand and Path(cand).parent.is_dir():
            folder = Path(cand).parent
            break
    else:
        folder = Path(transcript_dir)
    base = slug(title)
    out = folder / f"{base}.html"
    n = 2
    while out.exists():
        out = folder / f"{base}-{n}.html"
        n += 1
    return out


def ours(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f'<meta name="generator" content="{GENERATOR.split()[0]}' in f.read(4096)
    except (OSError, UnicodeDecodeError):
        return False


def render_file(transcript_path, analysis_path, out=None, audio=None):
    tr = json.loads(Path(transcript_path).read_text(encoding="utf-8"))
    an = json.loads(Path(analysis_path).read_text(encoding="utf-8"))
    base = Path(transcript_path).resolve().parent
    for p in tr.get("speakers", []):
        if p.get("audio") and not Path(p["audio"]).is_absolute():
            p["audio"] = str(base / p["audio"])
    if tr.get("audio") and not Path(tr["audio"]).is_absolute():
        tr["audio"] = str(base / tr["audio"])
    errors, warnings = validate(tr, an, audio)
    if errors:
        raise Invalid(errors)
    if out is None:
        out = default_out(tr, an["meeting"]["title"], audio, base)
    elif Path(out).exists() and not ours(out):
        raise Invalid([f"--out: {out} exists and was not written by this renderer; choose another name"])
    page = Page(tr, an, out, audio and str(Path(audio).resolve()))
    text = page.render()
    tmp = Path(str(out) + ".part")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(out)
    return Path(out), warnings + page.warnings


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("transcript")
    ap.add_argument("analysis")
    ap.add_argument("--audio", help="one file with everyone (Zoom's mixed audio, a Recordings audio.m4a)")
    ap.add_argument("--out", help="page path; default: <title>.html next to the recording (or next to transcript.json "
                                  "when there is no audio), never over another file")
    a = ap.parse_args(argv)
    try:
        out, warnings = render_file(a.transcript, a.analysis, a.out, a.audio)
    except Invalid as e:
        print(f"{len(e.errors)} problem(s); nothing written. Fix analysis.json and render again:", file=sys.stderr)
        for err in e.errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    print(out.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
