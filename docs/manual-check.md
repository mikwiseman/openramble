# Manual application verification

Use an installed, notarized build for these checks. Automated tests cover the
logic; this list covers macOS permissions and interaction with other apps.

Record each row as pass, fail, blocked, or not applicable; never infer a pass
from an automated test. Restore every system setting and clipboard value changed
for the check.

1. Launch OpenRamble from Finder and confirm the three-step onboarding window
   appears, fits without clipping, and can be completed using only the keyboard.
2. Grant Microphone and Accessibility access. Confirm the state refreshes after
   returning from System Settings and the app never requests Input Monitoring.
3. Download the model, cancel and resume once, then restart the app. Confirm
   it remains ready and recognition still works with Wi-Fi off.
4. Check onboarding, every Settings tab, the menu, permission errors, model
   progress/errors, an empty/populated dictionary, and the recovery menu in
   light and dark appearances at the smallest supported display scale. Repeat
   at 200%/the largest macOS Text Size and confirm content remains reachable
   without clipped labels or controls.
5. Repeat the transient HUD check with Reduce Motion, Reduce Transparency, and
   Increase Contrast enabled. Confirm recording is identifiable without color
   and no text is exposed in the HUD or screen sharing. With VoiceOver on,
   confirm the microphone opening is a tone, not words; nothing is spoken while
   it is open; "Transcribing…" is spoken only when it lasts longer than half a
   second; and an error that ends a take, such as unplugging the microphone, is
   spoken once, after the microphone closes. Start the next take while a notice
   is still showing and confirm it still gets its tone. Click through the
   visible HUD into the app below; it must never intercept the click. Let an
   identical warning auto-hide twice and confirm VoiceOver announces both
   impressions.
6. Dictate short, long, Russian, English, mixed-language, punctuation, technical
   vocabulary, silence, and immediate-release samples into TextEdit, Safari, and
   a code editor using hold-to-talk. Confirm the compact HUD disappears as soon
   as insertion starts; a successful paste must not leave a banner behind. In
   the dictionary form, confirm Return submits a populated pair and does not add
   an empty or half-filled replacement.
7. Double-press the hotkey to start hands-free recording, then press once to
   stop. Confirm Escape and a conflicting shortcut cancel without inserting text.
   Hold the hotkey and press C right away (a shortcut such as ⌘C): nothing is
   inserted. In an empty TextEdit document, hold it, speak for a second or
   two, press Down Arrow, keep talking and release: the whole take is
   inserted, including the words after the key. The key is not swallowed:
   under Right Command it reaches the app as ⌘↓, which an empty document has
   nowhere to act on, and in any other field a late chord (⌘A, ⌘↓) acts
   before the paste lands.
   Set the input volume to zero and hold the key for 2 s: the orange panel
   names the microphone and History gains nothing. Restore the volume, hold
   the key and tap the desk once without speaking: the panel says the
   recording is in History, and History shows "Nothing recognized" with Play,
   the ↻ button ("Recognize this recording again") and Delete, and no Copy.
