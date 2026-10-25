# OpenRamble

OpenRamble is a free, open-source, local dictation app for Mac. Hold a key, speak and let go, and your words appear as text at the cursor in any app.

OpenRamble's speech-to-text runs offline with Parakeet Ultra, a model built on NVIDIA Parakeet TDT 0.6B v3, so your voice and text never leave your Mac. OpenRamble removes filler words such as "um" and "uh" without rewording you. It also records meetings and your screen and transcribes the audio locally. The code is MIT licensed, and there is no account and no subscription.

**[Download OpenRamble for Mac](https://github.com/mikwiseman/openramble/releases/latest)**

OpenRamble is free and needs macOS 14 or later on an Apple Silicon Mac. Support for Intel Macs is experimental. Each build is signed with an Apple Developer ID and notarized by Apple.

## How it works

1. Hold Right Command.
2. Speak.
3. Let go. OpenRamble turns your speech into text on your Mac and pastes it at your cursor.

Double-press the key to dictate hands-free, and press it once more to finish. One dictation, from pressing the key until you let go or finish, is called a take. Press Escape to cancel a take.

## Install

1. Download the DMG from the [latest release](https://github.com/mikwiseman/openramble/releases/latest) and drag OpenRamble to Applications.
2. Open OpenRamble. It offers to download the speech model, which is about 490 MB, and it starts the download only when you click. It then asks for Microphone and Accessibility access.

OpenRamble is in public beta. It installs an update only after you click.

## What OpenRamble does

### Dictation in any app

OpenRamble's voice typing works in any app that accepts text, from Mail, Slack and browsers to Cursor, VS Code and the terminal.

- **Hold to talk (push-to-talk).** The default key is Right Command, and you can choose Fn, Right Option, Right Control, Left Command, Left Option or Left Control instead.
- **Hands-free.** Double-press the key to dictate without holding it. In Settings, you can also let hands-free dictation finish when you stop talking.
- **Long dictation.** You can dictate for longer than five minutes, and OpenRamble starts transcribing while you are still speaking.
- **Personal dictionary.** Tell OpenRamble how a word sounds and how to write it. A built-in list already covers common technical terms. You can also import and export your dictionary as a file.
- **Your clipboard comes back.** Once the text has been read, usually a quarter of a second after the paste, OpenRamble puts back what was on your clipboard, images included. If no app reads the text within three seconds, OpenRamble puts your clipboard back, tells you the text was not inserted and keeps it for Insert Last Dictation. Dictated text is marked so that it stays off Universal Clipboard and out of clipboard managers that respect the standard privacy markers.
- **History.** Replay, copy or delete recent dictations, or recognize one again. If a paste fails, choose Insert Last Dictation from the OpenRamble menu in the menu bar.
- **VoiceOver.** With VoiceOver on, OpenRamble plays a short tone when the microphone opens instead of a spoken announcement, so VoiceOver's speech does not end up in your dictation.

### Clean Verbatim removes filler words without rewording you

Clean Verbatim removes filler words such as "uh" and "um", short stutters such as "the the", restarts such as "a, uh, a", and anything you take back with "scratch that". It only deletes words, and it never rewords, reorders or adds one, so OpenRamble never paraphrases you unless you ask. Clean Verbatim is a set of written rules, not an AI model.

| You say | OpenRamble types |
|---|---|
| Um, so the deploy failed, uh, scratch that, the deploy passed. | The deploy passed. |
| Uh, I need you to um, fix the login bug, um, and then update the readme. | I need you to fix the login bug and then update the readme. |
| It's a, uh, a leak. | It's a leak. |
| Мы, э, думаем, что, ээ, надо подождать. | Мы думаем, что надо подождать. |
| Um 5 Uhr treffen wir uns im Büro. | Um 5 Uhr treffen wir uns im Büro. |

The second row is what Parakeet wrote when a Mac voice read the sentence aloud.

- If a word might be one you meant, it stays. In the last row, the German "um" means "at", so OpenRamble keeps it.
- If a take was only a correction, OpenRamble pastes nothing and tells you so. The take stays in History.
- Meeting transcripts drop filler words but keep "scratch that" and one-word replies, because in a meeting those are things a person said.

Clean Verbatim was scored blind on 160 examples that were set aside while it was built. AI models wrote the examples and, for each one, the version a careful editor would produce by deleting words only. Two AI judges checked each example, and only the examples they both agreed on were kept. Clean Verbatim's output matched the editor's version exactly for 86.9% of the examples, and 0 of the 160 examples lost a real word. [PR #73](https://github.com/mikwiseman/openramble/pull/73) describes the method.

Clean Verbatim removes filler words in English, Russian, German and French, and stutters in English and Russian. "Scratch that" works in English.

### Dictation for Claude Code and the terminal

OpenRamble pastes into Claude Code, Codex, Cursor and any terminal the same way it pastes into any other app. Its cleanup and other text fixes, including dictionary matches by sound, leave text in backticks, file paths and code identifiers alone. A dictionary entry that matches a word exactly applies there too. The `openramble` command-line tool and the `openramble-transcribe` skill let an agent transcribe audio files, as [described below](#transcribe-audio-files-from-the-command-line).

OpenRamble also checks which app you are dictating into, and it decides from that whether to add line breaks or press Return.

- **Terminals and code editors get one line.** Terminal, iTerm2, Warp, Ghostty, Cursor, VS Code, Xcode and apps OpenRamble does not know never get a line break you did not ask for, because a line break in a terminal can run a command.
- **"Send it." presses Return in a terminal.** End a take with "Send it." as its own sentence, and OpenRamble presses Return after the text, so you can send a prompt to Claude Code or Codex without pressing Return yourself. If you say "send it" in the middle of a sentence, it stays as text. OpenRamble never presses Return outside a terminal.
- **Writing apps get paragraphs.** In Mail, Notes, Slack, browsers and document editors, say "New paragraph." to start a new paragraph, or pause for about a second and a half after a sentence.

### Voice commands

OpenRamble acts on the spoken commands below.

| Say | What happens | Where it works |
|---|---|---|
| "new line", "новая строка" or "с новой строки" at the end of a take | Ends the text with a line break | Any app |
| "New paragraph." or "Новый абзац." | Starts a new paragraph | Mail, Notes, Slack, browsers and document editors |
| "Send it.", "Press enter.", "Отправь." or "Энтер." as the last sentence | Presses Return after the text | Terminal apps only |
| "Scratch that", right after the words you want to remove | Removes the sentence or phrase you said just before it | Dictation in any app, in English |

### Meeting recorder

- OpenRamble records your microphone and what your Mac plays. It transcribes both on your Mac while you record and labels them You and Others.
- Press Control-Command-R (⌃⌘R) in any app to start or stop a recording, and you can change the shortcut. You can also start, pause, resume and stop a recording from the menu bar.
- You can rename a recording, copy the transcript, or export a Markdown transcript or an M4A audio file.
- OpenRamble does not tell the other people in a call that you are recording. In many places recording a conversation without everyone's consent is illegal, so asking them is your responsibility.

### Screen recording

Choose Record Screen to record your screen, optionally with your microphone, your Mac's audio and a camera bubble that you can move and resize while you talk. OpenRamble saves an MP4 video next to the audio and the transcript on your Mac. OpenRamble does not upload the video, make a share link or store it in the cloud. To put a copy somewhere else, choose Save Video.

### Transcribe audio files from the command line

The `openramble` command-line tool comes inside the app. To install it, open Settings → Setup → Install command-line tool, which creates a link at `~/.local/bin/openramble` without administrator rights. If your shell cannot find `openramble`, add `~/.local/bin` to your PATH.

```bash
openramble interview.m4a > transcript.txt
openramble interview.m4a --format srt > subtitles.srt
openramble *.m4a --format json --output-dir transcripts
openramble --check-model
```

- It writes plain text, JSON with word timestamps, SRT subtitles or VTT subtitles.
- It uses the model the app installed and downloads nothing, and the app can stay closed.
- With `--output-dir`, it never overwrites a file, and only you can read what it writes.
- Dictation in the app comes first, so the tool pauses while you dictate and then continues.
- Its output is the model's text, without the app's dictionary or cleanup.

Run `openramble --help` for every option.

**Claude Code and Codex.** The skill in [`skills/openramble-transcribe`](skills/openramble-transcribe/SKILL.md) lets an agent transcribe a local audio file with OpenRamble. Copy or link the folder to `~/.claude/skills/openramble-transcribe` for Claude Code or `~/.agents/skills/openramble-transcribe` for Codex, and then ask the agent to use `openramble-transcribe`.

## Privacy

Your voice and text never leave your Mac. OpenRamble turns speech into text on your Mac without the network, so dictation works offline once the model is installed. OpenRamble has no account, no analytics, no telemetry, no crash reporting service and no cloud sync, and it never writes dictated text, words or keystrokes to its logs.

"Learn from your edits" is off by default. When you turn it on, OpenRamble reads the text field it pasted into 8 seconds and 25 seconds after the paste, so that it can learn a word you corrected. It reads no other field.

### When OpenRamble uses the network

The Mac app connects to the internet only to download the speech model and to check for and download updates.

| Action | When | Goes to | What the service can see |
|---|---|---|---|
| Download the speech model | When you start a download | GitHub Releases, with Hugging Face as a fallback | Your IP address and the download request |
| Check for updates | About once a day, unless you turn it off in Settings → About | GitHub Pages | Your IP address and the app version |
| Download an update | Only after you click | GitHub Releases | Your IP address and the download request |

The update check sends no report about your Mac, its system version or its language. OpenRamble downloads fixed versions of the model files and checks each file against its SHA-256 checksum before it installs the model. The early Windows and Linux version connects to the internet only to download the speech model when you start the download. The Linux transcription server in `apps/cli` accepts connections from your own applications and makes none.

You can verify the network limits yourself. On every pull request and every push to main, an automated check runs [`scripts/check-network-surface.sh`](scripts/check-network-surface.sh). The check fails the build if any app code uses a network API outside the model download code, the update code and one file that opens local recordings for playback. With a model installed, the first script below runs recognition with the network blocked. The second script records every network call and fails if recognition makes one.

```bash
./scripts/test-zero-network.sh
./scripts/test-zero-network-trace.sh
```

### What OpenRamble keeps on your Mac

OpenRamble stores audio and text from your dictations and recordings only on your Mac, in `~/Library/Application Support/OpenRamble`:

- **Dictation history.** OpenRamble keeps your recent dictations with their audio, so you can replay, copy or delete them. It keeps the last 5 by default, and you can change that to 10, 20 or 50 in Settings → Dictation History → Keep. When a new dictation pushes an old one past the limit, OpenRamble deletes the old one's text and audio. A dictation you star with "Keep this one" does not count toward the limit and stays until you delete it. Each dictation also notes the kind of app it went to, such as mail, chat or terminal, never the app's name, so recognizing it again shapes the text the same way. You can also delete one dictation or all of them at any time. OpenRamble also keeps a take in which it recognized no words, so you can play it or recognize it again. Such takes never push out a dictation, because they have their own limit of the same number. A take that heard only silence is not kept.
- **Recordings.** OpenRamble keeps each meeting or screen recording with its audio, its transcript and any screen video. The audio takes about 230 MB per hour while you record, and about 43 MB per hour after OpenRamble compresses it once the transcript is done. A recording stays until you delete it, and deleting it moves it to the Trash. Your Mac's backups include your recordings but skip the folders that hold temporary dictation audio.

| Other local data | How long it stays |
|---|---|
| Speech model | Until you delete it in Settings |
| Audio saved after a technical failure, so a take is not lost | Up to 10 WAV files, for at most 7 days and about 1 GB |
| Technical journal, with no speech or text in it | On by default, for 7 days and at most 5 MB, and cleared when you turn it off |
| Settings and dictionary | Until you change or delete them |
| The copy of text that could not be pasted, kept for Insert Last Dictation | In memory only, until a later dictation is pasted, you delete its History entry, or you quit. Dictation history keeps its own copy. |

To report a problem, choose Settings → About → Save Error Report. OpenRamble saves a ZIP file on your Mac, and you decide whether to send it to the developer. The file holds technical events, timings, error codes, the app and macOS versions, the app's architecture (arm64 or x86_64), and up to five recent Apple crash reports rebuilt without your file paths or device identifiers. It never holds audio, transcripts or clipboard contents, and OpenRamble does not upload it. [docs/diagnostics.md](docs/diagnostics.md) lists exactly what it contains.

### The Linux transcription server

`openramble serve` in [`apps/cli`](apps/cli) is a separate program you run on your own Linux server so your other applications can turn audio into text. Unlike the Mac app, it receives audio over the network. Your applications send each file to it, and a reverse proxy on the same machine provides HTTPS. It accepts connections on one local port and opens none. It writes each upload and its decoded audio only to temporary files that have no name on disk, and the system frees them when the request ends, even if the server crashes. It keeps no audio, no transcripts and no history. Its log records the caller's key label, lengths, timings and status codes, never text, words, key terms or file names. The automated network check allows exactly one file, `apps/cli/src/listen.rs`, to accept connections, and the systemd service blocks every address outside the machine, for the server and for the ffmpeg decoder it runs.

## How OpenRamble compares

The table lists facts from each app's own website or repository, checked on 20 October 2026. Prices and features change, so check the linked pages before you decide.

| App | Where speech becomes text | Price | Open source | Platforms |
|---|---|---|---|---|
| OpenRamble | On your Mac, with no cloud option | Free | Yes, MIT | Mac, plus an early Windows and Linux version ([see FAQ](#does-openramble-work-on-windows-or-linux)) |
| [macOS Dictation](https://support.apple.com/guide/mac-help/mh40584/mac) | On the Mac for general text where supported. Keyboard settings show whether it stays on the Mac. | Free, built in | No | Apple devices |
| [Wispr Flow](https://wisprflow.ai/data-controls) | In the cloud | Subscription, with 2,000 free words a week on desktop | No | Mac, Windows, iOS, Android |
| [Superwhisper](https://superwhisper.com) | On the device or in the cloud, depending on the model | Free tier, then a subscription or a lifetime license | No | Mac, Windows, iOS, Android |
| [MacWhisper](https://macwhisper.com) | On the Mac, with optional cloud models | Free, or a one-time Pro license | No | Mac |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | On the Mac | One-time license, or free if you build it from source | Yes, GPL-3.0 | Mac with Apple Silicon, iOS |
| [Handy](https://github.com/cjpais/Handy) | On the computer | Free | Yes, MIT | Mac, Windows, Linux |
| [Aqua Voice](https://aquavoice.com/pricing) | Not stated. Aqua uses its own Avalon model, and its site describes no local mode. | Subscription, with 1,000 free words | No | Mac, Windows, iOS, Android |

OpenRamble does not rewrite your text with an AI model, and it has no voice commands for editing selected text. Some apps in the table can rewrite your text with an AI model if you turn that on, such as VoiceInk's Cloud Enhancement and Handy's post-processing.

## Accuracy and speed

All numbers below come from one MacBook Pro with an M4 Pro chip and 24 GB of memory on macOS 27.0.1. They use recorded read speech, not live dictation, so they describe recognition and not the time until text appears in an app. The method, the data and every raw output are in [the model comparison](research/model-upgrade-2026-10/README.md), [the scorecard baseline](research/scorecard/BASELINE.md) and [the October 2026 product benchmark](research/product-benchmark-2026-10/README.md).

Word error rate (WER) is the share of words that are wrong, missing or added compared with a human transcript, so lower is better. FLEURS is a public speech dataset from Google. The hour rows join public recordings with short pauses between them, so they are not natural meetings.

| Test | Parakeet v3, the previous model | Parakeet Ultra, the current model |
|---|---|---|
| WER on all 1,422 English and Russian FLEURS test recordings | 5.51% | 4.85% |
| Words invented on 11 recordings of silence and noise | 0 | 0 |
| English clips that came out in Cyrillic letters, out of 199 clips of one speaker | 20 | 0 |
| WER on one hour of English | 9.76% | 7.27% |
| Spoken words missing from that hour | 4.80% | 2.71% |
| WER on one hour that alternates Russian and English | 39.04% | 37.99% |

- Each hour row comes from a single run. On the alternating hour, Ultra's 8-bit file scored 39.79%, so the two models are about the same there. Both drop about a third of the words in that hour.
- The 199 clips were made to reproduce a known problem, so they show that Ultra fixed it on those clips, not how often it happens in daily use.
- On a sample of 100 English and 100 Russian FLEURS recordings, whisper.cpp with Whisper Large v3 Turbo had a WER of 5.10% in English and 5.15% in Russian, against 5.57% and 5.95% for Parakeet v3. On the same sample, Parakeet Ultra's 8-bit file scored 5.05% in English and 5.37% in Russian, so Whisper Turbo still made fewer errors on Russian read sentences.
- With the model loaded, four recordings shorter than 15 seconds were each recognized ten times, and half of those 40 runs took 75 ms or less and 95% took 125 ms or less. The time does not include recording or pasting. The times come from Ultra's 8-bit file, and the 4-bit file that the Mac downloads stayed within 3% of the 8-bit file's 95% figure.
- Transcribing one hour of English took 46.5 seconds in one run. Loading the model took 0.19 seconds when macOS already had the model file in memory. The recognition process peaked at 842 MB of memory.

## FAQ

### Is OpenRamble free and open source?

Yes. OpenRamble is free, and its source code is under the MIT License. There is no account, no subscription and no paid tier. The OpenRamble name, icon and marks are not covered by the license, and third-party components keep their own licenses.

### Does OpenRamble work offline? Does anything leave my Mac?

Yes, OpenRamble works offline once the model is installed, because it turns speech into text on your Mac without the network. Your voice and text never leave your Mac. The app goes online only to download the model, to check for updates and to download an update you click to install. [The privacy section](#when-openramble-uses-the-network) lists what each connection sends.

### How is OpenRamble different from Handy?

Both are free and MIT licensed, and OpenRamble runs on transcribe.cpp, the speech engine that CJ Pais and the Handy team make. Handy runs on Windows, macOS and Linux and lets you choose Whisper or Parakeet models. OpenRamble is a native Mac app with one Parakeet model. The Mac app also has "scratch that" to remove what you just said, a spoken "Send it." that presses Return in a terminal only on the takes where you say it, a meeting and screen recorder, and a command-line tool that writes SRT, VTT and JSON. If Handy works well for you, keep using it.

### Why not use the built-in macOS dictation?

You can, and it is free. OpenRamble adds a personal dictionary, a history you can replay, removal of filler words, and "Send it." for terminals. It also records meetings and screens and transcribes audio files from the command line.

### Is OpenRamble a free alternative to Wispr Flow or Superwhisper?

Yes. OpenRamble is a free, open-source dictation app for Mac, and it recognizes speech only on your Mac. Wispr Flow says on [its data controls page](https://wisprflow.ai/data-controls) that its transcription always happens in the cloud. Superwhisper offers local and cloud models, with a free tier and paid plans. OpenRamble does not rewrite your text with an AI model, so if you want that, look at the AI rewriting features of the apps in [the comparison](#how-openramble-compares).

### Does OpenRamble use Whisper or Parakeet?

OpenRamble uses Parakeet Ultra, a version of NVIDIA's Parakeet TDT 0.6B v3 that Moondream trained further, and transcribe.cpp runs it on your Mac. It does not use Whisper. In [OpenRamble's tests](research/scorecard/BASELINE.md), Parakeet invented no words on recordings of silence and noise, where Whisper Large v3 Turbo invented 19. On 200 short read sentences, Whisper Turbo made fewer errors than Parakeet v3, and compared with [Parakeet Ultra's 8-bit file](research/model-upgrade-2026-10/README.md) it made fewer errors in Russian and slightly more in English.

### Which languages does OpenRamble support?

OpenRamble recognizes 25 European languages, one language at a time, including English, Russian, German, French, Spanish, Italian, Polish and Ukrainian. It does not support Chinese, Japanese or Korean, and [Languages](#languages) has the full list.

### Which Macs does OpenRamble run on? Does it work on Intel?

OpenRamble needs macOS 14 or later and runs on every Apple Silicon Mac, M1 included, where it recognizes speech on the GPU. Support for Intel Macs is experimental. On an Intel Mac, OpenRamble recognizes speech on the processor. The Intel version has been tested only under Rosetta on an Apple Silicon Mac, never on an actual Intel Mac.

### Does OpenRamble remove filler words like "um" and "uh"? Will it rewrite what I said?

Yes. OpenRamble's Clean Verbatim removes filler words such as "uh" and "um", short stutters such as "the the", and whatever you take back with "scratch that". It only deletes words and never rewords, reorders or adds one, so OpenRamble never paraphrases you unless you ask. If a word might be one you meant, such as "um" in German, it stays.

### Can I dictate into Claude Code, Cursor or the terminal? Can OpenRamble press Enter?

Yes. OpenRamble pastes into any app, and its cleanup leaves text in backticks, file paths and code identifiers alone. Terminals and code editors such as Cursor never get a line break you did not ask for. In a terminal app such as Terminal, iTerm2, Warp or Ghostty, end a take with "Send it." as its own sentence, and OpenRamble presses Return (Enter) for you. The terminal panel inside a code editor does not get a Return.

### Can OpenRamble record and transcribe meetings? Does it tell the other people?

Yes. OpenRamble records your microphone and what your Mac plays, and it transcribes both on your Mac while you record. It labels the two sides You and Others. It does not tell the other people, and in many places recording without everyone's consent is illegal, so asking them is your responsibility.

### Can OpenRamble transcribe audio files or make subtitles?

Yes. The `openramble` command-line tool comes with the app and writes plain text, JSON with word timestamps, SRT or VTT. For example, `openramble interview.m4a --format srt > interview.srt` writes a subtitle file. The tool uses the model the app already installed and downloads nothing.

### How accurate and how fast is OpenRamble?

On all 1,422 English and Russian FLEURS test recordings of read speech, OpenRamble's model, Parakeet Ultra, had a word error rate of 4.85%. On a sample of 200 of those recordings, Whisper Large v3 Turbo made fewer errors than Parakeet v3, the model OpenRamble used before, and about as many as Parakeet Ultra's 8-bit file. Once the model is loaded, recognizing four recordings under 15 seconds, ten times each, took a median of 75 ms on an M4 Pro MacBook Pro, measured with Ultra's 8-bit file. The 75 ms covers the speech model alone, without recording or pasting, so it is not the time until text appears. [Accuracy and speed](#accuracy-and-speed) and [the scorecard](research/scorecard/README.md) have the method and the limits.

### What does OpenRamble store, and for how long?

OpenRamble keeps your last 5 dictations with their audio so you can replay or copy them. You can raise the limit to 10, 20 or 50, or delete dictations at any time. Recordings stay until you delete them, and both are stored on your Mac in `~/Library/Application Support/OpenRamble`.

### What permissions does OpenRamble need? Does it log my keystrokes?

OpenRamble needs Microphone access to hear you and Accessibility access to notice the dictation key and paste the text. It compares each key press only with the dictation key, Escape and the shortcuts you set in Settings, such as Control-Command-R for recording, and it does not record, store or send any other key. Input Monitoring is not needed.

### Does OpenRamble work on Windows or Linux?

An early Windows and Linux version is in [`apps/desktop`](apps/desktop), and its latest installers are in the [desktop-v0.21.2 release](https://github.com/mikwiseman/openramble/releases/tag/desktop-v0.21.2) from August 2026. It needs Windows 10 or later on x86_64, or Linux with X11 or Wayland. It recognizes speech on the processor, and it has no meeting or screen recorder and no automatic updates. Its only network use is the model download you start.

## Requirements

- macOS 14 or later. Recording what your Mac plays needs macOS 14.2 or later. On 14.0 and 14.1, recordings capture only your microphone.
- A Mac with Apple Silicon, where recognition runs on the GPU. Support for Intel Macs is experimental. On an Intel Mac, recognition runs on the processor. The Intel version has been tested only under Rosetta on an Apple Silicon Mac.
- About 490 MB of disk space for the speech model, plus temporary space while it downloads.
- If you used Parakeet v3 before, Settings offers the upgrade to Parakeet Ultra, and nothing downloads until you click. Both models stay on disk, about 1.2 GB together, until Ultra has been verified and loaded. OpenRamble then deletes v3.
- In OpenRamble's tests, the recognition process used at most 842 MB of memory with the model loaded. The model stays loaded until an hour passes with no dictation or recording, and nothing unloads it earlier, memory pressure included. The next dictation reloads it while you speak, and recording starts at once either way.
- Permissions:
  - Microphone, to hear you.
  - Accessibility, to notice the dictation key and paste the text.
  - System Audio Recording, only when a meeting or screen recording includes what your Mac plays, so that the other people in a call are recorded too. OpenRamble asks for it the first time you record, and dictation works without it.
  - Screen Recording, only when you record your screen.
  - Camera, only for the camera bubble.

## Languages

OpenRamble recognizes 25 European languages:

Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish and Ukrainian.

There is no language setting, because the model detects the language by itself. The model writes one language at a time, so when a take mixes languages, many words of the other language are dropped. In the measured hour that alternates Russian and English, about a third of the words were missing. Chinese, Japanese, Korean and languages outside the list are not supported. OpenRamble has measured accuracy only in English and Russian. [Moondream's model card](https://huggingface.co/moondream/parakeet-ultra) reports accuracy for all 25 languages.

### Interface language

The interface is in English or Russian. It follows your Mac, so it is in Russian when Russian comes before English in your preferred languages and in English otherwise. You can change it in Settings → General → Interface language. The interface language does not change speech recognition.

## Build from source

You need Xcode with the Swift 6 toolchain, rustup and CMake. The repository pins Rust 1.97.1 in `rust-toolchain.toml`, and XcodeGen is downloaded at a pinned version and checked by SHA-256.

```bash
git clone https://github.com/mikwiseman/openramble.git
cd openramble

swift test --package-path Packages/DictationCore
swift test --package-path Packages/LocalASR

./scripts/build-ffi.sh
"$(./scripts/pinned-xcodegen.sh)" generate --spec apps/macos/project.yml
xcodebuild -project apps/macos/OpenRamble.xcodeproj -scheme OpenRamble \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Run `./scripts/check.sh` before you commit, because it runs every test and check. `./scripts/build-dmg.sh` builds a development DMG. Development builds are named OpenRambleDev and use the bundle identifier `is.waiwai.dictation.dev`, so they do not touch the permissions of the released app.

- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Manual verification](docs/manual-check.md)
- [Release process](docs/release.md)
- [Benchmark methodology](docs/benchmarks.md)
- [Model lifecycle](docs/model-lifecycle.md)

## Credits and licenses

- Speech recognition runs on [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) 0.4.0 by CJ Pais and the [Handy](https://handy.computer) team, under the MIT License. It includes ggml, miniz and code translated from Silero VAD, all under the MIT License.
- The speech model is [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) by Moondream, a version of NVIDIA's [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) trained further. Both are licensed CC BY 4.0. OpenRamble uses handy-computer's [GGUF conversion](https://huggingface.co/handy-computer/parakeet-ultra-gguf), quantized to Q4_K_M for the Mac. Windows and Linux builds made from this version use Q8_0.
- Macs that have not upgraded yet, and the desktop-v0.21.2 release for Windows and Linux, use NVIDIA's Parakeet TDT 0.6B v3 in handy-computer's [GGUF conversion](https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf), quantized to Q8_0.
- Updates come through [Sparkle](https://sparkle-project.org), under the MIT License.
- The benchmarks use Google's [FLEURS](https://huggingface.co/datasets/google/fleurs) dataset, licensed CC BY 4.0.

Third-party notices are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

OpenRamble's source code is under the [MIT License](LICENSE), © 2026 Mik Wiseman. The OpenRamble name, icon and marks are not covered by that license, as [NOTICE](NOTICE) explains.
