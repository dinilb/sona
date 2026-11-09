#!/bin/zsh
# Builds the test audio with macOS `say` and ffmpeg (adapted from an earlier prototype):
#   test-audio/two-voices.wav         Samantha and Daniel taking turns, ~1.5 min, 0.6 s between turns
#   test-audio/two-voices.turns.tsv   start, end, voice, text for every turn (for scripts/score.py)
#   test-audio/three-voices.wav       three similar male voices, short turns (speaker separation)
#   test-audio/two-conversations.wav  conversation A, 20 s of silence, conversation B (for `sona simulate`)
set -euo pipefail
cd "${0:A:h}/.."
rm -rf test-audio/parts && mkdir -p test-audio/parts

lines_a=(
  "Samantha|Hey Daniel, did you get a chance to look at the budget for the March launch?"
  "Daniel|I did. Marketing wants forty thousand dollars, which feels high for a soft launch."
  "Samantha|Agreed. What if we cut the paid ads and spend more on the community events instead?"
  "Daniel|That could work. The meetup in Brisbane last month brought in nearly two hundred sign ups."
  "Samantha|Right, and it only cost us about three thousand dollars. Can you send me those numbers by Friday?"
  "Daniel|Sure, I'll put them in a spreadsheet tonight. Should I include the churn data too?"
  "Samantha|Yes please. Also, remind me who's handling the press release."
  "Daniel|Priya is writing it. She said the first draft will be ready on Wednesday morning."
  "Samantha|Perfect. Let's meet again on Thursday at two to make the final call."
  "Daniel|Sounds good. I'll book the small meeting room and send out the invite."
  "Samantha|One more thing. The investors asked for a demo of the new onboarding flow."
  "Daniel|We can show the prototype. It's rough, but the sign up takes under ninety seconds now."
  "Samantha|Great, that's exactly the kind of number they want to hear."
  "Daniel|I'll also record a short video walkthrough in case the live demo breaks."
  "Samantha|Smart. Last time the wifi in that office was terrible. Talk soon."
)
lines_b=(
  "Daniel|Quick question before I head out. Did the designer send over the new logo files?"
  "Samantha|Not yet. She promised them by tomorrow afternoon, with a dark mode version as well."
  "Daniel|Okay. Can you forward them to me as soon as they land? I want them in the pitch deck."
  "Samantha|Will do. Have a good evening, and say hi to your sister for me."
)

# Harder: three similar male voices, short turns and one-word replies.
lines_c=(
  "Daniel|So the plan is to launch the beta to fifty users next Monday."
  "Eddy (English (UK))|Fifty feels small. Why not a hundred?"
  "Fred|Because support is just me right now."
  "Daniel|Fair."
  "Eddy (English (UK))|Okay, fifty. But we need the feedback form working before then."
  "Fred|Yeah."
  "Daniel|Who owns the form?"
  "Fred|I can do it tomorrow if nobody else wants it."
  "Eddy (English (UK))|Take it. I'll write the welcome email instead."
  "Daniel|Great. And I'll pick the fifty from the waitlist tonight."
  "Fred|Send me the list when it's done."
  "Eddy (English (UK))|Right."
)

# say -> aiff -> 16 kHz mono wav, 0.6 s of silence after each turn. Writes the turn table as it goes.
render() {
  local name=$1; shift
  local -a entries=("$@")
  local -a list=()
  local i=0 t=0.0
  : > test-audio/$name.turns.tsv
  for entry in $entries; do
    local voice=${entry%%|*} text=${entry#*|}
    i=$((i+1))
    local f=$(printf "test-audio/parts/%s-%02d" $name $i)
    say -v "$voice" -o "$f.aiff" "$text"
    ffmpeg -hide_banner -loglevel error -y -i "$f.aiff" -af "aresample=16000,apad=pad_dur=0.6" -ar 16000 -ac 1 "$f.wav"
    local d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f.wav")
    local speech=$(( d - 0.6 ))
    printf "%.2f\t%.2f\t%s\t%s\n" $t $(( t + speech )) "$voice" "$text" >> test-audio/$name.turns.tsv
    t=$(( t + d ))
    list+=("$f.wav")
  done
  # The concat demuxer: every part has the same format, so the samples are just joined.
  : > test-audio/parts/$name.list
  for f in $list; do echo "file '${f:A}'" >> test-audio/parts/$name.list; done
  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i test-audio/parts/$name.list -c:a pcm_s16le -ar 16000 -ac 1 test-audio/$name.wav
}

render two-voices "${lines_a[@]}"
render conv-b "${lines_b[@]}"
render three-voices "${lines_c[@]}"

# A, 20 s of silence, B.
ffmpeg -hide_banner -loglevel error -y -f lavfi -t 20 -i anullsrc=r=16000:cl=mono -c:a pcm_s16le test-audio/parts/silence16.wav
printf "file '%s'\nfile '%s'\nfile '%s'\n" "${PWD}/test-audio/two-voices.wav" "${PWD}/test-audio/parts/silence16.wav" "${PWD}/test-audio/conv-b.wav" > test-audio/parts/both.list
ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i test-audio/parts/both.list -c:a pcm_s16le -ar 16000 -ac 1 test-audio/two-conversations.wav

rm -rf test-audio/parts
for f in two-voices two-conversations; do
  echo "wrote test-audio/$f.wav ($(ffprobe -v error -show_entries format=duration -of csv=p=0 test-audio/$f.wav) s)"
done
