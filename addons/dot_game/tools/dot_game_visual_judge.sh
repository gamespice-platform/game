#!/usr/bin/env bash
# The visual judge loop (docs/visual-qa.md "The judge loop", docs/visual-judge-rubric.md): a GPU capture, then a FRESH
# judge that reads the frames before anything else and writes verdict.json with production_ready true|false, then
# fix -> recapture -> fresh judge until it passes. Metrics are never shown to the judge. Run it as gamedev from the
# game checkout or a ~/wt worktree:
#   bash addons/dot_game/tools/dot_game_visual_judge.sh --clips DIR [--capture 'CMD'] [--only a,b] [--anims a,b]
#        [--out DIR] [--subject TEXT] [--model opus] [--max-rounds N] [--fix-cmd 'CMD'] [--give-up] [--repos a,b]
#        [--cameras N] [--peaks N] [--strip N] [--no-judge]
# --clips: the capture's clips, <item>/<clip>.mp4 (dot_game_visual_qa.sh, anim_review.sh) or <item>__<clip>.mp4
#   (capture_reviews.sh). Each mp4 is the clip's cameras side by side at the capture fps.
# --capture: the GPU capture to run first (it must log the renderer; an llvmpipe log is refused). Without it the
#   clips already in --clips are judged.
# --fix-cmd: run between rounds with VERDICT=<out>/verdict.json in its environment (for example a fresh claude -p
#   fixer); without it each call is one round and the author fixes and calls again (the round count is kept in --out).
# --max-rounds (env VISUAL_JUDGE_MAX_ROUNDS, default 0 = unlimited): at that round, or with --give-up, every
#   unresolved blocker/major defect gets a nightly item (key written back into verdict.json) and the tool exits 3.
# --no-judge builds the packs only (to look at them yourself; it never counts as a verdict).
# Exit: 0 production ready, 1 not ready (defects printed), 3 gave up (items filed), 2 usage, 4 llvmpipe/no clips,
#   5 the judge wrote no valid verdict.
set -uo pipefail
self=$(readlink -f "$0")
cd "$(dirname "$0")/../../.." || exit 2
clips= capture= only= anims= out= subject= fix= give_up=0 repos= judge=1
model=${VISUAL_JUDGE_MODEL:-opus}
max_rounds=${VISUAL_JUDGE_MAX_ROUNDS:-0}
cameras=${VISUAL_JUDGE_CAMERAS:-3}
peaks=${VISUAL_JUDGE_PEAKS:-3}
strip=${VISUAL_JUDGE_STRIP:-48}
while (($#)); do
  case $1 in
    --clips) clips=$2; shift 2 ;;
    --capture) capture=$2; shift 2 ;;
    --only) only=,$2,; shift 2 ;;
    --anims | --clips-named) anims=,$2,; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --subject) subject=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --max-rounds) max_rounds=$2; shift 2 ;;
    --fix-cmd) fix=$2; shift 2 ;;
    --give-up) give_up=1; shift ;;
    --repos) repos=$2; shift 2 ;;
    --cameras) cameras=$2; shift 2 ;;
    --peaks) peaks=$2; shift 2 ;;
    --strip) strip=$2; shift 2 ;;
    --no-judge) judge=0; shift ;;
    *) echo "dot_game_visual_judge.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
