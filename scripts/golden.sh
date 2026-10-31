#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded jobs called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through qwen3-inproc with the
# lane configuration, requests and seeding the worker uses. Each pair must be byte for byte the same WAV.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases (int8): ryan with no emotion, ryan angry, aiden with a delivery description, vivian in Chinese with a pause, and
# two designed samples (seed 7 and 8) of one description.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/qwen3-tts.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product qwen3-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/qwen3-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# Qwen3-TTS golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
same() { # name, gpp wav, inproc wav
  local a=$(shasum -a 256 $2 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $3 2>/dev/null | cut -c1-16)
  if [[ -n $a && $a == $b ]]; then pass=$((pass+1)); say "PASS  $1: byte-identical, sha256 $a…"
  else fail=$((fail+1)); say "FAIL  $1: differs ($a… / $b…)"; fi
}
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' }

# speak <name> <seed> <params json> <text> [inproc args…]
speak() {
  local name=$1 seed=$2 params=$3 text=$4; shift 4
  $CHECK $B --operation audio.speak --model qwen3-tts --lane int8 --params $params --seed $seed --text "text=$text" \
    --models-root "$MODELS" --budget 64000000000 --timeout 900 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | tail -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.wav
  $INPROC speak --seed $seed --text "$text" --models-root "$MODELS" --out $OUT/$name-inproc.wav "$@" 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  same $name $OUT/$name-gpp.wav $OUT/$name-inproc.wav
}

speak ryan 42 '{"voice":"ryan"}' 'Gaea speaks. This sentence came from a signed plugin, over its own protocol.' --voice ryan
speak angry 42 '{"voice":"ryan","emotion":{"label":"angry"}}' 'I told you three times already. Put it back where you found it.' --voice ryan --emotion angry
speak described 3 '{"voice":"aiden","emotion":{"description":"tired, as if after a very long day"}}' 'Fine. I will do it tomorrow morning, first thing.' --voice aiden --emotion-description 'tired, as if after a very long day'
speak vivian 1 '{"voice":"vivian","language":"zh"}' '今天天气很好，我们去公园散步吧。[pause 1s] 你觉得怎么样？' --voice vivian --language zh

DESC='A warm, low voice of a woman in her forties, unhurried, with a slight rasp.'
$CHECK $B --operation audio.design_voice --model qwen3-tts-design --lane int8 --params '{"count":2,"language":"en"}' --seed 7 \
  --text "description=$DESC" --models-root "$MODELS" --budget 64000000000 --timeout 900 --session $OUT/design.gpp > $OUT/design-gpp.log 2>&1
i=0; for f in $(outputs $OUT/design-gpp.log); do [[ -f $f ]] && cp $f $OUT/design-gpp-$i.wav; i=$((i+1)); done
$INPROC design --description "$DESC" --count 2 --language en --seed 7 --models-root "$MODELS" --out-dir $OUT/design-inproc 2>> $LOG | tail -1 > $OUT/design-inproc.json
say "      design: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/design-gpp.log | head -1); in-process $(cat $OUT/design-inproc.json)"
same "design sample 0 (seed 7)" $OUT/design-gpp-0.wav $OUT/design-inproc/samples-0.wav
same "design sample 1 (seed 8)" $OUT/design-gpp-1.wav $OUT/design-inproc/samples-1.wav

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
