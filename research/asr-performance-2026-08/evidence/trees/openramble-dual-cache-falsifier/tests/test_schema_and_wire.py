from __future__ import annotations

import dataclasses
import io
import struct
import unittest

from dual_cache_harness.schema import (
    AuditedResult,
    CacheImportError,
    CacheImporter,
    RawTokenWindow,
    SerializedClosedWindowCache,
    canonical_json_bytes,
)
from dual_cache_harness.wire import HEADER, MAGIC, VERSION, Kind, WireError, read_sync
from run import fake_descriptor, fake_identity, fake_pcm


class CacheImportTests(unittest.TestCase):
    def make_record(self) -> SerializedClosedWindowCache:
        identity = fake_identity()
        descriptor = fake_descriptor()
        pcm = fake_pcm()
        return SerializedClosedWindowCache(
            trial_id="trial",
            capture_storage_id="storage",
            speculative_generation="generation",
            producer_identity=identity,
            descriptor=descriptor,
            exact_input_pcm=pcm[: descriptor.chunk_end * 4],
            tokens=(RawTokenWindow(1, 2, 0x3F00_0000, 3),),
        )

    def validate(self, records, *, identity=None, pcm=None):
        record = records[0]
        return CacheImporter.validate(
            records,
            expected_identity=identity or fake_identity(),
            trial_id="trial",
            capture_storage_id="storage",
            speculative_generation="generation",
            authoritative_pcm=pcm or fake_pcm(),
            planned_descriptors={record.descriptor.index: fake_descriptor()},
        )

    def test_exact_record_is_accepted(self) -> None:
        record = self.make_record()
        self.assertEqual(self.validate([record]), (record,))

    def test_one_pcm_bit_is_rejected_even_when_shape_matches(self) -> None:
        record = self.make_record()
        changed = bytes([record.exact_input_pcm[0] ^ 1]) + record.exact_input_pcm[1:]
        mutated = dataclasses.replace(record, exact_input_pcm=changed)
        with self.assertRaisesRegex(CacheImportError, "exact_input_mismatch"):
            self.validate([mutated])

    def test_duplicate_index_is_rejected(self) -> None:
        record = self.make_record()
        with self.assertRaisesRegex(CacheImportError, "duplicate_window_index"):
            self.validate([record, record])

    def test_compute_route_and_runtime_metadata_are_exact_fences(self) -> None:
        record = self.make_record()
        identity = fake_identity()
        mutations = (
            {"ml_compute_units": "cpuOnly"},
            {"encoder_placement": "neuralEngine"},
            {"os_build": "OTHER"},
            {"coreml_bundle_build": "OTHER"},
            {"coreml_binary_sha256": "f" * 64},
            {"hardware_model": "OtherMac"},
        )
        for mutation in mutations:
            changed_execution = dataclasses.replace(identity.execution, **mutation)
            changed_identity = dataclasses.replace(identity, execution=changed_execution)
            with self.subTest(mutation=mutation):
                with self.assertRaisesRegex(CacheImportError, "execution_identity_mismatch"):
                    self.validate([record], identity=changed_identity)

    def test_model_code_config_language_and_vocabulary_are_exact_fences(self) -> None:
        record = self.make_record()
        identity = fake_identity()
        mutations = (
            dataclasses.replace(identity, executable_sha256="f" * 64),
            dataclasses.replace(identity, code_revision="different"),
            dataclasses.replace(identity, language_hint="en"),
            dataclasses.replace(identity, configuration_json=canonical_json_bytes({"x": 1})),
            dataclasses.replace(identity, vocabulary_json=canonical_json_bytes({"revision": 99})),
            dataclasses.replace(
                identity,
                model_files=(dataclasses.replace(identity.model_files[0], sha256="e" * 64),),
            ),
        )
        for changed_identity in mutations:
            with self.subTest(identity=changed_identity.canonical_sha256):
                with self.assertRaisesRegex(CacheImportError, "execution_identity_mismatch"):
                    self.validate([record], identity=changed_identity)

    def test_configuration_canonicalizer_forbids_ambiguous_float_json(self) -> None:
        with self.assertRaisesRegex(ValueError, "IEEE bit integers"):
            canonical_json_bytes({"similarity": 0.65})

    def test_audited_parity_compares_full_token_fields_not_only_text(self) -> None:
        token = RawTokenWindow(1, 2, 0x3F00_0000, 3)
        result = AuditedResult(
            transcript="same",
            primary_tokens=(token,),
            token_strings=("same",),
            word_records_json=canonical_json_bytes([]),
            vocabulary_outcome="no_candidate",
            candidate_regions_json=canonical_json_bytes([]),
        )
        changed = dataclasses.replace(
            result,
            primary_tokens=(dataclasses.replace(token, confidence_bits=token.confidence_bits + 1),),
        )
        with self.assertRaises(AssertionError):
            result.assert_exact_parity(changed)


class WireTests(unittest.TestCase):
    def test_kind_payload_cap_is_checked_before_body_read(self) -> None:
        declared = 240_000 * 4 + 1
        header = HEADER.pack(MAGIC, VERSION, int(Kind.CACHE_RECORD), 1, declared)
        stream = io.BytesIO(header + struct.pack(">I", 0))
        with self.assertRaisesRegex(WireError, "payload too large"):
            read_sync(stream)

    def test_no_payload_kind_rejects_declared_byte_before_body_read(self) -> None:
        header = HEADER.pack(MAGIC, VERSION, int(Kind.HELLO), 1, 1)
        stream = io.BytesIO(header + struct.pack(">I", 0))
        with self.assertRaisesRegex(WireError, "payload too large"):
            read_sync(stream)


if __name__ == "__main__":
    unittest.main()