die() { echo "dot_game_visual_judge.sh: $*" >&2; exit "${code:-2}"; }
[[ -n $clips ]] || die "--clips DIR is required"
for n in max_rounds cameras peaks strip; do [[ ${!n} =~ ^[0-9]+$ ]] || die "--${n//_/-} must be a whole number (0 = unlimited for --max-rounds), not ${!n}"; done
[[ $model != *fable* ]] || die "the judge runs on opus, sonnet or haiku, never $model"
[[ -d $clips ]] || mkdir -p "$clips"
clips=$(readlink -f "$clips")
out=$(readlink -m "${out:-$clips/judge}")
# The repo's own name (from origin), not the worktree's directory (~/wt/<repo>-<task>), so nightly keys are stable.
game=$(basename "$(git remote get-url origin 2> /dev/null || echo "$PWD")" .git)
repos=${repos:-$game}
mkdir -p "$out"
# The rubric lives in dot-game's docs; the addon is a symlink into a dot-game checkout.
rubric=$(dirname "$self")/../../../docs/visual-judge-rubric.md
[[ -f $rubric ]] || rubric=/home/gamedev/projects/godot/dot-game/docs/visual-judge-rubric.md
[[ -f $rubric ]] || die "no docs/visual-judge-rubric.md beside $self"
rubric=$(readlink -f "$rubric")
command -v ffmpeg > /dev/null || die "no ffmpeg"
# The judge is a fresh claude -p. The fleet's Claude accounts live under christian (nightly account env picks one
# under its limits), so gamedev runs it there; VISUAL_JUDGE_CLAUDE overrides the whole command prefix.
judge_claude() {
  if [[ -n ${VISUAL_JUDGE_CLAUDE:-} ]]; then $VISUAL_JUDGE_CLAUDE "$@"; return; fi
  local cfg
  cfg=$(run_nightly account env 2> /dev/null | sed -n "s/^export CLAUDE_CONFIG_DIR='\\(.*\\)'$/\\1/p")
  if [[ $(id -un) == christian ]]; then CLAUDE_CONFIG_DIR=${cfg:-$HOME/.claude} /home/christian/.local/bin/claude "$@"
  elif [[ -n $cfg ]] && sudo -n -u christian true 2> /dev/null; then sudo -n -u christian env CLAUDE_CONFIG_DIR="$cfg" /home/christian/.local/bin/claude "$@"
  else claude "$@"; fi
}
nightly=${NIGHTLY:-/home/core/stack/nightly/bin/nightly}
run_nightly() { if [[ $(id -un) == core ]]; then "$nightly" "$@"; else sudo -u core "$nightly" "$@"; fi; }

