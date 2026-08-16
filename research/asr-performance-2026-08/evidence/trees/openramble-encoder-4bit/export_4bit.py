#!/usr/bin/env python3
"""Run the frozen 15 s exporter with an explicit 4-bit encoder palette.

This wrapper leaves the previously sealed exporter byte-for-byte unchanged.
It replaces only the constructor bound in that module, so the single existing
palettization call receives ``nbits=4`` instead of ``nbits=6``.  The output
metadata is then annotated with the actual override and wrapper hashes are
recorded separately by the orchestration command.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys


SOURCE = Path("$TMP/openramble-short-shape/short_export.py")


def main() -> None:
    spec = importlib.util.spec_from_file_location("frozen_short_export", SOURCE)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load frozen exporter")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    original = module.OpPalettizerConfig

    def four_bit_config(*args: object, **kwargs: object) -> object:
        kwargs["nbits"] = 4
        return original(*args, **kwargs)

    module.OpPalettizerConfig = four_bit_config
    module.main()

    output_index = sys.argv.index("--output-dir") + 1
    metadata_path = Path(sys.argv[output_index]) / "prototype-metadata.json"
    metadata = json.loads(metadata_path.read_text())
    metadata["temporary_experiment"] = {
        "encoder_palette_nbits": 4,
        "frozen_exporter": str(SOURCE),
    }
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
