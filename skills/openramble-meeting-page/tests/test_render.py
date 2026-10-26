"""Renderer tests: python3 -m unittest discover -s skills/openramble-meeting-page/tests"""
import base64
import copy
import hashlib
import html.parser
import json
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import render  # noqa: E402

EVIL = '</script><script>alert(1)</script><img src=x onerror=alert(2)> "quoted" & \'single\' <!-- c -->'


def seg(i, speaker, start, text, **kw):
    return dict({"id": f"s{i:04d}", "speaker": speaker, "start": start, "end": start + 3.0, "text": text,
                 "turn": i, "silent": False, "failed": False}, **kw)


def transcript(kind="tracks"):
    sp = [{"id": "p1", "name": "Анна Белова", "from": "track", "audio": None},
          {"id": "p2", "name": "Дмитрий Орлов", "from": "track", "audio": None}]
    who = (lambda n: None) if kind == "mixed" else (lambda n: "p1" if n % 2 else "p2")
    texts = ["Привет, начинаем.", "Дима, фикс на тебе до пятницы, 20 ноября.", "Да, беру.",
             "Решили: релиз в четверг.", "Ниже 99,5 не выпускаем.", "is a very important question.",
             "Payval включается конфигом.", "Пока."]
    segs = [seg(n, who(n), 4.0 * (n - 1), t) for n, t in enumerate(texts, 1)]
    segs[5]["silent"] = True
    segs[5]["end"] = segs[5]["start"]
    return {"schemaVersion": 1, "kind": kind, "timed": True, "duration": 40.0, "asr": "OpenRamble test",
            "speakers": [] if kind == "mixed" else sp, "segments": segs}


def analysis():
    return {
        "schemaVersion": 1, "language": "ru",
        "meeting": {"title": "Планёрка", "kind": "Синк", "date": "2026-11-16"},
        "lead": [{"text": "Релиз в четверг.", "evidence": ["s0004"]}],
        "participants": [{"speaker": "p1", "short": "Анна"}, {"speaker": "p2", "aliases": ["Дима"]}],
        "mentioned": [{"name": "Олег", "note": "маркетинг", "evidence": ["s0007"]}],
        "dates": [{"date": "2026-11-20", "said": "до пятницы, 20 ноября", "text": "Фикс", "evidence": ["s0002"]}],
        "decisions": [{"id": "d1", "text": "Релиз в четверг", "evidence": ["s0004"], "disagreement": "x1", "cautions": ["c1"]}],
        "actions": [{"id": "a1", "owner": "p2", "task": "Фикс", "due": "2026-11-20", "dueSaid": "до пятницы, 20 ноября",
                     "evidence": ["s0003", "s0002"]},
                    {"id": "a2", "owner": "Олег", "task": "Цифры", "evidence": ["s0007"]},
                    {"id": "a3", "owner": None, "task": "Скриншоты", "evidence": ["s0008"]}],
        "questions": [{"id": "q1", "text": "Paywall?", "status": "ждём", "evidence": ["s0007"]}],
        "risks": [{"id": "r1", "text": "Падения", "mitigation": "фикс", "evidence": ["s0005"]}],
        "disagreements": [{"id": "x1", "topic": "Когда релиз", "decision": "d1",
                           "positions": [{"speaker": "p1", "view": "в четверг", "evidence": ["s0004"]}],
                           "resolution": {"text": "в четверг", "evidence": ["s0004"]}}],
        "facts": [{"id": "f1", "text": "Порог 99,5", "evidence": ["s0005"]}],
        "chapters": [{"title": "Начало", "start": "s0001"}, {"title": "Даты", "start": "s0004", "gist": "релиз"}],
        "quotes": [{"segment": "s0003", "text": "Да, беру."}],
        "cautions": [{"id": "c1", "segment": "s0005", "heard": "Ниже 99,5", "meant": "не ниже 99,5"}],
        "glossary": [{"meant": "paywall", "heard": ["Payval"]}],
    }


class Collect(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags, self.scripts, self.styles, self._in = [], [], [], None

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))
        if tag in ("script", "style"):
            self._in = (tag, dict(attrs), [])

    def handle_data(self, data):
        if self._in:
            self._in[2].append(data)

    def handle_endtag(self, tag):
        if self._in and tag == self._in[0]:
            (self.scripts if tag == "script" else self.styles).append((self._in[1], "".join(self._in[2])))
            self._in = None


