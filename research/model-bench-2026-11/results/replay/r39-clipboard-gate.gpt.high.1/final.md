Fixed and committed as `ca03bcc`. The clipboard pattern was undefined. The scan crashed in a subprocess, and the gate treated the empty output as a pass. Clipboard scan errors now stop preflight.

The regression test proved that `clearContents()` reports its file and line and exits 1. A host-only write exits 0, and a missing source directory exits 1.

All 89 DictationCore tests passed. The LocalASR and app checks and the binary audit require artifacts absent from this offline checkout.
