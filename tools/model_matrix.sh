#!/bin/zsh
# Build a virtual iPod for each model family and run the write test on it.
# Needs LIBGPOD (built libgpod.4.dylib) and test audio files; see tools/virtual_ipod.py.
# Usage: tools/model_matrix.sh AUDIO_DIR
set -u
ROOT=${0:A:h:h}
cd "$ROOT"
AUDIO=$1
PY=.venv/bin/python
results=()

# volume  model  options  label   (older iPods get the iTunes-era library layout)
models=(
  "VIPOD3G   M8976 --itunes       iPod_3rd_gen"
  "VIPOD4G   M9585 --itunes       iPod_photo_4th_gen"
  "VIPOD5G   MA002 --itunes       iPod_video_5th_gen"
  "VIPOD55G  MA444 --itunes       iPod_video_5.5th_gen"
  "VIMINI2   M9800 --itunes,--hfs iPod_mini_2nd_gen_(Mac_formatted)"
  "VINANO1   MA004 --itunes       iPod_nano_1st_gen"
  "VINANO2   MA426 --itunes       iPod_nano_2nd_gen"
  "VINANO3   MA978 -              iPod_nano_3rd_gen"
  "VINANO4   MB480 -              iPod_nano_4th_gen"
  "VICLASS6  MB029 --hfs          iPod_classic_6th_gen_(Mac_formatted)"
  "VICLASS7  MC293 -              iPod_classic_7th_gen"
  "VINANO5   MC027 -              iPod_nano_5th_gen"
  "VINANO6   MC525 -              iPod_nano_6th_gen"
  "VINANO7   MD475 -              iPod_nano_7th_gen"
  "VIGTK5G   MA002 -              iPod_5th_gen_last_managed_by_gtkpod"
)

for row in $models; do
  parts=(${=row})
  vol=$parts[1] model=$parts[2] opts=${parts[3]//,/ } label=${parts[4]//_/ }
  [[ $opts == "-" ]] && opts=""
  echo "=== $label ($model)"
  if ! $PY tools/virtual_ipod.py create $model $vol ${=opts} >/dev/null 2>/tmp/vipod-err; then
    results+=("$label|could not create virtual iPod: $(tail -1 /tmp/vipod-err)")
    continue
  fi
  out=$($PY tools/engine_model_test.py $vol $AUDIO/test-mp3.mp3 $AUDIO/test-flac.flac $AUDIO/test-opus.opus 2>&1)
  print -r -- "$out" | grep -E "^(PASS|FAIL)"
  fails=$(print -r -- "$out" | grep -c "^FAIL")
  if [[ $fails == 0 ]]; then
    results+=("$label|works")
  else
    results+=("$label|$(print -r -- "$out" | grep -m1 '^FAIL' | cut -c1-220)")
  fi
  $PY tools/virtual_ipod.py remove $vol
done

echo
echo "SUMMARY"
for r in $results; do echo "  $r"; done
