from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path

from dual_cache_harness.controller import HarnessFailure
from dual_cache_harness.real_preflight import (
    SystemMemorySnapshot,
    parse_exact_swapusage,
    parse_memory_pressure_free_percent,
    parse_memory_pressure_level,
    validate_system_memory_gate,
    write_system_memory_report,
)


def snapshot(*, swap: int, level: int) -> SystemMemorySnapshot:
    return SystemMemorySnapshot(
        captured_monotonic_ns=1,
        swapusage_raw=f"total = 2.00G used = {swap}.00K free = 1.00G (encrypted)",
        swap_total_bytes=2 * 1024**3,
        swap_available_bytes=2 * 1024**3 - swap * 1024,
        swap_used_bytes=swap * 1024,
        swap_page_size_bytes=16 * 1024,
        swap_encrypted=True,
        memory_pressure_query_raw=(
            "The system has 100 pages.\nSystem-wide memory free percentage: 37%"
        ),
        memory_free_percent=37,
        pressure_level_raw=str(level),
        pressure_level=level,
    )


class SystemMemoryGateTests(unittest.TestCase):
    def test_parses_exact_binary_xsw_usage(self) -> None:
        raw = struct.pack(
            "<QQQIB3s",
            2 * 1024**3,
            512 * 1024**2,
            1536 * 1024**2,
            16 * 1024,
            1,
            b"\0\0\0",
        )
        swap = parse_exact_swapusage(raw)
        self.assertEqual(swap.total_bytes, 2 * 1024**3)
        self.assertEqual(swap.available_bytes, 512 * 1024**2)
        self.assertEqual(swap.used_bytes, 1536 * 1024**2)
        self.assertEqual(swap.page_size_bytes, 16 * 1024)
        self.assertTrue(swap.encrypted)
        self.assertEqual(
            parse_memory_pressure_free_percent(
                "The system has 1048576 pages.\n"
                "System-wide memory free percentage: 33%"
            ),
            33,
        )
        self.assertEqual(parse_memory_pressure_level("1\n"), 1)

    def test_rejects_malformed_resource_outputs(self) -> None:
        for parser, raw in (
            (parse_memory_pressure_free_percent, "free maybe 30"),
            (parse_memory_pressure_level, "normal"),
        ):
            with self.subTest(parser=parser.__name__):
                with self.assertRaises(HarnessFailure):
                    parser(raw)

    def test_rejects_xsw_usage_wrong_size_and_invariants(self) -> None:
        valid = (
            1024**3,
            256 * 1024**2,
            768 * 1024**2,
            16 * 1024,
            1,
            b"\0\0\0",
        )
        malformed = (
            struct.pack("<QQQIB3s", *valid)[:-1],
            struct.pack("<QQQIB3s", *valid[:-3], 12_000, 1, b"\0\0\0"),
            struct.pack("<QQQIB3s", 1024, 512, 2048, 4096, 1, b"\0\0\0"),
            struct.pack("<QQQIB3s", 4096, 1024, 2048, 4096, 1, b"\0\0\0"),
            struct.pack("<QQQIB3s", *valid[:-2], 2, b"\0\0\0"),
            struct.pack("<QQQIB3s", *valid[:-1], b"\0\1\0"),
        )
        for raw in malformed:
            with self.subTest(raw=raw.hex()):
                with self.assertRaises(HarnessFailure):
                    parse_exact_swapusage(raw)

    def test_requires_normal_pre_and_post_and_zero_swap_growth(self) -> None:
        validate_system_memory_gate(snapshot(swap=100, level=1))
        validate_system_memory_gate(
            snapshot(swap=100, level=1), snapshot(swap=99, level=1)
        )
        with self.assertRaisesRegex(HarnessFailure, "not normal"):
            validate_system_memory_gate(snapshot(swap=100, level=2))
        with self.assertRaisesRegex(HarnessFailure, "swap grew"):
            validate_system_memory_gate(
                snapshot(swap=100, level=1), snapshot(swap=101, level=1)
            )

    def test_raw_outputs_are_preserved_in_report(self) -> None:
        pre = snapshot(swap=100, level=1)
        post = snapshot(swap=100, level=1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "memory.json"
            write_system_memory_report(path, pre=pre, post=post, error=None)
            raw = path.read_text()
        self.assertIn(pre.swapusage_raw, raw)
        self.assertIn(pre.memory_pressure_query_raw.replace("\n", "\\n"), raw)
        self.assertIn('"swap_delta_bytes": 0', raw)


if __name__ == "__main__":
    unittest.main()
