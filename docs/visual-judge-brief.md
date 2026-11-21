# Visual judge brief

The one brief every agent that touches a model, animation, texture, grip, muzzle, effect, avatar, NPC, weapon or map look is pointed to (nightly prompt, polish briefs, CLAUDE.md files). Link it; do not paraphrase it. `gs_game_visual_judge.sh` sends the judge its prompt itself, so the judge never shares the author's context. Rubric: [visual-judge-rubric.md](visual-judge-rubric.md). Loop details: [visual-qa.md](visual-qa.md#the-judge-loop).

## For the author (paste this block into a brief)

```text
Visual work is done only when gs_game_visual_judge.sh exits 0: 3+ CONSECUTIVE fresh judges, each with ZERO
defects (minor counts), each on a new variant (other phases, motion bursts, a close-up camera, and with --capture
other camera angles and light). Run it as gamedev from the game checkout or your ~/wt worktree:
  bash addons/gs_game/tools/gs_game_visual_judge.sh --capture '<GPU capture command>' \
       --clips <dir of <item>/<clip>.mp4> --only <items> [--anims <clips>] --out <dir>/judge
Capture commands: FC weapons/arms  tools/anim_review.sh . <weapon> --anim <clips> [--avatar]
                  other games      bash addons/gs_game/tools/gs_game_visual_qa.sh <args>   (docs/visual-qa.md)
GPU only (staging02/staging via gpu.sh): the capture log must name the GPU box; llvmpipe or no log exits 4.
Never --soft for a verdict. One run per --out (a second exits 2); a judge is killed after --timeout (1800 s).
Exit 1: read <out>/verdict.json "defects", fix at the SOURCE (model, art row, rig, material; never by moving the
camera, cropping or shortening the clip) and run it again. Exit 0 is the only "done".
Never write or edit verdict.json/evidence.json/judge.jsonl, never judge frames yourself, never report done on a
metric PASS. The post tools re-check the judge's transcript evidence and refuse anything else
(they look up the judge's own Claude transcript, so a hand-made pack is refused).
Stopping with defects open: run once more with --give-up (files vj-<game>-<category>, exits 3) and say so.
Check before reporting: python3 addons/gs_game/tools/gs_game_visual_verdict.py --audit <out>/verdict.json
Cost: a failing pass stops the round, so a bad clip costs one judge; judge only the clips you changed (--only/--anims).
```

## Checklist by subject

| Subject | Capture | What the judge must see |
| --- | --- | --- |
| Weapon (model, grip, reload, fire) | FC `tools/anim_review.sh . <weapon> --anim draw,fire,reload_tactical,reload_empty,ads` | magazine and parts to scale, both hands on the gun, no pops between burst frames, effects from the muzzle/ejection port |
| Avatar / body | FC `tools/anim_review.sh . <weapon> --avatar` (walk, strafe, run, crouch, jump) | feet on the floor, no T-pose, no limb through the gun or body, team colours readable |
| Texture / material | the subject's clip under all 3 passes (light variants) | no untextured or placeholder parts, no stretched UVs, exposure holds in dim and bright light |
| Animation only | the clip plus `--anims` for neighbours it blends with | the bursts: no snap at transitions, the action lands before the clip ends |
| Map look | `gs_game_visual_qa.sh` map route (docs/visual-qa.md) | exposure, scale against doors/crates, no floating props |

## For the judge (sent by the tool, verbatim)

The tool builds this from `judge_prompt` in `addons/gs_game/tools/gs_game_visual_judge.sh`. It tells the judge to:

- read the rubric, then every image in the pack (stills, bursts, focus close-ups, delta strip, sheets) with one Read each;
- describe every image from every camera, even the fine ones, and list them in `looked_at`;
- default `production_ready` to false, set it true only with an empty `defects` list, and justify each category from named frames;
- write `verdict.json` to the schema in the rubric, and nothing else.

## For the supervisor

Before launching polish agents on visuals, check the latest judge run with `python3 addons/gs_game/tools/gs_game_visual_verdict.py --audit <out>/verdict.json`. An agent that reports "production ready" without an audit-clean verdict has not finished; send it back, do not relaunch it from scratch.
