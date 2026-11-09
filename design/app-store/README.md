# App Store images

The screenshots for Sona Notes' App Store listing, the optional App Store header and the GitHub social preview. Every
screen in them is a real capture of the Debug build in the simulator. The notes, names, places and voices are made up
(`sample-notes/make-notes.py`); nothing comes from anyone's real notes.

Re-render everything after changing a caption or a capture:

```sh
design/app-store/render.sh
```

It opens `screens.html` in headless Chrome (a throwaway profile, never your signed-in Chrome) at each image's exact
size, strips the alpha channel (App Store Connect refuses PNGs with one) and prints every file's size. The captions are
plain text in `screens.html` (the `images` table at the bottom); `\n` is where a caption breaks.

## The files

Sizes from Apple's screenshot specifications (checked 9 Nov 2026). One iPhone set covers every iPhone: App Store
Connect scales the large display down for the smaller ones.

| File | Size | App Store Connect slot | Shows |
| --- | --- | --- | --- |
| `iphone-6.9-01.png` | 1320 x 2868 | iPhone with Dynamic Island (large display) | "Tap record. Sona writes it down." A recording: the time, the red wave, Stop. |
| `iphone-6.9-02.png` | 1320 x 2868 | same | "Transcribed on your iPhone, never uploaded." A note playing: title, place, speakers, the line being played. |
| `iphone-6.9-03.png` | 1320 x 2868 | same | "Record from your wrist or Lock Screen." The watch recording screen, scaled up in a flat watch. |
| `iphone-6.9-04.png` | 1320 x 2868 | same | "Plain Markdown files in your iCloud." Home in dark mode (not the Files app: see below). |
| `iphone-6.9-05.png` | 1320 x 2868 | same | "Find any note by day or place." Home filtered to one place. |
| `iphone-6.9-06.png` | 1320 x 2868 | same | "No account. No ads. No tracking." Onboarding's first screen. |
| `apple-watch-01.png` | 422 x 514 | Apple Watch (Ultra 4 and 3 size; one set for every watch) | The record button. |
| `apple-watch-02.png` | 422 x 514 | same | Recording: the time, the wave, Stop. |
| `header-3840x1646.png` | 3840 x 1646 | Product page header (optional) | The icon, "Sona" and one line. |
| `../social/social-preview.png` | 1280 x 640 | GitHub: Settings > Social preview | The icon, "Sona", one line, "Open source". |

`captures/` has the raw simulator screenshots the images are drawn from (iPhone 17 Pro Max, iOS 27.2, status bar set
to 9:41 with full bars; Apple Watch Ultra 4, watchOS 27.2); `home.png` (light) and `search.png` (searching "budget",
which finds notes by what was said) are spares for another caption. `site/img/screen-home.png` and `screen-note.png` are the
same notes captured on an iPhone 17 Pro (1206 x 2622).

## Making the captures again

1. `python3 design/app-store/sample-notes/make-notes.py /tmp/sona-shots/notes` writes the made-up notes (`.md`,
   `.json`, `.m4a` made with `say`, in NoteWriter's format) and `/tmp/sona-shots/recording.wav`, the clip the
   recording screen plays instead of the microphone.
2. Build (`cd ios && lockf -k /tmp/sona-xcode.lock make build SIM="<your iPhone>"`), make your own simulators,
   install, then
   `xcrun simctl status_bar <udid> override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`.
3. `python3 design/app-store/capture.py <udid> /tmp/sona-shots/notes <out dir> home note search place recording welcome`
   relaunches the app with each screen's launch arguments and takes a few shots once it has drawn. Pick the best and
   copy it into `captures/`.
4. Watch: install `Sona.app/Watch/SonaWatch.app` on the paired watch, launch `com.dinilb.sona.watchkitapp` (the button)
   and again with `-debugFakeRecording`, and take `xcrun simctl io <watch> screenshot`.

A fresh simulator asks for notifications at the first recording and for location after it, and the keyboard shows a
"slide to type" tip the first time: answer them once, and turn the tip off with
`xcrun simctl spawn <udid> defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true`. Don't
kill the app while it records: the next launch says "Sona was closed while it was recording". Recordings wait in the
spool (the app's `Library/Application Support/Sona/Spool`) for the speech model and show on Home: delete them before
the next shot.

## Not in this set

- The Lock Screen. The caption of image 3 says "or Lock Screen", but only the watch is shown. In the simulator the
  Live Activity drew its timer as "1:--" (the dimmed always-on style), and with the 9:41 override on it read "Not
  recording" because the override also moves the Lock Screen's clock to 1 January.
- The Files app. iCloud isn't signed in on the simulator, so image 4 shows Home rather than the Markdown files in
  iCloud Drive.
- iPhone Duo. Apple will want screenshots for it from April 2027 for apps built with the iOS 27.1 SDK or later.
- The watch clock can't be set (watchOS has no status bar override), so the watch images show the real time.
