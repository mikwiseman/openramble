# Additional offline EN/mixed long-file diagnostics

Two further original fictional scripts were rendered continuously once by
installed macOS voices at rate 165: English by Samantha (1098.8209375 seconds,
18m18.8s), mixed RU/EN by Milena (1352.315 seconds, 22m32.3s). No loops or
padding extend them. These are separate from the primary Eleven v4 voices
and aligned 4/5/8/15-minute variants. The English passages spoken by a Russian
system voice have a pronunciation confound. Intended scripts are not
independent spoken gold; there is no reference word alignment.

Frozen plan SHA256:
`0ceabe1f3cf6b99e91abe58c0c91bf58db452dad5264a86fd7c8cabb04c830e8`.
Manifest SHA256:
`2e3ad6bae034cad3063479c004a8d2f4e08973a5824606ef352df2fbc1ef365d`.
All immutable audio, script and PCM hashes are retained locally. Parakeet,
Turbo and Breeze run serially with unchanged v2, original model hashes,
one/four/four threads, one load/warm-up per model series and baseline Rust
text binary. The RU diagnostic is an earlier separate manifest; none of its
inference is repeated. Do not pool different languages into a selection score
or estimate confidence from one parent per language.

| Parakeet input | File wall time | Raw/app WER | Raw/app CER |
|---|---:|---:|---:|
| EN | 23.418 s | 1.11% / 1.11% | 0.59% / 0.59% |
| Mixed | 29.037 s | 17.21% / 17.21% | 10.04% / 10.04% |

These are one-pass file timings, not repeated idle or GUI Stop-to-insertion
gates. Process peak is 927.8 MiB across both Parakeet inputs. Turbo and Breeze
each fail both files with unsupported-token-timestamp code 12. All model
processes exit normally; file failures remain in quality denominators. Their
rapid failure times are not successful performance results.

## Limited critical audit and observed loss

The [whole-file audit](critical-audit.json) reproduces primary raw/app S/D/I.
English has 31 substitutions, two deletions and two insertions over 3165
words. Its longest consecutive deletion is one word; first/last ten words
and all 38 `not`/`never`/`no` markers match.

Mixed has 267 substitutions, 223 deletions and 41 insertions over 3086 words.
The longest consecutive deletion contains 37 reference words. Three of 62
negative markers do not match: two are deleted and one is substituted.
The first ten words match; the last ten do not. Raw/app scores and these
audits are unchanged by the text pipeline. All reported intervals stay in
bounds with nondecreasing starts, and no app command is emitted. Valid
timestamps do not prove completeness or semantic safety.

## Post-error crop diagnostic

A separate experiment selected 100.8–119.44 seconds after observing the
largest omission, around decoder neighbors ending at 102.8s and starting
at 117.44s. The crop preserves the identical float PCM, lasts 18.64 seconds
and uses the short direct path. Its plan was frozen before inference:
`ad0367ce41a4537989b722121cfebba2c825b59ee987963b1f59608f59441025`.
The same v2/model/thread/text settings run serially, once per model.

All three models recover the missing English clause, including the value
twelve/12 degrees Celsius. See [aggregate crop evidence](crop-diagnostic.json).
Only that declared numeral-format equivalence is used for this clause audit;
primary WER normalization is unchanged. The crop is selected from an observed
error, has no independent spoken/word-boundary reference, and contributes no
quality example, confidence interval or accepted latency result.

Source absence alone cannot explain a clause that every decoder recovers
from the same PCM. This does not yet separate language decoding, segmentation
and joining causes. Short-crop Parakeet still mistranscribes the following
Russian fragment. No broad dictionary replacement repairs these omissions.
The exposed context sensitivity motivates a separately frozen development
window experiment, with independent validation required before promotion.

See [full aggregates](REPORT.md) and [producer identities](comparison.json).
Individual transcripts and audio stay outside Git.
