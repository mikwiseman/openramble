#!/usr/bin/env python3
import json
import re
import sys
from datetime import datetime
from pathlib import Path


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) not in {2, 3}:
    fail("usage: validate-live-benchmark.py report.json [expected-git-sha]")

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
metrics = report["metrics"]
speakers = report["speakers"]
frozen = json.loads(
    (Path(__file__).resolve().parent.parent / "quality" / "reproducibility.json")
    .read_text(encoding="utf-8")
)

required_strings = [
    "corpusSHA256", "rawResultsSHA256", "pipelineGitSHA", "modelRevision",
    "modelManifestSHA256", "scorerSHA256", "referencesFrozenAt", "scoredAt",
]
for field in required_strings:
    if not report.get(field) or str(report[field]).startswith("REQUIRED"):
        fail(f"missing {field}")

for field in ("corpusSHA256", "rawResultsSHA256", "modelManifestSHA256", "scorerSHA256"):
    if not re.fullmatch(r"[0-9a-f]{64}", str(report[field]).lower()):
        fail(f"{field} must be a full 64-hex SHA-256")
if not re.fullmatch(r"[0-9a-f]{40}", str(report["modelRevision"]).lower()):
    fail("modelRevision must be a full 40-hex revision")
if str(report["modelRevision"]).lower() != frozen["model"]["revision"]:
    fail("benchmark model revision differs from the frozen release candidate")
if str(report["modelManifestSHA256"]).lower() != frozen["model"]["manifestSHA256"]:
    fail("benchmark model manifest differs from the frozen release candidate")
if str(report["scorerSHA256"]).lower() != frozen["scorerSHA256"]:
    fail("benchmark scorer differs from the frozen scorer")
pipeline_sha = str(report["pipelineGitSHA"]).lower()
if not re.fullmatch(r"[0-9a-f]{40}", pipeline_sha):
    fail("pipelineGitSHA must be a full 40-hex SHA")
if len(sys.argv) == 3 and pipeline_sha != sys.argv[2].lower():
    fail("benchmark pipelineGitSHA does not match release HEAD")

try:
    frozen_at = datetime.fromisoformat(str(report["referencesFrozenAt"]).replace("Z", "+00:00"))
    scored_at = datetime.fromisoformat(str(report["scoredAt"]).replace("Z", "+00:00"))
except ValueError:
    fail("benchmark timestamps must be ISO-8601")
if frozen_at.tzinfo is None or scored_at.tzinfo is None:
    fail("benchmark timestamps must include a timezone")
if frozen_at > scored_at:
    fail("references must be frozen before scoring")

if report.get("emptyUserDictionary") is not True:
    fail("primary score must use an empty user dictionary")
if report.get("speakerCount", 0) < 5 or len(speakers) < 5:
    fail("at least five consented speakers are required")
if report.get("speakerCount") != len(speakers):
    fail("speakerCount does not match the speaker rows")
if len({speaker.get("id") for speaker in speakers}) != len(speakers):
    fail("speaker IDs must be unique")
if report.get("hardware", {}).get("memoryGB") != 8:
    fail("release gate must include the M1 8 GB class")
if "M1" not in str(report.get("hardware", {}).get("model", "")):
    fail("release quality gate must run on an M1-class Mac")
os_build = str(report.get("hardware", {}).get("osBuild", "")).strip()
if not os_build or os_build.startswith("REQUIRED"):
    fail("exact macOS build is required")
if not {"built-in", "external-or-bluetooth"}.issubset(set(report.get("microphones", []))):
    fail("built-in and external/Bluetooth microphones are required")

maximums = {
    "ruWER": 0.12,
    "enWER": 0.12,
    "mixedWER": 0.30,
    "engineReadyStopToTextP95Seconds": 2.0,
    "launchToReadyP95Seconds": 20.0,
    "warmedIdleRSSBytes": 1_000_000_000,
    "fiveMinutePeakRSSBytes": 1_500_000_000,
    "majorityWrongLanguageClips": 0,
    "crashes": 0,
    "recordingLosses": 0,
}
minimums = {"mixedEnglishTermRecall": 0.80, "firstWordRetention": 0.95}
for name, limit in maximums.items():
    if metrics[name] > limit:
        fail(f"{name}={metrics[name]} exceeds {limit}")
for name, limit in minimums.items():
    if metrics[name] < limit:
        fail(f"{name}={metrics[name]} is below {limit}")
if metrics.get("oneTimeCoreMLCompileSeconds", -1) < 0:
    fail("one-time Core ML compile duration must be measured separately")

for speaker in speakers:
    if max(speaker["ruWER"], speaker["enWER"]) > 0.20:
        fail(f"speaker {speaker['id']} WER tail exceeds 20%")
    if speaker["termRecall"] < 0.70:
        fail(f"speaker {speaker['id']} term recall is below 70%")
    if speaker["firstWordRetention"] < 0.90:
        fail(f"speaker {speaker['id']} first-word retention is below 90%")

taxonomy = report.get("failureTaxonomy")
if not isinstance(taxonomy, dict) or not taxonomy:
    fail("failure taxonomy is required")
if any(str(name).startswith("REQUIRED") for name in taxonomy):
    fail("failure taxonomy still contains template placeholders")

decision = report.get("decision", {})
if decision.get("value") not in {"keep-parakeet", "switch-engine"}:
    fail("signed keep/switch decision is required")
if not decision.get("signedBy") or str(decision["signedBy"]).startswith("REQUIRED"):
    fail("decision signer is required")
if not decision.get("signedAt") or str(decision["signedAt"]).startswith("REQUIRED"):
    fail("decision timestamp is required")
try:
    signed_at = datetime.fromisoformat(str(decision["signedAt"]).replace("Z", "+00:00"))
except ValueError:
    fail("decision timestamp must be ISO-8601")
if signed_at.tzinfo is None:
    fail("decision timestamp must include a timezone")

print("PASS: frozen live benchmark satisfies the safe-beta quality gate")
