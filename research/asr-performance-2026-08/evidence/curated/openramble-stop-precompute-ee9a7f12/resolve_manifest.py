#!/usr/bin/env python3
import hashlib
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
manifest = json.loads(source.read_text(encoding="utf-8"))
reference_source = manifest["reference_source"]
golden_path = Path(reference_source["path"])
actual = hashlib.sha256(golden_path.read_bytes()).hexdigest()
if actual != reference_source["sha256"]:
    raise SystemExit("golden SHA-256 mismatch")
golden = json.loads(golden_path.read_text(encoding="utf-8"))
for fixture in manifest["fixtures"]:
    reference = golden["texts"].get(fixture["reference_key"])
    if not isinstance(reference, str) or not reference:
        raise SystemExit(f"missing reference for {fixture['id']}")
    fixture["reference"] = reference
destination.write_text(
    json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
