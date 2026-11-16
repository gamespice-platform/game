#!/usr/bin/env bash
# The on-box half of a visual QA capture (docs/visual-qa.md): runs the game's capture script under xvfb at a fixed fps,
# turns each clip's frames into labelled contact sheets (PNG, which gpu.sh brings back) and one clip of the three views
# side by side at the same fps into --clip-dir, then drops the frames. A game's tools/<name>_shot.sh execs this (gpu.sh
# only runs a game's tools/*.sh):
#   exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
# Own options (before --):
#   --script PATH    the capture script (a DotGameVisualQaCapture, or any script writing the same frames); required
#   --out DIR        default screenshots/visual_qa      --clip-dir DIR   where the mp4s go (default: --out)
#   --fps N          default 60                         --size WxH    window and first-person view, default 960x540
#   --sheet-rate N   sheet cells per second of clip, default 15; --cell PX cell width, default 240; --cols N, default 8
#   --keep REGEX     more log lines to keep besides VISUALQA lines and errors      --timeout S  default 3300 (0 = none)
# Everything after -- goes to the capture script; --out, --fps and --clip-dir there override the ones above (--clips there
# is the capture's clip-name filter).
# Frames: <out>/<item>/_frames/<clip>/{f,t,o}_NNN.jpg (a fp_<clip> folder name also works). Output per clip:
# <out>/<item>/<clip>_{fp,tp,op}_sheet.png and <clips>/<item>__<clip>.mp4.
set -euo pipefail
cd "$(dirname "$0")/../../.."
script= out=screenshots/visual_qa clips= fps=60 size=960x540 rate=15 cell=240 cols=8 keep= limit=3300
while (($#)); do
  case $1 in
    --script) script=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --clip-dir) clips=$2; shift 2 ;;
    --fps) fps=$2; shift 2 ;;
    --size) size=$2; shift 2 ;;
    --sheet-rate) rate=$2; shift 2 ;;
    --cell) cell=$2; shift 2 ;;
    --cols) cols=$2; shift 2 ;;
    --keep) keep=$2; shift 2 ;;
    --timeout) limit=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "dot_game_visual_qa_shot.sh: unknown option $1 (capture script arguments go after --)" >&2; exit 2 ;;
  esac
done
pass=("$@")
for ((i = 0; i < ${#pass[@]}; i++)); do
  case ${pass[i]} in
    --out) out=${pass[i+1]} ;;
    --fps) fps=${pass[i+1]} ;;
    --clip-dir) clips=${pass[i+1]} ;;
  esac
done
[[ -n $script && -f $script ]] || { echo "dot_game_visual_qa_shot.sh: --script names no file: '$script'" >&2; exit 2; }
for v in fps rate cell cols limit; do
  [[ ${!v} =~ ^[0-9]+$ ]] || { echo "dot_game_visual_qa_shot.sh: --$v must be a whole number, not ${!v}" >&2; exit 2; }
done
((fps >= 1 && rate >= 1 && cell >= 16 && cols >= 1)) || { echo "dot_game_visual_qa_shot.sh: --fps, --sheet-rate and --cols must be at least 1, --cell at least 16" >&2; exit 2; }
[[ $size =~ ^([0-9]+)x([0-9]+)$ ]] || { echo "dot_game_visual_qa_shot.sh: --size is WxH, not $size" >&2; exit 2; }
height=${BASH_REMATCH[2]}
clips=${clips:-$out}
mkdir -p "$out" "$clips"
rc=0
run=(timeout "$limit")
((limit > 0)) || run=()
xvfb-run -a -s "-screen 0 ${size}x24" "${run[@]}" "${GODOT:-godot}" --path . --resolution "$size" --fixed-fps "$fps" \
  --script "$script" -- --out "$out" --fps "$fps" "$@" 2>&1 \
  | grep -E "^VISUALQA|SCRIPT ERROR|ERROR: .*visual_qa|^visual_qa: ${keep:+|$keep}" || rc=$?
# A sheet cell every fps/rate frames (every frame when fps <= rate), cols to a row, each labelled with frame index and time.
every=$((fps / rate))
((every >= 1)) || every=1
sheet() {
  local pattern=$1 count=$2 dest=$3
  local rows=$(((count / every + cols) / cols))
  ffmpeg -y -loglevel error -framerate "$fps" -i "$pattern" -vf \
    "scale=$cell:-2,drawtext=text='#%{n} %{pts\:flt}s':x=4:y=4:fontsize=14:fontcolor=white:box=1:boxcolor=black@0.6,select='not(mod(n\,$every))',tile=${cols}x${rows}:padding=2" \
    -frames:v 1 "$dest" || echo "VISUALQA_SHEET failed: $dest"
}
# The views side by side at the window's height, every frame, frame index burnt in for the notes.
clip() {
  local d=$1 dest=$2 in=(-framerate "$fps" -i "$1/f_%03d.jpg") filter="[0:v]null,"
  if [[ -e $d/t_000.jpg && -e $d/o_000.jpg ]]; then
    in+=(-framerate "$fps" -i "$d/t_%03d.jpg" -framerate "$fps" -i "$d/o_%03d.jpg")
    filter="[0:v]scale=-2:$height[f];[1:v]scale=-2:$height[t];[2:v]scale=-2:$height[o];[f][t][o]hstack=inputs=3,"
  fi
  ffmpeg -y -loglevel error "${in[@]}" -filter_complex \
    "${filter}drawtext=text='#%{n}':x=4:y=h-22:fontsize=16:fontcolor=white:box=1:boxcolor=black@0.6" \
    -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -r "$fps" "$dest" || echo "VISUALQA_CLIP failed: $dest"
}
for d in "$out"/*/_frames/*/; do
  [[ -d $d ]] || continue
  d=${d%/}
  name=$(basename "$d"); name=${name#fp_}; item=$(dirname "$(dirname "$d")")
  n=$(find "$d" -name 'f_*.jpg' | wc -l)
  ((n > 0)) || continue
  sheet "$d/f_%03d.jpg" "$n" "$item/${name}_fp_sheet.png"
  [[ -e $d/t_000.jpg ]] && sheet "$d/t_%03d.jpg" "$n" "$item/${name}_tp_sheet.png"
  [[ -e $d/o_000.jpg ]] && sheet "$d/o_%03d.jpg" "$n" "$item/${name}_op_sheet.png"
  clip "$d" "$clips/$(basename "$item")__${name}.mp4"
done
rm -rf "$out"/*/_frames
echo "dot_game_visual_qa_shot.sh: $(find "$out" -name '*_sheet.png' | wc -l) sheets in $out, $(find "$clips" -name '*.mp4' | wc -l) clips at $fps fps in $clips"
exit $rc
