from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

from dual_cache_harness.controller import (
    BoundedResourceSampler,
    DualProcessTrialRunner,
    ExactProcessGeneration,
    HarnessFailure,
    WorkerProcess,
    exact_trial_tag,
    symmetric_arm_order,
)
from dual_cache_harness.real_preflight import MarkerRecorder, RealPreflightRunner
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
        self.assertIsNotNone(observation.sigkill_monotonic_ns)
        self.assertIsNotNone(observation.waitpid_monotonic_ns)
        self.assertIsNotNone(observation.foreground_request_monotonic_ns)
        self.assertLessEqual(
            observation.sigkill_monotonic_ns or 0,
            observation.waitpid_monotonic_ns or 0,
        )
        self.assertLessEqual(
            observation.waitpid_monotonic_ns or 0,
            observation.foreground_request_monotonic_ns or 0,
        )
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

    async def test_prepare_ready_marker_keeps_exact_fake_generation(self) -> None:
        worker = WorkerProcess(
            FAKE_COMMAND,
            role="speculative",
            expected_identity=self.identity,
            environment=self.environment,
        )
        await worker.launch()
        original = worker.generation
        try:
            ready = await worker.prepare()
            self.assertEqual(ready["generation"], original.token)
            self.assertEqual(ready["pid"], original.pid)
            self.assertEqual(ready["stage"], "normal")
            self.assertEqual(ready["trial_id"], "")
            self.assertGreaterEqual(
                ready["model_ready_monotonic_ns"],
                ready["prepare_started_monotonic_ns"],
            )
            self.assertEqual(await worker.probe_idle(), original)
        finally:
            await worker.shutdown()

    async def test_prepare_started_is_causal_before_delayed_ready(self) -> None:
        worker = WorkerProcess(
            FAKE_COMMAND,
            role="speculative",
            expected_identity=self.identity,
            environment=self.environment,
        )
        await worker.launch()
        try:
            request_id, started = await worker.begin_prepare_for_trial(
                trial_id="causal-prepare",
                fake_prepare_ms=100,
            )
            self.assertEqual(started["stage"], "normal")
            self.assertEqual(started["trial_tag"], exact_trial_tag("causal-prepare"))
            self.assertIsNone(worker.process.returncode if worker.process else None)
            ready = await worker.finish_prepare_for_trial(request_id, timeout=1)
            self.assertGreaterEqual(
                ready["model_ready_monotonic_ns"],
                started["prepare_started_monotonic_ns"],
            )
        finally:
            await worker.shutdown()

    async def test_late_prepare_response_poisons_generation_until_exact_reap(self) -> None:
        worker = WorkerProcess(
            FAKE_COMMAND,
            role="speculative",
            expected_identity=self.identity,
            environment=self.environment,
        )
        await worker.launch()
        request_id, _ = await worker.begin_prepare_for_trial(
            trial_id="late-ready",
            fake_prepare_ms=1_000,
        )
        try:
            with self.assertRaises(HarnessFailure):
                await worker.finish_prepare_for_trial(request_id, timeout=0.001)
            with self.assertRaisesRegex(HarnessFailure, "transport-poisoned"):
                await worker.probe_idle()
        finally:
            await worker.kill_and_reap()

    async def test_waitpid_timeout_retains_exact_process_handle(self) -> None:
        class NeverReapedProcess:
            returncode = None
            stdin = None
            killed = False

            def kill(self) -> None:
                self.killed = True

            async def wait(self) -> int:
                await asyncio.sleep(60)
                return -9

        worker = WorkerProcess(
            FAKE_COMMAND,
            role="speculative",
            expected_identity=self.identity,
        )
        fake_process = NeverReapedProcess()
        generation = ExactProcessGeneration(token="timeout-generation", pid=4242)
        worker.process = fake_process  # type: ignore[assignment]
        worker.generation = generation
        with self.assertRaisesRegex(HarnessFailure, "did not reap"):
            await worker.kill_and_reap(timeout=0.001)
        self.assertIs(worker.process, fake_process)
        self.assertEqual(worker.generation, generation)
        self.assertTrue(fake_process.killed)
        worker.process = None
        worker.generation = None

    async def test_next_session_stop_kills_replacement_during_prepare_before_f(self) -> None:
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
        pcm = fake_pcm()
        baseline = await runner.run_baseline(
            pcm=pcm,
            trial_id="prepare-baseline",
            capture_storage_id=str(uuid.uuid4()),
        )
        try:
            interrupted = await runner.run_stop_during_prepare(
                pcm=pcm,
                trial_id="prepare-interrupted",
                capture_storage_id=str(uuid.uuid4()),
                stop_after_ms=10,
                fake_prepare_ms=60_000,
            )
        finally:
            await foreground.shutdown()
        baseline.result.assert_exact_parity(interrupted.result)
        self.assertEqual(interrupted.ordinary_final_invocations, 1)
        self.assertEqual(interrupted.prepare_stage, "normal")
        self.assertFalse(interrupted.native_coreml_active_proven)
        self.assertLessEqual(interrupted.kill_to_reap_ns, 250_000_000)
        self.assertLessEqual(
            interrupted.waitpid_monotonic_ns,
            interrupted.foreground_request_monotonic_ns,
        )
        with self.assertRaises(ProcessLookupError):
            os.kill(interrupted.speculative_pid, 0)

    async def test_real_preflight_runner_baseline_directly_requests_and_returns(self) -> None:
        foreground = WorkerProcess(
            FAKE_COMMAND,
            role="foreground",
            expected_identity=self.identity,
            environment=self.environment,
        )
        await foreground.launch()
        sampler = BoundedResourceSampler(interval_seconds=0.010, limit_bytes=1 << 50)
        sampler.track("foreground", foreground)
        await sampler.start()
        with tempfile.TemporaryDirectory() as directory:
            markers = MarkerRecorder(Path(directory) / "markers.jsonl")
            runner = RealPreflightRunner(
                foreground=foreground,
                worker_command=FAKE_COMMAND,
                expected_identity=self.identity,
                environment=self.environment,
                markers=markers,
                resources=sampler,
            )
            try:
                result = await runner.baseline(
                    pcm=fake_pcm(),
                    trial_id="direct-real-baseline",
                    storage_id=str(uuid.uuid4()),
                    offset_ms=25,
                )
                self.assertEqual(result.observation.arm, "baseline")
                self.assertGreater(result.observation.stop_to_result_ns, 0)
                self.assertEqual(result.observation.ordinary_final_invocations, 1)
                self.assertEqual(result.observation.adopted_cache_count, 0)
                self.assertTrue(
                    any(
                        '"event":"foreground_request"' in line
                        for line in markers.path.read_text().splitlines()
                    )
                )
            finally:
                markers.close()
                await sampler.stop()
                sampler.retire("foreground", foreground)
                await foreground.shutdown()

    async def test_high_rate_resource_sampler_keeps_exact_pid_series(self) -> None:
        foreground = WorkerProcess(
            FAKE_COMMAND,
            role="foreground",
            expected_identity=self.identity,
            environment=self.environment,
        )
        speculative = WorkerProcess(
            FAKE_COMMAND,
            role="speculative",
            expected_identity=self.identity,
            environment=self.environment,
        )
        await foreground.launch()
        await speculative.launch()
        sampler = BoundedResourceSampler(interval_seconds=0.005, limit_bytes=1 << 50)
        sampler.track("foreground", foreground)
        sampler.track("speculative", speculative)
        await sampler.start()
        try:
            await asyncio.sleep(0.030)
            sampler.checkpoint("prediction_started")
            sampler.checkpoint("pre_kill")
            self.assertGreaterEqual(len(sampler.samples), 4)
            self.assertGreater(sampler.peak_combined_resident_bytes, 0)
            expected_pids = {foreground.pid, speculative.pid}
            for sample in sampler.samples:
                self.assertEqual({item.pid for item in sample.processes}, expected_pids)
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "resources.jsonl"
                sampler.write_jsonl(output)
                self.assertEqual(len(output.read_text().splitlines()), len(sampler.samples))
        finally:
            await sampler.stop()
            sampler.retire("speculative", speculative)
            sampler.retire("foreground", foreground)
            await speculative.shutdown()
            await foreground.shutdown()

    async def test_resource_sampler_fails_closed_if_live_tracked_pid_disappears(self) -> None:
        foreground = WorkerProcess(
            FAKE_COMMAND,
            role="foreground",
            expected_identity=self.identity,
            environment=self.environment,
        )
        speculative = WorkerProcess(
            FAKE_COMMAND,
            role="speculative",
            expected_identity=self.identity,
            environment=self.environment,
        )
        await foreground.launch()
        await speculative.launch()
        sampler = BoundedResourceSampler(interval_seconds=0.005, limit_bytes=1 << 50)
        sampler.track("foreground", foreground)
        sampler.track("speculative", speculative)
        await sampler.start()
        try:
            await speculative.kill_and_reap()
            await asyncio.sleep(0.020)
            with self.assertRaisesRegex(HarnessFailure, "resource sampler failed closed"):
                await sampler.stop()
        finally:
            sampler.retire_if_tracked("speculative", speculative)
            sampler.retire_if_tracked("foreground", foreground)
            if foreground.process is not None:
                await foreground.shutdown()

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
            "identity_coreml_kind",
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
