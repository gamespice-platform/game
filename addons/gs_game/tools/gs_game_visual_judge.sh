#!/usr/bin/env bash
# The visual judge loop (docs/visual-qa.md "The judge loop", docs/visual-judge-rubric.md): a GPU capture, then a FRESH
# judge that reads the frames before anything else and writes verdict.json with production_ready true|false, then
# fix -> recapture -> fresh judge until it passes. Metrics are never shown to the judge. Run it as gamedev from the
# game checkout or a ~/wt worktree:
#   bash addons/gs_game/tools/gs_game_visual_judge.sh --clips DIR [--capture 'CMD'] [--only a,b] [--anims a,b]
#        [--out DIR] [--subject TEXT] [--model opus] [--max-rounds N] [--fix-cmd 'CMD'] [--give-up] [--repos a,b]
#        [--cameras N] [--peaks N] [--strip N] [--passes N] [--no-judge]
# --passes (env VISUAL_JUDGE_PASSES, default 3, never below 3): production_ready needs this many CONSECUTIVE fresh
#   judge passes, each with zero defects of any severity. Pass k is a new judge on variant k-1: shifted phase stills,
#   different motion bursts (consecutive frames around the peaks), a close-up of one camera, and with --capture a
#   recapture under SHOT_VQA_VARIANT=k-1 (GSGameVisualQaViews moves the outside cameras and turns/dims the lights).
#   The first pass with a defect ends the round (the streak resets); later passes are not run, so a bad clip costs one judge.
# Evidence: each judge runs with --output-format stream-json; the pack's evidence.json records the judge's session id,
#   every image it Read, the sha256 of every image, of the clip and of the verdict it Wrote, the pass, variant, round,
#   source and the GPU renderer. gs_game_visual_verdict.py --pack then checks the pack against the judge's own Claude
#   transcript (in the judge account, not writable by the author), and --audit derives production_ready from the packs
#   alone: this script exits 0 only when that audit says sound. A hand-written, edited or copied verdict never posts.
# One run per --out at a time (a lock); a round clears the run's old packs and verdict first, so a stale pass never counts.
# --timeout (env VISUAL_JUDGE_TIMEOUT, default 1800 s, 0 = none): a judge that runs longer is killed and counts as invalid.
# --clips: the capture's clips, <item>/<clip>.mp4 (gs_game_visual_qa.sh, anim_review.sh) or <item>__<clip>.mp4
#   (capture_reviews.sh). Each mp4 is the clip's cameras side by side at the capture fps. Every --only item and --anims
#   clip must have an mp4 (exit 4 otherwise), and with --capture every clip must be newer than that pass's capture.
# --capture: the GPU capture to run first. Without it the clips already in --clips are judged. Either way a capture log
#   (the capture's output, or a *.log beside the clips) must name the GPU: a "gpu.sh: the ... takes this frame" line or
#   Godot's "Using Device" line for a hardware device; no such line, or any llvmpipe/software line, exits 4.
# --fix-cmd: run between rounds with VERDICT=<out>/verdict.json in its environment (for example a fresh claude -p
#   fixer); without it each call is one round and the author fixes and calls again (the round count is kept in --out).
# --max-rounds (env VISUAL_JUDGE_MAX_ROUNDS, default 0 = unlimited): at that round, or with --give-up, every
#   unresolved defect (any severity) gets a nightly item (key written back into verdict.json) and the tool exits 3.
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
passes=${VISUAL_JUDGE_PASSES:-3}
judge_timeout=${VISUAL_JUDGE_TIMEOUT:-1800}
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
    --passes) passes=$2; shift 2 ;;
    --timeout) judge_timeout=$2; shift 2 ;;
    --no-judge) judge=0; shift ;;
    *) echo "gs_game_visual_judge.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
