#!/usr/bin/env python3
"""Build a 7.5 s Encoder package that reuses shipping neural weights.

The shipping and independently exported 7.5 s MIL programs have identical
operation topology.  Only the 24 relative-position tensors have different
shapes.  This experiment keeps the short graph/types, points every
shape-independent blob operation at the shipping weight file, and keeps the
24 short relative-position tensors in a second file.
"""

from __future__ import annotations

import argparse
import os
import shutil
from pathlib import Path

import coremltools as ct
from coremltools.libmilstoragepython import _BlobStorageReader as BlobReader
from coremltools.libmilstoragepython import _BlobStorageWriter as BlobWriter
from coremltools.proto import MIL_pb2


def has_blob(operation) -> bool:
    return any(value.HasField("blobFileValue") for value in operation.attributes.values())


def output_types_match(left, right) -> bool:
    if len(left.outputs) != len(right.outputs):
        return False
    return all(
        left_output.SerializeToString() == right_output.SerializeToString()
        for left_output, right_output in zip(left.outputs, right.outputs)
    )


def retarget_blobs(operation, file_name: str) -> None:
    for value in operation.attributes.values():
        if value.HasField("blobFileValue"):
            value.blobFileValue.fileName = file_name


def copy_blob(value, reader: BlobReader, writer: BlobWriter) -> None:
    data_type = value.type.tensorType.dataType
    old_offset = value.blobFileValue.offset
    if data_type == MIL_pb2.FLOAT16:
        new_offset = writer.write_fp16_data(reader.read_fp16_data(old_offset))
    elif data_type == MIL_pb2.UINT8:
        new_offset = writer.write_uint8_data(reader.read_uint8_data(old_offset))
    else:
        name = MIL_pb2.DataType.Name(data_type)
        raise SystemExit(f"unsupported compact blob type: {name}")
    value.blobFileValue.fileName = "@model_path/weights/short-shape.bin"
    value.blobFileValue.offset = new_offset


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shipping", type=Path, required=True)
    parser.add_argument("--short", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.output.exists():
        raise SystemExit(f"output already exists: {args.output}")

    shipping_model = ct.models.MLModel(str(args.shipping), skip_model_load=True)
    short_model = ct.models.MLModel(str(args.short), skip_model_load=True)
    shipping_spec = shipping_model.get_spec()
    short_spec = short_model.get_spec()

    shipping_block = next(
        iter(shipping_spec.mlProgram.functions["main"].block_specializations.values())
    )
    short_block = next(
        iter(short_spec.mlProgram.functions["main"].block_specializations.values())
    )
    if len(shipping_block.operations) != len(short_block.operations):
        raise SystemExit("operation count mismatch")

    shutil.copytree(args.short, args.output)
    weights = args.output / "Data" / "com.apple.CoreML" / "weights"
    original_short_weight = weights / "weight.bin"
    compact_short_weight = weights / "short-shape.bin"
    short_reader = BlobReader(str(original_short_weight))
    short_writer = BlobWriter(str(compact_short_weight))

    shared_blob_operations = 0
    short_blob_operations = 0
    short_blob_names: list[str] = []
    for index, (shipping_operation, short_operation) in enumerate(
        zip(shipping_block.operations, short_block.operations)
    ):
        shipping_has_blob = has_blob(shipping_operation)
        short_has_blob = has_blob(short_operation)
        if shipping_has_blob != short_has_blob:
            raise SystemExit(f"blob topology mismatch at operation {index}")
        if not short_has_blob:
            continue

        if output_types_match(shipping_operation, short_operation):
            short_operation.CopyFrom(shipping_operation)
            retarget_blobs(short_operation, "@model_path/weights/shipping.bin")
            shared_blob_operations += 1
        else:
            for value in short_operation.attributes.values():
                if value.HasField("blobFileValue"):
                    copy_blob(value, short_reader, short_writer)
            short_blob_operations += 1
            short_blob_names.extend(output.name for output in short_operation.outputs)

    short_writer = None
    short_reader = None
    original_short_weight.unlink()

    shipping_weight = (
        args.shipping / "Data" / "com.apple.CoreML" / "weights" / "weight.bin"
    )
    shared_weight = weights / "shipping.bin"
    os.link(shipping_weight, shared_weight)

    model_path = args.output / "Data" / "com.apple.CoreML" / "model.mlmodel"
    model_path.write_bytes(short_spec.SerializeToString())

    print(f"shared_blob_operations={shared_blob_operations}")
    print(f"short_blob_operations={short_blob_operations}")
    print(f"short_blob_names={','.join(short_blob_names)}")
    print(f"shipping_weight_bytes={shipping_weight.stat().st_size}")
    print(f"short_shape_weight_bytes={compact_short_weight.stat().st_size}")
    print(f"shipping_hardlink_count={shared_weight.stat().st_nlink}")
    print(f"output={args.output}")


if __name__ == "__main__":
    main()
