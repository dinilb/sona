# Sona privacy policy

This policy covers Sona for iPhone and Apple Watch (on the App Store as "Sona Notes") and Sona for Mac.

## The short version

- Sona turns your recordings into text **on your device**. Your recordings, transcripts, titles and places are never
  sent to us. We have no server, and no account to make.
- We collect nothing: no analytics, no ads, no tracking, no crash-reporting service.
- Your notes are where you choose: on your device, in your own iCloud Drive, or in a folder you pick.
- Sona goes on the internet for exactly two things: downloading its speech model once (from Hugging Face), and, if you
  allow location, looking up a street name for a note (Apple's map service gets the coordinates, nothing else).

## What Sona keeps, and where

**Recordings and notes.** Each recording becomes a note: a text file with the transcript, a small data file, and the
audio (unless you choose not to keep it). They are stored:

- on this iPhone (or Mac) while they're being made, in the app's private storage, kept out of backups until the note
  is written;
- then where you chose when you set Sona up:
  - **iCloud**: Sona's folder in your own iCloud Drive, so they sync to your other devices and your Mac. Apple stores
    them under its iCloud terms; with Advanced Data Protection on, they are end-to-end encrypted.
  - **On this iPhone**: a folder on the device, included in your iPhone's own iCloud or computer backup.
  - **Another folder**: the folder you picked, which may be in iCloud Drive or another provider's storage.
- on your Mac, if you use Sona for Mac: it copies your iPhone's notes from iCloud Drive into its own notes folder.

**Audio.** You choose how long audio is kept: 30 days (the default), forever, or not at all once the note is
written. In 30-day mode, "Keep audio" on a note keeps that note's audio for good. The Mac keeps its copies under its
own settings: deleting audio or a note on your iPhone doesn't delete the Mac's copy.

**Titles.** On iPhones that support Apple Intelligence, a short title is made by Apple's on-device model. Otherwise
Sona for Mac may title your iPhone's notes with the Mac's own on-device model and save the titles beside your notes in
iCloud Drive. Titles are never made by a server, ours or Apple's Private Cloud Compute.

**Places.** Only if you allow location ("While Using the App"; Sona asks once, when you first set it up):

- Sona takes one location reading when a recording starts and one when it stops. It never tracks you, and has no
  permission to use location in the background, so a recording started or stopped from the Lock Screen may have no
  place.
- The coordinates are saved in the note (to about 11 metres), and in the app's private storage on the device until
  the note has its place (at most 30 days).
- To show a street name such as "4 Main St", Sona sends the coordinates, and nothing else, to Apple's map service
  (MapKit reverse geocoding), only while Sona is on screen. Apple handles that request under Apple's privacy policy.
- With Approximate Location, a note shows the town, not the street.
- Apple Watch recordings get no place.
- You can turn location off any time in Settings > Apps > Sona > Location. New notes then have no place.

**Apple Watch.** Recordings made on the watch are sent to your iPhone over Apple's watch connection (directly between
your devices) and deleted from the watch once the iPhone has saved them.

**The app's log.** Sona keeps a short log of what it did on the device (a recording started or stopped, a note was
written and how long that took, errors by their code), to help work out problems such as a note that's slow to arrive.
It never holds your words, titles, file names or places. When your notes go to iCloud, the newest part of it (about
256 KB) is also copied to `Diagnostics/iPhone.log` in Sona's folder in your own iCloud Drive, so you can read it on your
Mac or in the Files app. It goes nowhere else. It's replaced every time it's copied (when Sona opens or leaves the
screen, at most once a minute while it's on screen, within seconds while it works in the background), so deleting it
clears it only until the next copy. The first copy after you choose iCloud includes what was logged before. With On this
iPhone or another folder there's no copy, and choosing one of those deletes the copy from iCloud.

**Widgets, Live Activity and notifications.** The Lock Screen and Home Screen can show that Sona is recording, how long
for, and your newest note's title (the Lock Screen hides the title until the phone is unlocked). Notifications (a
paused or stopped recording, a recording still going) are made on the device. None of this leaves your devices.

## What goes over the network

1. **The speech model, once.** About 480 MB, downloaded from Hugging Face (huggingface.co) the first time you set Sona
   up, and again only if it's missing. Like any download, Hugging Face sees your device's IP address and the files
   requested. Nothing of yours is sent.
2. **Street names, if you allow location.** Coordinates go to Apple's map service, as described above.
3. **iCloud, if you choose it.** Your notes sync through your own iCloud account. That's between you and Apple; we
   never see it.

There is nothing else: no analytics, advertising, tracking, crash reports or accounts.

## Deleting

- Delete a note in Sona: its text, data and audio go from where Sona keeps them (and from iCloud, if that's where it
  is). Copies Sona for Mac already made stay on the Mac until you delete them there.
- Delete notes in the Files app (iCloud Drive > Sona) or in Finder.
- Delete the app: everything Sona kept on the iPhone goes. Notes in iCloud stay in your iCloud Drive until you delete
  them there or in Settings > [your name] > iCloud > Manage Storage.
- Places: turn off location for Sona, and delete a note to remove its place.

## The microphone

Sona records only when you start a recording (in the app, on the watch, from a widget, the Lock Screen, Control
Center, the Action button or Siri) and stops when you stop it. While it records, iOS shows its recording indicator and
Sona shows a Live Activity with a Stop button.

## Recording other people

Recording laws differ by place: some need everyone's consent before a conversation is recorded. You're responsible
for recording lawfully. Speaker labels come from comparing voices on your device, and no voiceprints are kept.

## Children

Sona isn't directed at children under 13 and collects nothing from anyone.

## Changes

If this policy changes, the new version is posted here with a new date. Since we collect nothing, there's no one for
us to notify by email.

## Contact

Sona is made by Dinil Balasuriya. Questions about this policy: [open an issue on GitHub](https://github.com/dinilb/sona/issues).
