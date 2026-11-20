# Visual QA: does it look like a real game?

The family's loop for weapons, avatars and NPCs: one test scene per item, a first-person camera and two outside cameras (a teammate behind-right, an opponent in front), every frame captured at 60 fps, contact sheets, a clip per animation that plays every frame in the nightly viewer, a numeric pre-filter per clip, and a fresh judge (below) whose verdict is the only thing that says a clip is done. Findings go to nightly notes and items; re-capture until the judge says production_ready. FC (Fatal Contact) ran the pilot (game-fatal-contact `docs/anim-review.md`) and now runs on this harness.

Nothing here ships in a pack, so none of it bumps the API level.

## The pieces

| File | What |
| --- | --- |
| `addons/dot_game/qa/dot_game_visual_qa_capture.gd` | `DotGameVisualQaCapture`, a `SceneTree` script: the capture scene contract. A game extends it and overrides the hooks |
| `addons/dot_game/qa/dot_game_visual_qa_views.gd` | `DotGameVisualQaViews`: the behind-right and opponent cameras as SubViewports of the game's world, `place(feet, yaw)`, `save(dir, i, first_person)` (f/t/o jpgs), `tag_layers` |
| `addons/dot_game/tools/dot_game_visual_qa_shot.sh` | the on-box half: runs the capture under xvfb at `--fixed-fps`, makes the sheets and the side-by-side clip (into `--clip-dir`, default `--out`), drops the frames |
| `addons/dot_game/tools/dot_game_visual_qa.sh` | the driver: routes the shot tool to a GPU box (`gpu.sh shot --route --pull`), falls back to `heavy`, files the clips, writes `report.md` |
| `addons/dot_game/tools/dot_game_visual_qa_post.sh` | posts clips (with `fps`, frames and verdict in `--metrics`) and first-person sheets to a nightly review item |
| `examples/visual_qa_demo.gd` | a runnable capture (a capsule with a nose turning and walking a circle, plus a clip that skips): copy it to start |
| `examples/headless_visual_qa.tscn` | the suite for the plan filter, the verdict, the T-pose distance and the camera placement |

## Adopting it in a game (a few minutes)

1. `tools/visual_qa.gd`:

```gdscript
extends DotGameVisualQaCapture

var _avatar: Node3D

func _items() -> PackedStringArray:
	return PackedStringArray(["soldier"])

func _clips(_item: String) -> PackedStringArray:
	return PackedStringArray(["idle", "walk", "run", "jump"])

func _stage(item: String, clip: String) -> DotResult:
	if _avatar == null:
		_avatar = (load("res://avatars/%s.tscn" % item) as PackedScene).instantiate()
		root.add_child(_avatar)
	var player := _avatar.find_child("AnimationPlayer") as AnimationPlayer
	if not player.has_animation(clip):
		return DotResult.fail(DotError.CODE_INVALID, "no %s clip" % clip)
	player.play(clip)
	player.pause()
	return DotResult.success(clip)

func _subject(_item: String) -> Node3D:
	return _avatar

func _drive(_item: String, _clip: String, t: float, _frame: int) -> void:
	(_avatar.find_child("AnimationPlayer") as AnimationPlayer).seek(t, true)
```

