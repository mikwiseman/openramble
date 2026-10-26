#!/usr/bin/env python3
"""Turn transcription output into transcript.json and transcript.txt.

    transcript.py INPUT... --out DIR [--speaker FILE=NAME]... [--me NAME] [--other NAME] [--lang ru|en]

INPUT is one of:
  - one JSON per participant track (from transcribe.py, the macOS or Linux
    `openramble` CLI, or a server response): the speaker is the track; a mixed
    recording among them (Zoom's audio_only, or any track that repeats the
    others) is refused, because it would be a speaker who says everything;
  - a single JSON of a mixed recording: no speakers, never guessed;
  - an OpenRamble Recordings folder (meta.json + transcript.json): the
    microphone is --me (or "Я (микрофон)"), the system channel is
    "Собеседники", or --other when the user names the one other person; a
    transcription OpenRamble did not finish is kept as "incomplete" and warned
    about, so the page can say so;
  - a VTT, SRT or TXT transcript whose lines read "Name: text".

Words are cut into sentences, so a claim can cite the exact sentence. A
segment whose words all have zero length was recognised in silence; it is
kept, marked silent, and can never be cited. Nothing here prints transcript
text: the files are the output.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

AUDIO_EXT = (".m4a", ".mp4", ".mp3", ".wav", ".ogg", ".opus", ".flac", ".aac", ".caf", ".aiff", ".webm", ".mkv", ".mov")
SENT_END = re.compile(r"[.?!…][\"'»”)\]]*$")
PAUSE = 1.0        # a silence this long ends a segment (on a track, someone else is talking)
MAX_SENTENCE = 30.0
TURN_GAP = 2.0
TURN_MAX = 60.0    # a longer monologue, or a mixed recording, gets a new paragraph and time
WINDOW_CHARS = 32000  # one window is read whole: about 18,000 tokens of Russian, fewer of English


class Fail(Exception):
    pass


# ------------------------------------------------------------------ names

def name_from_file(path):
    """Zoom names its tracks audioAnnaBelova21234.m4a; our samples audio-anna-belova.m4a."""
    stem = Path(path).stem
    if stem.startswith("audio") and (len(stem) == 5 or stem[5].isupper() or stem[5] in "_- "):
        stem = stem[5:]
    stem = re.sub(r"[\d_\-\s]+$", "", stem)
    stem = re.sub(r"(?<=[a-zа-яё])(?=[A-ZА-ЯЁ])", " ", stem)
    words = [w for w in re.split(r"[\s_\-.]+", stem) if w]
    words = [w[:1].upper() + w[1:] if w.islower() else w for w in words]
    return " ".join(words) or Path(path).stem


def speaker_override(path, overrides):
    p = Path(path)
    for key in (p.name, p.stem):
        if key in overrides:
            return overrides[key]
    return None


# ------------------------------------------------------------------ word-timed input

def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise Fail(f"{path}: cannot read JSON ({e})")


def words_of(doc):
    """macOS CLI / normalized: {words:[{text,start,end}]}; server: words with type=="word"."""
    out = []
    for w in doc.get("words") or []:
        if w.get("type", "word") != "word":
            continue
        text = str(w.get("text", "")).strip()
        if not text:
            continue
        start, end = float(w["start"]), float(w["end"])
        out.append({"text": text, "start": start, "end": max(start, end)})
    return out


def zero(w):
    return w["end"] - w["start"] <= 0


def sentences(words):
    """Cut at sentence punctuation and at pauses; then cut anything over 30 s at its largest gap."""
    # runs of two or more zero-length words are text recognised in silence: keep them apart
    zrun = [False] * len(words)
    i = 0
    while i < len(words):
        j = i
        while j < len(words) and zero(words[j]):
            j += 1
        if j - i >= 2:
            for k in range(i, j):
                zrun[k] = True
        i = max(j, i + 1)
    out, cur = [], []
    for i, w in enumerate(words):
        if cur and (w["start"] - cur[-1]["end"] >= PAUSE or zrun[i] != zrun[i - 1]):
            out.append(cur)
            cur = []
        cur.append(w)
        if SENT_END.search(w["text"]):
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    final = []
    stack = list(reversed(out))
    while stack:
        ws = stack.pop()
        if len(ws) > 1 and ws[-1]["end"] - ws[0]["start"] > MAX_SENTENCE:
            k = max(range(1, len(ws)), key=lambda k: ws[k]["start"] - ws[k - 1]["end"])
            stack.append(ws[k:])
            stack.append(ws[:k])
        else:
            final.append(ws)
    return final


def word_segments(words, speaker):
    segs = []
    for ws in sentences(words):
        segs.append({"speaker": speaker, "start": round(ws[0]["start"], 2), "end": round(ws[-1]["end"], 2),
                     "text": " ".join(w["text"] for w in ws), "silent": all(zero(w) for w in ws)})
    return segs


def piece_segments(doc, speaker):
    """Linux CLI: {segments:[{start,end,label,text}]} with no word times; pieces are taken as is."""
    segs = []
    for p in doc.get("segments") or []:
        text = str(p.get("text", "")).strip()
        if text:
            segs.append({"speaker": speaker, "start": round(float(p["start"]), 2), "end": round(float(p["end"]), 2),
                         "text": text, "label": p.get("label")})
    return segs


def audio_beside(json_path, doc):
    a = doc.get("audio")
    if a:
        p = Path(a)
        if not p.is_absolute():
            p = Path(json_path).parent / p
        return p
    stem = Path(json_path).stem
    for ext in AUDIO_EXT:
        p = Path(json_path).with_name(stem + ext)
        if p.exists():
            return p
    return None


ZOOM_MIX = re.compile(r"audio[_\- ]?only", re.I)


def repeats_others(docs, i):
    """A track whose words the other tracks already hold, at the same moments, is a mix of them, not a person."""
    def key(w):
        return re.sub(r"[^\w]", "", w["text"].lower())
    others = {}
    for j, (_, d) in enumerate(docs):
        if j != i:
            for w in words_of(d):
                others.setdefault(key(w), []).append((w["start"], j))
    mine = words_of(docs[i][1])
    hits = [next((j for t, j in others.get(key(w), []) if abs(t - w["start"]) <= 0.6), None) for w in mine]
    found = [j for j in hits if j is not None]
    return len(mine) >= 20 and len(found) >= 0.5 * len(mine) and len(set(found)) >= 2


def track_inputs(paths, overrides):
    docs = [(p, load_json(p)) for p in paths]
    for p, d in docs:
        if not (d.get("words") or d.get("segments")) and "words" not in d:
            raise Fail(f"{p}: no words or segments; is this a transcription output?")
    if len(docs) > 1:
        for i, (p, d) in enumerate(docs):
            if ZOOM_MIX.match(Path(p).stem) or ZOOM_MIX.match(Path(d.get("audio") or "").stem) or repeats_others(docs, i):
                raise Fail(f"{p.name} is a mixed recording of everyone (like Zoom's audio_only.m4a), not one person's "
                           "track: it would add a speaker who repeats every line. Leave it out here and give its audio "
                           "to render.py --audio.")
    named = [speaker_override(p, overrides) or speaker_override(d.get("audio") or "", overrides) for p, d in docs]
    if len(docs) == 1 and not named[0]:
        p, d = docs[0]
        labels = {s.get("label") for s in d.get("segments") or [] if s.get("label")}
        if labels:
            return labelled_pieces(p, d)
        segs = word_segments(words_of(d), None) if d.get("words") is not None else piece_segments(d, None)
        a = audio_beside(p, d)
        return {"kind": "mixed", "speakers": [], "segments": segs, "audio": a,
                "duration": float(d.get("duration") or 0), "asr": d.get("asr")}
    speakers, segs, duration, asr = [], [], 0.0, None
    for n, ((p, d), name) in enumerate(zip(docs, named), 1):
        pid = f"p{n}"
        a = audio_beside(p, d)
        speakers.append({"id": pid, "name": name or name_from_file(d.get("audio") or p), "from": "track",
                         "audio": str(a) if a else None})
        segs += word_segments(words_of(d), pid) if d.get("words") is not None else piece_segments(d, pid)
        duration = max(duration, float(d.get("duration") or 0))
        asr = asr or d.get("asr")
    return {"kind": "tracks", "speakers": speakers, "segments": segs, "duration": duration, "asr": asr}


def labelled_pieces(path, doc):
    names, segs = [], []
    for s in piece_segments(doc, None):
        label = s.pop("label", None)
        if label and label not in names:
            names.append(label)
        s["speaker"] = f"p{names.index(label) + 1}" if label else None
        segs.append(s)
    speakers = [{"id": f"p{i}", "name": n, "from": "label", "audio": None} for i, n in enumerate(names, 1)]
    a = audio_beside(path, doc)
    return {"kind": "labelled", "speakers": speakers, "segments": segs, "audio": a,
            "duration": float(doc.get("duration") or 0), "asr": doc.get("asr")}


# ------------------------------------------------------------------ Recordings folder

def cyrillic(text):
    letters = re.findall(r"[^\W\d_]", text)
    return bool(letters) and sum(1 for c in letters if "Ѐ" <= c <= "ӿ") / len(letters) > 0.3


def recordings(folder, me, other, lang):
    folder = Path(folder)
    meta = load_json(folder / "meta.json")
    tr = load_json(folder / "transcript.json")
    utts = tr.get("utterances") or []
    if lang is None:
        lang = "ru" if cyrillic(" ".join(u.get("text", "") for u in utts[:200])) else "en"
    mic_name = me or ("Я (микрофон)" if lang == "ru" else "Me (microphone)")
    sys_name = other or ("Собеседники" if lang == "ru" else "Others")
    layout = meta.get("channelLayout") or ["microphone", "system"]
    used = {u.get("channel") for u in utts}
    audio = next((folder / n for n in ("audio.m4a", "audio.wav") if (folder / n).exists()), None)
    speakers, ids = [], {}
    for ch in layout:
        if ch == "system" and ch not in used and not (meta.get("systemAudio") or {}).get("wasRequested"):
            continue
        ids[ch] = f"p{len(speakers) + 1}"
        speakers.append({"id": ids[ch], "name": mic_name if ch == "microphone" else sys_name, "from": "channel",
                         "audio": str(audio) if audio else None})
    segs = []
    for u in utts:
        text = str(u.get("text", "")).strip()
        failed = bool(u.get("isFailed"))
        if not text and not failed:
            continue
        segs.append({"speaker": ids.get(u.get("channel")), "start": round(float(u["start"]), 2),
                     "end": round(float(u["end"]), 2), "text": text, "failed": failed})
    started = meta.get("startedAt")
    state = meta.get("transcriptionState")  # complete, or: live, partial, failed, waitingForModel, none
    return {"kind": "channels", "speakers": speakers, "segments": segs, "audio": audio,
            "duration": float(meta.get("duration") or 0), "title": meta.get("title"), "recordedAt": started,
            "incomplete": state if state and state != "complete" else None}


# ------------------------------------------------------------------ VTT / SRT / TXT

CUE_TIME = re.compile(r"((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})")
LABEL = re.compile(r"^\s*([^\s:][^:]{0,48}?)\s*:\s+(\S.*)$")
VOICE = re.compile(r"^<v(?:\.[^ >]*)?\s+([^>]+)>(.*?)(?:</v>)?$")


def secs(t):
    parts = t.replace(",", ".").split(":")
    return sum(float(x) * 60 ** i for i, x in enumerate(reversed(parts)))


def cues(text):
    out = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").replace("\r", "\n")):
        lines = [l for l in block.split("\n") if l.strip()]
        for i, l in enumerate(lines):
            m = CUE_TIME.search(l)
            if m:
                body = " ".join(x.strip() for x in lines[i + 1:])
                if body:
                    out.append((secs(m.group(1)), secs(m.group(2)), body))
                break
    return out


def split_label(body):
    m = VOICE.match(body)
    if m:
        return m.group(1).strip(), re.sub(r"<[^>]+>", "", m.group(2)).strip()
    body = re.sub(r"<[^>]+>", "", body).strip()
    m = LABEL.match(body)
    if m and not re.fullmatch(r"[\d\s.]+", m.group(1)):
        return m.group(1).strip(), m.group(2).strip()
    return None, body


def subtitle_file(path):
    raw = Path(path).read_text(encoding="utf-8-sig")
    timed = cues(raw)
    if timed:
        items = [(a, b) + split_label(body) for a, b, body in timed]
    else:
        items = []
        for para in re.split(r"\n\s*\n|\n(?=[^\s:][^:\n]{0,48}:\s)", raw.replace("\r\n", "\n")):
            para = " ".join(l.strip() for l in para.split("\n") if l.strip())
            if para:
                items.append((None, None) + split_label(para))
    labelled = sum(1 for it in items if it[2]) >= 0.6 * max(1, len(items))
    names, segs = [], []
    for a, b, label, body in items:
        if not labelled and label:
            body = f"{label}: {body}"
            label = None
        if label and label not in names:
            names.append(label)
        if body:
            segs.append({"speaker": f"p{names.index(label) + 1}" if label else None,
                         "start": None if a is None else round(a, 2), "end": None if b is None else round(b, 2),
                         "text": body})
    speakers = [{"id": f"p{i}", "name": n, "from": "label", "audio": None} for i, n in enumerate(names, 1)]
    return {"kind": "labelled" if names else "mixed", "speakers": speakers, "segments": segs,
            "timed": bool(timed), "duration": max([s["end"] for s in segs if s["end"] is not None] or [0])}


# ------------------------------------------------------------------ assemble

def build(inputs, overrides=None, me=None, other=None, lang=None):
    overrides = overrides or {}
    paths = [Path(p) for p in inputs]
    for p in paths:
        if not p.exists():
            raise Fail(f"{p}: not found")
    if len(paths) == 1 and paths[0].is_dir():
        if not (paths[0] / "meta.json").exists():
            raise Fail(f"{paths[0]}: a folder must be an OpenRamble recording with meta.json and transcript.json")
        t = recordings(paths[0], me, other, lang)
    elif len(paths) == 1 and paths[0].suffix.lower() in (".vtt", ".srt", ".txt"):
        t = subtitle_file(paths[0])
    elif all(p.suffix.lower() == ".json" for p in paths):
        if len(paths) == 1 and "utterances" in load_json(paths[0]):
            t = recordings(paths[0].parent, me, other, lang)
        else:
            t = track_inputs(paths, overrides)
    else:
        raise Fail("give one folder, one VTT/SRT/TXT file, or one or more transcription JSON files")
    timed = t.get("timed", True)
    segs = t["segments"]
    if timed:
        segs.sort(key=lambda s: (s["start"], s["end"]))
    turn, prev, began = 0, None, 0.0
    for n, s in enumerate(segs, 1):
        s["id"] = f"s{n:04d}"
        s.setdefault("silent", False)
        s.setdefault("failed", False)
        alone = s["silent"] or s["failed"]
        if (alone or prev is None or prev["silent"] or prev["failed"] or s["speaker"] != prev["speaker"]
                or not timed or s["start"] - prev["end"] > TURN_GAP or s["start"] - began > TURN_MAX):
            turn += 1
            began = s["start"] if timed else 0.0
        s["turn"] = turn
        prev = s
    duration = max([float(t.get("duration") or 0)] + [s["end"] for s in segs if s["end"] is not None])
    doc = {"schemaVersion": 1, "kind": t["kind"], "timed": timed, "duration": round(duration, 2),
           "asr": t.get("asr") or "OpenRamble",
           "speakers": t["speakers"],
           "segments": [{k: s[k] for k in ("id", "speaker", "start", "end", "text", "turn", "silent", "failed")}
                        for s in segs]}
    if t.get("audio"):
        doc["audio"] = str(t["audio"])
    for k in ("title", "recordedAt", "incomplete"):
        if t.get(k):
            doc[k] = t[k]
    return doc


def clock(t, long):
    t = max(0, int(t))
    h, m, s = t // 3600, t % 3600 // 60, t % 60
    return f"{h}:{m:02d}:{s:02d}" if long else f"{m:02d}:{s:02d}"


def text_lines(doc):
    names = {p["id"]: p["name"] for p in doc["speakers"]}
    long = doc["duration"] >= 3600
    lines = []
    for n, s in enumerate(doc["segments"], 1):
        at = clock(s["start"], long) if doc["timed"] else f"¶{n}"
        if s["failed"]:
            lines.append(f'{s["id"]} {at} (not recognised until {clock(s["end"], long)}; cannot be cited)')
        elif s["silent"]:
            lines.append(f'{s["id"]} {at} (recognised in silence, not said; cannot be cited) {s["text"]}')
        else:
            who = f'[{names[s["speaker"]]}] ' if s["speaker"] in names else ""
            lines.append(f'{s["id"]} {at} {who}{s["text"]}')
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("--out", required=True, help="folder for transcript.json and transcript.txt")
    ap.add_argument("--speaker", action="append", default=[], metavar="FILE=NAME",
                    help="name the speaker of a track (file name or stem)")
    ap.add_argument("--me", help="name of the person at the Mac (Recordings microphone channel)")
    ap.add_argument("--other", help="name of the one other person in a 1:1 recording")
    ap.add_argument("--lang", choices=["ru", "en"], help="language of default speaker labels")
    a = ap.parse_args(argv)
    overrides = {}
    for item in a.speaker:
        if "=" not in item:
            ap.error(f"--speaker {item!r}: use FILE=NAME")
        k, v = item.split("=", 1)
        overrides[Path(k).name] = v.strip()
        overrides[Path(k).stem] = v.strip()
    try:
        doc = build(a.inputs, overrides, a.me, a.other, a.lang)
    except Fail as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    lines = text_lines(doc)
    for name, text in (("transcript.json", json.dumps(doc, ensure_ascii=False, indent=1)), ("transcript.txt", "\n".join(lines))):
        (out / name).write_text(text + "\n", encoding="utf-8")
        os.chmod(out / name, 0o600)
    words = [len(l.split()) for l in lines]
    windows, start, acc = [], 1, 0
    for i, line in enumerate(lines, 1):
        if acc and acc + len(line) + 1 > WINDOW_CHARS:
            windows.append((start, i - 1))
            start, acc = i, 0
        acc += len(line) + 1
    if start <= len(lines):
        windows.append((start, len(lines)))
    segs = doc["segments"]
    print(f"{out / 'transcript.json'}: {doc['kind']}, {len(doc['speakers'])} speakers, {len(segs)} segments, "
          f"{sum(words)} words, {doc['duration'] / 60:.1f} min; "
          f"{sum(s['silent'] for s in segs)} silent, {sum(s['failed'] for s in segs)} failed", file=sys.stderr)
    print(f"read transcript.txt in {len(windows)} line window(s), one at a time: "
          + ", ".join(f"{a}-{b}" for a, b in windows), file=sys.stderr)
    if doc.get("incomplete"):
        heard = [s["end"] for s in segs if not s["failed"] and s["end"] is not None]
        long = doc["duration"] >= 3600
        print(f"warning: OpenRamble had not finished transcribing this recording ({doc['incomplete']}); the last "
              f"recognised sentence ends at {clock(max(heard or [0]), long)} of {clock(doc['duration'], long)}. "
              "Tell the user: the page will say so, and anything said in the untranscribed part is missing from it.",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
