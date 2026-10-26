"""transcript.py tests: python3 -m unittest discover -s skills/openramble-meeting-page/tests"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import transcript as T  # noqa: E402


def words(*items):
    """items: (text, start, end)"""
    return [{"text": t, "start": a, "end": b} for t, a, b in items]


class Files:
    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name)

    def json(self, name, obj):
        p = self.path / name
        p.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
        return p

    def text(self, name, s):
        p = self.path / name
        p.write_text(s, encoding="utf-8")
        return p


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.f = Files()

    def tearDown(self):
        self.f.dir.cleanup()

    def test_names_from_zoom_files(self):
        self.assertEqual(T.name_from_file("audioAnnaBelova21234567.m4a"), "Anna Belova")
        self.assertEqual(T.name_from_file("audio-anna-belova.json"), "Anna Belova")
        self.assertEqual(T.name_from_file("audioМихаилВайсман11.m4a"), "Михаил Вайсман")
        self.assertEqual(T.name_from_file("interview.m4a"), "Interview")

    def test_sentences_and_pauses(self):
        ws = words(("Привет.", 0, 0.5), ("Как", 0.6, 0.8), ("дела?", 0.8, 1.2), ("Хорошо", 3.0, 3.4), ("всё", 3.4, 3.6))
        segs = T.word_segments(ws, "p1")
        self.assertEqual([s["text"] for s in segs], ["Привет.", "Как дела?", "Хорошо всё"])

    def test_long_sentence_splits_at_largest_gap(self):
        ws = [{"text": f"w{i}", "start": i * 0.9, "end": i * 0.9 + 0.5} for i in range(40)]
        ws[25]["start"] += 0.3  # the largest gap, still under a pause
        for w in ws[25:]:
            w["end"] = max(w["end"], w["start"] + 0.5)
        segs = T.word_segments(ws, "p1")
        self.assertEqual(len(segs), 2)
        self.assertTrue(segs[1]["text"].startswith("w25"))
        self.assertTrue(all(s["end"] - s["start"] <= 30 for s in segs))

    def test_text_recognised_in_silence_is_marked(self):
        ws = words(("Thanks", 500.0, 500.4), ("all", 500.4, 500.7)) + \
            words(*[(t, 510.11, 510.11) for t in ["is", "a", "very", "important", "question."]])
        segs = T.word_segments(ws, "p4")
        self.assertEqual([s["silent"] for s in segs], [False, True])
        joined = words(("so", 1.0, 1.2), ("is", 1.3, 1.3), ("a", 1.3, 1.3), ("bit", 1.4, 1.6))
        self.assertEqual([s["silent"] for s in T.word_segments(joined, "p1")], [False, True, False])

    def test_tracks_merge_by_time_into_turns(self):
        a = self.f.json("audioAnnaBelova1.json", {"duration": 20, "audio": "/x/audioAnnaBelova1.m4a",
                                                   "words": words(("Привет.", 0, 1), ("Начнём.", 1.2, 2), ("Итак.", 9, 10))})
        d = self.f.json("audio-dima.json", {"duration": 21, "words": words(("Да.", 4, 5))})
        doc = T.build([a, d], {"audio-dima": "Дмитрий Орлов"})
        self.assertEqual(doc["kind"], "tracks")
        self.assertEqual([p["name"] for p in doc["speakers"]], ["Anna Belova", "Дмитрий Орлов"])
        self.assertEqual(doc["speakers"][0]["audio"], "/x/audioAnnaBelova1.m4a")
        self.assertEqual([(s["speaker"], s["turn"]) for s in doc["segments"]], [("p1", 1), ("p1", 1), ("p2", 2), ("p1", 3)])
        self.assertEqual(doc["duration"], 21)

    def test_single_file_is_mixed_without_speakers(self):
        m = self.f.json("mix.json", {"duration": 5, "words": words(("Привет.", 0, 1), ("Да.", 1.1, 2))})
        self.f.text("mix.m4a", "")
        doc = T.build([m])
        self.assertEqual((doc["kind"], doc["speakers"]), ("mixed", []))
        self.assertTrue(all(s["speaker"] is None for s in doc["segments"]))
        self.assertTrue(doc["audio"].endswith("mix.m4a"))

    def test_server_words_and_linux_pieces(self):
        scribe = self.f.json("a.json", {"text": "Привет, мир.", "words": [
            {"text": "Привет,", "start": 0.1, "end": 0.5, "type": "word"}, {"text": " ", "start": 0.5, "end": 0.5, "type": "spacing"},
            {"text": "мир.", "start": 0.5, "end": 0.9, "type": "word"}]})
        linux = self.f.json("b.json", {"duration": 60, "segments": [{"start": 0, "end": 24.5, "label": None, "text": "Длинный кусок"}]})
        doc = T.build([scribe, linux])
        self.assertEqual([s["text"] for s in doc["segments"]], ["Длинный кусок", "Привет, мир."])

    def test_labelled_vtt(self):
        vtt = self.f.text("call.vtt", "WEBVTT\n\n1\n00:00:01.000 --> 00:00:04.000\nАнна Белова: Привет.\n\n"
                                      "2\n00:00:04.500 --> 00:00:06.000\n<v Дмитрий>Да.</v>\n\n"
                                      "3\n00:00:07.000 --> 00:00:08.000\nАнна Белова: Начнём.\n")
        doc = T.build([vtt])
        self.assertEqual(doc["kind"], "labelled")
        self.assertEqual([p["name"] for p in doc["speakers"]], ["Анна Белова", "Дмитрий"])
        self.assertEqual([s["text"] for s in doc["segments"]], ["Привет.", "Да.", "Начнём."])
        self.assertEqual(doc["segments"][1]["start"], 4.5)

    def test_srt_and_untimed_txt(self):
        srt = self.f.text("a.srt", "1\n00:00:01,000 --> 00:00:02,500\nMaya: Hello.\n\n2\n00:00:03,000 --> 00:00:04,000\nTom: Hi.\n")
        self.assertEqual([p["name"] for p in T.build([srt])["speakers"]], ["Maya", "Tom"])
        txt = self.f.text("notes.txt", "Maya: Hello there.\nStill Maya.\nTom: Hi.\n")
        doc = T.build([txt])
        self.assertFalse(doc["timed"])
        self.assertEqual([s["text"] for s in doc["segments"]], ["Hello there. Still Maya.", "Hi."])
        self.assertEqual(T.text_lines(doc)[1], "s0002 ¶2 [Tom] Hi.")

    def test_recordings_folder(self):
        folder = self.f.path / "rec"
        folder.mkdir()
        (folder / "meta.json").write_text(json.dumps({"id": "A", "startedAt": "2026-11-19T07:00:00Z", "duration": 60,
                                                       "channelLayout": ["microphone", "system"],
                                                       "systemAudio": {"wasRequested": True}}), encoding="utf-8")
        (folder / "transcript.json").write_text(json.dumps({"schemaVersion": 1, "utterances": [
            {"id": "1", "channel": "system", "start": 10, "end": 22, "text": "Добрый день."},
            {"id": "2", "channel": "microphone", "start": 0, "end": 9, "text": "Привет."},
            {"id": "3", "channel": "system", "start": 30, "end": 40, "text": "", "isFailed": True}]}), encoding="utf-8")
        (folder / "audio.m4a").write_text("")
        doc = T.build([folder])
        self.assertEqual(doc["kind"], "channels")
        self.assertEqual([p["name"] for p in doc["speakers"]], ["Я (микрофон)", "Собеседники"])
        self.assertEqual([s["text"] for s in doc["segments"]], ["Привет.", "Добрый день.", ""])
        self.assertTrue(doc["segments"][2]["failed"])
        self.assertEqual(doc["recordedAt"], "2026-11-19T07:00:00Z")
        self.assertTrue(doc["audio"].endswith("audio.m4a"))
        named = T.build([folder], me="Анна", other="Олег")
        self.assertEqual([p["name"] for p in named["speakers"]], ["Анна", "Олег"])
        self.assertIn("(not recognised until", T.text_lines(doc)[2])


if __name__ == "__main__":
    unittest.main()
