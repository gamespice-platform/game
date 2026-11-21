#!/usr/bin/env bash
# The suite step of the Nightly Performance gate: `nightly perf gate --game $PERF_GAME` judges the latest recorded run of this game
# against its budgets and the noise-aware baseline. Called by a game's `./game.sh test` after the suites and by `./game.sh perf-gate`.
#   PERF_GAME   the game's slug in Nightly (the game's tools/perf.sh sets it; pass it in the environment here)
#   PERF_GATE   warn (default): print the verdict, never fail the suite; strict: a failed gate fails (exit 1); off: skip
# Exit: 0 pass / warn / skipped (no `nightly` on this machine, no run recorded yet), 1 strict and the gate failed.
mode=${PERF_GATE:-warn}
[[ $mode == off ]] && exit 0
game=${PERF_GAME:-}
[[ -n $game ]] || { echo "perf-gate: PERF_GAME is not set; skipped" >&2; exit 0; }
command -v nightly >/dev/null 2>&1 || { echo "perf-gate: no nightly on this machine; skipped"; exit 0; }
out=$(nightly perf gate --game "$game" 2>&1); rc=$?
printf '%s\n' "$out"
case $rc in
	0) echo "perf-gate: $game pass" ;;
	2) echo "perf-gate: $game has no recorded run yet; skipped" ;;
	*) echo "perf-gate: $game FAILED its budgets or regressed against the baseline ($mode)"; [[ $mode == strict ]] && exit 1 ;;
esac
exit 0
