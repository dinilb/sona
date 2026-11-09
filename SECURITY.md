# Security and privacy

Sona records what your microphone hears, so bugs that leak audio or transcripts matter.

## Reporting a problem

Please don't open a public issue for a security or privacy problem. Use [GitHub's private vulnerability reporting](https://github.com/dinilb/sona/security/advisories/new) on this repository (Security → Report a vulnerability). Include what you saw, how to reproduce it, and the macOS and app versions. You'll get a reply within a week.

## What's in scope

- Audio, transcripts or notes leaving the Mac, or being readable by other users or apps they shouldn't be.
- Transcript text appearing in logs.
- The MCP server reading or writing outside the notes folder.
- Anything that records when the app says it's paused or stopped.

## How it's built to be private

- No network use except downloading models (Hugging Face). The iPhone app has one more: it looks up a street name for a place with Apple's map service (coordinates only, only with the app on screen and location allowed). Its location fixes stay on the iPhone, out of backups, until the note has its place.
- No accounts, analytics or crash reporting.
- Audio is spooled to `~/Library/Application Support/Sona/Spool` until its note is written, then deleted (kept only if `keepAudio` is set in settings.json). With always-on off, no audio is kept at all.
- The iPhone app (ios/) keeps each recording's audio on purpose, as an `.m4a` next to its note, on the iPhone, in the iCloud Drive folder you pick, and on the Mac once imported. Its spool and its local notes folder are kept out of iCloud Backup. A note only moves to iCloud Drive once it's whole (its WAV turned into the m4a).
- Notes and their folders are private to your account (files 0600, folders 0700), and so is the support folder and everything in it (settings, log, spool, search index).
- The iPhone's notes say where they were recorded (a street name and its coordinates). On the Mac the street names are in the search index, so a search finds them, and the MCP server shows them to AI apps; the coordinates stay in the note. Neither is ever logged.
- The app is signed with the hardened runtime (every build, not just releases), so another process can't inject a library and borrow its microphone, Accessibility or System Audio Recording permission.
- A settings file that can't be read never turns anything on: always-on, AI access and Mac audio stay off, and the iPhone import doesn't run, until a setting is changed. A settings file without the AI access switch reads as off.
- Dictation never pastes into a password field, and never puts a password manager's copied secret back on the clipboard.
- The MCP server runs only when an AI app starts it, talks over stdio only, and only reads the notes and the live transcript (plus speaker renames, which rewrite the note). With AI access off in Settings, it answers nothing else. It never reads, renames or deletes through a symlink in the notes folder.
- What an AI app does with what it reads is up to that app.
