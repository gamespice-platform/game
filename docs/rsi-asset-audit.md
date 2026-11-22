# RSI asset audit

`tools/rsi_asset_audit.py` measures every weapon model in every GameSpice weapon pack (fc-weapons, zee-dot-weapons, zed-dot-weapons, zz-modern-weapons, zz-medieval-weapons) and gives each a score. It exists because the visual judge only failed textures that were placeholders, so low-poly models, 1K textures on rifles and reloads that never move the magazine passed review after review (owner complaint 2026-11-22: FC sniper reload, burst rifle).

```sh
sudo -u gamedev python3 ~gamedev/godot/dot-game/tools/rsi_asset_audit.py            # all packs
sudo -u gamedev python3 tools/rsi_asset_audit.py --pack fc-weapons=/home/gamedev/wt/fc-weapons-x --no-glb   # one pack, a worktree
```

It reads GLBs with the Python standard library (Pillow only for the flat-albedo check), so it needs no Godot and runs anywhere in a few seconds. Output goes to `/home/gamedev/perf-bench/rsi-assets/audit.json`, schema `rsi-assets/1` in `SCHEMA.md` next to it, plus a self-contained copy of each weapon GLB (external textures embedded) in `glb/` for the Nightly Assets viewer.

What it measures per weapon: triangles, vertices per triangle (flat shading), materials, bounding box, box-sized meshes, every texture (size, power of two, which maps it feeds, Godot import compression, albedo luminance spread), animation clips with how far the magazine node travels, and for fc-weapons the procedural reload style from `aw_weapon_art.gd` against the model's magazine (`MAG_BOXES`, `mag_node`) and the reload prop's triangle count.

Scoring: 100 minus 20 per error, 7 per warning, 2 per info; a weapon passes with no errors and a score of at least 70. Thresholds sit at the top of the script and are written into `audit.json`. Gun textures must reach 2048 px (a view model is about 1000 px wide on a 1080p screen), melee and throwables 1024.

Texture tiers: textures are judged against one video texture-quality tier, the same four levels as the `texture_quality` setting in dot-menu (0 low, 1 medium, 2 high, 3 ultra). `--tier high` is the default and writes `audit.json`; any other tier writes `audit-<tier>.json`. Each tier sets the albedo edge a gun and a small weapon must reach (`min_tex`, `min_tex_small`) and the lowest lossy WebP quality it accepts (`LOSSY_TEX`, so ultra accepts lossless only). The rows live in `TIERS` at the top of the script; `--tiers-json FILE` overrides them without editing the script, and nothing is capped. A shipped texture serves its own tier and every tier below it, so check the highest tier you ship for. Embedded GLB images are matched to the files Godot extracts (`<glb>_<index>.<ext>`) to read their import settings.

```sh
for t in low medium high ultra; do sudo -u gamedev python3 tools/rsi_asset_audit.py --no-glb --tier $t; done
```

Limits: clip support for procedural packs is detected per pack from the code, not per weapon. Sounds and arms reaching the grips need a Godot run and are not measured yet (`sounds` is empty, `ARMS_MISSING` never raised).
