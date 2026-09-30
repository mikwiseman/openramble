# Critical synthetic cases

These checks compare decoder/app outputs with the intended fictional scripts.
The provider's alignment text matches those scripts; it is not an independent
human verification of the generated speech. Three voices of a text are related
observations. The primary WER keeps digit/word and alphabet differences.

The grouped synthetic holdout has 36 recordings, with all outcomes retained
for Parakeet, Turbo and Breeze. All 108 outcomes completed without failure.

| Held-out check | Reviewed model/voice outcomes | Observation |
|---|---:|---|
| RU and EN number scenarios | 18 | 208, 63, 4500, RU 09:20 and EN October 26 retained; formatting differs |
| RU and EN negation scenarios | 18 | Negations and value 9 retained |
| Mixed identifiers | 9 | Values 315 and 3 and the prohibition retained; `issue` is often misspelled/transliterated |
| Mixed release | 9 | Both Russian negations retained; `pod` may become Cyrillic or a different token |
| Trailing command scenario | 9 | The prohibition and final sentence retained; no accidental submit/Return |
| RU ordinary-word controls | 9 | `в центре` and `комету` retained as ordinary Russian |

No `app_command` was emitted in the 216 combined development/holdout outcomes.
This is limited coverage, not a guarantee that arbitrary numbers or prohibitions
will survive. Primary scores include formatting differences rather than hiding
them behind a numeral rewrite. For example, the 208/63/4500 number script can
be lexically far from a correct spelled-out transcript.

Mixed-language development exposes a material limitation. Parakeet rendered
the Russian prohibition preceding English text in Latin script for all three
voices; the English-native voice's output no longer contains a readable Russian
negation. In another development recording, Turbo with that voice omitted the
Russian clause containing value 12. The two Russian-native voices also show
transliteration errors across models. Do not describe these as a passed general
mixed-language gate or repair missing meaning with a broad dictionary alias.

The frozen exact `pull реквест` alias changes two development Parakeet outputs.
It changes none of the 2000 main outputs, none of the 36 synthetic holdout
outputs and none of the 1422 FLEURS Parakeet outputs. The ordinary-word controls
remain unchanged. There is no demonstrated held-out gain yet; shipping text
behavior remains unchanged. Long independently scripted technical narration
will provide another diagnostic once generation credits reset.

The main Golos aggregate also has substantial numeral-format sensitivity. A
source-only exploratory lexical split is retained in
[numeric-strata.json](main/numeric-strata.json), with its complete vocabulary.
It is not a semantic parser or a filter of model failures. Even the 398 Crowd
references with no listed numeral lexemes score 3.85% / 14.34% / 29.56% WER
for Parakeet / Turbo / Breeze; the equivalent 490 Farfield references score
7.23% / 19.32% / 37.77%. The overall model ranking is therefore not explained
solely by spelling numbers differently. These exploratory strata do not
replace the preregistered 500-example sets or their paired intervals.

GigaAM CTC's 15 held-out RU outputs also retain the reviewed values
208/63/4500/09:20, all four prohibitions, the six fictional names and the
ordinary Russian controls. Technical terms account for substantial errors.
Its additional Crowd lexical split still scores 9.18% WER on the same 398
references without listed numeral lexemes, versus Parakeet 3.85%; the 490
Farfield counterparts score 6.16% versus 7.23%. Formatting and domain effects
must be reported together, without claiming that every lexical difference
changes a numeric value.

The separate 15-RU RNN-T development screen retains reviewed values
42/17/12900/September 15 and the prohibitions/value 7. It improves a few
technical outputs relative to CTC, but the English-native voice still writes
ordinary Russian `центре` in Latin script as `Centre`. No broad correction
of that ordinary word is justified. Its small development improvement is
not a held-out semantic guarantee.
