# Visual judge brief

Paste this into any brief, nightly prompt or CLAUDE.md that touches a model, animation, grip, muzzle, effect, avatar or NPC. `dot_game_visual_judge.sh` sends the judge prompt below to a fresh `claude -p` itself, so the judge never shares the author's context.

## For the author (the agent making the change)

```
Visual changes are done only when a fresh judge says production_ready: true.
After any change to a model, animation, grip, muzzle, effect, avatar or NPC:
  bash addons/dot_game/tools/dot_game_visual_judge.sh --capture '<the game's GPU capture command>' \
       --clips <dir with <item>/<clip>.mp4> --only <items> --out <dir>/judge
It captures on a GPU box (staging02/staging; never llvmpipe), builds full-res stills + a delta strip for every
camera, and runs a fresh judge (docs/visual-judge-rubric.md) that writes verdict.json. Exit 0 = production ready.
Exit 1 = read verdict.json defects, fix them at the source (the model, the art row, the rig; never by moving the
camera or cropping), and run it again. Loop until it passes; there is no round cap unless VISUAL_JUDGE_MAX_ROUNDS
is set (0 = unlimited). If you must stop with defects open, run it with --give-up: it files one nightly item per
defect category (each defect a line on it) and fails loudly. Never post, close an item or report "done" on a metric PASS or your own
reading of the frames. The post tools refuse anything without a verdict.
```

## For the judge (sent by the tool, verbatim)

The tool builds this from the template in `addons/dot_game/tools/dot_game_visual_judge.sh` (`judge_prompt`). It tells the judge to:

- read the rubric, then every image in the pack at full size before writing anything; there are no metrics and no author notes;
- describe every still from every camera, even the fine ones;
- default `production_ready` to false and justify each category from named frames;
- write `verdict.json` to the schema in the rubric, and nothing else.
