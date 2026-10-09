"""Derive fixed public fixtures from the existing October corpus, before inference."""
import hashlib
import json
import sys
import wave
from pathlib import Path

root = Path(sys.argv[1]).resolve()
manifest = json.loads((root / "manifest.json").read_text())
dest = root / "mini"
dest.mkdir(exist_ok=True)
fixtures = []
for lang in ("ru", "en"):
    source = [f for f in manifest["fixtures"] if f["language"] == lang]
    short = next(f for f in source if 4 <= f["duration_seconds"] <= 12)
    fixtures.append(dict(short, role="short", id=lang + "-short", source_id=short["id"]))
    for seconds in (60, 360, 3540):
        path = dest / f"{lang}-{seconds}s.wav"
        frames, refs, components = 0, [], []
        with wave.open(str(path), "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            while frames < seconds * 16000:
                item = source[len(components) % len(source)]
                with wave.open(item["path"]) as inp:
                    pcm = inp.readframes(inp.getnframes())
                out.writeframes(pcm)
                out.writeframes(b"\0" * 16000)
                frames += len(pcm) // 2 + 8000
                refs.append(item["reference"])
                components.append(item["id"])
        fixtures.append({"id": f"{lang}-{seconds}s", "role": str(seconds), "language": lang,
                         "path": str(path), "audio_sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest(),
                         "duration_seconds": frames / 16000, "reference": " ".join(refs),
                         "components": components, "license": "CC BY 4.0", "kind": "composite-read-speech"})
mixed = next(f for f in manifest["long_fixtures"] if f["id"] == "mixed-3540s")
fixtures.append(dict(mixed, role="3540"))
for fixture in fixtures:
    fixture["reference_sha256"] = hashlib.sha256(fixture["reference"].encode()).hexdigest()
document = {"source": manifest["source"], "source_revision": manifest["source_revision"],
            "source_manifest_sha256": hashlib.file_digest((root / "manifest.json").open("rb"), "sha256").hexdigest(),
            "fixtures": fixtures}
(root / "mini-inputs.json").write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
print([(f["id"], f["duration_seconds"]) for f in fixtures])
