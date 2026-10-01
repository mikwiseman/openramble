# Configuration frozen before held-out recognition

The study keeps the shipping Parakeet configuration as its baseline. Turbo and
Breeze have already failed the main-set quality and speed replacement gates;
the held-out pass still measures both with the predeclared four-thread decoder.
No settings are chosen from FLEURS or synthetic holdout results.

The additional Russian-only candidate is GigaAM v3 E2E CTC Q8_0, revision
`ab38ecc31dbd25264cf96e07dd4dbcf744151618`, one decoder thread, SHA256
`9ccce4750dc813a493d96ca15ee251712bedec15ac9a02fa3d2bd732f08ae5eb`.
It uses the existing adapter and automatic current pipeline without a prompt,
language hint or language router. It is not an English-capable replacement.
Its 100-recording RU development screen gave 3.27% WER versus Parakeet's 4.90%,
with a paired difference of −1.63 pp, 95% interval [−3.26, −0.28] pp. Larger RU
datasets and RU synthetic cases will test that signal with the same settings.

The sole text candidate appends the exact alias `pull реквест` → `pull request`
to the existing starter dictionary. Inflection and phonetic matching are off
for this entry, and it adds no acoustic boost. The development replay changed
two RU outputs, improved app WER by 0.84 pp, and changed none of the 2000 main
outputs. No broad correction of ordinary Russian phrases such as `в центре`
or `комету` is proposed. This is a research example; shipping text behavior is
unchanged pending the held-out replay and false-replacement checks.

All new model passes use the same release CLI, SHA256
`3164e3cbe7d7ad346d0e8900d9ef9131544405f09f574a63eb21c8d54badec96`,
and shipping text-core binary, SHA256
`a37f0f721b48530f576d70cb5334b8247ea0aabd571b069aca5ce551e9828a2a`.
The v2 CLI reports native error codes and reads inputs through local file
handles. Its recognition configuration is unchanged. Earlier screening runs
retain their original binary and source identities.

FLEURS remains the full 775 RU + 647 EN set, manifest SHA256
`4d3a11141dba3254814b8c6e628e1a1e97b6727493eb0757def4a4d6abddf711`.
The synthetic holdout is all 36 reserved recordings, SHA256
`298bf6ee87d4bcf2ea2ba07bc8613283f9e82a90ee12309e3940a09b67239adf`.
All three voices of a held-out text stay in the same source group. GigaAM's
RU subset has the same source audio and references; English and mixed cases
are outside its declared support. Subset comparisons must reuse the existing
baseline outputs and verify source identities rather than infer them again.

The operational coordinator holds an exclusive ASR lane lock and refuses to
start while the app or another ASR CLI is running. Results are fsynced as each
example completes; retained process failures require review rather than a
silent automatic rerun. Resume permits an unrelated documentation commit only
when every source hash, binary, model, manifest, setting and host identity is
unchanged, and preserves the original inference's commit provenance.
