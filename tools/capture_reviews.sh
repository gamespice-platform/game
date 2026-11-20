#!/usr/bin/env bash
# Captures short looping clips of the animations that changed since the last posted review and files them on the
# nightly panel's /reviews page (before = the clip posted last time, after = the new one, plus a filmstrip sheet).
# The shared script (dot-game/tools); a game's tools/capture_reviews.sh cds to its root and execs it, and
# tools/qa.conf supplies three functions:
#   review_items                  print the item ids (a weapon, a gait), one per line
#   review_fingerprint ITEM       print every input that decides how ITEM animates (files, rows); a changed hash = recapture
#   review_look KIND              (optional) one line on what to look for in a clip of that kind
#   review_capture OUTDIR ITEM... on a GPU box, write OUTDIR/<item>__<kind>.mp4 (kinds: reload, fire, walk, ...)
#
#   tools/capture_reviews.sh                 every item whose fingerprint changed since the last posted capture
#   tools/capture_reviews.sh --all           every item
#   tools/capture_reviews.sh pistol smg      these items, changed or not
#   tools/capture_reviews.sh --dry-run       list what would be captured
#   tools/capture_reviews.sh --no-post       capture into .godot/review-clips/ only
# State (the last posted clips, which become the next "before", and the fingerprints) is in $REVIEW_STATE
# (default ~/.local/state/dot-reviews/<game>). Key of the review: <game>-anim-<date>. Exit 1 if a clip is missing.
# Before anything is posted, a fresh judge (addons/dot_game/tools/dot_game_visual_judge.sh, docs/visual-judge-rubric.md)
# reads every clip and writes .godot/review-clips/judge/verdict.json. A clip is posted only when the judge says
# production_ready, or when each blocker/major defect has a filed nightly item; its look text is the verdict and the
# item's review verdict is the judge's. VISUAL_JUDGE_GIVE_UP=1 files the open defects (one nightly item each) so they
# can be posted as open.
set -uo pipefail
SHARED=$(cd "$(dirname "$0")" && pwd)
ROOT=$PWD
GAME=$(basename "$ROOT")
[ -f tools/qa.conf ] || { echo "reviews: no tools/qa.conf in $ROOT" >&2; exit 2; }
# shellcheck disable=SC1091
. tools/qa.conf
declare -F review_items >/dev/null || { echo "reviews: tools/qa.conf has no review_items" >&2; exit 2; }

all=0 post=1 dry=0 items=()
for a in "$@"; do
    case $a in
        --all) all=1 ;;
        --no-post) post=0 ;;
        --dry-run) dry=1 ;;
        -*) echo "unknown option $a" >&2; exit 2 ;;
        *) items+=("$a") ;;
    esac
done
state=${REVIEW_STATE:-$HOME/.local/state/dot-reviews}/$GAME
work=.godot/review-clips
mkdir -p "$state" "$work"

