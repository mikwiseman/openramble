#!/usr/bin/env python3
"""Collect model manifests with checksums.

Goes to Hugging Face for a tree of files of a specific revision, selects only those
bundles that are needed for recognition, and writes deterministic JSON.

There are two models:

* Parakeet TDT 0.6B v3 - basic recognition. The repository weighs about
  3 GB - there are also MelEncoder, EncoderInt4 and JointDecisionv2, which
  FluidAudio does not load for our scenario. The working set is approximately 483 MB.
* Parakeet CTC 110M - acoustic term prompter (custom vocabulary).
  The set is checked against what FluidAudio itself downloads: CtcHead.mlmodelc is not
  needed - its output is built into AudioEncoder, and the description of the head is in
  ctc_head_metadata.json. The working set is approximately 98 MB.

Where do the amounts come from: for large files, Hugging Face stores them in the lfs.oid field
(this is SHA-256). Small files are not included under LFS, so they have to be
download and calculate locally - this is tens of kilobytes.

The mirror key in the already recorded manifest is kept as is: it is added
hands when laying out the mirror on GitHub Releases, and overwriting it would leave
loading without a backup source.

Launch:
    python3 scripts/generate-model-manifest.py
"""

from __future__ import annotations

import hashlib
import json
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

RESOURCES = Path(__file__).resolve().parents[1] / "Packages/LocalASR/Sources/LocalASR/Resources"

FLUIDAUDIO_VERSION = "0.15.5"


@dataclass(frozen=True)
class ModelSpec:
    model_id: str
    repository: str
    revision: str
    quantization: str
    license: str
    required_prefixes: tuple[str, ...]
    required_files: tuple[str, ...]
    output: Path


SPECS = (
    # The set is verified not according to the documentation, but according to the tag code 0.15.5: there for the third
    # version requires JointDecisionv3.mlmodelc, whereas the manual for
    # manual loading calls JointDecision.mlmodelc - it is deprecated.
    ModelSpec(
        model_id="parakeet-tdt-0.6b-v3",
        repository="FluidInference/parakeet-tdt-0.6b-v3-coreml",
        revision="aed02740059203c4a87495924f685de3722ae9ce",
        quantization="encoder 6-bit palettized, mixed precision",
        license="CC-BY-4.0",
        required_prefixes=(
            "Preprocessor.mlmodelc/",
            "Encoder.mlmodelc/",
            "Decoder.mlmodelc/",
            "JointDecisionv3.mlmodelc/",
        ),
        required_files=("parakeet_vocab.json",),
        output=RESOURCES / "model-manifest.json",
    ),
    # The set is checked against the download of FluidAudio itself (ModelHub caches exactly
    # these files): CtcModels.loadDirect reads MelSpectrogram, AudioEncoder and
    # vocab.json, CtcTokenizer - tokenizer.json with neighbors.
    ModelSpec(
        model_id="parakeet-ctc-110m",
        repository="FluidInference/parakeet-ctc-110m-coreml",
        revision="accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
        quantization="mixed precision",
        license="CC-BY-4.0",
        required_prefixes=(
            "MelSpectrogram.mlmodelc/",
            "AudioEncoder.mlmodelc/",
        ),
        required_files=(
            "vocab.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "config.json",
            "ctc_head_metadata.json",
        ),
        output=RESOURCES / "vocabulary-manifest.json",
    ),
)


def fetch_tree(spec: ModelSpec) -> list[dict]:
    """Revision file tree. HF has cursor pagination, let's go to the end."""
    entries: list[dict] = []
    url = (
        f"https://huggingface.co/api/models/{spec.repository}/tree/{spec.revision}"
        "?recursive=true&expand=true"
    )
    while url:
        request = urllib.request.Request(url, headers={"User-Agent": "openramble-manifest"})
        with urllib.request.urlopen(request, timeout=60) as response:
            entries.extend(json.loads(response.read()))
            link = response.headers.get("Link", "")
        url = None
        for part in link.split(","):
            if 'rel="next"' in part:
                url = part.split(";")[0].strip().strip("<>")
    return entries


def is_required(spec: ModelSpec, path: str) -> bool:
    return path.startswith(spec.required_prefixes) or path in spec.required_files


def sha256_of_remote(spec: ModelSpec, path: str) -> str:
    """Download the file and calculate the amount - only for non-LFS change."""
    url = f"https://huggingface.co/{spec.repository}/resolve/{spec.revision}/{path}"
    request = urllib.request.Request(url, headers={"User-Agent": "openramble-manifest"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=300) as response:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def existing_mirror(output: Path) -> dict | None:
    """Mirror is written manually when uploaded to GitHub Releases."""
    if not output.exists():
        return None
    try:
        return json.loads(output.read_text()).get("mirror")
    except (OSError, json.JSONDecodeError):
        return None


def generate(spec: ModelSpec) -> int:
    print(f"→ {spec.model_id} @ {spec.revision[:8]}")
    try:
        tree = fetch_tree(spec)
    except urllib.error.URLError as error:
        print(f"Failed to get file tree: {error}", file=sys.stderr)
        return 1

    files = []
    for entry in tree:
        if entry.get("type") != "file":
            continue
        path = entry["path"]
        if not is_required(spec, path):
            continue

        lfs = entry.get("lfs") or {}
        checksum = lfs.get("oid")
        size = lfs.get("size") or entry.get("size")

        if not checksum:
            print(f" count the sum locally: {path}")
            checksum = sha256_of_remote(spec, path)

        files.append({"path": path, "byteCount": int(size), "sha256": checksum.lower()})

    if not files:
        print("No required files were found - check the prefixes", file=sys.stderr)
        return 1

    missing = [name for name in spec.required_files if name not in {f["path"] for f in files}]
    if missing:
        print(f"There are no required files in the revision: {missing}", file=sys.stderr)
        return 1

    files.sort(key=lambda item: item["path"])
    manifest = {
        "modelID": spec.model_id,
        "repository": spec.repository,
        "revision": spec.revision,
        "fluidAudioVersion": FLUIDAUDIO_VERSION,
        "quantization": spec.quantization,
        "license": spec.license,
    }
    # Mirror comes before files - the same as in a manually written manifesto,
    # so that regeneration does not create empty permutations in the diff.
    mirror = existing_mirror(spec.output)
    if mirror:
        manifest["mirror"] = mirror
    manifest["files"] = files

    spec.output.parent.mkdir(parents=True, exist_ok=True)
    spec.output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

    total = sum(item["byteCount"] for item in files)
    print(f" written: {spec.output.name}")
    print(f" files: {len(files)}, weight: {total:,} bytes ({total / 1_000_000:.1f} MB)")
    return 0


def main() -> int:
    for spec in SPECS:
        status = generate(spec)
        if status != 0:
            return status
    return 0


if __name__ == "__main__":
    sys.exit(main())
