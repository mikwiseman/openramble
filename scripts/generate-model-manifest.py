#!/usr/bin/env python3
"""Собрать манифест модели с контрольными суммами.

Ходит в Hugging Face за деревом файлов конкретной ревизии, отбирает только те
бандлы, которые нужны для распознавания, и записывает детерминированный JSON.

Зачем отбор: репозиторий модели весит около 3 ГБ — там лежат ещё MelEncoder,
EncoderInt4 и JointDecisionv2, которые FluidAudio для нашего сценария не грузит.
Рабочий набор — примерно 483 МБ.

Откуда берутся суммы: у больших файлов Hugging Face хранит их в поле lfs.oid
(это и есть SHA-256). Мелкие файлы под LFS не заведены, поэтому их приходится
скачать и посчитать локально — это десятки килобайт.

Запуск:
    python3 scripts/generate-model-manifest.py
"""

from __future__ import annotations

import hashlib
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPOSITORY = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
REVISION = "aed02740059203c4a87495924f685de3722ae9ce"
MODEL_ID = "parakeet-tdt-0.6b-v3"
FLUIDAUDIO_VERSION = "0.15.5"
QUANTIZATION = "encoder 6-bit palettized, mixed precision"
LICENSE = "CC-BY-4.0"

# Что именно грузит FluidAudio для Parakeet v3.
#
# Набор сверен не по документации, а по коду тега 0.15.5: там для третьей версии
# требуется JointDecisionv3.mlmodelc, тогда как руководство по ручной загрузке
# называет JointDecision.mlmodelc — оно устарело. Рядом в репозитории лежат ещё
# EncoderInt4, JointDecisionv2, MelEncoder и прочее наследие: всё это не нужно и
# утроило бы вес загрузки.
REQUIRED_PREFIXES = (
    "Preprocessor.mlmodelc/",
    "Encoder.mlmodelc/",
    "Decoder.mlmodelc/",
    "JointDecisionv3.mlmodelc/",
)
REQUIRED_FILES = ("parakeet_vocab.json",)

OUTPUT = Path(__file__).resolve().parents[1] / (
    "Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json"
)


def fetch_tree() -> list[dict]:
    """Дерево файлов ревизии. Пагинация у HF курсорная, идём до конца."""
    entries: list[dict] = []
    url = (
        f"https://huggingface.co/api/models/{REPOSITORY}/tree/{REVISION}"
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


def is_required(path: str) -> bool:
    return path.startswith(REQUIRED_PREFIXES) or path in REQUIRED_FILES


def sha256_of_remote(path: str) -> str:
    """Скачать файл и посчитать сумму — только для не-LFS мелочи."""
    url = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{path}"
    request = urllib.request.Request(url, headers={"User-Agent": "wai-dictation-manifest"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=300) as response:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    try:
        tree = fetch_tree()
    except urllib.error.URLError as error:
        print(f"Не удалось получить дерево файлов: {error}", file=sys.stderr)
        return 1

    files = []
    for entry in tree:
        if entry.get("type") != "file":
            continue
        path = entry["path"]
        if not is_required(path):
            continue

        lfs = entry.get("lfs") or {}
        checksum = lfs.get("oid")
        size = lfs.get("size") or entry.get("size")

        if not checksum:
            print(f"  считаю сумму локально: {path}")
            checksum = sha256_of_remote(path)

        files.append({"path": path, "byteCount": int(size), "sha256": checksum.lower()})

    if not files:
        print("Не найдено ни одного нужного файла — проверьте префиксы", file=sys.stderr)
        return 1

    files.sort(key=lambda item: item["path"])
    manifest = {
        "modelID": MODEL_ID,
        "repository": REPOSITORY,
        "revision": REVISION,
        "fluidAudioVersion": FLUIDAUDIO_VERSION,
        "quantization": QUANTIZATION,
        "license": LICENSE,
        "files": files,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

    total = sum(item["byteCount"] for item in files)
    print(f"\nЗаписано: {OUTPUT}")
    print(f"Файлов: {len(files)}")
    print(f"Суммарный вес: {total:,} байт ({total / 1_000_000:.1f} МБ)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
