#!/usr/bin/env bash
# The capture step of the visual QA loop (docs/visual-qa.md): hands the game's shot tool to a GPU box (gpu.sh shot
# --route, which copies the clips back with --pull), falls back to heavy here when no box takes it, files each clip as
# <out>/<item>/<clip>.mp4 next to its sheets, and writes <out>/report.md from the VISUALQA lines. Run it as gamedev
# (who holds the box key) from the game checkout or a ~/wt worktree:
#   bash addons/gs_game/tools/gs_game_visual_qa.sh --shot tools/visual_qa_shot.sh [--out DIR] [--fps 60] [--fresh all|a,b]
#        [--soft] [--no-report] [--timeout 3500] [-- capture args, e.g. --only rifle --clips fire,reload]
# --fresh deletes those items' old sheets and clips first; --soft stays here on software rendering (slow; llvmpipe can
# crash on big scenes); --no-report leaves report.md to the game (FC writes its own). The log is <out>/capture.log.
set -euo pipefail
cd "$(dirname "$0")/../../.."
shot= out=screenshots/visual_qa fps=60 fresh= soft=0 report=1 limit=3500
while (($#)); do
  case $1 in
    --shot) shot=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --fps) fps=$2; shift 2 ;;
    --fresh) fresh=$2; shift 2 ;;
    --soft) soft=1; shift ;;
    --no-report) report=0; shift ;;
    --timeout) limit=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "gs_game_visual_qa.sh: unknown option $1 (capture arguments go after --)" >&2; exit 2 ;;
  esac
done
[[ $shot == tools/*.sh && -f $shot ]] || { echo "gs_game_visual_qa.sh: --shot must name the game's tools/*.sh shot wrapper (gpu.sh runs only those): '$shot'" >&2; exit 2; }
[[ $fps =~ ^[0-9]+$ && $fps -ge 1 ]] || { echo "gs_game_visual_qa.sh: --fps must be a whole number of at least 1, not $fps" >&2; exit 2; }
[[ $limit =~ ^[0-9]+$ ]] || { echo "gs_game_visual_qa.sh: --timeout must be whole seconds (0 = none), not $limit" >&2; exit 2; }
# heavy and the godot it hands on live in gamedev's own bin dirs, which sudo -u gamedev leaves off PATH.
command -v heavy > /dev/null || PATH=$HOME/bin:$HOME/.local/bin:/home/gamedev/bin:/home/gamedev/.local/bin:$PATH
command -v heavy > /dev/null || { echo "gs_game_visual_qa.sh: no heavy on PATH (run as gamedev)" >&2; exit 2; }
log=$out/capture.log
mkdir -p "$out"
# Only the named items' old output goes: a run for one item keeps every other item's review.
if [[ $fresh == all ]]; then
  rm -f "$out"/*/*_sheet.png "$out"/*/*_metrics.json "$out"/*/*.mp4
elif [[ -n $fresh ]]; then
  IFS=, read -ra picked <<< "$fresh"
  for w in "${picked[@]}"; do
    [[ -n $w && $w != */* && $w != .* ]] && rm -f "$out/$w"/*_sheet.png "$out/$w"/*_metrics.json "$out/$w"/*.mp4
  done
fi
[[ $soft == 1 ]] && export GPU_OFFLOAD=0
# The clips come back through a scratch directory at the same absolute path on the box and here.
clips=$(mktemp -d /tmp/visual-qa-clips.XXXXXX)
chmod 755 "$clips"
trap 'rm -rf "$clips"' EXIT
cmd=("$shot" --out "$out" --clip-dir "$clips" --fps "$fps" "$@")
run=(timeout "$limit")
((limit > 0)) || run=()
gpu=$(dirname "$PWD")/gpu.sh
rc=75
# --route: exit 75 when no box takes it (then heavy queues it here), else the tool's own exit code.
if [[ $soft == 0 && -x $gpu ]]; then
  rc=0
  route=(--timeout "$limit")
  ((limit > 0)) || route=()
  SHOT_DIR=$PWD GPU_SHOT_WAIT=${GPU_SHOT_WAIT:-1500} "$gpu" shot --route "${route[@]}" --pull "$clips" "$(basename "$PWD")" "${cmd[@]}" > "$log" 2>&1 || rc=$?
fi
if [[ $rc == 75 ]]; then
  rc=0
  heavy -- "${run[@]}" "${cmd[@]}" > "$log" 2>&1 || rc=$?
fi
for c in "$clips"/*__*.mp4; do
  [[ -e $c ]] || continue
  n=$(basename "$c" .mp4)
  mkdir -p "$out/${n%%__*}" && mv "$c" "$out/${n%%__*}/${n#*__}.mp4"
done
grep -E 'SCRIPT ERROR|ERROR|failed' "$log" | head -5 >&2 || true
((report == 1)) || exit $rc
python3 - "$out" "$log" "$fps" <<'PY' || rc=$?
import json, os, sys
out, log, fps = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = [json.loads(l[len("VISUALQA "):]) for l in open(log, errors="replace") if l.startswith("VISUALQA {")]
judged = sorted((r for r in rows if "pass" in r), key=lambda r: (r["item"], r["clip"]))
skipped = sorted((r for r in rows if "pass" not in r), key=lambda r: (r["item"], r["clip"]))
lines = ["# Visual QA", "", "fps: %d (clips play every frame)" % fps, "",
         "Checklist: docs/visual-qa.md in gs-game. The numbers catch foot slide, floor clipping and T-pose; look at the sheets for the rest.", "",
         "| item | clip | verdict | why | first person | behind-right | opponent | clip |", "|---|---|---|---|---|---|---|---|"]
fails = 0
for r in judged:
    base = os.path.join(out, r["item"], r["clip"])
    files = [base + "_fp_sheet.png", base + "_tp_sheet.png", base + "_op_sheet.png", base + ".mp4"]
    fails += 0 if r["pass"] else 1
    why = "; ".join(r["fail"]) if r["fail"] else "worst " + ", ".join("%s %s" % kv for kv in r.get("worst", {}).items())
    lines.append("| %s | %s | %s | %s | %s |" % (r["item"], r["clip"], "PASS" if r["pass"] else "FAIL", why,
        " | ".join(os.path.abspath(f) if os.path.exists(f) else "missing" for f in files)))
for r in skipped:
    lines.append("| %s | %s | N/A | %s | | | | |" % (r["item"], r["clip"], r.get("why", "")))
lines += ["", "%d clips, %d FAIL, %d not playable" % (len(judged), fails, len(skipped))]
open(os.path.join(out, "report.md"), "w").write("\n".join(lines) + "\n")
print("visual_qa: %d clips, %d PASS, %d FAIL, %d not playable; report %s" % (len(judged), len(judged) - fails, fails, len(skipped), os.path.abspath(os.path.join(out, "report.md"))))
if not rows:
    sys.exit("visual_qa: nothing captured (see %s; llvmpipe crashes, so wait for a GPU box with GPU_SHOT_WAIT)" % log)
PY
exit $rc