die() { echo "gs_game_visual_judge.sh: $*" >&2; exit "${code:-2}"; }
[[ -n $clips ]] || die "--clips DIR is required"
for n in max_rounds cameras peaks strip passes judge_timeout; do [[ ${!n} =~ ^[0-9]+$ ]] || die "--${n//_/-} must be a whole number (0 = unlimited for --max-rounds), not ${!n}"; done
((passes >= 3)) || die "--passes $passes: production_ready needs at least 3 consecutive clean fresh judge passes (VISUAL_JUDGE_PASSES >= 3)"
[[ $model != *fable* ]] || die "the judge runs on opus, sonnet or haiku, never $model"
[[ -d $clips ]] || mkdir -p "$clips"
clips=$(readlink -f "$clips")
out=$(readlink -m "${out:-$clips/judge}")
# The repo's own name (from origin), not the worktree's directory (~/wt/<repo>-<task>), so nightly keys are stable.
game=$(basename "$(git remote get-url origin 2> /dev/null || echo "$PWD")" .git)
repos=${repos:-$game}
mkdir -p "$out"
exec 9> "$out/.lock"
flock -n 9 || die "another judge run holds $out/.lock: wait for it (one run per --out)"
gate=$(dirname "$self")/gs_game_visual_verdict.py
[[ -f $gate ]] || die "no gs_game_visual_verdict.py beside $self"
# The rubric lives in gs-game's docs; the addon is a symlink into a gs-game checkout.
rubric=$(dirname "$self")/../../../docs/visual-judge-rubric.md
[[ -f $rubric ]] || rubric=/home/gamedev/projects/godot/gs-game/docs/visual-judge-rubric.md
[[ -f $rubric ]] || die "no docs/visual-judge-rubric.md beside $self"
rubric=$(readlink -f "$rubric")
command -v ffmpeg > /dev/null || die "no ffmpeg"
# The judge is a fresh claude -p. The fleet's Claude accounts live under christian (nightly account env picks one
# under its limits), so gamedev runs it there; VISUAL_JUDGE_CLAUDE overrides the whole command prefix.
# Sets jc to the judge command (with the timeout in front).
judge_cmd() {
  jc=()
  ((judge_timeout > 0)) && jc=(timeout -k 30 "$judge_timeout")
  if [[ -n ${VISUAL_JUDGE_CLAUDE:-} ]]; then read -r -a extra <<< "$VISUAL_JUDGE_CLAUDE"; jc+=("${extra[@]}"); return; fi
  local cfg
  cfg=$(run_nightly account env 2> /dev/null | sed -n "s/^export CLAUDE_CONFIG_DIR='\\(.*\\)'$/\\1/p")
  if [[ $(id -un) == christian ]]; then jc+=(env CLAUDE_CONFIG_DIR="${cfg:-$HOME/.claude}" /home/christian/.local/bin/claude)
  elif [[ -n $cfg ]] && sudo -n -u christian true 2> /dev/null; then jc+=(sudo -n -u christian env CLAUDE_CONFIG_DIR="$cfg" /home/christian/.local/bin/claude)
  else jc+=(claude); fi
}
nightly=${NIGHTLY:-/home/core/stack/nightly/bin/nightly}
# NIGHTLY (another nightly CLI, the self-test's stub) runs as is; the real one runs as core.
run_nightly() { if [[ $(id -un) == core || -n ${NIGHTLY:-} ]]; then "$nightly" "$@"; else sudo -u core "$nightly" "$@"; fi; }

