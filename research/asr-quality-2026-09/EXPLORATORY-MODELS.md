# Additional development screens

These fixed configurations extend the original comparisons. They do not
change the already frozen Parakeet/Turbo/Breeze/GigaAM-CTC configuration or
choose settings from its held-out results. Revisions and screens were declared
before inference; both original development screens are now complete. Both use the same v2 CLI, baseline text
binary and one decoder thread, without language hints or new public APIs.

| Variant | Immutable weights revision | SHA256 | Screen |
|---|---|---|---|
| primeLine Q8 | `7c63545b352e5d410ccc1ea1eb49aa751e65780b` | `dbd1ec2985aea64d16550a0068ea9153c0bc01955bf2a5c18b74ca213546d3cd` | Same 100 RU + 100 EN development inputs; German fine-tune, CC BY 4.0 |
| GigaAM E2E RNN-T Q8 | `b9b68a835993df09018237a11d2a9b8c1925844d` | `78d63b47723b7f8d78c6113a6ef983b5a86e2a86f6c273e1f5cb6967b1c4467a` | Same 100 RU development inputs; alternative head, RU-only, MIT |

The weights are from `handy-computer/parakeet-primeline-gguf` and
`handy-computer/gigaam-v3-e2e-rnnt-gguf`. Their intended-use and architecture
contracts are pinned to transcribe.cpp 0.2.3. The first tests whether an
otherwise compatible fine-tune preserves the target languages; the second
tests the accuracy/speed trade-off between CTC and RNN-T in the RU specialist.
Do not run an unsupported English test and label its failures general RU
quality. Reuse exact baseline outputs where manifest and execution identities
match. Any extension past development must be declared before its inference;
an exploratory screen alone cannot authorize a model replacement.

Completed [primeLine results](primeline-dev/REPORT.md) are EN/RU WER 9.48/8.17%,
versus shipping Parakeet 7.95/4.90%; paired regression intervals exclude zero.
[RNN-T results](giga-rnnt-dev/REPORT.md) tie CTC at 3.27% on 100 RU examples,
with file p95 81 versus 62 ms. Baseline recognition was reused where exact
manifest and execution identities matched.

A further fixed 15-RU technical development screen was declared separately
before its inference (plan SHA256
`29e86acfab73909413b9e244e086c99bcaf4d2c13240d3fc5b86dfa61779a7fe`).
It reuses the original Parakeet/CTC outcomes on those exact source fixtures.
[App WER](giga-rnnt-synthetic-dev/REPORT.md) is 11.39% RNN-T, 13.50% CTC and
10.55% Parakeet. Five script groups give wide intervals; this is not a confirmed
held-out improvement or a claim about larger RNN-T sets. No new model setting
was selected from held-out results.
