#!/bin/zsh
# Test audio for hearing this Mac's audio as its own track (macOS `say` and ffmpeg):
#   test-audio/mac-audio.wav       what the Mac plays: a narrated video (Karen), with pauses
#   test-audio/mac-room.wav        what the mic hears: two people in the room (Samantha, Daniel) plus the video
#                                  coming back through the speakers, 80 ms late and 10 dB quieter
#   test-audio/mac-room.turns.tsv  start, end, track, voice, text for every line
# Daniel talks over the video once, and Samantha repeats a few of its words straight after it ("Forty cups an
# hour?"): both must stay.
# Run it headless with the two side by side (see README, Build and test):
#   LIVE_FILE=test-audio/mac-room.wav LIVE_FILE_MAC=test-audio/mac-audio.wav
set -euo pipefail
cd "${0:A:h}/.."
rm -rf test-audio/parts-mac && mkdir -p test-audio/parts-mac

# start (s) | track | voice | text
lines=(
  "0.5|room|Samantha|Did you see the video Priya sent about the new office?"
  "4.0|mac|Karen|Welcome back to the channel. Today we are touring the new harbour office in Brisbane."
  "6.4|room|Daniel|That's the building near the ferry."
  "11.5|room|Daniel|Oh, this is it. Let it play for a bit."
  "15.0|mac|Karen|The kitchen has a coffee machine that makes forty cups an hour."
  "18.5|room|Samantha|Forty cups an hour?"
  "21.5|mac|Karen|And the rooftop terrace looks straight over the river."
  "26.0|room|Daniel|Okay, pause it there. I think we should book a visit for Thursday."
  "30.5|room|Samantha|Sounds good, I'll email them tonight."
  "34.0|mac|Karen|Thanks for watching, and don't forget to subscribe for more office tours."
)

room=() mac=()
: > test-audio/mac-room.turns.tsv
i=0
for entry in $lines; do
  i=$((i+1))
  local start=${entry%%|*} rest=${entry#*|}
  local track=${rest%%|*}; rest=${rest#*|}
  local voice=${rest%%|*} text=${rest#*|}
  local f=$(printf "test-audio/parts-mac/%02d" $i)
  say -v "$voice" -o "$f.aiff" "$text"
  local ms=$(printf "%.0f" $(( start * 1000 )))
  ffmpeg -hide_banner -loglevel error -y -i "$f.aiff" -af "aresample=16000,adelay=${ms}" -ar 16000 -ac 1 "$f.wav"
  local d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f.aiff")
  printf "%.2f\t%.2f\t%s\t%s\t%s\n" $start $(( start + d )) $track "$voice" "$text" >> test-audio/mac-room.turns.tsv
  if [[ $track == mac ]]; then mac+=("$f.wav"); else room+=("$f.wav"); fi
done

# Mix each track's lines (amix pads the shorter ones with silence; normalize=0 keeps their levels).
mix() {
  local out=$1; shift
  local -a args=() ; for f in "$@"; do args+=(-i "$f"); done
  ffmpeg -hide_banner -loglevel error -y "${args[@]}" -filter_complex "amix=inputs=$#:duration=longest:normalize=0" \
    -c:a pcm_s16le -ar 16000 -ac 1 "$out"
}
mix test-audio/mac-audio.wav "${mac[@]}"
mix test-audio/parts-mac/room.wav "${room[@]}"
# The mic: the room, plus the video through the speakers (80 ms late, 10 dB down), then 2 s of quiet.
ffmpeg -hide_banner -loglevel error -y -i test-audio/parts-mac/room.wav -i test-audio/mac-audio.wav -filter_complex \
  "[1]adelay=80,volume=0.316[echo];[0][echo]amix=inputs=2:duration=longest:normalize=0,apad=pad_dur=2" \
  -c:a pcm_s16le -ar 16000 -ac 1 test-audio/mac-room.wav
rm -rf test-audio/parts-mac
echo "test-audio/mac-audio.wav ($(ffprobe -v error -show_entries format=duration -of csv=p=0 test-audio/mac-audio.wav) s), test-audio/mac-room.wav"
