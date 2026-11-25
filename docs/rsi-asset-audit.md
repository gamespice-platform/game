# Asset audit

`tools/rsi_asset_audit.py` audits every 3D asset (GLB/glTF) of the sources registered in Nightly Assets: weapons, props, avatars, pickups, grenades, vehicles, viewmodel arms, buildings, anything else. It has no built-in pack, game or budget list; all of that comes from Nightly's database.

```
nightly assets source add <name> --root <dir>       # once per pack or game
nightly assets config > rsi-config.json             # rsi-config/1: tiers, sources, kinds with budgets
python3 tools/rsi_asset_audit.py --config rsi-config.json --out rsi-assets [--source NAME] [--tier low|medium|high] [--no-glb]
nightly assets ingest rsi-assets/audit.json         # schema rsi-assets/2: an `assets` array, each with a `kind`
```

Each model is classified by the source's kind rules, then the kinds' `match` regexes, then the source's default kind. Checks per kind come from that kind's budget: poly range, texture resolution per video tier, normal/ORM maps, rig (skin, bone range, required clips), scale, pivot, LODs. Flag codes match `lib/assets-checks.mjs` in Nightly. Measurement constants (faceted vertices per triangle, flat-albedo deviation) live in `THRESHOLDS` in the script.

`TEXTURE_QUALITY` (warn) flags a blotched albedo: soft mid-frequency patches (AI-generated or voronoi mottling) instead of crisp detail. `texture_blotch` measures luminance at 1024 px over the texels the mesh samples (`uv_cover` rasterises the TEXCOORD_0 triangles; the island padding is never seen):

| Term | Meaning |
|---|---|
| `mf` | RMS(blur3 - blur12) x 1000: patch energy at 3-12 px |
| `ratio` | RMS(L - blur1) / RMS(blur3 - blur12): crisp grain, screws and wear edges raise it |
| `axis` | share of the strongest 10% gradients within 8 deg of the UV axes: panel lines and trims raise it |
| `blotch` | mf x (1 - axis) x (1 - min(ratio, 1)) |

`blotch` above `THRESHOLDS["tex_blotch"]` (15.0; a kind budget may set `max_tex_blotch`) flags. Calibrated on fc-weapons (2026-11-24): the Polyy-sourced minigun 15.6 (re-textured: 4.7), lmg 20.6, sniper_rifle 24.8; clean authored guns 1-11 (bullpup 1.3, machine_pistol 4.5, pump_shotgun 7.6, smg 10.4), the rusty knife_ph 14.4. The value lands in `textures[].quality` and in the finding. Tests: `python3 -m unittest discover tests/rsi_asset_audit`.

`--tier` judges texture size against that video setting; non-high tiers write `audit-<tier>.json`.

A source may name an adapter in its config (`{"adapter": "fc-art", "addon": "..."}`) to load extra checks from `tools/rsi_adapters/<name>.py` (`context(source)` and `check(source, rec, glb, ctx, audit)`). The bundled `fc_art` adapter reads a pack's weapon art table to catch static magazines and primitive reload props.
