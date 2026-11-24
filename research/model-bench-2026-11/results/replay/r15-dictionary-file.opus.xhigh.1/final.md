The dictionary file format, reading and merge are built in DictationCore with the interface you gave. All DictationCore tests pass, with CI's warnings-as-errors build. It is committed on `work` as 7baee95, not pushed. The app is untouched.

**What it does**
- **The file:** `{"openRambleDictionary": 1, "replacements": [{"spoken": "...", "written": "..."}]}`. The `openRambleDictionary` key is both the version and the only sign that a JSON file is a dictionary.
- **Export:** no ids. A setting is written only when it differs from the default, so a plain pair is just its two fields. The output is indented, Cyrillic and slashes stay unescaped, and keys are sorted, so two exports of the same dictionary are identical byte for byte.
- **Import:** a file with only pairs imports with every setting at its default. Both sides are trimmed (spaces, tabs, newlines), and phrases with an empty side are dropped.
- **Refusals:**
  - Any JSON without the marker is "not a dictionary file". That includes a bare list of pairs and the app's own storage format.
  - A newer version is refused with its number, before its contents are read.
  - Unreadable bytes, and our own file with a broken shape, are reported as damaged with the place to fix, for example "Phrase 2 has no “written”."
- **Error messages:** the errors come with plain wording the Settings screen can show, such as "This dictionary was saved by a newer version of OpenRamble (format 2). Update OpenRamble to import it."
- **Merge:** a phrase you already have is updated where it stands and keeps its id. New phrases go after yours in the file's order. The counts compare the end result with the start, so importing your own export reports 0 added and 0 updated.

**Decisions I made**
- **A file broken in one phrase is refused whole.** Importing only the readable part would lose the rest without saying which phrase to fix.
- **The file states the whole phrase.** When a file updates one of your phrases, a setting it leaves out goes back to its default; it does not keep yours. Reading returns complete phrases, so there is nothing to tell "left out" from "set to default".
- **You keep your own spelling of the spoken side.** If the file differs from yours only in capitals there, it counts as no change. A difference in capitals on the written side ("Github" to "GitHub") does count.
- **A phrase repeated in the file lands once, and its last entry wins.** If your phrase changes and then goes back to how it was, it is not counted.
- **Duplicates you already have:** only the first matching phrase is updated.
- **Unknown fields inside a phrase**, such as an old `id`, are ignored.

**Not verified:** the LocalASR tests did not run, because they would need to download FluidAudio and the work was offline. My change only adds files to DictationCore and LocalASR uses nothing new from it. The network check passed.

When the Settings buttons land, the README's privacy table will need a line saying the dictionary can be exported to a file the person chooses.

Files:
- /Users/mikwiseman/.openramble/model-bench/work/r15-dictionary-file/run-opus/Packages/DictationCore/Sources/DictationCore/DictionaryTransfer.swift
- /Users/mikwiseman/.openramble/model-bench/work/r15-dictionary-file/run-opus/Packages/DictationCore/Tests/DictationCoreTests/DictionaryTransferTests.swift
