# Sona

Sona listens on your Mac and writes down what it hears:

- **Live transcript**: what's being said, word by word, with who is speaking.
- **This Mac's audio too**, if you turn it on: a video, a call, anything the Mac plays, as its own track labelled Mac audio.
- **Hold to dictate**: hold fn (or your own shortcut) in any app, talk, let go, and the words are pasted where you're typing.
- **Always-on notes**, if you want them: every conversation becomes a markdown note with who said what, in a folder you own.
- **For your AI**: Claude, Cursor, Codex or any MCP client can read the notes, the live transcript and the conversation still going on, if you let it.

Everything runs on your Mac: no account, no cloud, no API keys, no analytics. The only network use is downloading the speech models once and, if you allow it, checking for updates.

Sona is open source (MIT), for Apple Silicon Macs, in English only. A companion iPhone and Apple Watch app is in [`ios/`](ios/README.md).

## Speed and weight

| | Measured on an M2 MacBook Air (16 GB) |
| --- | --- |
| Word spoken → on screen | about 0.25 s (median) |
| Dictation key released → text pasted | about 0.24 s (median), and never before the last word is in. 2% word error on test speech, quiet speech and a video playing too (the live words alone: 6%) |
| Always on, window closed, quiet room | about 1.6% CPU and 85 MB of memory (the CPU figure leaves out the Neural Engine) |
| This Mac's audio on, nothing playing | no extra cost: no tap runs |
| This Mac's audio on, an app holding a silent output (a call app, a browser after a video) | the tap closes after 45 s of silence, then only looks for a second every 15 s |
| A video playing, room and Mac's audio both heard | about the same CPU as the mic alone hearing it, and about 8 MB more |
| The app | about 18 MB |
| Speech models, downloaded once | about 1.4 GB: 960 MB for the live transcript and dictation, first; 465 MB more for notes, only if always-on is on |
| A conversation → its note | about 70x real time |

## Install