2. `tools/visual_qa_shot.sh` (gpu.sh runs only a game's `tools/*.sh`):

```bash
#!/usr/bin/env bash
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
```

3. Run it as gamedev from the checkout or a `~/wt` worktree, in the background (one item and clip takes a minute or two on a box):

```bash
sudo -u gamedev bash addons/dot_game/tools/dot_game_visual_qa.sh --shot tools/visual_qa_shot.sh --fresh soldier -- --only soldier --clips walk
```

4. Read `screenshots/visual_qa/report.md`, then the sheets (below), then post: `nightly review new "<Game> visual QA <date>" --key <game>-visual-qa-<date>` once, and `bash addons/dot_game/tools/dot_game_visual_qa_post.sh <key> [--fails] [--variant before|after]`.

Add `screenshots/` to `.gitignore` if it is not there.

## The capture scene contract

`DotGameVisualQaCapture` builds on the first frame (`_initialize` runs before the tree is ready), then for each (item, clip) after `--only` and `--clips`: `_stage`, `_warmup_frames` frames, one staged draw so the outside views have caught up, then `round(_seconds * fps)` frames. Each frame: `_drive(item, clip, t, frame)`, then just before the draw `_before_draw`, `_place_first_person` and the outside cameras' `place` at the subject's feet and yaw, a `DotClipMetrics` pose sample of `_skeleton` and the T-pose count; after the draw all three views are saved to `<out>/<item>/_frames/<clip>/{f,t,o}_NNN.jpg`. Then one line per clip:

`VISUALQA {"item","clip","fps","frames","pass","fail":["check value (limit x) note"],"worst":{check: value},"checks":[rows]}`, or `VISUALQA {"item","clip","status":"skip","why"}` when `_stage` fails (shown as N/A). `VISUALQA_DONE` ends the run; exit 1 if a frame could not be saved.

| Hook | Default | Override when |
| --- | --- | --- |
| `_items()`, `_clips(item)` | none | always |
| `_build()` | `build_stage()`: a 40 m grid floor at y 0, a sun with shadows, a plain sky, a current first-person `Camera3D` | the game's own client or map must stand around the subject (FC builds its offline client) |
| `_stage(item, clip) -> DotResult` | fails (unsupported) | always: spawn or reuse the subject, ready the clip; fail with the reason when the item has no such clip |
| `_subject(item) -> Node3D` | null | always: its position is the feet, its Y rotation the facing (-Z forward) |
| `_skeleton(item)` | the first `Skeleton3D` under the subject | several skeletons (pick the body, not the arms) |
| `_seconds`, `_warmup_frames` | 2.0 s, 2 frames | per clip length, streaming assets |
| `_drive(item, clip, t, frame)` | nothing | always: seek (`AnimationPlayer.seek(t, true)`), never let it play on its own, so reruns draw the same frames; or press the real input actions for movement clips |
| `_grounded(item, clip, t)` | true | jumps (the floor check skips airborne frames) |
| `_before_draw(item, clip, frame)` | nothing | hide your own body from the first-person camera |
| `_place_first_person(item)` | eyes at 1.6 m, looking down-forward | the game has its own player camera |
| `_checks(item, clip, rows)` | rows unchanged | add the game's own rows: grip distance, muzzle offset, held-item offset |

Args after `--`: `--out DIR` (default `screenshots/visual_qa`), `--fps N` (60), `--only a,b`, `--clips a,b` (`--anims` too), `--limits res://x.json` (a `DotClipMetrics.limits_for` file; add `"tpose_frames"` to allow some rest-pose frames). Layers: the outside cameras draw everything but layers 18 and 20 (bits 17 and 19); put the first-person arms there with `DotGameVisualQaViews.tag_layers(arms, 1 << 17)`, and your own body on another layer the first-person camera culls.

A game that already has its own capture scene (FC's `tools/anim_review.gd`) can skip the class and use only `DotGameVisualQaViews` and the shot tool: anything that writes `<out>/<item>/_frames/<clip>/{f,t,o}_NNN.jpg` (or `fp_<clip>` folders) gets the sheets and clips. Its own log lines survive the shot tool's filter with `--keep REGEX`, and the driver's `--no-report` leaves `report.md` to it.

## Output and cost

Per clip: `<item>/<clip>_fp_sheet.png`, `_tp_sheet.png`, `_op_sheet.png` (15 cells a second, every fourth frame at 60 fps, eight to a row, 240 px cells labelled `#frame seconds`; `--sheet-rate`, `--cell`, `--cols` on the shot tool) and `<item>/<clip>.mp4`: the three views side by side at the window height, every frame, at the capture rate, frame index burnt in. The frames are deleted. `report.md` has one row per clip: verdict, why, the sheet and clip paths, and an `fps:` line.

The metric verdict in `report.md` is a pre-filter: it catches foot slide, pops and T-poses cheaply, and says nothing about whether the clip looks shipped. Never close, post or report a clip as done on it.

## The judge loop

A visual change is done only when **3 or more consecutive fresh judges** each find zero defects, every one on a new variant (see below). The author never judges their own frames: it took a weeks-long run of metric PASSes on a magazine three times the gun's size to learn that ([visual-qa-root-cause.md](visual-qa-root-cause.md)).

```bash
bash addons/dot_game/tools/dot_game_visual_judge.sh --clips screenshots/visual_qa [--capture '<GPU capture cmd>'] \
     [--only item,item] [--anims clip,clip] [--out DIR] [--passes N] [--give-up] [--fix-cmd CMD]
```

- It refuses software frames and unproven ones: the capture log (`<clips>/capture.log`, or `<out>/capture.log` with `--capture`) must exist and name a GPU (`gpu.sh: the <box> takes this frame`, or Godot's `Using Device` line for a hardware device); a log naming llvmpipe, softpipe, lavapipe or SwiftShader, or no log, exits 4. The renderer line goes into every pack's `evidence.json`. Capture on staging02/staging (gpu.sh) only.
- It exits 4, never skips, when a requested `--only` item or `--anims` clip has no mp4, when a pack cannot be built from a clip, or when `--capture` did not rewrite a clip (a stale mp4 would be judged as new).
- One run per `--out`: a second run on the same directory exits 2 (flock on `<out>/.lock`). Each round starts clean: the previous round's `verdict.json`, `results.tsv` and `pass*/` packs are removed, so a later round never inherits an earlier round's passes.
- Per clip it builds a pack: full-resolution stills (start, quarter, mid, three-quarter, end and the top motion peaks, every camera side by side), two motion bursts (five consecutive frames around a peak, so pops and teleports show frame to frame), a frame-delta strip and the clip's sheets. It has no metrics and no author notes.
- Passes: `--passes N` (`VISUAL_JUDGE_PASSES`, default 3, refused below 3). Pass k is a new fresh judge on variant k-1: the quarter stills shift, the bursts move to other peaks, passes 2+ add a doubled close-up of one camera (first person, then behind-right, then opponent), and with `--capture` the clips are recaptured with `SHOT_VQA_VARIANT=k-1` (gpu.sh carries `SHOT_*` to the box; `DotGameVisualQaViews` moves both outside cameras and turns and dims or brightens every `DirectionalLight3D`, and logs a `VISUALQA variant` line). The first pass with any defect, minor included, ends the round. `verdict.json` holds the streak (`passes_clean`, `passes_required`, each pass's variant, judge sessions and image counts) and the source state it judged (HEAD, uncommitted diff and capture command).
- Evidence: the judge runs with `--output-format stream-json`; `judge.jsonl` is its transcript and `evidence.json` its session id, every image it Read, the images' sha256 and the sha256 of the `verdict.json` it wrote. `evidence.json` also records the item, clip, the judged mp4 and its sha256, pass, variant, round and renderer. A judge that skipped an image, or a verdict file that differs from what it wrote, is invalid and judged again (two judges per pack, then exit 5). Each judge is killed after `--timeout`/`VISUAL_JUDGE_TIMEOUT` seconds (default 1800), and a timeout counts as an invalid judge.
- Anchor: the gate does not trust `judge.jsonl` alone, since whoever writes the pack could write it too. It looks up the judge's own Claude transcript (`<session>.jsonl` under christian's `~/.claude*/projects/`, owned by christian, not by the pack's author) and checks that the session ran in this pack directory, Read every image and that its last Write of `verdict.json` has the exact content on disk. A pack with no such transcript is unsound. Limit: root can forge anything; the anchor stops an agent working as gamedev or core. `VISUAL_JUDGE_TRANSCRIPTS` overrides the lookup for the self-test only; the post tools unset it.
- It runs a fresh `claude -p` judge (`VISUAL_JUDGE_MODEL`, default opus; haiku, sonnet or opus, never Fable) on the pack with [visual-judge-rubric.md](visual-judge-rubric.md). The judge writes `verdict.json`: per-frame findings, defects (category, severity, camera, frames, what, fix hint), `production_ready` and a justification. An invalid verdict (an image not Read or not in `looked_at`, a frame without findings, true with any defect, a thin justification) is rejected and judged again.
- Exit 0 means production ready, and only after `dot_game_visual_verdict.py --audit` agrees with the run (otherwise exit 5). Exit 1 means fix the defects at their source and run it again. With `--capture` and `--fix-cmd` it loops by itself. There is no round cap unless `VISUAL_JUDGE_MAX_ROUNDS` is set (0 = unlimited).
- To stop with defects open, run `--give-up` (or hit the round cap): it files one nightly item per game and defect category under a stable key (`vj-<game>-<category>`; a done, dropped or wontfix item is reopened to queue) with each open defect (any severity), its clip, frames, fix hint, pack, round and judge session as a note, writes the keys into `verdict.json` after each one and exits 3. If any defect cannot be filed it exits 1 and says which. It fails loudly; it never passes. The gate accepts a filed defect only when its nightly item exists and names that judge session.
- The post tools (`dot_game_visual_qa_post.sh`, the games' wrappers, `tools/capture_reviews.sh`) read `verdict.json` through `dot_game_visual_verdict.py`. They pass the clip's own mp4 (`--mp4`) and refuse it unless it is the very file the judge saw (sha256), and unless the run is production ready with a sound streak, or every defect has a filed nightly key (a `--variant before` post needs only a verdict); every one needs judge evidence that still matches the files. `dot_game_visual_verdict.py --audit <out>/verdict.json` checks a whole run (`--pack DIR` one pack) and prints `sound: PRODUCTION READY` or the reasons it is not; it never trusts the run's own `production_ready` field. Self-test: `bash tests/visual_judge/selftest.sh` (stub judge and nightly, no GPU). The post's look text is the verdict and its defects, and the item's review verdict is the judge's.

The snippet for briefs, nightly prompts and CLAUDE.md files is [visual-judge-brief.md](visual-judge-brief.md).

## 60 fps in the nightly viewer

The review viewer already plays clips at their own rate: it reads the file's frame rate (ffprobe `r_frame_rate`), steps one frame per 1/fps, and has a playback-rate control. `dot_game_visual_qa_post.sh` also posts the rate as the `fps` metric, from the file itself, and the repo's `tools/capture_reviews.sh` does the same. A browser shows at most the display's refresh rate, so a 60 fps clip plays fully on a 60 Hz or faster screen; step frame by frame for anything finer. A sheet shows 15 frames a second, so a one-frame pop can fall between cells: that is what the clip and the numbers are for.

## The checklist

The numbers catch some of it (`foot_slide`, `floor_contact`, `framing`, `bone_pop` from `DotClipMetrics`, `tpose` from the capture, plus the game's own rows); the eye catches the rest. Read the first-person sheet left to right as a flip book, then behind-right, then opponent, and ask whether it looks like a real game:

- **Floor clipping:** feet or body sinking into the floor, or hovering over it while grounded (`floor_contact`).
- **T-pose:** arms straight out, a body in its rest pose, a frame with no animation applied (`tpose`).
- **Grip:** a hand off the grip or magazine it should hold, fingers through the grip or open in the air, the trigger finger away from the trigger, hands on the wrong sides.
- **Floating items:** a gun, magazine or prop not attached to a hand, left in the air after a reload or a swap, held at the knee in third person.
- **Texture resolution:** a blurry or stretched texture next to sharp ones, a seam, a face with no texture, a plain white or magenta material.
- **Muzzle flash location:** the flash or tracer starting behind the barrel's end, inside or beside the gun, or (opponent view) from the body instead of the gun.
- **Foot slide:** feet skating over the grid while planted (`foot_slide`), legs not moving while the body moves.
- Pops: a cell that does not follow from its neighbours, a loop that snaps where it wraps (`bone_pop`).
- Framing: the subject or a hand cut off at the edge of the screen, an arm through the camera (`framing`).
- Clipping: a forearm through the gun, an arm through the body.

Frame 0 of an outside sheet can show the scene a frame before the camera moved; ignore it.

## Recording findings

Each finding is a nightly note on the item you work (`nightly note <key> "soldier walk #34-40: left foot slides 10 cm"`), with item, clip, frame numbers and the sheet. Post the clips you judged with `--variant before` before the fix and `--variant after --only <item> --clips <clip>` after it, so the owner sees the pair. File a nightly item per subject for anything left. Never leave a finding only in a doc or a commit message.

## Where it runs

The driver hands the game's shot wrapper to a GPU box (staging or staging02) with `gpu.sh shot --route --pull <clips dir>`, which needs gamedev's box key; when no box takes it (exit 75) it runs through `heavy` here. gpu.sh may say it could not copy the frames back: they are deleted on purpose, and the sheets still arrive. `--soft` stays here on llvmpipe, which can crash (signal 11) on big scenes. If rsync cannot write `screenshots/`, make it writable for gamedev (`chmod -R a+rwX screenshots`). The log is `<out>/capture.log`.

## Filmstrip, the other capture

`addons/dot_game/tools/dot_game_filmstrip.sh` plays scripted scenarios (`tools/filmstrip_scenarios.json`) through the game's real client with `--write-movie`: one camera, a whole level or interaction, for gameplay feel. Visual QA is per subject, three cameras, every frame judged. Use the filmstrip for "does the match play right", visual QA for "does this weapon, avatar or NPC look right".
