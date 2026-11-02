# Dictation benchmark runner: plays each manifest clip into BlackHole while
# holding the app's push-to-talk key, then times the text arriving in the
# TextEdit test document.
# usage: zsh run.zsh <purr|wispr|sw> <id-regex> [tag]
# Keep test.txt (next to this script) open in front in TextEdit. BLACKHOLE_INDEX
# is BlackHole's number in the list from
# `ffmpeg -f lavfi -i anullsrc -t 0.1 -f audiotoolbox -list_devices true -`
# (default 1). MANIFEST picks another clip list.
zmodload zsh/datetime
B=${0:A:h}
DEV=${BLACKHOLE_INDEX:-1}
APP=$1; PAT=$2; TAG=${3:-$1}
DOC=$B/test.txt
OUT=$B/results/$TAG.tsv
TXT=$B/results/$TAG; mkdir -p $TXT
[[ -f $B/last_synth ]] || print -r -- $EPOCHREALTIME > $B/last_synth

case $APP in
  purr)  down() { $B/tools/ropt down }; up() { $B/tools/ropt up } ;;            # Right Option
  wispr) down() { $B/tools/fnkey down }; up() { $B/tools/fnkey up } ;;          # fn
  sw)    down() { $B/tools/key 5 cmd down }; up() { $B/tools/key 5 cmd up } ;;  # Command-G
  *) echo "unknown app $APP"; exit 2 ;;
esac

idle_s() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF/1000000000; exit}' }
front_bundle() { lsappinfo info -only bundleid "$(lsappinfo front)" | sed 's/.*="\(.*\)"/\1/' }
synth() { print -r -- $EPOCHREALTIME > $B/last_synth }
# The user is back if the idle timer reset after this script's last synthetic event.
user_check() {
  local last=$(<$B/last_synth) i=$(idle_s)
  if (( EPOCHREALTIME - i > last + 2.5 )); then printf 'user active (idle %.1fs)\n' $i; return 1; fi
}
ready() {
  user_check || return 1
  [[ $(front_bundle) == com.apple.TextEdit ]] || { echo "front app is $(front_bundle)"; return 1 }
  [[ $(osascript -e 'tell application "TextEdit" to get path of document 1' 2>/dev/null) == $DOC ]] || { echo "front TextEdit document is not the test one"; return 1 }
  [[ -z $(ioreg -l -w 0 | /usr/bin/grep -o 'kCGSSessionSecureInputPID"=[0-9]*') ]] || { echo "Secure Input is on"; return 1 }
}
set_doc() { osascript -e "tell application \"TextEdit\" to set text of (first document whose path is \"$DOC\") to \"\"" >/dev/null }
abort() { up; synth; echo "aborted"; exit 1 }
trap abort INT TERM

[[ -f $OUT ]] || print -r -- $'id\tblock\tdur\tfirst\tfinal\tchars\tstart\tgap\ttup' > $OUT
tail -n +2 ${MANIFEST:-$B/bench/manifest.tsv} | while IFS=$'\t' read -r id block file ref terms note; do
  [[ $id =~ $PAT ]] || continue
  clip=$B/bench/clips/$file
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $clip </dev/null)
  # No-text wait after release: long clips can take a while to transcribe.
  timeout=$(( dur > 60 ? 120 + dur / 2 : 20 ))
  ready || exit 1
  set_doc; /bin/sleep 0.4
  # Warm poller first, so its startup isn't counted; times are relative to key-up.
  pf=$B/poll.out
  export POLL_MARKER=$B/released; rm -f $POLL_MARKER
  $B/tools/poll $DOC $(( dur + timeout + 2 )) 2.5 $TXT/$id.txt > $pf &
  ppid_=$!
  /bin/sleep 0.6
  start=$EPOCHREALTIME
  down; synth
  /bin/sleep 0.5
  ffmpeg -hide_banner -loglevel error -nostdin -re -i $clip -f audiotoolbox -audio_device_index $DEV - || abort
  synth; /bin/sleep 0.4
  up; tup=$EPOCHREALTIME; synth; : > $POLL_MARKER
  wait $ppid_
  res=$(<$pf)
  synth
  fa=${${res#first=}%% *}; rest=${res#* final=}; fz=${rest%% *}; chars=${${res#* chars=}%% *}; gap=${res##* gap=}
  if (( fa < 0 )); then first=-1; else first=$(( fa - tup )); fi
  final=$(( fz - tup ))
  printf '%s\t%s\t%.2f\t%.3f\t%.3f\t%s\t%.3f\t%s\t%.3f\n' $id $block $dur $first $final $chars $start $gap $tup >> $OUT
  printf '%s %s dur=%.1f first=%.3f final=%.3f chars=%s gap=%s\n' $id $block $dur $first $final $chars $gap
  /bin/sleep 1.2
done
