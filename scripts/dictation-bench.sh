#!/bin/zsh
# Hold-to-dictate, end to end, headless: the app plays a test file as the mic and presses the dictation key at set
# times (LIVE_DICTATE), then this scores what each dictation would have pasted. Needs `make` first, ffmpeg, and the
# live models in the test home (SONA_HOME=$PWD/test-home build/sona models).
#
#   scripts/dictation-bench.sh [mic|mac|quiet|all] [label]
#     mic    the mic alone
#     mac    the same, with this Mac playing continuous speech the whole time (LIVE_FILE_MAC, "macAudio": true);
#            the mic doesn't hear it (headphones), so this measures the two tracks sharing one engine
#     quiet  the mic alone, 20 dB quieter (someone speaking softly, or far from the mic)
#   Results: test-home/bench/<label>-<condition>.jsonl, scored by scripts/dictation-score.py. Extra settings for the
#   app can be passed in the environment (LIVE_DICTATE_TAIL=0.3, say).
#
# The clips (made once, with macOS `say`): 30 dictations, each a sentence with quiet around it. In the first 24 the
# key goes down right as the speech starts or 0.1 s after it started, and comes up 0.2 s after it ends, right as it
# ends, or 0.15 s before it ends. In the last 6 the same voice says something else first ("Right, got it.") that
# ends 0.3 to 0.8 s before the dictated sentence: none of it may be pasted.
set -euo pipefail
cd "${0:A:h}/.."
which=${1:-all}
label=${2:-run}
home=$PWD/test-home
app=build/Sona.app/Contents/MacOS/Sona
[[ -x $app ]] || { echo "build first: make"; exit 1; }
[[ -d $home/Models/parakeet-unified-en-0.6b ]] || { echo "no live models in $home (SONA_HOME=$home build/sona models)"; exit 1; }

sentences=(
  "Can you send me the updated pricing sheet before lunch tomorrow?"
  "Remind me to call the dentist on Thursday afternoon."
  "The meeting with Sam has moved to the afternoon."
  "Please book a table at the Italian place near the river."
  "I think we should ship the beta to a small group next week."
  "Add milk, eggs and coffee beans to the shopping list."
  "Thanks for the feedback, I will fix the onboarding screen tonight."
  "Let's push the launch back a little so support is ready."
  "Write a short note to the landlord about the broken heater."
  "Make sure the invoice goes out before the end of the month."
  "Hey, are you free for a quick call after the standup?"
  "The new logo looks great, but the green feels a bit too bright."
  "Schedule a review of the benchmark results on Monday."
  "Our flight lands in Brisbane early in the morning."
  "Move the database backup so it runs every night."
  "Can we cut the paid ads and spend more on community events?"
  "Tell the team the office is closed on Friday for the holiday."
  "Order a new charger for the laptop, the old one stopped working."
  "The test passed on my machine but failed in the build."
  "Please summarise the main risks before the investor meeting."
  "I'll pick up the keys from reception after work."
  "Send Priya the draft of the press release for review."
  "We need better error messages when the microphone is missing."
  "Good morning, here is the plan for today's sprint."
  "Book a meeting room for the design review."
  "Remember to water the plants before the trip."
  "Can you check whether the backup finished last night?"
  "Let's keep the pricing page simple for now."
  "Ask the landlord when the plumber is coming."
  "Put the slides in the shared folder before noon."
)
# Said just before the last 6, with this much quiet before the dictated sentence.
preludes=("That sounds good." "Okay, one more thing," "Right, got it." "Sure, no worries," "Thanks, that helps." "Alright, next one,")
gaps=(0.3 0.5 0.8 0.3 0.5 0.8)
voices=(Samantha Karen)
# Key down after the speech starts, key up after it ends (seconds), cycled.
downs=(0 0.1)
ups=(0.2 0 -0.15)

mic=test-audio/dictate-mic.wav
quiet=test-audio/dictate-quiet.wav
mac=test-audio/dictate-mac.wav
table=test-audio/dictate.tsv

# A `say` line as 16 kHz mono, with the voice's own silence trimmed off both ends.
speak() {
  say -v "$1" -o "$3.aiff" "$2"
  ffmpeg -hide_banner -loglevel error -y -i "$3.aiff" -af \
    "aresample=16000,silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse" \
    -ar 16000 -ac 1 "$3.wav"
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$3.wav"
}

quietness() { ffmpeg -hide_banner -loglevel error -y -f lavfi -t $1 -i anullsrc=r=16000:cl=mono -c:a pcm_s16le $2; }