If [Releases](../../releases) has a DMG, download it, open it and drag Sona to Applications. Releases are signed and notarized. Sona keeps itself up to date with [Sparkle](https://sparkle-project.org): on its second launch it asks whether to check for updates automatically, and Sona > Check for Updates... checks any time.

Otherwise build it (needs Xcode 26):

```sh
git clone https://github.com/dinilb/sona.git && cd sona
make install   # builds, puts Sona in /Applications and starts it
```

A build without your own Developer ID certificate is signed ad hoc, so macOS asks for the microphone and Accessibility again after every build (see Build and test).

It runs on Apple Silicon Macs with macOS 14 or later, and is tested on macOS 27.


## First run

One screen says what Sona does and asks how it should listen:

- **Always on**: the mic stays on and each conversation becomes a note.
- **Only while I hold the key**: the mic stays off until you hold the dictation key, and only the text you dictate is kept.

Then it asks for two permissions and downloads the models:

- **Microphone**, to hear anything at all.
- **Accessibility**, to notice the dictation key in any app and paste. Without it, everything but dictation still works.

A last, optional line: also hear what this Mac plays (see below). It's off unless you tick it.

You can change all of these later in System Settings > Privacy & Security, and always-on in Sona's settings.

## This Mac's audio

Settings > Hear this Mac's audio too (off by default; macOS 14.2 or later):

- What the Mac plays (a YouTube video, a call's other side, a podcast) is transcribed as its own track, labelled **Mac audio** (or Mac audio 1, Mac audio 2 when it has several voices), never as someone in the room. The room keeps Speaker 1, Speaker 2. In the note and in Now they're merged by time; each word in the note's `.json` has `"track": "mac"` when it came from the Mac.
- It's heard through a Core Audio process tap of everything the Mac plays except Sona: no virtual audio driver, no admin rights. It only runs while something plays; with nothing playing there's no tap and no cost.
- Some apps hold their output open while playing nothing (Zoom, Discord, a browser after a video). After 45 s of silence the tap closes, though Mac audio stays on, and it opens again when another app starts playing, one of those starts again, or at a one-second look every 15 s that hears something (someone talking on a call that had gone quiet: up to 15 s of it can be missed).
- Switching outputs (AirPods to the speakers) or the output's sample rate builds the tap again for it, so the audio never plays at the wrong speed, and a tap whose audio stops for 2 s while apps play is opened again.
- macOS asks for **System Audio Recording** (Privacy & Security > Screen & System Audio Recording) when you turn it on. Without it, the Mac's audio is silence and everything else works as before; Settings says so if nothing comes through.
- **When it plays through the speakers**, the mic hears it too. Those words are taken out of the room's track: a run of 3 or more mic words that twin the Mac's within about 2 s, a long word that's exactly the Mac's within half a second, or any twin where the mic's loudness followed the Mac's. They stay in the `.json` with `"echo": true` and are never shown. Someone in the room talking over a video, or repeating what it said a moment later, stays. No echo cancellation runs on the mic (Apple's voice processing turned videos down and didn't take out other apps' audio).
- A note that's only Mac audio (a video with nobody talking) is marked `media: true` as before. A call doesn't count.
- The two tracks share the live speech model, taking turns: while both talk at once, one side's live words can come a few seconds late. What the Mac's track saved up while you dictated goes in a second at a time, so the next dictation never waits behind all of it. The note is transcribed again from both tracks in full.

## Dictation

- Hold the key and talk. The live words show in a slim one-line pill at the bottom of the screen, above the Dock, as you speak (the latest words, scrolling left as the line fills). Let go, and what you said is transcribed once more, whole, by the notes model (it hears the sentence at once, so it's more accurate, quiet speech too), then pasted where your cursor is. Your clipboard is put back 3 s later (if the words are still on it), and clipboard managers are told to skip the words. A password copied from a password manager is never put back: the clipboard is left empty instead.
- It never pastes half a sentence: it waits until every word up to the release is in, plus 0.15 s of sound after the key in case the last word runs past it (none when it was already quiet as you let go). That's usually a quarter of a second or less; if it takes longer, the dot turns into a small spinner. After 8 s it pastes what it has and says "Cut short".
- It starts from the moment the key goes down, not when the app got round to it. Words said a moment before the press count if they run straight into the dictation; anything before a pause doesn't, and a full stop or comma left over from what you said before never starts one.
- If the mic isn't on yet when you press (always-on is off, or it's reopening after sleep), the pill says "Mic starting..." until it is, so you know when to talk.
- While you dictate it has the live speech model to itself: this Mac's audio waits and catches up after.
- The shortcut is fn unless you change it (Settings > Shortcut > change, then press it): modifiers held alone (Right ⌘, ⌃⌥, Caps Lock) or with one key (⇪ A, ⌃⌥ Space). One modifier alone keeps its side, so Right ⌘ isn't left ⌘; anything else takes either side. A key on its own (or with only ⇧) isn't allowed, except F1 to F20. So Sona can sit beside Wispr Flow, which uses fn.
- While it's fn, pressing fn/🌐 does nothing else (no emoji picker); your old fn setting comes back when you change the shortcut, turn dictation off or quit. fn only works on Apple keyboards.
- With Caps Lock in the shortcut, Caps Lock is remapped to F18 while Sona runs, so it's held instead of turning caps on (other key remaps stay). It goes back when you change the shortcut, turn dictation off or quit, and on the next launch after a crash.
- The key of a modifiers-plus-key shortcut is swallowed while it's down, so nothing gets typed; modifiers always reach other apps. Under secure input (a password field, Terminal's Secure Keyboard Entry) macOS hides key presses from other apps, so only shortcuts of modifiers alone (not Caps Lock) work there.
- Another key during the hold (fn+arrow, ⌘C, ⌘Tab) or another modifier means it wasn't dictation, and nothing is pasted. Sleep or locking the screen cancels too. A hold stops at 2 minutes and pastes what it has.
- Two dictations in a row don't run together. Before pasting, Sona asks the focused field through Accessibility what's just before the caret: a space goes in front unless that's a space, a new line, an opening bracket or a quote (or the field is empty). Apps that hide their text (many Electron apps, some terminals) can't say, so there a paste into the same app within 2 minutes of the last one gets the space. The words are pasted as said, never re-cased.
- If no text box is selected (a button, a list or the desktop has focus), nothing is pasted: the words stay on the clipboard and the pill turns into a small "Copied to clipboard" for 3 s, so a dictation is never lost. If Accessibility can't tell (many Electron apps), it pastes anyway and doesn't put the old clipboard back, so the words are still there if the paste went nowhere. Then the words are only handed to the clipboard when an app reads them: if no app has within 0.6 s, the paste went nowhere, and the pill says "Copied to clipboard" too.
- Password fields aren't typed into: the words go to the clipboard instead (the pill says so), marked as a password so clipboard history skips them, and are cleared after a minute. The paste uses the V key of your keyboard layout (AZERTY, Dvorak).
- If a paste lands in the wrong place, the menu bar's Copy Last Dictation has it (kept in memory only, gone on quit). Save Last Dictation for Debugging writes its audio and what happened to it to `Debug/` in the support folder, only when you click it.
- Without the notes model (always-on off, so it isn't downloaded), the live words are pasted. Its own copy of the model costs about 30 MB of memory, and loads in a fraction of a second once the notes have compiled it.
- The log gets one line per dictation (how long it was held, whether the mic was on, how long the text took, how many words, and what happened), never the words.

## Always on, or only while you hold the key

- **Always on**: the mic is on all day, and macOS shows its mic indicator. Three minutes of quiet ends a conversation, which then becomes a note. Pause from the menu bar for an hour or until tomorrow morning.
- **Only while you hold the key** (always-on off in Settings): the mic opens when you hold the dictation key and closes 30 seconds after your last dictation, so the next one starts at once. No audio and no notes are kept; what you dictate is listed by day in `Dictations/` in the notes folder. The notes models aren't even downloaded.

## The menu bar and the window

- The menu bar icon (the logo, a lily pad) is always there and shows the state: listening, hearing someone (a ring round it), paused, a problem (with the reason in its menu), loading, not set up (an outline), or off (dimmed: always-on is off).
- Its menu: what it's doing, Open Sona, Pause for 1 hour or until tomorrow (or Resume), Delete the last 5, 15 or 60 minutes, Copy Last Dictation and Save Last Dictation for Debugging (after a dictation), Quit. Quit asks first, so a stray ⌘Q doesn't end a day of listening.
- The window's sidebar has **Now** (the live transcript), then days: today, yesterday and the rest of the week by name, older days under their month (the newest month open, older ones closed; a click opens or closes one, and that's remembered), and Settings. A day lists its conversations (times, title, speakers, length); one shows its lines with speakers, a link back to its day, and Copy, Show in Finder and Delete (to the Trash).
- Closing the window never quits. The Dock icon only shows while the window is open.
- Settings: always-on, dictation and its key, AI access, the microphone, speaker labels, this Mac's audio, open at login, the notes folder, and words it should know. The microphone is Automatic by default: the Mac's input, but never a Bluetooth one (that switches AirPods to call quality) unless you pick it.

## Delete the last few minutes

From the menu bar or Now: delete the last 5, 15 or 60 minutes. After one confirmation everything heard in that time is gone for good, not to the Trash: audio not yet transcribed, notes and note lines from then on, the live transcript (and what AI apps can see of it), and dictations. A note you edited is cut by whole lines, so your edits before that time stay; notes from your iPhone and Apple Watch are cut by when they were recorded, like the Mac's own, and notes made from an audio file (`sona file`) aren't touched. It can't reach copies made elsewhere: Time Machine backups, a synced notes folder (the iPhone's iCloud Drive folder still has its copy: delete it on the iPhone; the Mac won't import it again), or whatever an AI app already read.

## Words it should know

Settings > Words it should know: one line per word the model gets wrong, with the spellings it writes and what you want instead (`cooper netties, kuber netties` → `Kubernetes`). Whole words or phrases, any case. It fixes dictation, the live transcript and new notes.

## Notes

Each conversation is a markdown file at `~/Sona/Conversations/YYYY-MM-DD/HH-MM <title>.md` (you can move the folder in Settings):

```markdown
---
title: "The pricing page needs work"
date: 2026-10-27
start: "14:03:12"
end: "14:21:40"
duration: 18m 28s
speakers: ["Speaker 1", "Speaker 2"]
model: parakeet-tdt-0.6b-v2
tags: [sona]
---

# The pricing page needs work

[00:00] Speaker 1: So the pricing page needs work.

[00:04] Speaker 2: Agreed, let's ship Friday.
```

- Next to it, a `.json` has every word with its time and speaker (and, with this Mac's audio on, which track it came from).
- The title is the first few meaningful words. No AI writes anything.
- Once a conversation ends, all of it is transcribed again with the whole conversation in view: Parakeet TDT for the words, pyannote community-1 with VBx for the speakers. How many people the live pass heard helps it.
- Past an hour, a conversation is split at the next 2 s pause (at 75 minutes if there's none), so a TV on all evening makes hour-long notes.
- If this Mac was playing audio (a video, a podcast) for 80% or more of the speech, and no app was on a call, the note is marked `media: true` and tagged `likely-media`. Nothing is dropped.
- The audio is deleted once the note is written.
- They're plain files: point Obsidian at `~/Sona` and it just works.

## iPhone and Apple Watch

There is a Sona for iPhone and Apple Watch in `ios/`: a dictaphone. Tap to record on the watch or the phone, the iPhone turns it into text on the device with the same engine as this app, and the notes reach your Mac through iCloud (see "iPhone notes" below). Onboarding asks where notes go (the app's iCloud folder, this iPhone only, or a folder you pick) and how long audio stays (30 days, forever, or deleted once transcribed). The iPhone downloads its speech model once (about 480 MB), shows a place with each note (one location fix at the start and one at the end, street name from Apple's map service) and can title notes on the device. The iPhone's screens look like Apple Notes: a list of days, then a day's notes. TestFlight builds have run on a real iPhone and an Apple Watch since 8 Nov 2026. What it is, how to build and test it, its launch arguments and the TestFlight release are in [ios/README.md](ios/README.md).

## iPhone notes

The iPhone app writes its notes the same way (a `.md`, a `.json` and the recording as `.m4a`, with `source: "iPhone"` or `"Apple Watch"`) into iCloud Drive: the app's own folder (`iCloud~com~dinilb~sona`, the default) or, if the iPhone's choice is Other folder, the one picked there (`iCloud Drive/Sona/Conversations`). With "On this iPhone" the notes never leave the phone, so there is nothing to copy. Sona copies them into your notes folder at launch and then every minute, so the window, search and your AI see them like any other note. `sona import-phone` does it once by hand (`--from PATH` for one folder). Sona itself makes no network calls to do this: iCloud puts the files on the Mac. The notes may carry `ai_title`, `place`, `geo`, `place_end`, `geo_end` and `keep_audio` lines; Sona keeps them and shows `ai_title` as the title. On macOS 26 or later with Apple Intelligence, after each pass Sona also titles the iPhone's notes from the last 14 days that have no `ai_title` (with its on-device model only, never a server) and writes them to `Titles/YYYY-MM-DD.json` beside `Conversations` in the iPhone's iCloud folder, where the iPhone folds them in. This Mac's copy of the note gets the title straight away (only a copy you haven't changed here). It never edits a note the iPhone wrote.

- It only copies. No note is deleted on either side; the one thing it clears is the hidden half-copied file a stopped import can leave in a day folder of your notes (once it is a few minutes old). A note is copied once it is all there (the `.md`, its `.json` and any audio); one still coming from iCloud waits for a later run.
- A note in both folders is copied once, from the picked folder, unless that copy isn't all there yet (its `.json` hasn't come, or a file is still coming from iCloud or can't be read yet) and the other folder's is: then from that one.
- If the iPhone changes a note, this Mac's copy is replaced, unless you changed it here (a speaker renamed through your AI, say) or deleted it: then your copy stays. What the iPhone adds to a note later still reaches a copy you changed: its place (`place`, `geo`, `place_end`, `geo_end`), Keep audio (`keep_audio`) and its AI title (`ai_title`; not into a note cut by "delete the last N minutes", and never taken away).
- A note the iPhone deletes, or whose audio it deletes after 30 days, stays here with its audio: this Mac's copies follow this Mac's rules.
- Notes from the iPhone and the watch show which one recorded them and where (the street names, never the coordinates), in the window and to your AI, and their AI title when they have one. Search, and the MCP `search` tool, also find a note by its title or place.
- The app's own iCloud folder is read where iCloud puts it on this Mac, `~/Library/Mobile Documents/iCloud~com~dinilb~sona/Documents`. Sona isn't sandboxed, so it needs no iCloud entitlement for that.
- What was copied is remembered in `phone-import.json` in the support folder, so a note you delete here doesn't come back. Each notes folder keeps its own list: pick another notes folder in Settings and the iPhone's notes are copied into it from the start (a note already there with the same words is left alone), and going back to an earlier folder keeps what you deleted or cut there. A note already here with the same name but different words is never overwritten: the iPhone's gets a number after its name.
- macOS may ask Sona to allow access to iCloud Drive the first time. Until you allow it, nothing is copied.
- The iPhone's own log is in the same iCloud folder, `~/Library/Mobile Documents/iCloud~com~dinilb~sona/Documents/Diagnostics/iPhone.log` (its newest ~256 KB, copied when the iPhone app opens or leaves the screen, at most once a minute on screen, within seconds in the background and before it's suspended, only while its notes go to iCloud). It says when each recording started and stopped, reached the iPhone from the watch, and became a note, and how long that took, with no words, titles, file names or places: read it when a note is slow to arrive. The import never reads it.

## Connect your AI

The MCP server is `Sona.app/Contents/MacOS/sona-mcp` (stdio, local only). One line adds it to Claude Code for every session, in every folder (`--scope user`; `claude mcp list` shows it). `make install` prints it, and Settings > AI access has a copy button:

```sh
claude mcp add --scope user sona -- /Applications/Sona.app/Contents/MacOS/sona-mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`) and Cursor (`~/.cursor/mcp.json`):

```json
{ "mcpServers": { "sona": { "command": "/Applications/Sona.app/Contents/MacOS/sona-mcp" } } }
```

Codex: `codex mcp add sona -- /Applications/Sona.app/Contents/MacOS/sona-mcp`

| Tool | What the AI gets |
| --- | --- |
| `live` | The live transcript: the last N seconds (default 2 minutes, at most 10) or the last N words, with speakers. Only while always-on is on and not paused. `minutes` or `since` reach further back: past 10 minutes it reads like `transcript`. |
| `current_conversation` | All of the conversation going on now, from its start, with speakers (or the one that just ended, until its note is written). |
| `transcript` | Everything said between two times (`14:05`, `2026-11-09 14:05`, ISO 8601), from the notes and from audio not yet in a note alike, in time order. |
| `recent` | What was said in the last N minutes (default 60), or the last N conversations, and whether one is still going. |
| `list_conversations` | Conversations between two dates (default today). |
| `read_conversation` | One transcript, paged. |
| `search` | Full-text search over every transcript, by words, dates or speaker, and over the conversation going on now (`in_progress: false` skips it). |
| `rename_speaker` | Puts a name on a speaker in one conversation (Speaker 1 → Alex). The only tool that changes anything: it rewrites that note (marked destructive, so AI apps can ask first), and never one that changed since it read it. |

A conversation only becomes a note a few minutes after it goes quiet, and the live transcript keeps 10 minutes. For the rest, the tools transcribe its audio in the spool when asked, with the notes model, the way `sona file` does: `sona-mcp` starts `sona spool-serve` beside it the first time, which loads the model (well under a second, or about 20 s the first time after an install), transcribes five minutes at a time at about 90x real time, newest first, and keeps what it transcribed in memory, so asking again only transcribes what's new. A call waits at most about 40 s (20 s for `search`), says what isn't done yet, and the rest carries on in the background. Speaker numbers there are the reply's own until the note is written. It writes nothing: no note, no file. It lets the model go after an idle minute (about 400 MB) and quits after ten, or when your AI app quits.

**The off switch**: turn off Settings > AI access, and every tool answers "AI access is turned off in Sona's settings" and nothing else. The live transcript file is deleted too, and `sona spool-serve` stops, with what it transcribed.

Then ask things like "what did I talk about this morning?" or "who said they'd send the logo files?".

## Command line

`Sona.app/Contents/Helpers/sona` (and `build/sona` after `make`):

```sh
sona file meeting.m4a                # the notes pipeline on an audio file
sona file meeting.m4a --speakers 3   # a speaker count (3, or a range like 2-4) when voices sound alike
sona process-spool                   # turn audio left over after a crash into notes
sona import-phone                    # copy the iPhone app's notes in from iCloud Drive (--from PATH for one folder)
sona models                          # download the notes models
sona mcp                             # the MCP server (same as sona-mcp)
sona spool-serve                     # for the MCP server: transcribe audio not yet in a note, on request
sona status                          # settings, models, spool, and whether the app is running
```

## Privacy

- Nothing of yours leaves your Mac: no server, account, analytics or crash reporting. The network is used to download the models from Hugging Face, once, and, if you allow it, to check for updates (Sparkle reads a small file from the project site, dinilb.github.io; updates download from GitHub). (The iPhone app also looks up street names with Apple's map service, sending coordinates only, and only with location allowed; see [ios/README.md](ios/README.md).)
- Notes and their folders are readable only by you (files 0600, folders 0700), and so is the support folder with everything in it (settings, the log, the spool, the search index). The log never contains what was said.
- The app is signed with the hardened runtime, so no other program can load code into it and use its microphone, Accessibility or System Audio Recording permission.
- If settings.json can't be read, always-on, AI access and Mac audio are off and the iPhone's notes aren't copied in until you change a setting (the file is left as it is; `sona import-phone` then needs `--notes-dir`). A settings file without the AI access switch reads as off. Turning AI access off also deletes the search index.
- The MCP server only runs when your AI app starts it, only talks over stdio, and only reads your notes, the live transcript file and the audio in the spool (`rename_speaker` rewrites one note). The spool's audio is transcribed in the memory of `sona spool-serve`, its own helper, which writes nothing and quits with it. It never follows a symlink in the notes folder. What your AI app then sends to its own cloud model is between you and that app.
- **Recording laws differ by place**: some need everyone's consent before a conversation is recorded. Speaker labels come from comparing voices, on this Mac, and no voiceprints are kept.
- This Mac's audio is only heard with its switch on and the System Audio Recording permission given, only while something plays, and like the mic, only while always-on is on and not paused. It's everything the Mac plays (videos, music, calls, notification sounds), transcribed on this Mac; its audio is kept with the conversation's until the note is written, then deleted.

| What | Where |
| --- | --- |
| Notes | `~/Sona/Conversations/` (Settings can move it) |
| Dictations, with always-on off | `~/Sona/Dictations/` |
| Settings and the words list | `~/Library/Application Support/Sona/settings.json` |
| Models | `~/Library/Application Support/Sona/Models/` |
| Audio not yet in a note | `~/Library/Application Support/Sona/Spool/` (the Mac's in `<id>.mac.wav`), deleted once the note is written |
| The last 10 minutes of live transcript, for `live` | `~/Library/Application Support/Sona/Live/now.json` |
| Search index (a cache, safe to delete) | `~/Library/Application Support/Sona/search.sqlite` |
| Which iPhone notes were copied in (so one you deleted doesn't come back) | `~/Library/Application Support/Sona/phone-import.json` |
| Log (no transcript text) | `~/Library/Application Support/Sona/sona.log` |
| A dictation you saved for debugging (its audio and text) | `~/Library/Application Support/Sona/Debug/`, only when you click Save Last Dictation for Debugging |

To uninstall: turn off Open at login, quit, then delete the app and `~/Library/Application Support/Sona`. Your notes stay in `~/Sona`.

## Reliability

- Audio goes to disk as it's heard and is flushed every 5 s. After a crash, a kill or a power cut, the conversation (up to its last 5 s) becomes a note on the next launch.
- Quitting, logging out or a plain `kill` saves the open conversation first; if there's no time to transcribe it, that happens on the next launch.
- A conversation that fails 3 times is moved to `Spool/failed` with its audio, and the menu says so. Nothing is dropped silently.
- The mic is opened straight through Core Audio, on its own device: AirPods or another device connecting, disconnecting or becoming the default never moves it or stops it (and never puts AirPods into call quality). It's reopened when the device it's on goes away or changes its sample rate, when you pick another one, after sleep if it hasn't sent any sound since waking, and when it goes silent for 6 s. Once, not twice: a mic that's sending sound is never closed, and one that was just opened gets the full 6 s to start (after a wake that can take a couple of seconds). An open that Core Audio doesn't answer within 10 s is given up and tried again, so a stuck one never leaves the mic off.
- A dictation never waits behind this Mac's audio, and never pastes before its last word is in (see Dictation).
- This Mac's audio follows the output (AirPods to speakers, a new sample rate), its tap is reopened if its audio stops, and audio that stops and comes straight back keeps its live transcript.
- Open at login is the system's own login item. If Sona quits or crashes, it stays down until the next login or until you open it: no menu bar icon means it isn't listening.

## Limits

- English only.
- The other side of a call in your headphones is only in the transcript with "Hear this Mac's audio too" on (macOS 14.2+). Through the speakers, the mic's copy of it is taken out by matching words, not echo cancellation: a few mis-heard words can slip through, and a phrase said along with a video at the same moment can be taken out.
- A global tap hears everything the Mac plays, music included: lyrics can become Mac audio lines (marked media when that's all there is).
- Speakers are numbered per conversation; the same person isn't recognised across conversations, and very similar voices can be merged.
- No summaries, no Windows or Linux, and no sync service of its own: the iPhone app's notes reach the Mac through your own iCloud Drive (see iPhone notes).

## Build and test

```sh
make           # build/Sona.app and build/sona-live-bench
make install   # build, replace /Applications/Sona.app and restart it
make test      # unit tests
make clip      # synthetic test audio (macOS say voices; needs ffmpeg)
make release   # signed, notarized DMG (needs your own Developer ID certificate and App Store Connect API key)
```

- `make` signs with your Developer ID certificate if the keychain has one (`SIGN_IDENTITY` picks another, `-` forces ad hoc). Otherwise it's ad hoc, and macOS asks for the microphone and Accessibility again after every build, because an ad-hoc signature changes each time. Either way it has the hardened runtime, as a release does.
- `make install` stops the running copy with SIGTERM (it saves the open conversation and gives the fn key and Caps Lock back), swaps in the new build after checking its signature, has LaunchServices forget other copies (build folders) and starts it in the background. `DRY_RUN=1` only prints the steps; `INSTALL_DIR`, `SONA_HOME` and `NO_LAUNCH=1` try it without touching your real app.
- Anything run by hand should use a test folder, never your real notes:

```sh
SONA_HOME=$PWD/test-home build/sona models
SONA_HOME=$PWD/test-home build/sona file test-audio/two-voices.wav
python3 scripts/score.py test-home/Notes/Conversations/<day>/<note>.json test-audio/two-voices.turns.tsv   # word error rate and speaker accuracy
SONA_HOME=$PWD/test-home scripts/mcp-smoke.sh
CLIP=test-audio/two-voices.wav SONA_HOME=$PWD/test-home scripts/mcp-smoke.sh budget   # with a conversation still being recorded
SONA_HOME=$PWD/test-home build/sona-live-bench test-audio/two-voices.wav   # spoken → right word on screen
scripts/make-mac-audio-clip.sh   # a room with a video playing: the mic file and the Mac's
SONA_HOME=$PWD/test-home LIVE_FILE=test-audio/mac-room.wav LIVE_FILE_MAC=test-audio/mac-audio.wav \
  build/Sona.app/Contents/MacOS/Sona   # both tracks headless ("macAudio": true in the test settings.json)
scripts/dictation-bench.sh all   # hold to dictate, headless: first and last word kept, word error, release → paste
SONA_HOME=$PWD/test-home LIVE_FILE=<saved>.wav LIVE_DICTATE=2.000-5.300 build/Sona.app/Contents/MacOS/Sona   # replay a dictation saved for debugging (its .json has the line)
```

- `LIVE_DICTATE=1.0-4.2,8.0-11.5` beside `LIVE_FILE` holds the dictation key over those seconds of the file and writes each result to `dictations-test.jsonl` in the test home instead of pasting (a test run never presses keys or touches the clipboard).
- In a test home the iPhone's iCloud folders are never read: `$SONA_HOME/PhoneInbox` stands in for them, for the app and for `sona import-phone` (which also takes `--from`). Drop notes (day folders with `.md`, `.json`, `.m4a`) in there to try the import.

- The logo, a dithered sound wave, is drawn in `design/icon/`: `icon.svg` for the app icon (with `icon-32.svg` and `icon-16.svg` redrawn on those sizes' pixel grid), and `Sources/SonaApp/MenuBarIcon.swift` for the menu bar icon in each state. `design/icon/render.swift` (built with that file, see its first lines) draws a contact sheet of both, and `render.swift apply` also rebuilds `Resources/AppIcon.icns`.
- The public website (home, privacy policy, support) is `site/`: plain HTML and one stylesheet, no build step, no scripts and nothing loaded from other sites. Not published yet. `design/site/` has the sources of its wave (`wave.py`), link-preview image (`og.html`) and touch icon (`touch-icon.html`).
- See [CONTRIBUTING.md](CONTRIBUTING.md) before sending changes, and [SECURITY.md](SECURITY.md) to report a privacy problem. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Licences

Sona is MIT licensed (`LICENSE`). It builds on open models and code, credited with their licences in [THIRD_PARTY.md](THIRD_PARTY.md): FluidAudio (Apache-2.0), Parakeet TDT (CC-BY-4.0), Parakeet Unified (NVIDIA Open Model License), Nemotron 3 Diarization (OpenMDW-1.1), pyannote community-1 (CC-BY-4.0) and Silero VAD (MIT). The models are downloaded from Hugging Face, not shipped in the app.
