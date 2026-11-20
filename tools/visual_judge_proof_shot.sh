#!/usr/bin/env bash
# The judge loop's GPU proof capture (tests/visual_judge/proof_capture.gd): gpu.sh runs only a project's tools/*.sh.
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_visual_qa_shot.sh" --script tests/visual_judge/proof_capture.gd -- "$@"
