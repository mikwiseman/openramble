#!/usr/bin/env python3

from __future__ import annotations

import math
import unittest

from endpoint_contract import (
    ENTRY_THRESHOLD,
    EXIT_THRESHOLD,
    GUARD_SAMPLES,
    MIN_SILENCE_CHUNKS,
    VAD_CHUNK_SAMPLES,
    EndpointMachine,
    constant_chunk,
)


def machine() -> EndpointMachine:
    return EndpointMachine(
        session_id="session-1",
        ingress_generation=7,
        model_revision="shipping-model-revision",
        product_config_sha256="a" * 64,
        vocabulary_snapshot_sha256="b" * 64,
        language_hint="en",
    )


class EndpointContractTests(unittest.TestCase):
    def test_no_tail_stop_is_unmodified_ordinary_raw(self) -> None:
        state = machine()
        speech = constant_chunk(0.25)
        state.ingest_full_chunk(speech, ENTRY_THRESHOLD)
        decision = state.stop()
        self.assertEqual(decision.path, "ordinary_raw")
        self.assertEqual(decision.sample_count, VAD_CHUNK_SAMPLES)
        self.assertEqual(decision.pcm_sha256, state.raw_pcm_sha256)

    def test_two_negative_chunks_create_stable_guarded_cut(self) -> None:
        state = machine()
        state.ingest_full_chunk(constant_chunk(0.25), 0.99)
        self.assertIsNone(state.ingest_full_chunk(constant_chunk(0.0), EXIT_THRESHOLD - 0.01))
        candidate = state.ingest_full_chunk(constant_chunk(0.0), EXIT_THRESHOLD - 0.01)
        self.assertIsNotNone(candidate)
        assert candidate is not None
        self.assertEqual(MIN_SILENCE_CHUNKS, 2)
        self.assertEqual(candidate.cut_sample, VAD_CHUNK_SAMPLES + GUARD_SAMPLES)
        key_before = candidate.key.digest()
        state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        self.assertEqual(state.candidate.key.digest(), key_before)
        state.mark_candidate_ready(key_before)
        decision = state.stop()
        self.assertEqual(decision.path, "reuse_ready_candidate")
        self.assertEqual(decision.sample_count, 2 * VAD_CHUNK_SAMPLES)

    def test_resumed_speech_invalidates_ready_candidate(self) -> None:
        state = machine()
        state.ingest_full_chunk(constant_chunk(0.2), 0.99)
        state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        candidate = state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        assert candidate is not None
        state.mark_candidate_ready(candidate.key.digest())
        state.ingest_full_chunk(constant_chunk(0.3), 0.99)
        decision = state.stop()
        self.assertEqual(decision.path, "ordinary_raw")
        self.assertEqual(decision.reason, "resumed_speech")

    def test_stop_partial_never_enters_asr_pcm_and_uncertain_partial_invalidates(self) -> None:
        state = machine()
        state.ingest_full_chunk(constant_chunk(0.2), 0.99)
        state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        candidate = state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        assert candidate is not None
        state.mark_candidate_ready(candidate.key.digest())
        partial = constant_chunk(0.0)[:400]
        state.append_unclassified_partial(partial)
        before_validation_count = state.sample_count
        state.validate_stop_partial(EXIT_THRESHOLD)
        decision = state.stop()
        self.assertEqual(state.sample_count, before_validation_count)
        self.assertEqual(decision.path, "ordinary_raw")
        self.assertEqual(decision.reason, "stop_partial_not_confident_silence")

    def test_confident_silent_stop_partial_preserves_candidate_and_raw_count(self) -> None:
        state = machine()
        state.ingest_full_chunk(constant_chunk(0.2), 0.99)
        state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        candidate = state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        assert candidate is not None
        state.mark_candidate_ready(candidate.key.digest())
        partial = constant_chunk(0.0)[:400]
        state.append_unclassified_partial(partial)
        raw_count = state.sample_count
        state.validate_stop_partial(EXIT_THRESHOLD - 0.01)
        decision = state.stop()
        self.assertEqual(state.sample_count, raw_count)
        self.assertEqual(decision.path, "reuse_ready_candidate")

    def test_candidate_key_covers_session_config_vocab_language_and_pcm(self) -> None:
        state = machine()
        state.ingest_full_chunk(constant_chunk(0.2), 0.99)
        state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        candidate = state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        assert candidate is not None
        baseline = candidate.key.digest()
        mutations = [
            {"session_id": "session-2"},
            {"ingress_generation": 8},
            {"model_revision": "different"},
            {"product_config_sha256": "c" * 64},
            {"vocabulary_snapshot_sha256": "d" * 64},
            {"language_hint": "ru"},
            {"canonical_pcm_sha256": "e" * 64},
        ]
        for mutation in mutations:
            values = dict(candidate.key.__dict__)
            values.update(mutation)
            changed = type(candidate.key)(**values)
            self.assertNotEqual(changed.digest(), baseline)

    def test_invalid_probability_fails_closed(self) -> None:
        for probability in (math.nan, math.inf, -0.1, 1.1):
            state = machine()
            with self.assertRaises(ValueError):
                state.ingest_full_chunk(constant_chunk(0.0), probability)
            self.assertEqual(state.stop().path, "ordinary_raw")

    def test_wrong_result_key_never_commits(self) -> None:
        state = machine()
        state.ingest_full_chunk(constant_chunk(0.2), 0.99)
        state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        candidate = state.ingest_full_chunk(constant_chunk(0.0), 0.0)
        assert candidate is not None
        state.mark_candidate_ready("f" * 64)
        decision = state.stop()
        self.assertEqual(decision.path, "ordinary_raw")
        self.assertEqual(decision.reason, "result_key_mismatch")


if __name__ == "__main__":
    unittest.main(verbosity=2)
