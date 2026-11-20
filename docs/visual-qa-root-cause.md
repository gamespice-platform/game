# Why the visual QA loop passed bad frames (2026-11-19)

The FC battle_rifle reload on review `game-arena-anim-2026-11-19` was posted with blown-out frames, a magazine larger than the receiver and the support hand off the gun, and nobody flagged it. This doc records what was verified. The fix is the judge loop in [visual-judge-rubric.md](visual-judge-rubric.md) and `addons/dot_game/tools/dot_game_visual_judge.sh`.

## What was wrong with the frames

| Defect | Cause, verified |
| --- | --- |
| Washed out, highlights clipped to white, blacks crushed | **Not the renderer.** The capture ran on Vulkan Forward+ on an NVIDIA GTX 1660 Ti (staging) and an RTX 2070 (staging02); `run.log` names both, and nothing was rendered on llvmpipe. It was a **colour-range bug** in FC `tools/review_clips_run.sh`. Godot's Movie Maker writes full-range JPEG frames, and the clip cut (`scale=960:-2 ... -pix_fmt yuv420p`) passed them through unconverted, tagged `color_range=tv`. The posted mp4s measure Y 0-4 to 247-255 under a limited-range tag, so every player stretches them a second time. The bright pastel `dm_box` dev map (near-white sand floor, average saturation about 19 of 255) made the result look milky. The light rig itself is sane (filmic tone map, exposure from the profile). |
| Magazine a flat blue slab longer than the gun | fc-weapons `aw_weapon_art.gd`: battle_rifle's row has `reload.prop_scale 2.3`, and `MAG_BOXES["battle_rifle.glb"]` is empty, so there is no carve and the reload shows the synthetic box prop. `aw_reload_sequence.gd` sizes that prop by the gun's length over `REAL_LENGTH` (clamped to 0.3-3.0) and then multiplies it by the row's 2.3 again. The double scale makes the prop about 2.3 times its real size: three plain boxes, no texture, swinging through the middle of the screen. smg, bullpup, burst_rifle and drum_shotgun carry the same 2.3; derringer has 4.0, quad_launcher 2.5 and grenade_launcher 3.0. |
| Support hand off the gun at idle and at the end; gun low and right; ammo still 1 in the last frame | Visible in every idle and end frame of the after clip. The last frame still shows 1 round, so the clip is cut before the reload lands. The glitch metrics passed it, because `detach_m` measures a hand against the grip it was told to hold, not whether that grip is on the gun. |

## Why the process let it through

1. **Nothing judged the posted clips.** GameSpice Game `tools/capture_reviews.sh`, which FC, game-arena and zombie-zone run through `tools/qa.conf`, cuts before and after clips and posts them as `<game>-anim-<date>` with only the `review_look` text. No verdict was ever written, so every weapon on the item read "not reviewed". Nobody had to look before it was posted.
2. **The docs told agents not to look.** FC `docs/anim-review.md` step 3: "Save tokens: read the report before any image ... crop to the cells". GameSpice Game `docs/visual-qa.md` asks for sheets "small enough for an agent to read cheaply". An agent read the numeric PASS, cropped a few 320 px cells and moved on. "Done" in practice meant metric PASS.
3. **The checklist had no quality criteria.** It covered foot slide, T-pose and detachment, which the metrics already catch. Scale, proportion, exposure, textures, silhouette, hands and fingers, and reference quality (CS:S or a modern FPS) were not on it, so nothing asked whether the result looked like a shipped game.
4. **The author judged their own work.** The agent that changed the clip also wrote the verdict, with the metrics and its own notes in context. A fresh reviewer rule existed in the family CLAUDE.md, but no tool enforced it.
5. **The review clips were too small and too slow to judge.** They were 960x540 at 30 fps with 320 px filmstrip cells, and FC's `tools/qa.conf` still fingerprinted `../arena-weapons`, a path that no longer exists.

## The fix

- `dot_game_visual_judge.sh` captures on a GPU box (it refuses llvmpipe), builds a judge pack (full-resolution stills at start, mid, end and the motion peaks, a frame-delta strip, every camera), and runs a fresh judge with no metrics and no author notes. The judge writes `verdict.json`, and `production_ready` defaults to false.
- The loop runs fix, recapture and a fresh judge with no round cap (`VISUAL_JUDGE_MAX_ROUNDS`, 0 = unlimited). When it gives up, it fails loudly and opens one nightly item per unresolved defect.
- `dot_game_visual_qa_post.sh` and `capture_reviews.sh` refuse to post without a passing verdict, or without every open defect filed in nightly. A posted item carries its verdict and defects.
- FC's `review_clips_run.sh` converts the range (`in_range=pc:out_range=tv`) and records at 1280x720 and 60 fps.