make_clips() {
  local parts=test-audio/parts-dictate
  rm -rf $parts && mkdir -p $parts
  : > $table
  local -a list=()
  local t=3.0 i=0
  quietness 3 $parts/lead.wav
  list+=($parts/lead.wav)
  for text in $sentences; do
    i=$((i+1))
    local voice=${voices[$(( (i - 1) % ${#voices} + 1 ))]}
    local f=$(printf "%s/%02d" $parts $i)
    local before="-" said="-" down=0 up=0.2
    if (( i > 24 )); then
      # Something else first, then a short pause, then the dictation (key down as it starts).
      local k=$(( i - 24 ))
      local pd=$(speak "$voice" "${preludes[$k]}" "$f.pre")
      quietness ${gaps[$k]} "$f.gap.wav"
      list+=("$f.pre.wav" "$f.gap.wav")
      t=$(( t + pd + ${gaps[$k]} ))
      before="${gaps[$k]}"
      said="${preludes[$k]}"
    else
      down=${downs[$(( (i - 1) % ${#downs} + 1 ))]}
      up=${ups[$(( ((i - 1) / ${#downs}) % ${#ups} + 1 ))]}
    fi
    local d=$(speak "$voice" "$text" "$f")
    quietness 3 "$f.after.wav"
    list+=("$f.wav" "$f.after.wav")
    # key down, key up, speech start, speech end, voice, text, then for the last 6: the quiet after what was said
    # before, and what it was (else -)
    printf "%.3f\t%.3f\t%.3f\t%.3f\t%s\t%s\t%s\t%s\n" $(( t + down )) $(( t + d + up )) $t $(( t + d )) "$voice" "$text" "$before" "$said" >> $table
    t=$(( t + d + 3.0 ))
  done
  : > $parts/list
  for f in $list; do echo "file '${f:A}'" >> $parts/list; done
  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i $parts/list -c:a pcm_s16le -ar 16000 -ac 1 $mic
  ffmpeg -hide_banner -loglevel error -y -i $mic -af "volume=-20dB" -c:a pcm_s16le -ar 16000 -ac 1 $quiet
  # This Mac: a narrated video that never stops, longer than the mic clip.
  say -v Daniel -o $parts/narration.aiff "Welcome back to the channel. Today we are walking through the old harbour, where the \
ferries used to dock before the bridge was built. The warehouses along the water have been turned into cafes, studios and \
a small museum about the river. If you look to the left, you can see the crane that lifted cargo for almost a century. \
Locals say the best coffee in the city is served from the little window under the stairs. Further along, the path climbs \
towards the gardens, where the fig trees are older than most of the buildings. On weekends there is a market with fresh \
bread, honey and flowers, and a band usually plays near the fountain. We will stop here for a moment and listen."
  ffmpeg -hide_banner -loglevel error -y -stream_loop 8 -i $parts/narration.aiff -af aresample=16000 -t $(( t + 30 )) \
    -c:a pcm_s16le -ar 16000 -ac 1 $mac
  rm -rf $parts
  echo "made $mic ($(ffprobe -v error -show_entries format=duration -of csv=p=0 $mic) s), $quiet, $mac, $table (${#sentences} dictations)"
}

[[ -f $mic && -f $quiet && -f $mac && -f $table ]] || make_clips

# Settings for a run: always-on (as most people use it), and this Mac's audio on or off.
settings() {
  python3 -I - "$home/settings.json" "$1" <<'PY'
import json, os, sys
path, mac = sys.argv[1], sys.argv[2] == "1"
s = json.load(open(path)) if os.path.exists(path) else {}
s.update({"onboarded": True, "alwaysOn": True, "dictation": True, "macAudio": mac, "mcp": False})
json.dump(s, open(path, "w"), indent=2)
PY
}

run() {
  local cond=$1
  local spec=$(awk -F'\t' '{printf "%s%s-%s", (NR>1?",":""), $1, $2}' $table)
  local n=$(wc -l < $table | tr -d ' ')
  local file=$mic
  [[ $cond == quiet ]] && file=$quiet
  local dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $file)
  local out=$home/dictations-test.jsonl
  mkdir -p $home/bench
  # A clean slate: nothing left in the spool to transcribe during the run.
  rm -rf $home/Spool $home/Notes $home/Live $out
  settings $([[ $cond == mac ]] && echo 1 || echo 0)
  local -a env=(SONA_HOME=$home LIVE_FILE=$file LIVE_DICTATE=$spec)
  [[ $cond == mac ]] && env+=(LIVE_FILE_MAC=$mac)
  echo "==> $label/$cond: $n dictations over ${dur%.*} s"
  env $env $app &
  local pid=$!
  local waited=0 limit=$(( ${dur%.*} + 150 )) peak=0
  while (( waited < limit )); do
    sleep 2
    waited=$((waited + 2))
    local rss=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ')
    [[ -n $rss ]] && (( rss > peak )) && peak=$rss
    local got=$( [[ -f $out ]] && wc -l < $out | tr -d ' ' || echo 0)
    (( got >= n )) && break
    kill -0 $pid 2>/dev/null || break
  done
  sleep 2  # the last one's extra passes
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  cp $out $home/bench/$label-$cond.jsonl 2>/dev/null || : > $home/bench/$label-$cond.jsonl
  echo "peak memory (RSS): $(( peak / 1024 )) MB"
  python3 -I scripts/dictation-score.py $table $home/bench/$label-$cond.jsonl
}

case $which in
  mic|mac|quiet) run $which ;;
  all) run mic; run mac; run quiet ;;
  *) echo "usage: $0 [mic|mac|quiet|all] [label]"; exit 2 ;;
esac
