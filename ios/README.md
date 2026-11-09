# Sona for iPhone and Apple Watch

A dictaphone. Tap to record on the watch or the phone. The iPhone turns the recording into text on the device, with the same speech engine as Sona on the Mac (Parakeet TDT v2, English). Each recording becomes a note in the Mac's exact format: a `.md`, a `.json` and the audio as an `.m4a`.

Onboarding asks where the notes go: the app's iCloud folder (the default when the phone is signed in to iCloud), this iPhone only, or another folder you pick. With iCloud, Sona on the Mac copies them into `~/Sona`, so the window, search and the MCP server see them like any other note.

The iPhone makes two kinds of network call. The first is the one-time download of the speech model (about 480 MB), which the welcome screen tells you about. The second is Apple's map service looking up a street name for a place, which only happens with location allowed and the app on screen, and sends coordinates only. Nothing else leaves the phone, and there is no account, analytics or crash reporting.

TestFlight builds have run on a real iPhone and an Apple Watch since 8 Nov 2026.

## Layout

`project.yml` is the source of truth. `make generate` turns it into `Sona.xcodeproj` (generated, gitignored, so are `Configuration/*.plist` and `Configuration/*.entitlements`). It needs [XcodeGen](https://github.com/yonaskolb/XcodeGen). iOS and watchOS 26, Swift 6.

| Target | Folder | What it is |
| --- | --- | --- |
| `Sona` | `Sona/` | The iPhone app (`com.dinilb.sona`). Links `NotesKit` and `SonaEngine` from the Mac package one folder up, so notes are the same format. |
| `SonaWidgets` | `SonaWidgets/` | Live Activity (Lock Screen and Dynamic Island, with Stop), a Record control (Control Center, Lock Screen, Action button) that starts a note and stops it when pressed again, Lock Screen widgets and a Home Screen widget. |
| `SonaWatch` | `SonaWatch/` | The watch app: one big record button, a short list of recent recordings. Embedded in the iPhone app. |
| `SonaWatchWidgets` | `SonaWatchWidgets/` | The watch face complications (circular, corner, inline, rectangular). A tap starts a note, a tap while recording stops it. While recording each shows the running time, which counts by itself, and a voice wave (still: complications can't animate), except the corner, which has room for one symbol. The circular and corner show a stop square and the rectangular says "tap to stop", so a tap meant to check on a note doesn't end it by surprise. |
| `SonaTests`, `SonaWatchTests` | `SonaTests/`, `SonaWatchTests/` | Unit tests. |

Shared code is in `Shared/` and is compiled into each target that needs it: `SonaIDs.swift` (App Group, iCloud container, deep links and the key they carry, the status the widgets read), `WatchTransfer.swift` (the watch-to-iPhone contract), `RecordingAttributes.swift` and `RecordingIntents.swift` (Live Activity and the Start, Toggle and Stop intents), `SonaTheme.swift`.

Inside `Sona/`:

- `App/`: the app, its model (what the screens show), `V1Settings` (the choices made in onboarding and Settings) and `Services.swift` (the one spool).
- `Recording/`: `PhoneRecorder` (the recording session), `MicCapture` (with the watchdog that notices audio stopping), `SpoolRecording` (writes the WAV into the spool), `RecoveryLoop` (gets the mic back after an interruption), `RecordingNotice` (the notifications), `RecordingDebug`.
- `Processing/`: `NotesService` (the queue that turns recordings into notes, and the speech model download), `AudioCompressor` (WAV to m4a), `AudioRetention` (deletes old audio), `NoteEnrichment` (places and titles after a note is written), `BackgroundProcessing` (the charging-time task), `ContinuedProcessing` (the note after an in-app stop, carried on off screen), `ProcessingDebug`.
- `Notes/`: `NotesLocation` (where notes go), `NoteFiles` (edits and deletes a note's files safely in iCloud), the folder picker, the list's note summaries, `WidgetStatus`.
- `Location/`: `PlaceStamps` (the fixes and street names), `PlaceStore`, `PlaceRules`, `OneShotFix`.
- `Titles/`: `PhoneTitles` (titles from Apple's on-device model).
- `Watch/`: `WatchReceiver` (WCSession) and `WatchInbox` (the contract, without WCSession).
- `Views/`: the screens: `RootView`, `HomeView`, `DayView.swift` (a day, and a place), `NoteDetailView`, `SettingsView`, `PrivacyView` (the policy text is in `PrivacyPolicy`), `OnboardingView`, `ModelProgressView`, `RecordPanel`, `ListRows.swift`.
- `Intents/`.

## How it fits together

**The spool.** A recording is a 16 kHz mono 16-bit WAV plus a small JSON entry (a `SpoolEntry`) in the app's one `Spool` (`Services.spool`, from the Mac package's SonaEngine). `SpoolRecording` appends to the WAV as audio arrives, so a crash or a kill keeps all of it, and flushes it to the disk itself every 10 s, so even a power cut loses at most the last 10 s. The spool's `openID` marks the recording in progress, so the processor never takes it. On the next launch an unfinished recording is finished and queued; if the app died mid-recording, the app says so. Under half a second isn't a recording and is deleted. A recording that was started 3 times and never finished (the app crashed or was killed while it was transcribed) moves to `Spool/failed` with its audio kept, before the models load, so it can't keep killing the app. One that fails 3 times moves there too. `Spool/failed` comes back once with each new build for one more try, and "Try again" on the failed banner gives each recording three. In the foreground, a recording that was never tried goes first. A failed or waiting recording can be swiped away in the list, which deletes it.

**Notes.** `NotesService` feeds the spool to the engine's `Processor`, one recording at a time, only with the model on disk. It runs in the foreground, and in the background on a charging-time `BGProcessingTask` (`com.dinilb.sona.transcribe`; on power only, which is what lifts iOS's background CPU limit for it). That task also picks up recordings that failed or timed out in the background, and a note the Neural Engine refused there is tried once more on the CPU. A Stop tapped in the app also asks for a `BGContinuedProcessingTask` (iOS 26, `com.dinilb.sona.finish.<suffix>`, one identifier per request, registered just before it's submitted): if he leaves the app before the note is written, it carries on off screen on the CPU, with a bar in the Dynamic Island and on the Lock Screen that he can cancel. iOS runs these only when asked for from the app on screen, so a stop from the Lock Screen, Siri or the watch gets none. iOS ends one whose bar sits still for about 30 s, so the bar moves every second on a guess from the audio's length (`ContinuedProgress`). The simulator never runs them. Without one, a recording that comes in off screen (a stop from the Lock Screen or Siri, the watch) is written on the ~30 s of background time iOS gives if it's 30 s of audio or less and its CPU estimate fits, and never while a recording runs (`NotesService.gate`, `heldAudioCap`: iOS also limits an app's CPU off screen when no task lifts it, and Core ML can't cap its threads); a longer one waits for the foreground or the charging task. iOS 27 keeps the Neural Engine from apps in the background without the Background Inference entitlement (`com.apple.developer.background-tasks.continued-processing.inference`), which Sona doesn't have yet, so off-screen notes are slower. The `Processor` writes the `.md` and `.json` and keeps the WAV, which `AudioCompressor` turns into an `.m4a` (AAC, 16 kHz mono, about 32 kbps, about 14 MB an hour) and then deletes. If the m4a doesn't check out, the WAV stays, and so does the note: on the phone, until its audio is an m4a. With "Delete once transcribed" no `.m4a` is made at all.

**The speech model.** The first screen of onboarding says Sona downloads a speech model once, about 480 MB. That screen is the disclosure App Review 4.2.3(ii) asks for, and its Continue allows the download (`V1Settings.modelDownloadAllowed`). After that there is no Download button anywhere: `NotesService.ensureModels()` starts it at launch, each time the app comes to the foreground, when the network comes back, and after a failure (it waits 5 s, 15 s, 45 s, then every 2 minutes). It keeps the screen awake while it runs. When the app leaves the screen it gets the 30 s or so iOS gives, then stops and keeps its partial files, and it picks up again when the app is back. The Neural Engine prep is never run in the background. A slim bar ("Downloading the local speech model, please wait... 42%") shows on every onboarding step after the welcome and on Home, and "Getting the speech model ready, please wait..." shows during the Neural Engine prep. The bar follows the bytes on disk (`Models.bytesOnDisk` against `Models.expectedBytes`, 487,263,709 bytes for v2), not FluidAudio's own fractions, which froze at 46% while the 445 MB encoder file resumed. Recording works while it downloads, and waiting recordings say "waits for the speech model". In the simulator a fresh download was ready in 104 s, and one killed at 35% picked up where it was and was ready in 162 s in all.

**Places.** One location fix when a recording starts and one when it stops (`CLLocationManager.requestLocation`, 10 s timeout), so a note can show where it was made and where it ended. "When In Use" is asked once, in onboarding's places step (an install that finished onboarding before that step is asked right after its first recording). There is no location background mode, so a start or stop in the background may get no fix, and the note then uses the other one or none. A fix is kept in `Application Support/Sona/Places/<id>.json` (out of backups) until its note has its place. The note gets `place` and `geo` (4 decimals, about 11 m) and `place_end` and `geo_end` only when the stop is more than 100 m from the start. The street name comes from Apple's reverse geocoder (`MKReverseGeocodingRequest`), asked in the foreground with coordinates only; a note written in the background or offline gets its `geo` at once and its name on a later foreground. Watch recordings get no place. Coordinates and names are never logged.

**Titles.** A note gets an `ai_title` in its front matter. `title:`, the heading and the file name keep the first-words title and no file is renamed, because the Mac keys notes by file name. Lists show `ai_title` when there is one. On an iPhone with Apple Intelligence, `PhoneTitles` titles the note on the device right after it is written (at most 10 s, before it moves), and tries once more on a later foreground for notes from the last 3 days. On other iPhones, Sona on the Mac (macOS 26 or later with Apple Intelligence) titles the iPhone's notes from the last 14 days with its on-device model only, writes them to `<root>/Titles/YYYY-MM-DD.json` beside `Conversations`, and the iPhone folds them in. Titles never go to a server or Private Cloud Compute. FoundationModels is weak-linked in the Mac app, so it still runs on macOS 14.

**Where notes go** (`NotesLocation`, by the choice made in onboarding and kept in Settings):

1. iCloud: the app's own iCloud container, in its `Documents/`. This is the default when the phone is signed in to iCloud, and it is what the Mac reads.
2. On this iPhone: `Documents/Notes`. It is in iCloud Backup and never in iCloud Drive.
3. Other folder: the folder you picked, kept as a security-scoped bookmark (suggested: iCloud Drive > Sona). An install from before v1 with a picked folder counts as this. Leaving it forgets the bookmark; notes already there stay there.

Every note is written in `Documents/Sona` first (staging, kept out of backups) and moves to its place only once it's whole: a written `.md`, its `.json`, and its audio as an `.m4a` (a WAV left beside it is converted first; with "Delete once transcribed" there is no audio). A note that isn't whole stays on the phone and is tried again next time, so a raw WAV or a half-written note never reaches iCloud Drive or the Mac. The `.md` moves last: a move cut short (an error, the app killed between files) is finished under the same name next time, and only a different note with the same name moves as "... 2". Nothing is lost or doubled. If the chosen place can't be reached (iCloud is off, the picked folder is gone), notes wait in staging and a banner says why.

Notes land in `<folder>/Conversations/YYYY-MM-DD/`, the same layout as the Mac. Mac Sona reads that folder out of iCloud Drive (see "iPhone notes" in `../README.md`). The list shows notes still waiting in staging as "on this iPhone, not synced yet" (not said when notes stay on this iPhone anyway), and notes iCloud took off the phone from their file names; they download when opened.

**Audio.** Onboarding and Settings choose how long audio stays: 30 days (the default), forever, or delete once transcribed. A note with `keep_audio: true` keeps its audio whatever the setting; in 30-day mode the Keep audio button on a note, or a swipe right in the list, sets it. A sweep runs at launch, on each foreground and after each note, and only once onboarding has shown the audio choice. It deletes only audio, never the note, and skips notes whose `.md` iCloud has taken off the phone until it is downloaded. Settings says how many audio files a stricter choice will delete before it does. The Mac's copies of the audio follow the Mac's own rules; the import never deletes.

**What stays on the phone.** The spool (raw WAVs, `Spool/failed` included), the watch's staged AAC, `Documents/Sona` (except while notes wait there with nowhere to go: then it's backed up) and the place fixes are kept out of iCloud Backup and computer backups, and are readable only once the phone has been unlocked since it started (recording and transcribing run while it's locked). With "On this iPhone", notes in `Documents/Notes` are backed up.

**The log.** `Log.note` writes `sona.log` in the app's Application Support (never words, titles, file names or places; an error is its domain and code, plus its words only for Sona's own errors that can't hold a name, `LogSafeError`). With notes in iCloud, `DiagnosticsLog` also copies its newest 256 KB (with `sona.old.log` in front while the log is short after a roll-over) to `Documents/Diagnostics/iPhone.log` in the app's iCloud container: at launch, when the app goes off screen, at most once a minute after new lines on screen and 10 s after them off screen, and before held background time, the watch's wake or a background task is given back (`DiagnosticsLog.flush`, waiting 3 s at most). A launch with nothing new logged doesn't copy again (the last copy's size and date are kept in the defaults). Writes go through `NSFileCoordinator` and give up after 10 s; the container is looked up again whenever where notes go changes. On the Mac it's `~/Library/Mobile Documents/iCloud~com~dinilb~sona/Documents/Diagnostics/iPhone.log`, beside `Conversations/`, which is all the Mac imports. With On this iPhone or Other folder there's no copy, and switching to one deletes the copy in iCloud.

**The screens.** Light and dark, with Dynamic Type, monochrome with the system red only for recording (`../design/DESIGN-RULES.md`); the watch and the widgets keep the fixed Sona look. The layout is like Voice Memos.

**The Live Activity.** White with ink on a light Lock Screen, black with white on a dark one (the system's appearance decides; the app's warm paper read as yellow there), red only for recording and problems. Under the time and Stop, a red wave of the last 4 s of the voice (`ActivityWave`): a Live Activity can't animate by itself, so the recorder keeps the last 40 levels on the audio thread (`WaveLevels`) and sends them every 4 s while the app is off screen (`PhoneRecorder.waveSeconds`). Paused, the wave is flat and grey. The expanded island has the wave under the time, the compact island a small one in place of the mic.

- Onboarding runs once, for existing installs too, in three screens: welcome (what Sona is, and the model download its Continue starts; the 480 MB line is pinned right above Continue, so it's on screen with it at every text size), your notes (where they go and how long audio stays, each shown with its default and changed from a menu; Continue saves exactly the Keep audio shown, `AudioChoice`), and what Sona asks for (one neutral Continue, then the microphone, notifications and When In Use location alerts one after another). Home comes straight after.
- Home is one list, newest first (recordings that aren't notes yet on top), with banners and the model bar above it, Settings at the top and the red record button at the bottom. While it records, a sheet has the time, the live wave and Stop; a small bar with Stop sits under it, so Stop stays on Home if the sheet can't come up, and the sheet is asked for again every second until it's up. Search finds a note when every word typed is in its title, places, "from watch" or what was said (only the lines' words, never the front matter or the speaker prefixes; read once per note and again when its file changes, `TranscriptCache`). Swipe left to delete (a red button, then a confirm), swipe right for Keep audio.
- A note shows its title, when, its places and who, then the transcript, with the player pinned at the bottom (Play, the recording's wave, the times). A place tapped shows Home filtered to the notes made there, by the exact name, with Show all to clear it (`AppModel.placeFilter`). While it plays the page follows the line being played, until it's scrolled by hand; Play or a tapped line follows again. A recording that starts pauses the note first. Audio iCloud took off the iPhone downloads when the note opens, and the player appears once it's here. Share is at the top, Keep audio and Delete in the menu.
- Settings has the notes location, audio, the places permission, the privacy policy and About with the licences. The policy text is in `PrivacyPolicy`; its public `url` is nil until a public page is approved.

**Watch to iPhone** (`Shared/WatchTransfer.swift`, WatchConnectivity):

1. The watch records into its own folder: `<id>.aac` (ADTS AAC, 16 kHz mono, about 14 MB an hour instead of 115 MB of WAV) and `<id>.json` (a `WatchRecording`), or `<id>.wav` if the AAC encoder won't start. The id is a UUID. A recording that never stopped (the app died) has a torn last frame cut off. Older builds' WAVs still read and send.
2. It sends the audio with `transferFile`, metadata `kind`, `id`, `startedAt`, `duration`. The system queues it and delivers it whenever the phone is in range, the app closed or not.
3. The iPhone's `WatchInbox` tells AAC from WAV by the first bytes. A WAV goes into its own spool inside the delegate callback (the system deletes it after), as a closed entry with source "Apple Watch". An AAC is moved to `Application Support/Sona/WatchStaging` and flushed to disk inside the callback, then cut back to its last whole frame and decoded into the spool's 16 kHz WAV after (at launch and after each arrival); one that won't decode stays there and is tried again. It remembers the last 1000 ids in `watch-received.json`, so a recording sent twice is stored once.
4. The iPhone then sends an `Ack` back with `transferUserInfo` (queued, survives both apps quitting) and, if the watch app is open, `sendMessage`. If the recording couldn't be saved it sends no ack. It also publishes the ids it has (the last 200) as its application context, and the watch deletes what is listed.
5. Only on the ack, or on being listed, does the watch delete its copy. A transfer that failed is sent again; one that was delivered but not acknowledged is not resent every hour any more. The watch recordings list keeps the last 5 acknowledged ones as "sent". Acks are handled in the background (a WatchConnectivity background task).

While the watch app is open and the iPhone is reachable, the watch wakes Sona on the iPhone with a message, so a waiting recording is taken at once. After Sona is swiped away on the iPhone, watch recordings may wait until it's opened (not verified on a device).

The simulator can't transfer files, so on a simulated watch recordings stay "waiting for iPhone".

**When something else takes the mic.** On the iPhone a call or Siri pauses the recording: the Live Activity says paused, a notification comes 20 s later if the mic hasn't come back, and the time it was away is kept as silence so the lines after keep their real times (measured on the monotonic clock, so a clock change doesn't move them). If audio stops arriving with no notification, a 5 s watchdog says paused and rebuilds the audio engine; coming back to the app rebuilds a silent engine too. A stop you didn't make (out of space, a write error) ends the activity with the reason; if the app dies, the activity goes stale and says it isn't recording. If iOS ends the Live Activity while it records, a "Sona is still recording" notification comes and opening Sona brings the activity back. The activity is renewed before the 8 hour limit while the app is open. On the watch a call or Siri saves the recording so far. A new one starts only if Sona is on screen and the mic is back within 2 minutes ("Carried on after a call or Siri"); otherwise a notification says the recording was saved. The watch won't start under 100 MB free and stops (saving) under 50 MB. A recording with no recognised words is still kept, as "No speech transcribed" with its audio.

**Watch health.** Every minute, and when the wrist is raised, the watch checks that the recorder is still writing. A stopped recorder or a media services reset stops and saves the recording with a notification. If the checks themselves stop, a "Sona may have stopped recording" notification fires about 3 minutes later. A "still recording" notification comes at 2 hours. The complication stops showing a timer for a recording whose app died (no heartbeat for 3 minutes).

**Widgets.** The app writes a small `SharedStatus` (recording since when, paused since when, when the app last said it's alive, how many recordings wait, the newest note's title and time) into the App Group `group.com.dinilb.sona`. Each device has its own App Group, so the watch writes its own: how many recordings wait to be sent. The widgets and complications only read it. While the iPhone records, the app says it's alive every 5 minutes (`aliveAt`); a widget that hasn't heard for 6 minutes shows "not recording · open sona", and a widget showing a recording only opens the app. The app reloads their timelines when the status changes, and they never refresh on their own. The watch asks for a reload the first time it publishes after it starts, and after that when what the complications draw differs from what it last asked for (not from what's saved: a reload iOS dropped is saved all the same, and would never be asked for again).

**Deep links.** The widgets and complications open `sona://record?k=<key>` and `sona://stop?k=<key>`. The key (`LinkKey`, in `Shared/SonaIDs.swift`) is a random string made the first time anything reads it and kept in that device's App Group, so the iPhone and the watch each have their own. The app acts on a record or stop link only when its key matches (`DeepLink.trusted(url:)`); a link without it, or with another, just opens the app and nothing starts or stops. Any app or web page can open a `sona://` link, but none can read the App Group, so none can start the mic. The Record control, Siri and the Live Activity's Stop button use App Intents, not links. The Control Center and Lock Screen control uses `ToggleRecordingIntent` (a press starts a note, a press while recording stops it); Siri's "Record a note" stays start-only. A first start from the background, before the microphone was ever asked for, continues in the app, because that question can only show on screen. A record link in the first 10 seconds after a launch that found a cut-short recording only opens the app, because it comes from a widget still showing that recording. A Shortcut that opens a bare `sona://record` now only opens the app: use the "Record a Note" action instead.

## Build, test, run

Run these from `ios/`. They need Xcode 26 and XcodeGen. `DEVELOPER_DIR` defaults to `/Applications/Xcode.app/Contents/Developer`.

```sh
make sims          # makes "Sona iPhone" and "Sona Watch" simulators and pairs them (once; safe to repeat)
make build         # the iPhone app, with the watch app inside, for the simulator
make test          # SonaTests
make build-watch   # the watch app alone
make test-watch    # SonaWatchTests
make run ARGS="-debugRecordFile /path/clip.wav -debugAutoRecordSeconds 10"   # build, install, launch on the phone simulator
make run-watch ARGS="-debugFakeRecording"   # the same on the watch simulator
make generate      # only regenerate Sona.xcodeproj
make icon          # redraw the app icon (runs scripts/make-icon.swift from the repo root)
make clean
scripts/widget-snapshots.sh /tmp   # the Live Activity and widgets drawn to PNGs in /tmp, no phone or previews
```

Notes:

- The simulators are our own (`SIM` and `WATCH_SIM` change the names), so nothing else using the usual ones gets in the way.
- Build output is in `build/DerivedData`.
- Only one Xcode build should run at a time. When several run on one Mac, share a lock: `lockf -k /tmp/sona-xcode.lock make build`. This isn't built into the Makefile, so use the same lock file everywhere.
- `make test` and `make test-watch` print only results and errors, and still fail when a test does.
- `scripts/widget-snapshots.sh` builds the widgets' views into a small executable, runs it on the booted phone simulator (`SIM=...` picks another) and prints where each PNG went. It also checks the widgets' text helpers, which unit tests can't reach (they're in an extension).
- Never record from the simulator's mic: it is the Mac's mic. Use `-debugRecordFile`.

## Launch arguments (DEBUG builds only)

`make build` is a Debug build, so these work. Release builds ignore them. Pass them with `ARGS=` or as `xcrun simctl launch <sim> <bundle id> <args>`.

| Argument | App | What it does |
| --- | --- | --- |
| `-debugRecordFile <path>` | iPhone | Recordings play this audio file (any format) in real time instead of the mic. |
| `-debugAutoRecordSeconds N` | iPhone | A recording starts at launch and stops after N seconds. |
| `-debugNotesFolder <path>` | iPhone | That folder stands in for the picked notes folder. |
| `-debugProcessSpool` | iPhone | Turns everything waiting in the spool into notes, prints one line (counts and times, never titles) and quits. |
| `-debugOpenNote latest` | iPhone | Opens the newest note once it's listed (for screenshots). |
| `-debugPlayNote` | iPhone | A note that opens plays from a third of the way in, muted (screenshots of a note playing). |
| `-debugNoModelDownload` | iPhone | With `-debugSkipOnboarding`: the speech model doesn't download (screenshots). |
| `-debugSearch <words>` | iPhone | Home opens with the search open and these words in it. |
| `-debugPlace <name>` | iPhone | Home opens on the notes made at that place. |
| `-debugContinueDisabled` | iPhone | Onboarding's Continue is drawn disabled (screenshots of how that reads). |
| `-debugSkipOnboarding` | iPhone | Onboarding counts as done with defaults: notes On this iPhone (or Other folder when `-debugNotesFolder` is passed), audio 30 days, the model download allowed. |
| `-debugOnboardingStep N` | iPhone | Opens onboarding at screen N (1 welcome, 2 your notes, 3 what Sona asks for) without saving anything. Past screen 1 it allows the model download. |
| `-debugFakeRecording` | Watch | The recording screen with a made-up waveform and no mic. |
| `-debugShowList` | Watch | Opens on the recordings list instead of the button. |

An end-to-end check in the simulator, with a test clip standing in for the mic:

```sh
make run ARGS="-debugRecordFile $PWD/../test-audio/two-voices.wav -debugAutoRecordSeconds 10 -debugNotesFolder /tmp/sona-e2e/picked"
```

The note appears in `/tmp/sona-e2e/picked/Conversations/<day>/`. The first run downloads the speech model into the simulator by itself (the welcome screen's Continue allows it; `-debugSkipOnboarding` does too).

## Release to TestFlight

```sh
make release NOTES="what to test"
```

One command: archive, sign, check the signed app, upload, wait for Apple to process it, then hand it to the "Personal Testing" group and notify it. `NOTES` is the test notes; without it, the last commit's subject is used. `EXPORT_ONLY=1 make release` stops after signing and checks signing without uploading. Don't run it casually: it uploads a build to Apple.

- **The App Store Connect app** is "Sona Notes" (plain "Sona" is taken), app ID `6829732693` (`release.sh` reads `ASC_APP_ID` and `TESTFLIGHT_GROUP_ID` from the environment, with these values as defaults), bundle ID `com.dinilb.sona`. The home screen still says Sona.
- **Build numbers are the time**, `YYMMDDHHMM` (`BUILD=...` overrides it), so there is nothing to bump. The version is `MARKETING_VERSION` in `project.yml`.
- **Signing** is cloud signing with the App Store Connect API key from the active `asc` profile: the key ID comes from `asc auth status`, the issuer from `asc auth issuer-id`, and the `.p8` from `~/.asc/keys/`. Nothing secret is stored in the repo or printed. If it says "No usable asc key", run `asc auth status --validate`.
- **Why it signs ad hoc before export.** The archive is built unsigned (this Mac has no development certificate or device). An unsigned binary carries no entitlements, so export would sign the app without its App Group and the widgets could never see the app's state. So `release.sh` signs each bundle ad hoc with its own entitlements first, innermost first (watch widgets, watch app, widgets, the app), and export then re-signs for the App Store and keeps them. After export it opens the IPA and fails before upload unless the signed IPA matches `project.yml`: the entitlements of each bundle, the App Group on every bundle, iCloud (Production) on the app, no `get-task-allow`, the background modes exactly as declared, and the When In Use location string with no Always string. `../PRIVACY.md` is the privacy policy; it is published at https://dinilb.github.io/sona/privacy.html.

## The app's own iCloud folder

The app's own container (`iCloud.com.dinilb.sona`, no folder to pick) is on. It took one click with the Apple ID, because the App Store Connect API key can't attach an iCloud container to an App ID (Xcode's signing gets `401 NOT_AUTHORIZED` from `/xcbuild/v1/cloudContainers`, and `asc` has no command for it): developer.apple.com > Certificates, Identifiers & Profiles > Identifiers > `com.dinilb.sona` > iCloud > Configure > tick `iCloud.com.dinilb.sona`, done on 6 Nov 2026. The entitlements are in `project.yml`, under the `Sona` target's `entitlements` properties:

```yaml
com.apple.developer.icloud-container-identifiers: [iCloud.com.dinilb.sona]
com.apple.developer.ubiquity-container-identifiers: [iCloud.com.dinilb.sona]
com.apple.developer.icloud-services: [CloudDocuments]
```

`release.sh` adds `com.apple.developer.icloud-container-environment: Production` when it signs, and checks the container is in the signed app. The container is what the iCloud choice in onboarding uses. A picked folder is used only when Other folder is the choice.
