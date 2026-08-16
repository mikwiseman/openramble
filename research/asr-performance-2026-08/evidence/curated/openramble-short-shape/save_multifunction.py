#!/usr/bin/env python3
"""TEMP-only iOS 18/macOS 15 multi-function package builder."""

from pathlib import Path
import argparse
import time

import coremltools as ct


def combine(short: Path, shipping: Path, destination: Path) -> float:
    descriptor = ct.utils.MultiFunctionDescriptor()
    descriptor.add_function(str(short), "main", "bucket_7_5")
    descriptor.add_function(str(shipping), "main", "bucket_15")
    descriptor.default_function_name = "bucket_7_5"
    started = time.perf_counter()
    ct.utils.save_multifunction(descriptor, str(destination))
    return time.perf_counter() - started


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--short-dir", type=Path, required=True)
    parser.add_argument("--shipping-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    timings = {}
    for component in ("Preprocessor.mlpackage", "Encoder.mlpackage"):
        timings[component] = combine(
            args.short_dir / component,
            args.shipping_dir / component,
            args.output_dir / component,
        )
    print(timings)


if __name__ == "__main__":
    main()
