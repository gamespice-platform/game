# Asset audit

`tools/rsi_asset_audit.py` audits every 3D asset (GLB/glTF) of the sources registered in Nightly Assets: weapons, props, avatars, pickups, grenades, vehicles, viewmodel arms, buildings, anything else. It has no built-in pack, game or budget list; all of that comes from Nightly's database.

```
nightly assets source add <name> --root <dir>       # once per pack or game
nightly assets config > rsi-config.json             # rsi-config/1: tiers, sources, kinds with budgets
python3 tools/rsi_asset_audit.py --config rsi-config.json --out rsi-assets [--source NAME] [--tier low|medium|high] [--no-glb]
nightly assets ingest rsi-assets/audit.json         # schema rsi-assets/2: an `assets` array, each with a `kind`
```

Each model is classified by the source's kind rules, then the kinds' `match` regexes, then the source's default kind. Checks per kind come from that kind's budget: poly range, texture resolution per video tier, normal/ORM maps, rig (skin, bone range, required clips), scale, pivot, LODs. Flag codes match `lib/assets-checks.mjs` in Nightly. Measurement constants (faceted vertices per triangle, flat-albedo deviation) live in `THRESHOLDS` in the script.

`--tier` judges texture size against that video setting; non-high tiers write `audit-<tier>.json`.

A source may name an adapter in its config (`{"adapter": "fc-art", "addon": "..."}`) to load extra checks from `tools/rsi_adapters/<name>.py` (`context(source)` and `check(source, rec, glb, ctx, audit)`). The bundled `fc_art` adapter reads a pack's weapon art table to catch static magazines and primitive reload props.
