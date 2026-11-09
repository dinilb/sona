# Notes for coding agents

Read README.md and CONTRIBUTING.md first. Sona is a Swift 6 package; `make` wraps it into an app.

## Build and test

- `make` builds `build/Sona.app` (ad hoc signed without a Developer ID) and `build/sona-live-bench`.
- `make test` runs the unit tests. Tests that need the speech models skip without them. To run those too: `SONA_HOME=$PWD/test-home build/sona models`, then `make test`.
- One build at a time. Don't start `swift build` or `swift test` while another is running (wait for `swift-build`, `swift-frontend` and `xctest` to exit).
- Don't run `make install` (it replaces and restarts `/Applications/Sona.app`) or `make release` (it signs and notarizes) unless you're asked to.

## Run it headless

- Always set `SONA_HOME` to a test folder (`$PWD/test-home` is gitignored). Never touch the real `~/Library/Application Support/Sona` or `~/Sona`.
- Never open windows or launch the app the normal way (`open`, Finder): it takes the mic and the fn key and asks for permissions.
- `LIVE_FILE=clip.wav` runs the app's pipeline (live transcript, always-on notes) on a file instead of the mic, with no window, until SIGTERM.
- `LIVE_FILE_MAC=other.wav` beside it plays a second file as this Mac's audio (instead of a Core Audio tap), from the same moment; it needs `"macAudio": true` in the test home's `settings.json`. `scripts/make-mac-audio-clip.sh` makes a pair. Never create a real process tap in a test: it hears whatever the Mac is playing.
- `LIVE_DICTATE=1.0-4.2,8.0-11.5` beside `LIVE_FILE` holds the dictation key over those seconds of the file and writes each result to `dictations-test.jsonl` in the test home instead of pasting. `scripts/dictation-bench.sh all` makes the clips, runs it (mic, with this Mac's audio, quiet) and scores it. Test runs never install key monitors, post key events or touch the clipboard; keep it that way.
- `LIVE_SNAPSHOT=out.png` draws one view to a PNG and exits. Pick it with `LIVE_SNAPSHOT_VIEW=now|day|day:YYYY-MM-DD|conversation|dictations|settings|about|firstrun|pill|copied` (`day` is the newest day; `pill` and `copied` are the dictation pill and its "Copied to clipboard" toast).
- Both refuse to run without `SONA_HOME`. Example: `SONA_HOME=$PWD/test-home LIVE_SNAPSHOT=/tmp/now.png build/Sona.app/Contents/MacOS/Sona`
- Test runs never watch the keyboard or remap Caps Lock (`KeyMonitor.mayTouchKeyboard`). The one exception is `SONA_KEY_PROBE=rightCommand` (a shortcut as written in settings.json, or `record`), which runs only the dictation key monitor, prints each shortcut down, up and interruption with its time, and quits by itself after 20 s; it also needs `SONA_HOME`. Only run it with the user's OK: posted events reach every app (the real Sona and other dictation apps too), and a shortcut with a key swallows that key while the probe runs. Post in short bursts and always post the key-up too.
- The CLI and the MCP server: `build/sona file test-audio/two-voices.wav` (after `make clip`), `scripts/mcp-smoke.sh`.

## iPhone and watch (ios/)

- Read `ios/README.md` first. Build and test with the Makefile in `ios/` (`make build`, `make test`, `make build-watch`, `make test-watch`), not with `swift build`.
- One Xcode build at a time, and share the lock when several agents run on one Mac: `lockf -k /tmp/sona-xcode.lock make build`.
- Use your own simulators: `scripts/sims.sh "<iPhone name>" "<watch name>"` makes and pairs them, and `SIM=` and `WATCH_SIM=` pick them for `make`. Don't borrow the shared "Sona iPhone" and "Sona Watch" if another agent is using them.
- Never record from the simulator's mic: it is the Mac's mic. Use `-debugRecordFile <wav>` (with `-debugAutoRecordSeconds N` and `-debugNotesFolder <dir>`) so the app runs on a file.
- Don't run `make release` unless you're asked: it uploads a build to TestFlight.
- `$SONA_HOME/PhoneInbox` stands in for iCloud Drive in a test home, for the Mac app and for `sona import-phone`. Drop day folders with `.md`, `.json` and `.m4a` in there to try the import.

## Style

- Short, plain-English comments that say why. Match the code around you.
- Keep changes minimal and focused. No new dependencies, network calls, accounts or analytics.
- Never log transcript text or note titles.
- Tests for behaviour changes; before and after numbers for latency, accuracy or weight.

## Commits

- Small commits with plain-English messages that say what changed.
- No AI attribution: no Co-Authored-By trailers or "Generated with" lines for tools. `make release` stops if the history has them.

## Gotchas

- 1 Nov 2026: a key probe (an active event tap) plus synthetic key events and a Caps Lock hidutil remap froze the user's keyboard while he was using the Mac. Never run event taps, post key events or change hidutil on the real Mac without the user's OK at that moment; test runs never install input taps.
