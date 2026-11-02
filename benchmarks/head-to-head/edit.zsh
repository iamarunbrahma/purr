# Voice edit benchmark: puts each case's starting text in the TextEdit test
# document, selects it, holds the app's edit key while the spoken command plays
# into BlackHole, then waits for the text to change and settle.
# usage: zsh edit.zsh purr <id-regex> [tag]
# Same setup as run.zsh: test.txt open in front in TextEdit, BLACKHOLE_INDEX.
zmodload zsh/datetime
B=${0:A:h}
DEV=${BLACKHOLE_INDEX:-1}
APP=$1; PAT=$2; TAG=${3:-edit-$1}
DOC=$B/test.txt
OUT=$B/results/$TAG.tsv
TXT=$B/results/$TAG; mkdir -p $TXT
[[ -f $B/last_synth ]] || print -r -- $EPOCHREALTIME > $B/last_synth

case $APP in
  purr)  down() { $B/tools/key 14 ctrl,alt down }; up() { $B/tools/key 14 ctrl,alt up } ;;  # Control-Option-E
  *) echo "unknown app $APP"; exit 2 ;;
esac

idle_s() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF/1000000000; exit}' }
front_bundle() { lsappinfo info -only bundleid "$(lsappinfo front)" | sed 's/.*="\(.*\)"/\1/' }
synth() { print -r -- $EPOCHREALTIME > $B/last_synth }
user_check() {
  local last=$(<$B/last_synth) i=$(idle_s)
  if (( EPOCHREALTIME - i > last + 2.5 )); then printf 'user active (idle %.1fs)\n' $i; return 1; fi
}
ready() {
  user_check || return 1
  [[ $(front_bundle) == com.apple.TextEdit ]] || { echo "front app is $(front_bundle)"; return 1 }
  [[ $(osascript -e 'tell application "TextEdit" to get path of document 1' 2>/dev/null) == $DOC ]] || { echo "front TextEdit document is not the test one"; return 1 }
}
set_doc() { osascript - "$DOC" "$1" <<'AS' >/dev/null
on run argv
  tell application "TextEdit" to set text of (first document whose path is (item 1 of argv)) to (item 2 of argv)
end run
AS
}
abort() { up; synth; echo "aborted"; exit 1 }
trap abort INT TERM

[[ -f $OUT ]] || print -r -- $'id\tfirst\tfinal\tchars' > $OUT
tail -n +2 $B/edit/cases.tsv | while IFS=$'\t' read -r id start cmd expect; do
  [[ $id =~ $PAT ]] || continue
  ready || exit 1
  set_doc "$start"; print -rn -- "$start" > $B/edit/base.txt; /bin/sleep 0.4
  $B/tools/key 0 cmd tap; synth; /bin/sleep 0.4      # select all
  $B/tools/poll2 $DOC 40 3 $TXT/$id.txt $B/edit/base.txt > $B/poll.out &
  pid=$!
  /bin/sleep 0.6
  down; synth; /bin/sleep 0.5
  ffmpeg -hide_banner -loglevel error -nostdin -re -i $B/edit/$id.wav -f audiotoolbox -audio_device_index $DEV - || abort
  synth; /bin/sleep 0.4
  up; tup=$EPOCHREALTIME; synth
  wait $pid; res=$(<$B/poll.out); synth
  fa=${${res#first=}%% *}; rest=${res#* final=}; fz=${rest%% *}; chars=${${res#* chars=}%% *}
  if (( fa < 0 )); then first=-1; final=-1; else first=$(( fa - tup )); final=$(( fz - tup )); fi
  printf '%s\t%.3f\t%.3f\t%s\n' $id $first $final $chars >> $OUT
  printf '%s first=%.2f final=%.2f chars=%s\n' $id $first $final $chars
  /bin/sleep 1.5
done
