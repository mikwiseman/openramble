#!/usr/bin/env python3
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 4:
    fail("usage: validate-release-evidence.py evidence.json git-sha artifact.dmg")

report_path = Path(sys.argv[1])
expected_git_sha = sys.argv[2].lower()
artifact_path = Path(sys.argv[3])
report = json.loads(report_path.read_text(encoding="utf-8"))

if not re.fullmatch(r"[0-9a-f]{40}", expected_git_sha):
    fail("expected Git SHA is not a full 40-hex SHA")
if str(report.get("gitSHA", "")).lower() != expected_git_sha:
    fail("manual evidence Git SHA does not match release HEAD")
if not artifact_path.is_file():
    fail(f"artifact does not exist: {artifact_path}")

digest = hashlib.sha256()
with artifact_path.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
actual_dmg_sha = digest.hexdigest()
if str(report.get("dmgSHA256", "")).lower() != actual_dmg_sha:
    fail("manual evidence DMG SHA-256 does not match the release artifact")

# The field must be filled out meaningfully, but the exact text is not verified.
# Previously, the line “Russian-UI safe beta” was nailed here - the interface became
# in English, and the validator began to demand lies. Validator falling on
# truth, teaches to tailor evidence for verification, and this is exactly the opposite of what
# why evidence exists.
positioning = str(report.get("positioning", "")).strip()
if len(positioning) < 8:
    fail("release positioning must be stated in the evidence file")

for field in ("m1MacOS14", "currentAppleSiliconMacOS26", "sparkleFromPreviousInstalledBuild"):
    item = report.get(field, {})
    if item.get("result") != "pass":
        fail(f"{field} is not passed")
    evidence = str(item.get("evidence", "")).strip()
    if not evidence or evidence.startswith("REQUIRED"):
        fail(f"{field} has no evidence")

macos15 = report.get("macOS15", {})
if macos15.get("result") not in {"pass", "not-tested"}:
    fail("macOS15 must be pass or explicitly not-tested")
macos15_evidence = str(macos15.get("evidence", "")).strip()
if not macos15_evidence or macos15_evidence.startswith("REQUIRED"):
    fail("macOS15 needs evidence or an explicit beta-note")

for field in ("signedBy", "signedAt"):
    value = str(report.get(field, "")).strip()
    if not value or value.startswith("REQUIRED"):
        fail(f"missing {field}")

try:
    signed_at = datetime.fromisoformat(str(report["signedAt"]).replace("Z", "+00:00"))
except ValueError:
    fail("signedAt must be ISO-8601")
if signed_at.tzinfo is None:
    fail("signedAt must include a timezone")

print(f"PASS: manual matrix matches HEAD and DMG {actual_dmg_sha}")
