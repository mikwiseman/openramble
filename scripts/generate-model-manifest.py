#!/usr/bin/env python3
"""Собрать манифесты моделей с контрольными суммами.

Ходит в Hugging Face за деревом файлов конкретной ревизии, отбирает только те
бандлы, которые нужны для распознавания, и записывает детерминированный JSON.

Моделей две:

* Parakeet TDT 0.6B v3 — основное распознавание. Репозиторий весит около
  3 ГБ — там лежат ещё MelEncoder, EncoderInt4 и JointDecisionv2, которые
  FluidAudio для нашего сценария не грузит. Рабочий набор — примерно 483 МБ.
* Parakeet CTC 110M — акустический подсказчик терминов (custom vocabulary).
  Набор сверен с тем, что скачивает сам FluidAudio: CtcHead.mlmodelc не
  нужен — его выход встроен в AudioEncoder, а описание головы лежит в
  ctc_head_metadata.json. Рабочий набор — примерно 98 МБ.

Откуда берутся суммы: у больших файлов Hugging Face хранит их в поле lfs.oid
(это и есть SHA-256). Мелкие файлы под LFS не заведены, поэтому их приходится
скачать и посчитать локально — это десятки килобайт.

Ключ mirror в уже записанном манифесте сохраняется как есть: он добавляется
руками при выкладке зеркала на GitHub Releases, и его затирание оставило бы
загрузку без запасного источника.

Запуск:
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
    # Набор сверен не по документации, а по коду тега 0.15.5: там для третьей
    # версии требуется JointDecisionv3.mlmodelc, тогда как руководство по
    # ручной загрузке называет JointDecision.mlmodelc — оно устарело.
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
    # Набор сверен с загрузкой самого FluidAudio (ModelHub кладёт в кэш ровно
    # эти файлы): CtcModels.loadDirect читает MelSpectrogram, AudioEncoder и
    # vocab.json, CtcTokenizer — tokenizer.json с соседями.
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
    """Дерево файлов ревизии. Пагинация у HF курсорная, идём до конца."""
    entries: list[dict] = []
    url = (
        f"https://huggingface.co/api/models/{spec.repository}/tree/{spec.revision}"
        "?recursive=true&expand=true"
    )
    while url:
        request = urllib.request.Request(url, headers={"User-Agent": "wai-dictation-manifest"})
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
    """Скачать файл и посчитать сумму — только для не-LFS мелочи."""
    url = f"https://huggingface.co/{spec.repository}/resolve/{spec.revision}/{path}"
    request = urllib.request.Request(url, headers={"User-Agent": "wai-dictation-manifest"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=300) as response:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def existing_mirror(output: Path) -> dict | None:
    """Mirror записывается руками при выкладке на GitHub Releases."""
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
        print(f"Не удалось получить дерево файлов: {error}", file=sys.stderr)
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
            print(f"  считаю сумму локально: {path}")
            checksum = sha256_of_remote(spec, path)

        files.append({"path": path, "byteCount": int(size), "sha256": checksum.lower()})

    if not files:
        print("Не найдено ни одного нужного файла — проверьте префиксы", file=sys.stderr)
        return 1

    missing = [name for name in spec.required_files if name not in {f["path"] for f in files}]
    if missing:
        print(f"В ревизии нет обязательных файлов: {missing}", file=sys.stderr)
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
    # Mirror стоит до files — так же, как в записанном руками манифесте,
    # чтобы регенерация не создавала пустых перестановок в diff.
    mirror = existing_mirror(spec.output)
    if mirror:
        manifest["mirror"] = mirror
    manifest["files"] = files

    spec.output.parent.mkdir(parents=True, exist_ok=True)
    spec.output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

    total = sum(item["byteCount"] for item in files)
    print(f"  записано: {spec.output.name}")
    print(f"  файлов: {len(files)}, вес: {total:,} байт ({total / 1_000_000:.1f} МБ)")
    return 0


def main() -> int:
    for spec in SPECS:
        status = generate(spec)
        if status != 0:
            return status
    return 0


if __name__ == "__main__":
    sys.exit(main())
