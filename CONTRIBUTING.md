# Contributing

Thanks for helping. Sona's one rule: **stay small, light and local.** Every change should keep or lower idle CPU, memory and the app's size, and add no network calls, accounts or analytics. New dependencies need a very good reason.

## Build and test

You need an Apple Silicon Mac with macOS 14+ and Xcode 26.

```sh
make            # build/Sona.app and build/sona-live-bench
make install    # build, replace /Applications/Sona.app and restart it
make test       # unit tests
make clip       # synthetic test audio (macOS `say` voices; needs ffmpeg)
```

Some tests need the models. Download them once into a throwaway folder and point the tests at it:

```sh
SONA_HOME=$PWD/test-home build/sona models
SONA_TEST_HOME=$PWD/test-home swift test
```

Never test against your real notes: anything that runs the app or CLI by hand should use `SONA_HOME` pointing at a test folder.

The iPhone and Apple Watch app is in `ios/`, built with its own Makefile and XcodeGen: see [ios/README.md](ios/README.md). CI builds and tests the Mac package only.

## Issues

- Bugs and ideas: open an issue from the templates. For anything bigger than a small fix, open one before you start, so we can agree on the approach first.
- Never attach transcripts, notes or audio of real people. `sona.log` never contains what was said, so its lines are fine to paste.
- Security and privacy problems go through [SECURITY.md](SECURITY.md), not a public issue.

## Changes

- Keep pull requests small and focused, with tests for behaviour changes.
- If you touch latency, accuracy or weight, include before and after numbers: `sona-live-bench` for latency, `scripts/score.py` for accuracy, and idle CPU and memory. For idle, run the app headless in a test folder (`SONA_HOME=$PWD/test-home LIVE_FILE=<clip.wav> build/Sona.app/Contents/MacOS/Sona`; it feeds silence after the clip), wait 25 s, then average a few `top` samples. CPU% leaves out the Neural Engine.
- Never put transcript text in logs. Logs name conversations by time (`2026-10-29/14-03`), never by title.
- Don't commit audio of real people. Test clips are generated with `say`, on your Mac, and aren't committed either.
- Small commits with plain-English messages that say what changed. No attribution lines for tools (Co-Authored-By trailers, "Generated with"): the release script refuses a history that has them.

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Licence

By contributing you agree your contribution is licensed under the MIT License (see LICENSE). Credit any code or ideas you take from elsewhere in THIRD_PARTY.md.
