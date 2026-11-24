Fixed and committed as `c2a2c62` on `work`. The clipboard pattern was undefined. Its scan failed in a subprocess, and the parent treated empty output as a clean scan. Scanner errors now fail the gate.

The new CI regression test reproduces the false pass on the original gate. The fixed gate rejects `pasteboard.clearContents()` with its file and line, rejects unauthorized `URLSession` use, accepts the host-only clipboard call, and fails on missing sources.

The checkout’s source gate and all 490 DictationCore package tests passed. The full preflight and shipping-runtime audit require dependencies unavailable offline.