def render_page(tr, an, audio=None, out=None):
    with tempfile.TemporaryDirectory() as d:
        tp, ap = Path(d) / "transcript.json", Path(d) / "analysis.json"
        tp.write_text(json.dumps(tr, ensure_ascii=False), encoding="utf-8")
        ap.write_text(json.dumps(an, ensure_ascii=False), encoding="utf-8")
        path, warnings = render.render_file(tp, ap, out or Path(d) / "page.html", audio)
        return path.read_text(encoding="utf-8"), warnings


def errors_of(tr, an, audio=None):
    errors, _ = render.validate(tr, an, audio)
    return errors


class RenderTests(unittest.TestCase):
    def test_full_page_renders_in_russian(self):
        page, warnings = render_page(transcript(), analysis())
        self.assertIn('<html lang="ru"', page)
        self.assertIn("1</span> <span class=\"lab\">решение", page)
        self.assertIn("срок назван у 1 из 2", page)
        self.assertIn("Никто не взял", page)
        self.assertIn("не был на встрече", page)
        self.assertIn("до пт 20 ноя", page)
        self.assertIn('id="s0006"', page)  # silent text is shown, greyed and unattributed
        self.assertIn("распознано в тишине", page)
        self.assertEqual(warnings, [])

    def test_minimal_analysis(self):
        an = {"schemaVersion": 1, "language": "en", "meeting": {"title": "Sync"},
              "lead": [{"text": "We ship.", "evidence": ["s0004"]}], "chapters": [{"title": "All", "start": "s0001"}]}
        page, _ = render_page(transcript(), an)
        self.assertIn('<html lang="en"', page)
        self.assertIn("Nothing was decided.", page)
        self.assertIn("No tasks were taken.", page)
        self.assertNotIn("None", re.sub(r'<script type="application/json".*?</script>', "", page, flags=re.S))

    def test_hostile_text_stays_text(self):
        tr, an = transcript(), analysis()
        tr["segments"][0]["text"] = EVIL
        tr["speakers"][0]["name"] = EVIL
        an["meeting"]["title"] = "<b>x</b></title><script>alert(3)</script>"[:60]
        an["lead"][0]["text"] = EVIL
        an["decisions"][0]["text"] = EVIL
        an["glossary"][0]["meant"] = "</script><script>alert(4)</script>"[:80]
        page, _ = render_page(tr, an)
        c = Collect()
        c.feed(page)
        self.assertEqual(len(c.scripts), 3)
        self.assertEqual([a.get("type") for a, _ in c.scripts], ["application/json", "application/json", None])
        self.assertEqual(c.scripts[2][1], (ROOT / "scripts" / "page.js").read_text(encoding="utf-8"))
        for a, body in c.scripts[:2]:
            self.assertNotIn("<", body)
            json.loads(body)
        self.assertNotIn("img", [t for t, _ in c.tags])
        self.assertIn("&lt;b&gt;x&lt;/b&gt;&lt;/title&gt;", page)
        self.assertIn("&lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;&lt;img src=x onerror=alert(2)&gt;", page)
        for tag, attrs in c.tags:
            self.assertFalse([k for k in attrs if k.startswith("on")], tag)
            self.assertNotIn("style", attrs, tag)

    def test_csp_pins_the_only_style_and_script(self):
        page, _ = render_page(transcript(), analysis())
        c = Collect()
        c.feed(page)
        csp = next(a["content"] for t, a in c.tags if t == "meta" and a.get("http-equiv") == "Content-Security-Policy")
        digest = lambda s: base64.b64encode(hashlib.sha256(s.encode("utf-8")).digest()).decode()
        self.assertEqual(len(c.styles), 1)
        self.assertIn(f"style-src 'sha256-{digest(c.styles[0][1])}'", csp)
        self.assertIn(f"script-src 'sha256-{digest(c.scripts[2][1])}'", csp)
        self.assertIn("default-src 'none'", csp)
        self.assertNotIn("unsafe", csp)

    def test_no_external_urls(self):
        tr = transcript()
        tr["segments"][0]["text"] = "see https://example.com/x and //cdn.example.com"
        tr["speakers"][0]["audio"] = "/nonexistent/audio-anna.m4a"
        page, warnings = render_page(tr, analysis())
        c = Collect()
        c.feed(page)
        for tag, attrs in c.tags:
            for k in ("src", "href", "action", "poster", "data", "xlink:href", "srcset"):
                v = attrs.get(k)
                if v is not None:
                    self.assertFalse(re.match(r"^([a-z][a-z0-9+.-]*:|//)", v, re.I), f"{tag} {k}={v}")
        self.assertTrue(any("audio-anna.m4a" in w for w in warnings))
        plain, _ = render_page(transcript(), analysis())
        self.assertNotRegex(plain, r"(?i)https?:|//[a-z0-9.-]+\.[a-z]{2,}|@import")
        self.assertNotRegex(plain, r"url\((?!#)")

    def test_nine_hour_transcript(self):
        n = 9 * 3600 // 4
        tr = {"schemaVersion": 1, "kind": "tracks", "timed": True, "duration": 9 * 3600.0, "asr": "x",
              "speakers": [{"id": f"p{i}", "name": f"Speaker {i}", "from": "track", "audio": None} for i in range(1, 9)],
              "segments": [dict(seg(k, f"p{k % 8 + 1}", 4.0 * (k - 1), f"Предложение номер {k}, и ещё немного слов."),
                                turn=k // 3) for k in range(1, n + 1)]}
        an = {"schemaVersion": 1, "language": "ru", "meeting": {"title": "Девять часов"},
              "lead": [{"text": "Долго.", "evidence": [f"s{n:04d}"]}],
              "chapters": [{"title": f"Глава {c}", "start": f"s{1 + c * 900:04d}"} for c in range(9)]}
        t0 = time.time()
        page, _ = render_page(tr, an)
        self.assertLess(time.time() - t0, 20)
        self.assertIn(">8:59:56</a>", page)
        self.assertEqual(page.count('class="sg'), n)
        self.assertGreater(page.count('class="chunk"'), n // 3 // 40)

    def test_untimed_text_uses_paragraph_numbers(self):
        tr = transcript("tracks")
        tr["timed"] = False
        for s in tr["segments"]:
            s["start"] = s["end"] = None
            s["silent"] = False
        page, _ = render_page(tr, analysis())
        self.assertIn(">¶4<", page)
        self.assertNotIn('class="strip"', page)
        self.assertNotIn('id="player"', page)

    def test_never_overwrites_a_foreign_file(self):
        with tempfile.TemporaryDirectory() as d:
            other = Path(d) / "notes.html"
            other.write_text("<p>mine</p>", encoding="utf-8")
            with self.assertRaises(render.Invalid):
                render_page(transcript(), analysis(), out=other)
            self.assertEqual(other.read_text(encoding="utf-8"), "<p>mine</p>")
            ours = Path(d) / "page.html"
            render_page(transcript(), analysis(), out=ours)
            render_page(transcript(), analysis(), out=ours)  # its own page may be replaced
            tr = transcript()
            audio = Path(d) / "mix.m4a"
            audio.write_bytes(b"")
            (Path(d) / "планёрка.html").write_text("x", encoding="utf-8")
            self.assertEqual(render.default_out(tr, "Планёрка", str(audio)).name, "планёрка-2.html")

    def test_example_is_valid(self):
        ex = ROOT / "example"
        tr = json.loads((ex / "transcript.json").read_text(encoding="utf-8"))
        an = json.loads((ex / "analysis.json").read_text(encoding="utf-8"))
        self.assertTrue(an.get("synthetic"))
        self.assertEqual(errors_of(tr, an), [])


class ValidationTests(unittest.TestCase):
    def expect(self, mutate, needle, tr_mutate=None, audio=None):
        tr, an = transcript(), analysis()
        if tr_mutate:
            tr_mutate(tr)
        mutate(an)
        errs = errors_of(tr, an, audio)
        self.assertTrue(any(needle in e for e in errs), f"{needle!r} not in {errs}")

    def test_unknown_segment(self):
        self.expect(lambda a: a["lead"][0].update(evidence=["s0099"]), "unknown segment s0099")

    def test_silent_segment_cannot_be_cited(self):
        self.expect(lambda a: a["risks"][0].update(evidence=["s0006"]), "recognised in silence")

    def test_failed_segment_cannot_be_cited(self):
        self.expect(lambda a: a["facts"][0].update(evidence=["s0001"]), "not recognised",
                    lambda t: t["segments"][0].update(failed=True))

    def test_claim_needs_evidence(self):
        self.expect(lambda a: a["decisions"][0].update(evidence=[]), "decisions[0].evidence: needs at least 1")
        self.expect(lambda a: a["questions"][0].pop("evidence"), 'missing "evidence"')

    def test_duplicate_id(self):
        self.expect(lambda a: a["risks"][0].update(id="d1"), "already used")

    def test_owner_must_be_known(self):
        self.expect(lambda a: a["actions"][0].update(owner="Вася"), "is not a participant id")

    def test_mixed_owner_must_be_named_in_evidence(self):
        def mixed(t):
            t["kind"] = "mixed"
            t["speakers"] = []
            for s in t["segments"]:
                s["speaker"] = None

        def strip_people(a):
            a.pop("participants")
            a["disagreements"][0]["positions"][0]["speaker"] = None
            a["mentioned"].append({"name": "Дима", "evidence": ["s0002"]})
            a["actions"][0]["owner"] = "Дима"
            a["actions"][1]["owner"] = "Олег"
            a["actions"][1]["evidence"] = ["s0004"]
        self.expect(strip_people, 'actions[1].owner: "Олег" is not named', mixed)
        tr, an = transcript(), analysis()
        mixed(tr)
        strip_people(an)
        an["actions"][1]["evidence"] = ["s0007"]
        an["mentioned"][0]["evidence"] = ["s0007"]
        an["mentioned"][0]["name"] = "Олег"
        tr["segments"][6]["text"] = "Олегу напишу, Payval включается конфигом."
        self.assertEqual(errors_of(tr, an), [])
        an["participants"] = [{"speaker": "p1"}]
        self.assertTrue(any("mixed recording has no speakers" in e for e in errors_of(tr, an)))

    def test_due_needs_spoken_words(self):
        self.expect(lambda a: a["actions"][0].pop("dueSaid"), "set without dueSaid")
        self.expect(lambda a: a["actions"][0].update(dueSaid="к понедельнику"), "is not in the task's evidence")
        self.expect(lambda a: a["dates"][0].update(said="в среду"), "dates[0].said")

    def test_due_matches_after_normalisation(self):
        tr, an = transcript(), analysis()
        an["actions"][0]["dueSaid"] = "ДО ПЯТНИЦЫ 20 ноября"
        self.assertEqual(errors_of(tr, an), [])

    def test_quote_must_be_verbatim(self):
        self.expect(lambda a: a["quotes"][0].update(text="Да, беру!"), "not an exact substring")

    def test_caution_heard_must_be_in_segment(self):
        self.expect(lambda a: a["cautions"][0].update(heard="выше 99,5"), "cautions[0].heard")

    def test_glossary_variant_must_occur(self):
        self.expect(lambda a: a["glossary"][0]["heard"].append("Пейвол"), "does not occur")

    def test_chapters_start_at_first_segment_in_order(self):
        self.expect(lambda a: a["chapters"][0].update(start="s0002"), "must be the first segment")
        self.expect(lambda a: a["chapters"].append({"title": "x", "start": "s0003"}), "ascending order")

    def test_missing_audio(self):
        self.expect(lambda a: None, "--audio", audio="/nonexistent/mix.m4a")

    def test_schema_and_references(self):
        self.expect(lambda a: a.update(extra=1), 'unknown field "extra"')
        self.expect(lambda a: a["meeting"].update(title="x" * 61), "at most 60")
        self.expect(lambda a: a["meeting"].update(date="2026-02-30"), "not a calendar date")
        self.expect(lambda a: a["decisions"][0].update(disagreement="x9"), 'no disagreement "x9"')
        self.expect(lambda a: a["decisions"][0].update(cautions=["c9"]), 'no caution "c9"')
        self.expect(lambda a: a.update(lead=[]), "lead: needs at least 1")

    def test_all_errors_are_listed_together(self):
        tr, an = transcript(), analysis()
        an["lead"][0]["evidence"] = ["s0099"]
        an["actions"][0]["owner"] = "Вася"
        an["quotes"][0]["text"] = "нет"
        self.assertEqual(len(errors_of(tr, an)), 3)

    def test_warnings(self):
        tr, an = transcript(), analysis()
        an["lead"][0]["text"] = " ".join(["слово"] * 61)
        an["decisions"][0]["text"] = "**жирно**"
        _, warnings = render.validate(tr, an)
        self.assertTrue(any("61 words" in w for w in warnings))
        self.assertTrue(any("Markdown" in w for w in warnings))


if __name__ == "__main__":
    unittest.main()
