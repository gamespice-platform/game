#!/usr/bin/env bash
# The game contract of the Nightly Performance tab: arguments in, one perf report v1 (dot-profiler docs/perf-report.md) out.
# A game's tools/perf.sh is
#   export PERF_GAME=fc PERF_SERVER_SCENE=res://tools/x.tscn PERF_SERVER_BOTS_ARG='--n=%d' ...
#   exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_perf.sh" "$@"
#
#   tools/perf.sh --platform native|web --role client|server [--bots N] [--map M] [--duration S] [--out report.json] [--box staging02] [-- extra args]
#
# native client: the game's perf bench (tools/perf_bench.sh, a DotGamePerfBench) windowed on a GPU box through gpu.sh: Vulkan on the
#   NVIDIA card. The report's gpu string is checked and a software renderer (llvmpipe, swiftshader, empty) is refused (exit 4): a frame
#   time from it says nothing about a player's machine.
# native server: the game's headless dedicated-server scene (PERF_SERVER_SCENE; PERF_SERVER_BOTS_ARG and PERF_SERVER_MAP_ARG are printf
#   formats for the scene's own flags) under dot-profiler's dot_profiler_run.tscn on this box. Headless has no renderer, so the report is
#   the per-frame and per-system cost (the tick breakdown the scene reports through DotFrameCost), not a draw time.
# web: the game's PERF_WEB_CMD (a command that writes a perf report v1 to $PERF_OUT), run through gpu.sh cdp-run so Chrome has real WebGL on
#   the GPU box. A game without it exits 3 ("web capture not wired"), never a fake report.
# Exit: 0 report written, 2 bad arguments, 3 not supported, 4 software renderer, 1 run failed. The report path is the last stdout line.
# Environment: PERF_GAME (game_id), PERF_BENCH (default tools/perf_bench.sh), PERF_TIMEOUT (default 900 s), PERF_WARMUP (default 8 s),
# PERF_BOX (default staging02), PERF_BENCH_ARGS (extra bench args), PERF_BUDGET_MS (server spike threshold, default 16.7).
set -euo pipefail

here=$(cd "${PERF_PROJECT:-$(dirname "$0")/../../..}" && pwd)
platform=native role=client bots=4 map="" duration=20 out="" box=${PERF_BOX:-staging02}
while [[ $# -gt 0 ]]; do
	case $1 in
		--platform) platform=$2; shift 2 ;;
		--role) role=$2; shift 2 ;;
		--bots) bots=$2; shift 2 ;;
		--map) map=$2; shift 2 ;;
		--duration) duration=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		--box) box=$2; shift 2 ;;
		--) shift; break ;;
		*) echo "perf: unknown option $1" >&2; exit 2 ;;
	esac
done
[[ $platform == native || $platform == web ]] || { echo "perf: --platform native|web" >&2; exit 2; }
[[ $role == client || $role == server ]] || { echo "perf: --role client|server" >&2; exit 2; }
[[ $bots =~ ^[0-9]+$ && $duration =~ ^[0-9]+$ ]] || { echo "perf: --bots and --duration are whole numbers" >&2; exit 2; }
game=${PERF_GAME:-$(basename "$here")}
warm=${PERF_WARMUP:-8}
tmo=${PERF_TIMEOUT:-900}
[[ -n $out ]] || out="$here/.godot/perf-report-$game-$platform-$role.json"
mkdir -p "$(dirname "$out")"
log="${out%.json}.log"
: > "$log"

# Write the PERF_REPORT_V1 line of $log to $out, stamping what this script knows and the report may lack.
extract() {
	python3 - "$log" "$out" "$game" "$platform" "$role" <<'PY'
import json, sys
log, out, game, platform, role = sys.argv[1:6]
rep = None
for line in open(log, errors="replace"):
    if line.startswith("PERF_REPORT_V1 "):
        rep = json.loads(line[len("PERF_REPORT_V1 "):])
if rep is None:
    sys.exit(1)
if not rep.get("game_id"):
    rep["game_id"] = game
rep["platform"] = platform
rep["role"] = role
json.dump(rep, open(out, "w"), indent=1)
PY
}

case "$platform/$role" in
	native/client)
		bench=${PERF_BENCH:-$here/tools/perf_bench.sh}
		[[ -f $bench ]] || { echo "perf: no $bench" >&2; exit 3; }
		# shellcheck disable=SC2086
		GPU_TIMEOUT=$tmo bash "$bench" --box "$box" --tag "perf-$game" -- ${map:+--map "$map"} --bots "$bots" --seconds "$duration" --warmup "$warm" ${PERF_BENCH_ARGS:-} "$@" > "$log" 2>&1 || true
		# The bench prints its summary here and keeps the whole run (with the PERF_REPORT_V1 line) in a log of its own: "... -> <log>".
		benchlog=$(sed -n 's/^perf_bench: .* -> \(\/.*\.log\)$/\1/p' "$log" | head -1)
		[[ -n $benchlog && -f $benchlog ]] && cat "$benchlog" >> "$log"
		;;
	native/server)
		scene=${PERF_SERVER_SCENE:-}
		[[ -n $scene ]] || { echo "perf: $game has no PERF_SERVER_SCENE" >&2; exit 3; }
		sargs=()
		# shellcheck disable=SC2059
		[[ -n ${PERF_SERVER_BOTS_ARG:-} ]] && sargs+=("$(printf -- "$PERF_SERVER_BOTS_ARG" "$bots")")
		# shellcheck disable=SC2059
		[[ -n $map && -n ${PERF_SERVER_MAP_ARG:-} ]] && sargs+=("$(printf -- "$PERF_SERVER_MAP_ARG" "$map")")
		(cd "$here" && heavy -- timeout "$tmo" godot --headless --path . res://addons/dot_profiler/tools/dot_profiler_run.tscn -- \
			--profile-scene "$scene" --profile-warmup "$warm" --profile-seconds "$duration" --profile-budget "${PERF_BUDGET_MS:-16.7}" \
			--profile-game "$game" --profile-map "$map" --profile-bots "$bots" --profile-role server "${sargs[@]}" "$@") > "$log" 2>&1 || true
		;;
	web/*)
		[[ -n ${PERF_WEB_CMD:-} ]] || { echo "perf: web capture is not wired for $game (set PERF_WEB_CMD)" >&2; exit 3; }
		export PERF_OUT=$out PERF_BOTS=$bots PERF_MAP=$map PERF_DURATION=$duration PERF_ROLE=$role
		GPU_TIMEOUT=$tmo GPU_BOX=$box bash "${GPU_SH:-/home/gamedev/godot/dot-bootstrap/tools/gpu.sh}" cdp-run -- bash -c "$PERF_WEB_CMD" > "$log" 2>&1 || true
		[[ -s $out ]] && { echo "$out"; exit 0; }
		;;
esac

extract || { echo "perf: no PERF_REPORT_V1 in $log" >&2; tail -15 "$log" >&2; exit 1; }
if [[ $platform == native && $role == client ]]; then
	gpu=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("gpu",""))' "$out")
	if [[ -z $gpu ]] || echo "$gpu" | grep -qiE 'llvmpipe|swiftshader|software|softpipe'; then
		echo "perf: refusing a software renderer ('$gpu'); a real GPU box is required" >&2
		rm -f -- "$out"
		exit 4
	fi
	echo "perf: gpu=$gpu" >&2
fi
echo "$out"
