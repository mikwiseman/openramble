# Additional development screens

These fixed configurations extend the original comparisons. They do not
change the already frozen Parakeet/Turbo/Breeze/GigaAM-CTC configuration or
choose settings from its held-out results. Neither has run inference yet at
the point this document is written. Both use the same v2 CLI, baseline text
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
