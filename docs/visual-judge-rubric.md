# Visual judge rubric

A fresh judge reads this before it looks at any frame. It answers one question: **would this ship in a modern FPS (CS:S, CS2, Valorant, Apex) without a player noticing something wrong?** The default answer is **no**. `production_ready: true` must be earned by the frames. A metric PASS, an author's note or "it is better than before" earns nothing.

The tool is `addons/dot_game/tools/dot_game_visual_judge.sh` ([visual-qa.md](visual-qa.md#the-judge-loop)). Why it exists: [visual-qa-root-cause.md](visual-qa-root-cause.md).

## How to read the pack

1. Read **every** image in the pack at full size before you write anything, in order: the stills (start, quarter, mid, three-quarter, end, then the peaks), the motion bursts, any focus close-ups, then the delta strip, then any sheets. One Read per image: the tool checks your transcript and a verdict from a judge that skipped an image is thrown away. There are no metrics in the pack, on purpose. Never read the author's notes.
2. Each still is the clip's cameras side by side: first person, behind-right (a teammate), and the opponent in front. Judge every camera. If a camera is missing, that is a `missing` defect.
3. The delta strip shows how much each frame changed from the one before: bright means motion. A lone bright cell is a pop. A dark run in the middle of an action is a freeze. A bright first or last cell on a loop is a seam.
4. A **burst** (`burst_N_fA-B.jpg`) is five consecutive frames, top to bottom: compare each frame with its neighbour. A part that jumps, grows, vanishes or leaves a hand between two neighbours is a `motion` defect even when every still looks fine. A **focus** image (`focus_camC_*.jpg`) is one camera cropped and doubled: judge small parts there (magazine against the magwell, fingers on the grip and fore-end).
5. For each frame, write what you see, even when it is fine. Name the defect and where it is in the frame ("left third, the magazine").

## Categories

Every defect gets one of these categories and a severity.

| Category | Look for | Blocker when |
| --- | --- | --- |
| `exposure` | Clipped whites, crushed blacks, a milky or grey cast, colour washed out, a scene too bright to read the model's material | the model's material or detail cannot be read, or the image looks like a range or tone-map bug |
| `proportion` | Parts sized against each other and against the hands and body: magazine against receiver, a hand against the grip, a gun against the torso, a head against the shoulders | any part is visibly the wrong size (a magazine over about 1.3 times the magwell, a gun that fills half the screen at the hip) |
| `scale` | The whole item against the world and the camera: viewmodel size on screen, a body against a door or a crate | a player would call it toy-sized or giant |
| `silhouette` | Readable outline from each camera, no broken or degenerate shapes, no inside-out faces | the outline reads as the wrong object, or holes show |
| `texture` | Untextured boxes, flat placeholder colour, stretched or missing UVs, z-fighting, mismatched texel density, blurry or blotchy surfaces, faceted low-poly shapes | a placeholder or untextured part is on screen, or the weapon's row in the [RSI asset audit](rsi-asset-audit.md) has an error flag (LOW_TEX, LOW_TRIS, NO_TEXTURES, MAG_STATIC_RELOAD, PRIMITIVE_AMMO) |
| `hands` | Both hands on the weapon where they should be, fingers wrapped on the grip and the fore-end, no fingers through metal, no claw or flat paddle, the support hand present at idle | a hand is off the gun, through it, or missing when it should hold it |
| `clipping` | Parts passing through each other, the body or the weapon through the camera's near plane, feet below the floor, floating props or hands | any visible intersection or float |
| `motion` | Continuity frame to frame: pops, snaps, jitter, freezes, a loop seam, a part teleporting between hands | any pop or teleport a player sees at 60 fps |
| `timing` | Weight and pacing: anticipation, follow-through, a reload that lands with the ammo count changing, nothing floaty or instant | the action reads as floaty, robotic or unfinished (for example, the clip ends before the reload lands) |
| `effects` | Muzzle flash, tracer, shell and magazine drop start from the right place, in the right direction, and are sized to the gun | an effect starts away from its part |
| `missing` | A camera, a part (magazine, sight, hand, a limb), or the action itself absent from the frames | anything the clip is meant to show is not shown |
| `reference` | Overall quality against CS:S or a modern FPS: does it look shipped or prototype? | it reads as a prototype or programmer art |

Severity: `blocker` means it cannot ship, `major` means a player notices, `minor` means polish. A judge's `production_ready` is true only when `defects` is **empty**: a minor defect fails the pass too. The justification must say why each category is clean, citing frames. A verdict that is true with a thin justification is wrong.

## Passes, the streak and evidence

One clean verdict is not production ready. The tool runs **at least 3 consecutive fresh judges** (`--passes`, `VISUAL_JUDGE_PASSES`, never below 3), each on a new variant: other phase stills, other motion bursts, a close-up of another camera, and with `--capture` a recapture under `SHOT_VQA_VARIANT` (the outside cameras move and the scene's lights turn and dim or brighten). The run is production ready only when every pass is clean; the first defect ends the round and the streak starts again after the fix. Each judge's stream-json transcript is kept: `evidence.json` records its session id, the images it Read with their sha256, and the sha256 of the verdict it wrote. `dot_game_visual_verdict.py` (the post gate, `--audit` to check a run) refuses a verdict whose judge did not read every image, whose images or verdict changed afterwards, whose passes reuse a variant or a judge session, or whose streak is short. Authors never write or edit `verdict.json`, `evidence.json` or `judge.jsonl`.

## verdict.json

```json
{
  "subject": "fc battle_rifle reload_empty",
  "judge": "fresh claude -p, no author context",
  "cameras": ["first_person", "behind_right", "opponent"],
  "looked_at": ["still_00_start_f0.jpg", "still_01_q1_f30.jpg", "burst_0_f41-45.jpg", "delta_strip.jpg"],
  "frames": [{"file": "still_00_start.jpg", "camera": "all", "findings": "magazine seated, both hands on gun, exposure fine"}],
  "defects": [{"id": "D1", "category": "proportion", "severity": "blocker", "camera": "first_person",
               "frames": ["still_02_mid.jpg"], "what": "magazine about 3x the magwell, flat untextured box",
               "fix_hint": "prop scale doubled in the reload sequence", "nightly": ""}],
  "categories_clean": {"exposure": "stills 00-04: whites hold detail, no clipping"},
  "production_ready": false,
  "justification": "D1 blocks: ..."
}
```

`looked_at` lists every image in the order read; `frames` has one entry per image with at least a sentence of findings per camera. `nightly` is filled by the loop when it files an item for an unresolved defect (any severity, with `--give-up`). The post tools read `production_ready`, `justification` and `defects`.
