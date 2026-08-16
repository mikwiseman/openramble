from __future__ import annotations

import asyncio
import json
import os
import sys
import unittest
import uuid

from dual_cache_harness.controller import (
    DualProcessTrialRunner,
    HarnessFailure,
    WorkerProcess,
    symmetric_arm_order,
)
from run import (
    FAKE_COMMAND,
    environment,
    fake_descriptor,
    fake_identity,
    fake_pcm,
    run_fake_matrix,
    run_fault_soak,
)


class ProcessLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.identity = fake_identity()
        self.environment = environment(self.identity)

    async def test_exact_generation_is_killed_reaped_and_not_orphaned(self) -> None:
        foreground = WorkerProcess(
            FAKE_COMMAND,
            role="foreground",
            expected_identity=self.identity,
            environment=self.environment,
        )
        await foreground.launch()
        runner = DualProcessTrialRunner(
            foreground=foreground,
            speculative_command=FAKE_COMMAND,
            expected_identity=self.identity,
            speculative_environment=self.environment,
        )
        descriptor = fake_descriptor()
        try:
            observation = await runner.run_dual(
                pcm=fake_pcm(),
                trial_id="kill-reap",
                capture_storage_id=str(uuid.uuid4()),
                stop_offset_ms=0,
                speculation={
                    "active_ms": 60_000,
                    "completed_descriptors": [descriptor.to_dict()],
                    "planned_descriptors": [descriptor.to_dict()],
                },
            )
        finally:
            await foreground.shutdown()
        self.assertIsNotNone(observation.kill_to_reap_ns)
        self.assertGreater(observation.kill_to_reap_ns or 0, 0)
        assert observation.speculative_pid is not None
        with self.assertRaises(ProcessLookupError):
            os.kill(observation.speculative_pid, 0)

    async def test_wrong_handshake_identity_fails_closed_and_reaps(self) -> None:
        worker = WorkerProcess(
            FAKE_COMMAND,
            role="speculative",
            expected_identity=self.identity,
            environment={**self.environment, "DCHF_WRONG_HANDSHAKE": "1"},
        )
        with self.assertRaisesRegex(HarnessFailure, "execution identity mismatch"):
            await worker.launch()
        self.assertIsNone(worker.process)
        self.assertIsNone(worker.generation)

    async def test_idle_speculative_generation_is_reused_not_killed(self) -> None:
        worker = WorkerProcess(
            FAKE_COMMAND,
            role="speculative",
            expected_identity=self.identity,
            environment=self.environment,
        )
        await worker.launch()
        original = worker.generation
        try:
            first = await worker.probe_idle()
            second = await worker.probe_idle()
            self.assertEqual(first, original)
            self.assertEqual(second, original)
            self.assertIsNone(worker.process.returncode if worker.process else None)
        finally:
            await worker.shutdown()

    async def test_preflight_is_symmetric_and_exact(self) -> None:
        report = await run_fake_matrix([0, 25, 50, 75, 100], 2)
        self.assertTrue(report["full_exact_parity"])
        self.assertEqual(report["arms"]["baseline"]["count"], 10)
        self.assertEqual(report["arms"]["dual"]["count"], 10)
        self.assertEqual(report["speculative_orphans"], 0)
        self.assertLessEqual(report["foreground_fd_growth"], 2)
        self.assertEqual(report["max_live_children"], 2)

    async def test_faults_discard_cache_and_fallback_exactly_once(self) -> None:
        report = await run_fault_soak(32)
        self.assertTrue(report["ordinary_fallback_exactly_once"])
        self.assertTrue(report["full_exact_parity"])
        self.assertEqual(report["speculative_orphans"], 0)
        self.assertLessEqual(report["foreground_fd_growth"], 2)
        self.assertEqual(report["max_live_children"], 2)
        self.assertEqual(set(report["fault_counts"]), {
            "cache_pcm_bitflip",
            "duplicate_index",
            "wrong_generation",
            "descriptor_mismatch",
            "identity_compute_units",
            "identity_os_build",
            "identity_coreml_build",
            "identity_coreml_binary",
            "identity_model",
            "identity_config",
            "identity_language",
            "identity_vocabulary",
            "transport_digest",
            "exit_before_prediction",
            "stall_before_prediction",
            "malformed_frame",
        })

    def test_arm_order_is_balanced_at_each_boundary(self) -> None:
        order = symmetric_arm_order([0, 25], 3)
        for offset in (0, 25):
            arms = [arm for arm, candidate in order if candidate == offset]
            self.assertEqual(arms.count("baseline"), 3)
            self.assertEqual(arms.count("dual"), 3)
            self.assertNotEqual(arms[:2], arms[2:4])


if __name__ == "__main__":
    unittest.main()