declare -A sha reason
want=()
mapfile -t known < <(review_items)
[ ${#items[@]} -gt 0 ] && forced=1 || { forced=0; items=("${known[@]}"); }
for it in "${items[@]}"; do
    sha[$it]=$(review_fingerprint "$it" | sha1sum | cut -c1-12)
    old=$(cat "$state/$it.sha" 2>/dev/null || true)
    if [ "$forced" = 1 ] || [ "$all" = 1 ]; then want+=("$it"); reason[$it]="recaptured on request"
    elif [ -z "$old" ]; then want+=("$it"); reason[$it]="first capture"
    elif [ "$old" != "${sha[$it]}" ]; then want+=("$it"); reason[$it]="animation inputs changed ($old -> ${sha[$it]})"
    fi
done
echo "reviews: ${#want[@]} of ${#items[@]} items to capture: ${want[*]:-none}"
[ ${#want[@]} -eq 0 ] || [ "$dry" = 1 ] && exit 0

rm -rf "${work:?}"/*
# The capture's own output is the GPU proof the judge requires (gpu.sh's "takes this frame" or Godot's "Using Device").
review_capture "$work" "${want[@]}" 2>&1 | tee "$work/capture.log"
[ "${PIPESTATUS[0]}" = 0 ] || echo "reviews: capture reported a failure, judging what exists" >&2
shopt -s nullglob
[ -n "$(echo "$work"/*.mp4)" ] || { echo "reviews: no clips produced" >&2; exit 1; }
for it in "${want[@]}"; do
    f=("$work/${it}__reload.mp4"); [ -f "${f[0]}" ] || f=("$work/${it}__"*.mp4)
    [ -f "${f[0]:-}" ] && bash addons/dot_core/tools/dot_filmstrip.sh "${f[0]}" "$work/$it" --cols 4 --rows 3 --width 320 >/dev/null
done
[ "$post" = 1 ] || { echo "reviews: clips in $work (not posted)"; exit 0; }

# The fresh judge: never post on the capture's own reading.
judge=addons/dot_game/tools/dot_game_visual_judge.sh
[ -f "$judge" ] || judge=$SHARED/../addons/dot_game/tools/dot_game_visual_judge.sh
gate=$(dirname "$judge")/dot_game_visual_verdict.py
# Items the capture made no clip for are reported (and fail the run); the judge must see every clip it is asked about.
made=() missing=0
for it in "${want[@]}"; do
    f=("$work/${it}__"*.mp4)
    if [ -f "${f[0]:-}" ]; then made+=("$it"); else echo "reviews: no clip for $it" >&2; missing=1; fi
done
want=("${made[@]}")
judge_args=(--clips "$work" --out "$work/judge" --subject "$GAME" --only "$(IFS=,; echo "${want[*]}")")
[ "${VISUAL_JUDGE_GIVE_UP:-0}" = 1 ] && judge_args+=(--give-up)
bash "$judge" "${judge_args[@]}"; jrc=$?
case $jrc in
    0 | 1 | 3) ;;
    *) echo "reviews: the judge failed (exit $jrc): nothing posted" >&2; exit 1 ;;
esac

poster=$(mktemp); trap 'rm -f "$poster"' EXIT
if [ -f /home/core/stack/nightly/scripts/review-post.sh ]; then
    cat /home/core/stack/nightly/scripts/review-post.sh > "$poster"
else
    ssh -o BatchMode=yes dev01 'cat ~/stack/nightly/scripts/review-post.sh' > "$poster"
fi && chmod +x "$poster" || { echo "reviews: cannot fetch review-post.sh" >&2; exit 1; }
key="$GAME-anim-$(date +%F)"
commit=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
"$poster" new "$key" "$GAME animation clips $(date +%F) (changed items, before/after)" >/dev/null || exit 1
fail=0 refused=0
for it in "${want[@]}"; do
    posted=0 item_says=good item_note= sent=()
    for clip in "$work/${it}__"*.mp4; do
        kind=${clip##*__}; kind=${kind%.mp4}
        if ! judged=$(env -u VISUAL_JUDGE_TRANSCRIPTS python3 "$gate" "$work/judge/verdict.json" "$it" "$kind" --mp4 "$clip"); then
            echo "reviews: refusing $it $kind: $judged" >&2
            refused=$((refused + 1)); continue
        fi
        IFS=$'\t' read -r _ says look <<< "$judged"
        [ "$says" = good ] || item_says=wrong
        item_note="$item_note$kind: ${look:0:600} "
        note="${reason[$it]}; $GAME@$commit"
        extra=()
        if grep -q -- --look "$poster"; then
            # ffprobe prints them in its own order: width, height, r_frame_rate (30/1), duration, nb_frames.
            m=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames,duration,width,height,r_frame_rate -of csv=p=0 "$clip" 2>/dev/null)
            IFS=, read -r w h rate dur nf <<< "$m"
            fps=$(awk -F/ '$2 > 0 {printf "%g", $1 / $2}' <<< "$rate")
            extra=(--look "$look"
                   --metrics "{\"fps\":\"${fps:-?}\",\"frames\":\"$nf\",\"seconds\":\"$(printf "%.1f" "${dur:-0}")\",\"size\":\"${w}x${h}\"}")
        fi
        if [ -f "$state/${it}__$kind.mp4" ]; then
            "$poster" media "$key" "$it" "$state/${it}__$kind.mp4" --slot clip --variant before --label "$kind" --title "$kind before" "${extra[@]}" >/dev/null || fail=1
        else
            note="$note; no earlier clip to compare"
        fi
        "$poster" media "$key" "$it" "$clip" --slot clip --variant after --label "$kind" --title "$kind after" --note "$note" "${extra[@]}" >/dev/null && { posted=1; sent+=("$clip"); } || fail=1
    done
    [ -f "$work/${it}_sheet.png" ] && { "$poster" media "$key" "$it" "$work/${it}_sheet.png" --slot filmstrip --variant after --label "reload" >/dev/null || fail=1; }
    if [ "$posted" = 1 ]; then
        sudo -u core /home/core/stack/nightly/bin/nightly review verdict "$key" "$it" "$item_says" --note "${item_note:0:1500}" >/dev/null 2>&1 ||
            /home/core/stack/nightly/bin/nightly review verdict "$key" "$it" "$item_says" --note "${item_note:0:1500}" >/dev/null || fail=1
        # Only the clips that were posted become the next "before"; the fingerprint is kept only when all were.
        for clip in "${sent[@]}"; do cp "$clip" "$state/"; done
        all_clips=("$work/${it}__"*.mp4)
        [ "${#sent[@]}" = "${#all_clips[@]}" ] && echo "${sha[$it]}" > "$state/$it.sha"
    fi
done
echo "reviews: posted to $key ($([ $fail = 0 ] && echo ok || echo "with failures"); $refused clips refused without a passing or filed verdict): ${QA_URL:-http://x-tmc-dev01:3010}/reviews"
[ "$refused" = 0 ] || fail=1
[ "$missing" = 0 ] || fail=1
exit $fail