# Refuse software rendering: every capture log under --clips (and the capture's own output) is checked.
# Sets renderer to the line that proves a GPU rendered the clips; exits 4 without one or on any software line.
software='llvmpipe|softpipe|lavapipe|SwiftShader|software rasterizer'
check_gpu() {
  local logs=() l hit
  for l in "$@"; do [[ -f $l ]] && logs+=("$l"); done
  ((${#logs[@]})) || code=4 die "no capture log beside the clips in $clips (capture.log, or --capture): nothing proves they were rendered on a GPU; capture with gpu.sh shot on staging02/staging"
  hit=$(grep -lisE "$software" "${logs[@]}" 2> /dev/null | head -3)
  [[ -z $hit ]] || code=4 die "the capture rendered on software ($hit): never judge llvmpipe frames; rerun it on staging02/staging (gpu.sh shot)"
  renderer=$(grep -hiE 'gpu\.sh: the .* takes this frame|Using Device' "${logs[@]}" 2> /dev/null | grep -viE "$software" | head -1 | tr -d '\r' | cut -c1-200)
  [[ -n $renderer ]] || code=4 die "no GPU line in the capture log (${logs[*]}): it must log gpu.sh's 'the <box> takes this frame' or Godot's 'Using Device' line; rerun it on staging02/staging"
}

# One clip's judge pack: full-resolution stills (start, quarter, mid, three-quarter, end and the motion peaks) and
# a frame-delta strip. pack.txt maps every image to its frame.
make_pack() {
  local mp4=$1 dir=$2 variant=${3:-0} n w h fps
  rm -rf "$dir"; mkdir -p "$dir"; chmod 777 "$dir"  # the judge may run as another user and writes verdict.json here
  IFS=, read -r w h fps n < <(ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate,nb_read_frames -of csv=p=0 "$mp4")
  fps=$(awk -F/ '$2 > 0 {printf "%g", $1 / $2}' <<< "$fps")
  ((n > 0)) || { echo "gs_game_visual_judge.sh: $mp4 has no frames" >&2; return 1; }
  # Per-frame change (mean absolute luma difference to the previous frame).
  ffmpeg -v error -i "$mp4" -vf "format=gray,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=$dir/delta.txt" -f null - 2> /dev/null
  python3 - "$dir" "$n" "$peaks" "$w" "$h" "$fps" "$mp4" "$variant" "$passes" > "$dir/frames.tsv" <<'PY'
import re, sys
d, n, peaks = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
variant, passes = int(sys.argv[8]), max(1, int(sys.argv[9]))
deltas, frame = {}, None
for line in open(d + "/delta.txt"):
    m = re.match(r"frame:(\d+)", line)
    if m: frame = int(m.group(1)) + 1
    m = re.search(r"YAVG=([0-9.]+)", line)
    if m and frame is not None: deltas[frame] = float(m.group(1))
# Each pass sees other phases: the quarter stills shift by variant/passes of a quarter (start and end stay).
shift = (variant % passes) * n // (4 * passes)
fixed = [("start", 0), ("q1", min(n - 1, n // 4 + shift)), ("mid", min(n - 1, n // 2 + shift)),
         ("q3", min(n - 1, 3 * n // 4 + shift)), ("end", n - 1)]
used = [f for _, f in fixed]
rows = list(fixed)
# Motion peaks: pass k skips the k*peaks//2 biggest (already seen by earlier passes) so every pass sees new motion.
cand = [f for f, v in sorted(deltas.items(), key=lambda kv: -kv[1]) if f < n]
skip = variant * max(1, peaks // 2)
for f in cand[skip:] + cand[:skip]:
    if len(rows) >= len(fixed) + peaks: break
    if any(abs(f - u) < 4 for u in used): continue
    rows.append(("peak%.1f" % deltas[f], f)); used.append(f)
for i, (tag, f) in enumerate(rows):
    print("%02d\t%s\t%d" % (i, tag, f))
with open(d + "/deltas.tsv", "w") as o:
    for f in range(1, n): o.write("%d\t%.2f\n" % (f, deltas.get(f, 0.0)))
PY
  local i tag f
  while IFS=$'\t' read -r i tag f; do
    ffmpeg -v error -y -i "$mp4" -vf "select=eq(n\\,$f)" -frames:v 1 -q:v 2 "$dir/still_${i}_${tag%%.*}_f$f.jpg"
  done < "$dir/frames.tsv"
  # Motion bursts: the five consecutive frames around each of the first two peaks of this pass, stacked top to bottom at
  # half size, so the judge sees motion frame to frame (a pop, a teleport, a hand leaving the gun), not just stills.
  local b=0 pf lo
  while IFS=$'\t' read -r i tag f; do
    [[ $tag == peak* ]] || continue
    ((b < 2)) || break
    lo=$((f - 2)); ((lo < 0)) && lo=0
    ffmpeg -v error -y -i "$mp4" -vf "select=between(n\\,$lo\\,$((lo + 4))),scale=iw/2:-2,tile=1x5" -frames:v 1 -q:v 2 "$dir/burst_${b}_f${lo}-$((lo + 4)).jpg"
    b=$((b + 1))
  done < "$dir/frames.tsv"
  # A close-up of one camera per pass after the first (pass 2 first person, pass 3 behind-right, ...), cropped from
  # the mid still and the first peak and doubled, so small parts (a magazine, fingers on a grip) are judged up close.
  if ((variant > 0 && cameras > 0)); then
    local cam=$(((variant - 1) % cameras)) cw=$((w / cameras)) s
    for s in "$dir"/still_02_*.jpg "$dir"/still_05_*.jpg; do
      [[ -f $s ]] || continue
      ffmpeg -v error -y -i "$s" -vf "crop=$cw:$h:$((cam * cw)):0,scale=iw*2:-2:flags=lanczos" -q:v 2 "$dir/focus_cam${cam}_$(basename "$s")"
    done
  fi
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
    echo "burst_N_fA-B.jpg: frames A..B consecutive, top to bottom, half size: judge motion between neighbouring frames"
    ((variant > 0)) && echo "focus_camC_*.jpg: camera C (0 first person, 1 behind-right, 2 opponent) of that still, cropped and doubled"
    echo "pass variant: $variant${SHOT_VQA_VARIANT:+ (capture variant $SHOT_VQA_VARIANT: other camera angles and light)}"
  } > "$dir/pack.txt"
  rm -f "$dir/delta.txt"
}

judge_prompt() {
  cat << EOF
You are a FRESH visual judge for a game studio. You have never seen this work and you did not make it. Your job is to
decide whether this clip would ship in a modern FPS (CS:S, CS2, Valorant, Apex). Default: it would NOT.

1. Read the rubric: $rubric
2. Read pack.txt in the current directory, then Read EXACTLY the file names listed under "files to read" at its end (never guess or
   reconstruct a name from the stills table: its labels are not file names). That is every image at full size: every still,
   every burst (consecutive frames: look for pops, teleports, hands leaving the gun between neighbours), every focus
   close-up, and delta_strip.jpg${3:+ and every *_sheet.png}. Each image needs its own Read call; the tool checks. Do not skip any; do not read anything outside this directory except the rubric.
   There are no metrics and no author notes on purpose: judge only what you see.
3. Write ./verdict.json (and nothing else) in ONE Write call, to the rubric's schema for subject "$1" (item "$2"):
   - "looked_at": the file name of every image you read, in the order you read them.
   - "frames": one entry per image you read ("file", "camera", "findings"), with what you saw in EACH camera, even when
     it is fine (at least a sentence per image).
   - "defects": every problem, with category, severity (blocker|major|minor), camera, frames, what, fix_hint, "nightly": "".
     Minor defects count: a pass needs zero defects of any severity.
   - "categories_clean": for every rubric category with no defect, the frames that show it is clean.
   - "production_ready": true only if "defects" is empty; "justification" says why, category by category.
You have only Read and Write: to change the verdict, Write the whole file again (never patch it; a verdict that is not
exactly what you Wrote is refused as forged).
Be strict and specific ("the magazine is about 3x the magwell, in still_02"). A thin justification is a wrong verdict.
EOF
}

# Checks a verdict: it parses, it lists every image, production_ready matches the defects. Prints why it is invalid.
check_verdict() {
  python3 - "$1" "$2" << 'PY'
import json, os, sys
v, d = sys.argv[1], sys.argv[2]
try:
    with open(v) as f: j = json.load(f)
except Exception as e: print("unreadable: %s" % e); sys.exit(1)
if not isinstance(j, dict): print("verdict.json is not a JSON object"); sys.exit(1)
def lst(k):
    x = j.get(k)
    return x if isinstance(x, list) else []
imgs = sorted(f for f in os.listdir(d) if f.endswith((".jpg", ".png")))
frames = [fr for fr in lst("frames") if isinstance(fr, dict)]
seen = set(os.path.basename(str(fr.get("file", ""))) for fr in frames)
defects = lst("defects")
bad = []
if not isinstance(j.get("frames"), list) or len(frames) != len(lst("frames")): bad.append("frames is not a list of objects")
if not isinstance(j.get("defects", []), list): bad.append("defects is not a list")
if [x for x in defects if not isinstance(x, dict)]: bad.append("a defect is not an object")
missing = [f for f in imgs if f not in seen]
if missing: bad.append("frames does not cover %s" % ", ".join(missing))
if not isinstance(j.get("production_ready"), bool): bad.append("production_ready is not true/false")
if len(str(j.get("justification", "")).strip()) < 40: bad.append("justification missing or thin")
if j.get("production_ready") is True and defects: bad.append("production_ready true with %d defects (a pass needs zero)" % len(defects))
looked = set(os.path.basename(str(x)) for x in lst("looked_at"))
if not looked: bad.append("no looked_at list")
elif [f for f in imgs if f not in looked]: bad.append("looked_at misses %s" % ", ".join(f for f in imgs if f not in looked))
thin = [str(fr.get("file")) for fr in frames if len(str(fr.get("findings", "")).strip()) < 20]
if thin: bad.append("no real findings for %s" % ", ".join(thin[:5]))
if j.get("production_ready") is False and not defects: bad.append("production_ready false with no defects")
if bad: print("; ".join(bad)); sys.exit(1)
PY
}

# The judge's own transcript (stream-json) is the evidence: its session id, every image it Read, the verdict it Wrote.
# Writes evidence.json; fails (printing why) when the judge did not Read an image or verdict.json is not what it wrote.
evidence() {
  python3 - "$1" "$model" "$2" "$3" "$4" "$pass" "$variant" "$round" "$source" "$renderer" "$out" "$passes" << 'PY'
import hashlib, json, os, re, sys
d, model = sys.argv[1], sys.argv[2]
item, clip, mp4, pas, variant, rnd, source, renderer, out, need = sys.argv[3:13]
sid, reads, writes, failed, patched = None, [], [], set(), []
target = os.path.realpath(os.path.join(d, "verdict.json"))
for line in open(os.path.join(d, "judge.jsonl"), errors="replace"):
    try: e = json.loads(line)
    except ValueError: continue
    if not isinstance(e, dict): continue
    sid = sid or e.get("session_id")
    msg = e.get("message") if isinstance(e.get("message"), dict) else {}
    for c in msg.get("content") if isinstance(msg.get("content"), list) else []:
        if not isinstance(c, dict): continue
        if c.get("type") == "tool_result" and c.get("is_error"): failed.add(c.get("tool_use_id"))
        if c.get("type") != "tool_use": continue
        inp = c.get("input") if isinstance(c.get("input"), dict) else {}
        # Anything but Write that changes verdict.json (Edit, MultiEdit, a Bash redirect or sed) leaves a file the judge
        # never Wrote whole. This is the abort builders hit: with only --allowedTools the judge still had Edit.
        if c.get("name") in ("Edit", "MultiEdit", "NotebookEdit") and os.path.basename(str(inp.get("file_path", ""))) == "verdict.json":
            patched.append(c.get("name"))
        if c.get("name") == "Bash" and "verdict.json" in str(inp.get("command", "")) and re.search(r"[>]|sed\s+-i|tee|mv\s|cp\s|truncate", str(inp.get("command", ""))):
            patched.append("Bash")
        if c.get("name") == "Read": reads.append(os.path.basename(str(inp.get("file_path", ""))))
        if c.get("name") == "Write" and os.path.basename(str(inp.get("file_path", ""))) == "verdict.json":
            writes.append((c.get("id"), os.path.realpath(str(inp.get("file_path"))),
                           hashlib.sha256(str(inp.get("content", "")).encode()).hexdigest()))
# A Write the tool refused (is_error) left the file as it was, and a verdict.json written elsewhere is not this one: the
# file on disk must be the last Write that landed on this path.
landed = [w for w in writes if w[0] not in failed and w[1] == target]
wrote = landed[-1][2] if landed else None
hashes = dict(reversed(l.split(None, 1)) for l in open(os.path.join(d, "images.sha256")).read().splitlines() if l.strip())
hashes = {k.strip().lstrip("*"): v for k, v in hashes.items()}
bad = []
if not sid: bad.append("no judge session id in judge.jsonl")
unread = sorted(f for f in hashes if f not in reads)
if unread: bad.append("the judge never Read %s" % ", ".join(unread))
have = hashlib.sha256(open(os.path.join(d, "verdict.json"), "rb").read()).hexdigest()
if wrote != have:
    why = "%d Write(s) of a verdict.json, %d refused, %d to this path" % (len(writes), sum(1 for w in writes if w[0] in failed), sum(1 for w in writes if w[1] == target))
    if not any(w[2] == have for w in writes): why += ", none matches the file"
    if patched: why += "; the judge also changed it with %s (it may only Write the whole file)" % ", ".join(sorted(set(patched)))
    bad.append("verdict.json is not the file the judge wrote (%s)" % why)
json.dump({"judge_session": sid, "judge_model": model, "reads": reads, "images": hashes, "verdict_sha256": have,
           "item": item, "clip": clip, "mp4": mp4, "mp4_sha256": hashlib.sha256(open(mp4, "rb").read()).hexdigest(),
           "pass": int(pas), "variant": int(variant), "round": int(rnd), "source": source, "renderer": renderer,
           "out": out, "passes_required": int(need)}, open(os.path.join(d, "evidence.json"), "w"), indent=2)
if bad: print("; ".join(bad)); sys.exit(1)
PY
}

run_judge() {
  local dir=$1 subj=$2 item=$3 clip=$4 mp4=$5 why rc
  for attempt in 1 2; do
    rm -f "$dir/verdict.json" "$dir/evidence.json"
    judge_cmd
    (cd "$dir" && "${jc[@]}" -p "$(judge_prompt "$subj" "$item" "$(ls "$dir"/*sheet* 2> /dev/null)")" --model "$model" \
      --tools "Read,Write" --allowedTools "Read,Write" --permission-mode acceptEdits --add-dir "$(dirname "$rubric")" \
      --output-format stream-json --verbose > "$dir/judge.jsonl" 2> "$dir/judge.log")
    rc=$?
    if ((rc == 124 || rc == 137)); then why="the judge ran past ${judge_timeout}s and was killed"
    elif ! why=$(check_verdict "$dir/verdict.json" "$dir"); then why="$why (judge exit $rc: $(tail -c 300 "$dir/judge.log" | tr '\n' ' '))"
    elif why=$(evidence "$dir" "$item" "$clip" "$mp4") && why=$(python3 "$gate" --pack "$dir"); then return 0
    fi
    echo "gs_game_visual_judge.sh: judge $attempt for $subj wrote an invalid verdict ($why)" >&2
    echo "INVALID: $why" >> "$dir/judge.log"
    # The retry rewrites judge.jsonl and judge.log: keep this attempt's, it is the only evidence of what went wrong.
    cp -f "$dir/judge.jsonl" "$dir/judge.attempt$attempt.jsonl" 2> /dev/null; cp -f "$dir/judge.log" "$dir/judge.attempt$attempt.log" 2> /dev/null
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

# Files every open defect of the last pass: one nightly item per game and category (vj-<game>-<category>, reopened when
# it was done), each defect a note naming its clip, pack, round and judge session (the gate checks that the key names
# the session). Writes the keys back into verdict.json after each one. Exit 1 when any defect could not be filed.
file_defects() {
  python3 - "$out/verdict.json" "$game" "$repos" "$nightly" << 'PY'
import json, re, subprocess, sys, getpass
v, game, repos, nightly = sys.argv[1:5]
with open(v) as f: j = json.load(f)
cmd = [nightly] if getpass.getuser() == "core" or nightly != "/home/core/stack/nightly/bin/nightly" else ["sudo", "-n", "-u", "core", nightly]
def run(*a):
    try: return subprocess.run(cmd + list(a), capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e: return subprocess.CompletedProcess(cmd, 1, "", str(e))
def save():
    with open(v + ".tmp", "w") as f: json.dump(j, f, indent=2)
    import os; os.replace(v + ".tmp", v)
filed = failed = 0
for it in j.get("items") or []:
    if not isinstance(it, dict): continue
    for d in it.get("defects") or []:
        if not isinstance(d, dict) or d.get("nightly"): continue  # every severity: a pass needs zero defects
        cat = str(d.get("category") or "other")
        key = re.sub(r"-+", "-", re.sub(r"[^a-z0-9-]+", "-", ("vj-%s-%s" % (game, cat)).lower())).strip("-")
        frames = d.get("frames")
        frames = ", ".join(map(str, frames)) if isinstance(frames, list) else str(frames or "?")
        line = "[%s] %s %s, %s camera, frames %s: %s\nFix hint: %s\nPack: %s round %s judge session %s" % (
            d.get("severity"), it.get("item"), it.get("clip"), d.get("camera", "?"), frames, d.get("what", ""),
            d.get("fix_hint", ""), it.get("pack", ""), j.get("round", "?"), it.get("judge_session", "?"))
        shown = run("show", key)
        if shown.returncode == 0:
            if re.search(r"^status: (done|dropped|wontfix)", shown.stdout, re.M):
                run("set", key, "--status", "queue")
            r = run("note", key, "--by", "session", line)
        else:
            body = ("Unresolved %s defects from the fresh visual judge (gs_game_visual_judge.sh); one per note. "
                    "Done when a fresh judge finds no %s defect in these clips.\n\n%s" % (cat, cat, line))
            r = run("add", "--title", "%s visual: %s defects (judge)" % (game, cat), "--key", key, "--kind", "issue",
                    "--repos", repos, "--by", "session", "--body", body)
        if r.returncode != 0:
            print("could not file %s: %s" % (key, (r.stderr or r.stdout).strip()[:300]), file=sys.stderr); failed += 1; continue
        d["nightly"] = key; filed += 1
        save()
        print("filed %s" % key)
print("%d defects filed, %d failed" % (filed, failed))
sys.exit(1 if failed else 0)
PY
}

round_file=$out/round
round=$(cat "$round_file" 2> /dev/null || echo 0)
[[ $round =~ ^[0-9]+$ ]] || round=0
renderer=
while :; do
  round=$((round + 1))
  echo "$round" > "$round_file"
  # A round starts clean: the old run verdict and every old pack go, so nothing from an earlier round can count.
  rm -rf "$out/verdict.json" "$out/results.tsv" "$out"/pass[0-9]*
  # The source state the streak is about: the checkout's HEAD, its uncommitted diff and the capture command. Any change
  # (a fix between rounds) starts a new streak; the streak never carries across rounds.
  source=$( { git rev-parse HEAD 2> /dev/null; git diff HEAD 2> /dev/null; echo "$capture"; } | sha256sum | cut -c1-16)
  rm -f "$out/passes.tsv"
  for ((pass = 1; pass <= passes; pass++)); do
    variant=$((pass - 1))
    if [[ -n $capture ]]; then
      echo "gs_game_visual_judge.sh: round $round pass $pass/$passes: capture (SHOT_VQA_VARIANT=$variant): $capture"
      touch "$out/.pass_start"
      SHOT_VQA_VARIANT=$variant bash -c "$capture" > "$out/capture_round${round}_pass$pass.log" 2>&1 ||
        echo "gs_game_visual_judge.sh: the capture exited non-zero (see $out/capture_round${round}_pass$pass.log); judging what it made" >&2
      mapfile -t logs < <(find "$clips" -maxdepth 2 -name '*.log' -newer "$out/.pass_start" 2> /dev/null; echo "$out/capture_round${round}_pass$pass.log")
    else
      mapfile -t logs < <(find "$clips" -maxdepth 2 -name '*.log' -not -path "$out/*" 2> /dev/null | head -20)
    fi
    check_gpu "${logs[@]}"
    mapfile -t rows < <(list_clips)
    ((${#rows[@]})) || code=4 die "no clips under $clips${only:+ for $only}${anims:+ / $anims}"
    # Every requested item and clip must be there: a missing clip is never silently left unjudged.
    have=$(printf '%s\n' "${rows[@]}" | cut -f1,2)
    for w in ${only//,/ }; do cut -f1 <<< "$have" | grep -qxF -- "$w" || code=4 die "--only $w: no clip for it under $clips"; done
    for w in ${anims//,/ }; do cut -f2 <<< "$have" | grep -qxF -- "$w" || code=4 die "--anims $w: no clip by that name under $clips"; done
    results=()
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r item clip mp4 <<< "$row"
      dir=$out/pass$pass/$item/$clip
      if [[ -n $capture && ! $mp4 -nt $out/.pass_start ]]; then
        code=4 die "$mp4 is older than this pass's capture: the capture did not write it (stale clip); fix the capture"
      fi
      make_pack "$mp4" "$dir" "$variant" || code=4 die "could not build the judge pack for $mp4 (see above): no clip is skipped"
      for s in "$(dirname "$mp4")/${clip}"*sheet*.png "$(dirname "$mp4")/${item}_sheet.png"; do [[ -f $s ]] && cp "$s" "$dir/"; done
      # pack.txt is written before the sheets are copied. Append the exact file name of EVERY image the verdict must
      # cover (stills, bursts, focus close-ups, delta strip, sheets): the judge has only Read (no ls) and the still names
      # differ from the table above (peak2.3 is still_05_peak2_f94.jpg), so it must never have to guess a name.
      shopt -s nullglob; allimgs=("$dir"/*.jpg "$dir"/*.png); shopt -u nullglob
      { echo "files to read (EXACT names, one Read call each, at full size; every one needs an entry in frames and looked_at; sheets are contact sheets of the clip):"
        for s in "${allimgs[@]}"; do echo "  $(basename "$s")"; done; } >> "$dir/pack.txt"
      # Every pack image is hashed after the sheets are in (the judge must Read each one).
      (cd "$dir" && sha256sum -- *.jpg *.png 2> /dev/null > images.sha256)
      if ((judge == 0)); then echo "pack: $dir"; continue; fi
      subj="${subject:-$game} $item $clip"
      if run_judge "$dir" "$subj" "$item" "$clip" "$mp4"; then results+=("$item"$'\t'"$clip"$'\t'"$dir")
      else code=5 die "no valid verdict for $subj after two fresh judges (see $dir/judge.log)"; fi
    done
    ((judge == 1)) || { echo "gs_game_visual_judge.sh: packs only (--no-judge): this is not a verdict"; exit 1; }
    printf '%s\n' "${results[@]}" > "$out/results.tsv"
    cp "$out/results.tsv" "$out/pass$pass/results.tsv"
    printf '%s\t%s\t%s\n' "$pass" "$variant" "$out/pass$pass" >> "$out/passes.tsv"
    # A pass is clean when every clip's fresh verdict is production_ready with zero defects; the first unclean pass
    # ends the streak and the round (later passes would only spend judges on a known failure).
    python3 -c 'import json,sys; sys.exit(0 if all(json.load(open(l.split("\t")[2].strip()+"/verdict.json")).get("production_ready") is True and not json.load(open(l.split("\t")[2].strip()+"/verdict.json")).get("defects") for l in open(sys.argv[1]) if l.strip()) else 1)' "$out/results.tsv" || break
    echo "gs_game_visual_judge.sh: round $round pass $pass/$passes clean"
  done
  # The run's verdict: the last pass's clips (the failing one, or pass N) with the streak. The streak comes from this
  # round's passes only (pass1..N were cleared at the round start); the gate's audit, which re-derives everything from
  # the packs and the judges' transcripts, decides the exit.
  python3 - "$out/verdict.json" "$round" "$model" "$out/results.tsv" "$out/passes.tsv" "$passes" "$source" "${capture:+1}" << 'PY'
import json, os, sys
out, rnd, model, res, ptsv, need, source, captured = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]), sys.argv[7], sys.argv[8] == "1"
def load(d):
    with open(d + "/verdict.json") as f: v = json.load(f)
    with open(d + "/evidence.json") as f: ev = json.load(f)
    return v, ev
def rows(path):
    with open(path) as f: return [l.rstrip("\n").split("\t") for l in f if l.strip()]
items = []
for item, clip, d in rows(res):
    v, ev = load(d)
    v.update({"item": item, "clip": clip, "pack": d, "judge_session": ev.get("judge_session")})
    items.append(v)
streak = []
for p, variant, pdir in rows(ptsv):
    clips = []
    for item, clip, d in rows(os.path.join(pdir, "results.tsv")):
        v, ev = load(d)
        ok = v.get("production_ready") is True and not v.get("defects")
        clips.append({"item": item, "clip": clip, "pack": d, "clean": ok, "defects": len(v.get("defects") or []),
                      "judge_session": ev.get("judge_session"), "verdict_sha256": ev.get("verdict_sha256"), "images": len(ev.get("images") or {})})
    streak.append({"pass": int(p), "variant": int(variant), "capture_variant": captured, "clean": bool(clips) and all(c["clean"] for c in clips), "clips": clips})
clean_run = 0
for s in streak:
    if not s["clean"]: break
    clean_run += 1
ready = bool(items) and clean_run >= need
tmp = out + ".tmp"
with open(tmp, "w") as f:
    json.dump({"round": rnd, "judge_model": model, "production_ready": ready, "passes_required": need,
               "passes_clean": clean_run, "source": source, "streak": streak, "items": items}, f, indent=2)
os.replace(tmp, out)
print("streak: %d/%d consecutive clean passes%s" % (clean_run, need, "" if captured else " (no --capture: phase/burst/close-up variants only, no new camera angles or light)"))
for v in items:
    print("%-6s %s %s: %s" % ("CLEAN" if v.get("production_ready") is True and not v.get("defects") else "NOT", v["item"], v["clip"], str(v.get("justification", ""))[:200]))
    for d in v.get("defects") or []:
        print("   %s %-8s %-10s %s" % (d.get("id", "-"), d.get("severity"), d.get("category"), str(d.get("what", ""))[:160]))
PY
  [[ -f $out/verdict.json ]] || code=5 die "could not write $out/verdict.json"
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("production_ready") is True else 1)' "$out/verdict.json"; then
    if audit=$(python3 "$gate" --audit "$out/verdict.json"); then
      echo "$audit"
      echo "gs_game_visual_judge.sh: PRODUCTION READY ($passes consecutive clean fresh judges) after $round round(s): $out/verdict.json"
      exit 0
    fi
    echo "$audit" >&2
    code=5 die "the streak looked clean but the audit of its packs is not sound (above): nothing is ready"
  fi
  if ((give_up == 1)) || ((max_rounds > 0 && round >= max_rounds)); then
    file_defects || code=1 die "NOT production ready after $round round(s), and some defects could not be filed (above): file them, or fix and judge again"
    echo "gs_game_visual_judge.sh: NOT production ready after $round round(s); every open defect is filed in nightly (see $out/verdict.json)" >&2
    exit 3
  fi
  if [[ -z $fix ]]; then
    echo "gs_game_visual_judge.sh: NOT production ready (round $round). Fix the defects at their source and run this again; --give-up files them." >&2
    exit 1
  fi
  [[ -n $capture ]] || code=2 die "--fix-cmd needs --capture to recapture after the fix"
  echo "gs_game_visual_judge.sh: round $round failed; fixing: $fix"
  VERDICT=$out/verdict.json bash -c "$fix" > "$out/fix_round$round.log" 2>&1 || echo "gs_game_visual_judge.sh: the fix exited non-zero (see $out/fix_round$round.log)" >&2
done