# Refuse software rendering: every capture log under --clips (and the capture's own output) is checked.
check_gpu() {
  local logs=("$@") hit
  if ((${#logs[@]} == 0)); then
    echo "dot_game_visual_judge.sh: WARNING no capture log next to the clips; check they were rendered on a GPU box" >&2
    return 0
  fi
  hit=$(grep -lisE 'llvmpipe|softpipe|lavapipe|SwiftShader|software rasterizer' "${logs[@]}" 2> /dev/null | head -3)
  [[ -z $hit ]] || code=4 die "the capture rendered on software ($hit): never judge llvmpipe frames; rerun it on staging02/staging (gpu.sh shot)"
  grep -qisE 'NVIDIA|GeForce|RTX|Radeon|AMD|Intel\(R\) (Arc|UHD|Iris)|Vulkan [0-9.]+ - Forward|gpu.sh: the .*\(staging[0-9]*\) takes this frame' "${logs[@]}" 2> /dev/null ||
    echo "dot_game_visual_judge.sh: WARNING no GPU line in the capture log (${logs[*]:-none}); check it ran on a GPU box" >&2
}

# One clip's judge pack: full-resolution stills (start, quarter, mid, three-quarter, end and the motion peaks) and
# a frame-delta strip. pack.txt maps every image to its frame.
make_pack() {
  local mp4=$1 dir=$2 n w h fps
  rm -rf "$dir"; mkdir -p "$dir"; chmod 777 "$dir"  # the judge may run as another user and writes verdict.json here
  IFS=, read -r w h fps n < <(ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate,nb_read_frames -of csv=p=0 "$mp4")
  fps=$(awk -F/ '$2 > 0 {printf "%g", $1 / $2}' <<< "$fps")
  ((n > 0)) || { echo "dot_game_visual_judge.sh: $mp4 has no frames" >&2; return 1; }
  # Per-frame change (mean absolute luma difference to the previous frame).
  ffmpeg -v error -i "$mp4" -vf "format=gray,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=$dir/delta.txt" -f null - 2> /dev/null
  python3 - "$dir" "$n" "$peaks" "$w" "$h" "$fps" "$mp4" > "$dir/frames.tsv" <<'PY'
import re, sys
d, n, peaks = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
deltas, frame = {}, None
for line in open(d + "/delta.txt"):
    m = re.match(r"frame:(\d+)", line)
    if m: frame = int(m.group(1)) + 1
    m = re.search(r"YAVG=([0-9.]+)", line)
    if m and frame is not None: deltas[frame] = float(m.group(1))
fixed = [("start", 0), ("q1", n // 4), ("mid", n // 2), ("q3", 3 * n // 4), ("end", n - 1)]
used = [f for _, f in fixed]
rows = list(fixed)
for f, v in sorted(deltas.items(), key=lambda kv: -kv[1]):
    if len(rows) >= len(fixed) + peaks: break
    if f >= n or any(abs(f - u) < 4 for u in used): continue
    rows.append(("peak%.1f" % v, f)); used.append(f)
for i, (tag, f) in enumerate(rows):
    print("%02d\t%s\t%d" % (i, tag, f))
with open(d + "/deltas.tsv", "w") as o:
    for f in range(1, n): o.write("%d\t%.2f\n" % (f, deltas.get(f, 0.0)))
PY
  local i tag f
  while IFS=$'\t' read -r i tag f; do
    ffmpeg -v error -y -i "$mp4" -vf "select=eq(n\\,$f)" -frames:v 1 -q:v 2 "$dir/still_${i}_${tag%%.*}_f$f.jpg"
  done < "$dir/frames.tsv"
  # The delta strip: every k-th difference frame, boosted so motion is bright, in a grid read left to right.
  local k=$(((n + strip - 1) / (strip > 0 ? strip : n)))
  ((k >= 1)) || k=1
  local cells=$(((n + k - 1) / k)) cols=8
  ffmpeg -v error -y -i "$mp4" -vf "format=gray,tblend=all_mode=difference,lut=y=min(val*4\\,255),select=not(mod(n\\,$k)),scale=320:-2,tile=${cols}x$(((cells + cols - 1) / cols))" \
    -frames:v 1 -q:v 3 "$dir/delta_strip.jpg"
  {
    echo "clip: $mp4"
    echo "size: ${w}x$h, fps: $fps, frames: $n; the cameras are side by side (expected $cameras: first person, behind-right, opponent)"
    echo "stills (index, why, frame):"; sed 's/^/  /' "$dir/frames.tsv"
    echo "delta_strip.jpg: every ${k}th frame's difference to the one before, 8 per row, frame 1 top left; bright = motion"
  } > "$dir/pack.txt"
  rm -f "$dir/delta.txt"
}

judge_prompt() {
  cat << EOF
You are a FRESH visual judge for a game studio. You have never seen this work and you did not make it. Your job is to
decide whether this clip would ship in a modern FPS (CS:S, CS2, Valorant, Apex). Default: it would NOT.

1. Read the rubric: $rubric
2. Read pack.txt in the current directory, then Read EVERY image in the current directory at full size, every still and
   delta_strip.jpg${3:+ and the sheets}. Do not skip any; do not read anything outside this directory except the rubric.
   There are no metrics and no author notes on purpose: judge only what you see.
3. Write ./verdict.json (and nothing else) to the rubric's schema for subject "$1" (item "$2"):
   - "frames": one entry per image you read, with what you saw in EACH camera, even when it is fine.
   - "defects": every problem, with category, severity (blocker|major|minor), camera, frames, what, fix_hint, "nightly": "".
   - "categories_clean": for every rubric category with no defect, the frames that show it is clean.
   - "production_ready": true only if there is no blocker or major defect in any camera; "justification" says why.
Be strict and specific ("the magazine is about 3x the magwell, in still_02"). A thin justification is a wrong verdict.
EOF
}

# Checks a verdict: it parses, it lists every image, production_ready matches the defects. Prints why it is invalid.
check_verdict() {
  python3 - "$1" "$2" << 'PY'
import json, os, sys
v, d = sys.argv[1], sys.argv[2]
try: j = json.load(open(v))
except Exception as e: print("unreadable: %s" % e); sys.exit(1)
imgs = sorted(f for f in os.listdir(d) if f.endswith((".jpg", ".png")))
seen = " ".join(str(fr.get("file", "")) for fr in j.get("frames", []))
missing = [f for f in imgs if f not in seen]
bad = []
if missing: bad.append("frames does not cover %s" % ", ".join(missing))
if not isinstance(j.get("production_ready"), bool): bad.append("production_ready is not true/false")
if len(str(j.get("justification", "")).strip()) < 40: bad.append("justification missing or thin")
blocking = [x for x in j.get("defects", []) if x.get("severity") in ("blocker", "major")]
if j.get("production_ready") is True and blocking: bad.append("production_ready true with %d blocker/major defects" % len(blocking))
if j.get("production_ready") is False and not j.get("defects"): bad.append("production_ready false with no defects")
if bad: print("; ".join(bad)); sys.exit(1)
PY
}

run_judge() {
  local dir=$1 subj=$2 item=$3 why
  rm -f "$dir/verdict.json"
  for attempt in 1 2; do
    (cd "$dir" && judge_claude -p "$(judge_prompt "$subj" "$item" "$(ls "$dir"/*sheet* 2> /dev/null)")" --model "$model" \
      --allowedTools "Read,Write" --permission-mode acceptEdits --add-dir "$(dirname "$rubric")" > "$dir/judge.log" 2>&1)
    why=$(check_verdict "$dir/verdict.json" "$dir") && return 0
    echo "dot_game_visual_judge.sh: judge $attempt for $subj wrote an invalid verdict ($why)" >&2
    echo "INVALID: $why" >> "$dir/judge.log"
  done
  return 1
}

# Every clip under --clips, filtered.
list_clips() {
  local f rel item clip
  while IFS= read -r f; do
    rel=${f#"$clips"/}
    if [[ $rel == */* ]]; then item=${rel%%/*} clip=$(basename "$rel" .mp4)
    else rel=${rel%.mp4}; item=${rel%%__*} clip=${rel#*__}; fi
    [[ $item == judge || $clip == *before* ]] && continue
    [[ -z $only || $only == *",$item,"* ]] || continue
    [[ -z $anims || $anims == *",$clip,"* ]] || continue
    printf '%s\t%s\t%s\n' "$item" "$clip" "$f"
  done < <(find "$clips" -maxdepth 2 -name '*.mp4' -not -path "*/judge/*" | sort)
}

file_defects() {
  python3 - "$out/verdict.json" "$game" "$repos" "$nightly" << 'PY'
import json, re, subprocess, sys, datetime, getpass
v, game, repos, nightly = sys.argv[1:5]
j = json.load(open(v))
cmd = [nightly] if getpass.getuser() == "core" else ["sudo", "-u", "core", nightly]
day = datetime.date.today().strftime("%Y%m%d")
filed = 0
for it in j["items"]:
    for d in it.get("defects", []):
        if d.get("severity") not in ("blocker", "major") or d.get("nightly"): continue
        key = re.sub(r"[^a-z0-9-]+", "-", ("vj-%s-%s-%s-%s-%s" % (game, it["item"], it["clip"], d.get("category", "x"), day)).lower())
        body = "Unresolved after %d judge rounds (dot_game_visual_judge.sh).\n\n%s %s, %s camera, frames %s: %s\n\nFix hint: %s\n\nPack: %s" % (
            j.get("round", 0), d.get("severity"), d.get("category"), d.get("camera", "?"), ", ".join(d.get("frames", [])),
            d.get("what", ""), d.get("fix_hint", ""), it.get("pack", ""))
        if subprocess.run(cmd + ["show", key], capture_output=True).returncode == 0:
            subprocess.run(cmd + ["note", key, "--by", "session", "still open: " + d.get("what", "")], capture_output=True)
        else:
            r = subprocess.run(cmd + ["add", "--title", "%s %s %s: %s" % (game, it["item"], it["clip"], d.get("what", "")[:90]),
                                      "--key", key, "--kind", "issue", "--repos", repos, "--by", "session", "--body", body], capture_output=True, text=True)
            if r.returncode != 0: print("could not file %s: %s" % (key, r.stderr.strip()), file=sys.stderr); continue
        d["nightly"] = key; filed += 1
        print("filed %s" % key)
json.dump(j, open(v, "w"), indent=2)
print("%d defects filed" % filed)
PY
}

round_file=$out/round
round=$(cat "$round_file" 2> /dev/null || echo 0)
while :; do
  round=$((round + 1))
  echo "$round" > "$round_file"
  if [[ -n $capture ]]; then
    echo "dot_game_visual_judge.sh: round $round: capture: $capture"
    bash -c "$capture" > "$out/capture_round$round.log" 2>&1 || echo "dot_game_visual_judge.sh: the capture exited non-zero (see $out/capture_round$round.log); judging what it made" >&2
  fi
  mapfile -t logs < <(find "$clips" -maxdepth 2 -name '*.log' -newer "$round_file" 2> /dev/null; [[ -n $capture ]] && echo "$out/capture_round$round.log")
  ((${#logs[@]})) || mapfile -t logs < <(find "$clips" -maxdepth 2 \( -name capture.log -o -name run.log \) 2> /dev/null)
  check_gpu "${logs[@]}"
  mapfile -t rows < <(list_clips)
  ((${#rows[@]})) || code=4 die "no clips under $clips${only:+ for $only}${anims:+ / $anims}"
  results=()
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r item clip mp4 <<< "$row"
    dir=$out/$item/$clip
    make_pack "$mp4" "$dir" || continue
    for s in "$(dirname "$mp4")/${clip}"*sheet*.png "$(dirname "$mp4")/${item}_sheet.png"; do [[ -f $s ]] && cp "$s" "$dir/"; done
    if ((judge == 0)); then echo "pack: $dir"; continue; fi
    subj="${subject:-$game} $item $clip"
    if run_judge "$dir" "$subj" "$item"; then results+=("$item"$'\t'"$clip"$'\t'"$dir")
    else code=5 die "no valid verdict for $subj after two fresh judges (see $dir/judge.log)"; fi
  done
  ((judge == 1)) || { echo "dot_game_visual_judge.sh: packs only (--no-judge): this is not a verdict"; exit 1; }
  # The run's verdict: every clip's, and production_ready only if all are.
  printf '%s\n' "${results[@]}" > "$out/results.tsv"
  python3 - "$out/verdict.json" "$round" "$model" "$out/results.tsv" << 'PY'
import json, sys
out, rnd, model = sys.argv[1], int(sys.argv[2]), sys.argv[3]
items = []
for line in open(sys.argv[4]):
    if not line.strip(): continue
    item, clip, d = line.rstrip("\n").split("\t")
    v = json.load(open(d + "/verdict.json"))
    v.update({"item": item, "clip": clip, "pack": d})
    items.append(v)
ready = bool(items) and all(v["production_ready"] for v in items)
json.dump({"round": rnd, "judge_model": model, "production_ready": ready, "items": items}, open(out, "w"), indent=2)
for v in items:
    print("%-6s %s %s: %s" % ("READY" if v["production_ready"] else "NOT", v["item"], v["clip"], v["justification"][:200]))
    for d in v.get("defects", []):
        print("   %s %-8s %-10s %s" % (d.get("id", "-"), d.get("severity"), d.get("category"), d.get("what", "")[:160]))
PY
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["production_ready"] else 1)' "$out/verdict.json"; then
    echo "dot_game_visual_judge.sh: PRODUCTION READY after $round round(s): $out/verdict.json"
    exit 0
  fi
  if ((give_up == 1)) || ((max_rounds > 0 && round >= max_rounds)); then
    file_defects
    echo "dot_game_visual_judge.sh: NOT production ready after $round round(s); every open defect is filed in nightly (see $out/verdict.json)" >&2
    exit 3
  fi
  if [[ -z $fix ]]; then
    echo "dot_game_visual_judge.sh: NOT production ready (round $round). Fix the defects at their source and run this again; --give-up files them." >&2
    exit 1
  fi
  [[ -n $capture ]] || code=2 die "--fix-cmd needs --capture to recapture after the fix"
  echo "dot_game_visual_judge.sh: round $round failed; fixing: $fix"
  VERDICT=$out/verdict.json bash -c "$fix" > "$out/fix_round$round.log" 2>&1 || echo "dot_game_visual_judge.sh: the fix exited non-zero (see $out/fix_round$round.log)" >&2
done
