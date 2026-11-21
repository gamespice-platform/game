#!/usr/bin/env bash
# Posts a visual QA capture (gs_game_visual_qa.sh) to a nightly review item so the clips play in the viewer at their own
# rate: each <item>/<clip>.mp4 as a clip with its fps, frame count and verdict in --metrics (the viewer reads the file's
# own frame rate and steps one frame per 1/fps), and its first-person sheet as a filmstrip. Run from the game dir:
#   bash addons/gs_game/tools/gs_game_visual_qa_post.sh <review-key> [--out DIR] [--by NAME] [--variant before|after]
#        [--only item,item] [--clips clip,clip] [--fails] [--verdict FILE]
# Every clip needs a fresh judge verdict (gs_game_visual_judge.sh, default FILE $out/judge/verdict.json): a clip is
# posted only when the judge says production_ready, or when each blocker/major defect has a filed nightly item
# (--give-up), or as --variant before. The post's look text is the verdict and its defects, and the item's review
# verdict is set to good only when every posted clip is production ready. The capture's metric PASS/FAIL is only a
# label: it never decides anything. --fails posts only the clips the judge did not pass; --variant pairs a fix's
# before and after.
# The review item must exist: nightly review new "<Game> visual QA" --key <game>-visual-qa-<date>.
set -euo pipefail
key=${1:?usage: gs_game_visual_qa_post.sh <review-key> [--out DIR] [--by NAME] [--variant before|after] [--only a,b] [--clips a,b] [--fails]}
shift
out=screenshots/visual_qa by=visual-qa variant= only= clips= fails=0 verdict=
while (($#)); do
  case $1 in
    --out) out=$2; shift 2 ;;
    --by) by=$2; shift 2 ;;
    --variant) variant=$2; shift 2 ;;
    --only) only=,$2,; shift 2 ;;
    --clips | --anims) clips=,$2,; shift 2 ;;
    --fails) fails=1; shift ;;
    --verdict) verdict=$2; shift 2 ;;
    *) echo "gs_game_visual_qa_post.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")/../../.."
[[ -f $out/report.md ]] || { echo "gs_game_visual_qa_post.sh: no $out/report.md in $PWD; run the capture first" >&2; exit 2; }
verdict=${verdict:-$out/judge/verdict.json}
[[ -f $verdict ]] || { echo "gs_game_visual_qa_post.sh: no judge verdict $verdict: run addons/gs_game/tools/gs_game_visual_judge.sh --clips $out first; a metric PASS is not a verdict" >&2; exit 3; }
gate=addons/gs_game/tools/gs_game_visual_verdict.py
declare -A item_good=() item_note=()
nightly=${NIGHTLY:-/home/core/stack/nightly/bin/nightly}
run_nightly() { if [[ $(id -un) == core || -n ${NIGHTLY:-} ]]; then "$nightly" "$@"; else sudo -u core "$nightly" "$@"; fi; }
# The nightly runs as core, which cannot read a gamedev worktree: hand it copies in a world-readable scratch dir.
stage=$(mktemp -d /tmp/visual-qa-post.XXXXXX)
trap 'rm -rf "$stage"' EXIT
chmod 755 "$stage"
report_fps=$(sed -n 's/^fps: *\([0-9]*\).*/\1/p' "$out/report.md" | head -1)
posted=0 failed=0 refused=0
# report.md rows: | item | clip | verdict | why | ... |
while IFS='|' read -r _ item clip metric why _; do
  item=$(xargs <<< "$item"); clip=$(xargs <<< "$clip"); metric=$(xargs <<< "$metric")
  [[ $metric == PASS || $metric == FAIL ]] || continue
  [[ -z $only || $only == *",$item,"* ]] || continue
  [[ -z $clips || $clips == *",$clip,"* ]] || continue
  mp4=$out/$item/$clip.mp4 sheet=$out/$item/${clip}_fp_sheet.png
  [[ -f $mp4 ]] || { echo "gs_game_visual_qa_post.sh: no $mp4" >&2; failed=$((failed + 1)); continue; }
  gate_args=("$verdict" "$item" "$clip" --mp4 "$mp4")
  [[ $variant == before ]] && gate_args+=(--before)
  if ! judged=$(env -u VISUAL_JUDGE_TRANSCRIPTS python3 "$gate" "${gate_args[@]}"); then
    echo "gs_game_visual_qa_post.sh: refusing $item $clip: $judged" >&2
    refused=$((refused + 1)); continue
  fi
  IFS=$'\t' read -r _ judge_says look <<< "$judged"
  ((fails == 0)) || [[ $judge_says == wrong ]] || continue
  frames=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$mp4" 2>/dev/null || echo 0)
  # The file's own rate (60/1), so a report written at another fps cannot mislabel it.
  fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$mp4" 2>/dev/null | awk -F/ '$2 > 0 {printf "%g", $1 / $2}')
  fps=${fps:-${report_fps:-60}}
  why=$(xargs <<< "${why//\"/\'}" 2>/dev/null || true)
  metrics=$(printf '{"fps":"%s","frames":"%s","seconds":"%s","judge":"%s","metric_prefilter":"%s"}' "$fps" "$frames" "$(awk -v f="$frames" -v r="$fps" 'BEGIN{printf "%.2f", f/r}')" "$([[ $judge_says == good ]] && echo READY || echo NOT_READY)" "$metric")
  cp "$mp4" "$stage/${item}__$clip.mp4"; chmod 644 "$stage/${item}__$clip.mp4"
  args=(--label "$clip" --metrics "$metrics" --by "$by" --look "$look")
  [[ -z $variant ]] || args+=(--variant "$variant")
  run_nightly review media "$key" "$item" "$stage/${item}__$clip.mp4" --slot clip "${args[@]}" > /dev/null || { failed=$((failed + 1)); continue; }
  if [[ -f $sheet ]]; then
    cp "$sheet" "$stage/${item}__${clip}_sheet.png"; chmod 644 "$stage/${item}__${clip}_sheet.png"
    run_nightly review media "$key" "$item" "$stage/${item}__${clip}_sheet.png" --slot filmstrip "${args[@]}" > /dev/null || failed=$((failed + 1))
  fi
  posted=$((posted + 1))
  [[ ${item_good[$item]:-good} == wrong ]] || item_good[$item]=$judge_says
  item_note[$item]="${item_note[$item]:-}$clip: ${look:0:600} "
done < "$out/report.md"
# The item's review verdict is the judge's, never the author's: good only when every posted clip is production ready.
if [[ $variant != before ]]; then
  for item in "${!item_good[@]}"; do
    run_nightly review verdict "$key" "$item" "${item_good[$item]}" --note "${item_note[$item]:0:1500}" > /dev/null || failed=$((failed + 1))
  done
fi
echo "gs_game_visual_qa_post.sh: posted $posted clips to review $key${variant:+ ($variant)}, $failed failed, $refused refused without a passing or filed verdict"
((failed == 0 && refused == 0))