8. Switch focus during transcription and verify insertion returns to the field
   where dictation began. Cover rich text, a multiline field, an empty field, a
   secure field, and a destination that rejects paste.
   With two displays, repeat while the keyboard focus and pointer are on different
   screens; verify insertion still targets the original field and the HUD stays
   visible without stealing focus.
   Open a Spotlight or Raycast panel over a terminal, end a take with
   "Send it.", and confirm both the text and Return reach the panel, never the
   terminal behind it. With the Dvorak and Turkish F layouts selected, confirm
   a dictation pastes rather than typing ⌘K or copying.
   Dictate with no text field focused (Finder's desktop) and confirm the
   words appear on the panel within three seconds, in full, with "No text
   field. Click one, then tap Right ⌘." and the previous clipboard is back.
   Click into a text field and tap the dictation key: the words land and the
   panel says "Pasted into …" once. Repeat, and hold the key instead: a new
   take starts and the waiting words are in History. Repeat, and choose Later:
   the panel says "Kept in History. ⌃⌘V pastes it.", and ⌃⌘V pastes it.
   With Terminal's Secure Keyboard Entry on, dictate into Terminal and into
   another app: the words paste as usual, and ⌃⌘V pastes the last take. Still
   protected, dictate with no text field focused: the panel names Terminal, a
   tap copies, your own ⌘V pastes, and the panel does not appear in a
   screenshot while it shows the words. Turn Secure Keyboard Entry off while
   the words wait: the key's label changes from copies to pastes.
9. Confirm clipboard text, rich content, files, and multiple items are restored
   after insertion and do not appear on another device through Universal
   Clipboard. Verify password-manager values, lazy file promises, and content
   above 16 MiB use the safe Copy/Retry recovery instead.
10. Force capture, transcription, insertion, and kill/relaunch failures. Verify
    uninserted recognized text waits on the panel and leads the menu as the
    last take; retained voice is
    disclosed once and appears as `Recovered Recordings (N)…`, which opens the
    exact Finder folder for Preview/Delete. Verify the count, explicit Finder
    deletion, seven-day/count/size expiry, and bounded-background removal of
    ordinary successful audio. The app must not transcribe retained voice in the
    background. Inject a delete-intent storage failure and confirm automatic
    recovery fails closed: ambiguous WAVs remain byte-for-byte untouched and
    the idle menu persistently offers `Recording Support Files — Recovery
    Disabled…` rather than importing or deleting them.
11. Enable correction learning, correct an inserted term in the same field, and
    verify the learned replacement. Disable the setting and confirm the field is
    no longer re-read. Add and delete a personal replacement using keyboard and
    VoiceOver, then confirm it survives relaunch.
12. Trigger Check for Updates and verify that Sparkle offers the latest English
    release from `https://mikwiseman.github.io/openramble/appcast.xml`. Turn
    automatic checks off and confirm scheduled network access stops.
13. Press Record for the first time on a build that has never asked. Confirm the
    intro sheet appears once, that macOS then shows OpenRamble's own System Audio
    Recording prompt with the string from `project.yml`, and that recording
    starts whichever button is pressed. Confirm the sheet never appears again.
14. Record a meeting on built-in speakers with something playing. Confirm the
    other side is transcribed as Others, that the same words do not also appear
    as You, and that the headphone line is shown. Repeat on headphones and
    confirm both sides are attributed with nothing suppressed.
15. Record with the output on AirPods or AirPlay, the case where a tap returns
    silence. Confirm the orange strip, the menu-bar badge, the flat Others meter,
    and the VoiceOver announcement after a minute; the recording must continue
    and file as degraded rather than stop.
15b. Join a Zoom, Meet, Teams or FaceTime call, then start a recording. Confirm
    the You meter moves when you speak and that the finished file has your voice
    on the left. If another app has exclusive microphone access, confirm the
    orange strip says your microphone isn't being captured, the menu line says
    "not your microphone", and the filed recording carries that note — rather
    than a healthy-looking file of only the other side.
16. Deny System Audio Recording, then grant it in System Settings while the app
    runs. Confirm the app says a relaunch is needed rather than claiming to
    capture, and that it captures after relaunching. On macOS 14.0 or 14.1
    confirm the app says system audio needs 14.2 and records the microphone.
17. Record for ninety minutes. Confirm memory stays flat, disk grows at about
    230 MB an hour, the transcript keeps up or says how far behind it is, and
    that dictating mid-recording wins the engine without stopping the recording.
18. Save a transcript and an audio file from a finished recording. Confirm the
    names come from the recording's title, that the m4a plays in QuickTime with
    you on the left and the other side on the right, that a degraded recording
    says so inside the Markdown, and that cancelling a long export leaves no
    file behind. There is no Share — copy and save are the ways a recording
    leaves the app.
19. Force-quit during a recording. Confirm the next launch repairs the file,
    publishes it as recovered, plays it, and transcribes the untranscribed tail.
    Repeat with Command-Q and confirm the dialog and a sealed, playable file.
20. Hebrew. On a Mac without a Hebrew keyboard, confirm Settings → Setup shows
    the Hebrew row under More languages and first-run setup shows nothing about
    Hebrew. Download it, cancel and resume once, and confirm dictation in
    another language keeps working meanwhile. Confirm the row then reads
    "Hebrew is downloaded", says to add the Hebrew keyboard, and that Keyboard
    Settings… opens the Keyboard pane of System Settings. Add the Hebrew
    keyboard there and confirm the row changes to "Hebrew is ready" without a
    relaunch. With the model installed, run `openramble <a Hebrew file>
    --hebrew` and confirm Hebrew text.
21. Importing a file. Drop an M4A on the Library window: the window dims and
    says "Drop to transcribe", the file appears as a recording under its own
    name and plays at once, and its words arrive with a progress line. No
    paragraph is labelled You. Click the import button and choose an MP4 and
    an Ogg voice note together: the first is shown and transcribed, the
    second says "Waiting its turn." Dictate while a long file is being
    transcribed: the dictation lands as fast as usual and the file's line
    says it is paused. Start a recording during an import: both carry on.
    Quit during an import and relaunch: the transcript is finished without
    asking. Drop a PDF: a notice names the file and nothing is added. Move an
    import to the Trash while it is being transcribed: it stops. With the
    Hebrew model installed, an import asks which language the file is in,
    with the keyboard's language first, and a Hebrew file comes out in Hebrew
    while the keyboard is English. Without it, nothing is asked.
22. The menu and the shortcuts. Dictate four different sentences and open the
    menu: the three newest are its first rows, as their own words, the newest
    first with ⌃⌘V in the shortcut column. Click the second: it is pasted into
    the app in front. Hold Option with the menu open: each of the three reads
    Copy, and clicking one copies it. Delete one of them in the Library and
    confirm it leaves the menu. Library…, Settings… and Quit OpenRamble show
    no shortcut, and ⌘, and ⌘Q still work with the Library window in front.
    In Xcode or a browser, press ⌃⌘R: a recording starts and the app in front
    does nothing. Press ⌃⇧⌘R: the recording stops. Press ⌃⇧⌘R again: the
    Library opens on the screen recording choices, and Return starts. With
    Terminal's Secure Keyboard Entry on, confirm ⌃⌘R still starts and stops a
    recording. In Settings → General, set Record screen to the chord Record
    uses and confirm it is refused by name; clear it and confirm the menu row
    shows no shortcut. With the keyboard on Hebrew, dictate a Hebrew sentence
    and confirm Hebrew text lands right to left; switch to an English keyboard
    and confirm the next take is English. Switch keyboards during a take and
    during a recording and confirm neither changes language halfway. Remove
    Hebrew and confirm it asks first and that other dictation still works.
    Remove the Hebrew keyboard afterwards.

Do not attach recordings or dictated text to bug reports. Record only the app
version, macOS version, hardware, step number, and observed behavior.
