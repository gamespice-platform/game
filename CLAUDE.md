# GameSpice Game

The wiring every server game repeats, once: resolve the game, build the netcode and its bridge, identity then services, a roster, one authoritative tick, and a teardown in reverse. It holds no rules; those are GameSpice Match's and GameSpice Objective's.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this addon.

**gs-core, gs-server and gs-net are required.** Everything else a game touches (a map director, a vote, gs-chat, gs-voice, gs-moderation, gs-ui, gs-platform) is duck-typed or loaded by path and named nowhere.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | `GSGameModule`, `GSGameNetcode`, `GSGameRoster`, `GSGameChatClient`: why it exists, what belongs here, what is fatal, teardown order, `session_fn`, schema refusal, `report_map`, the Tab board, the suite |
| [docs/services.md](docs/services.md) | `GSGameServices`: build order, loading by path, the live tools, the hooks, hibernation |
| [docs/touch-controls.md](docs/touch-controls.md) | a game on a phone: `GSTouchButtons` with `GSFpsTouchSampler`, the handlers dictionary, `menu_button_corner`, a `headless_touch` suite, the phone frame, HUD placement |
| [docs/map-config.md](docs/map-config.md) | a game taking per-map settings (`GSGameMapConfig`, `_map_config_keys`, `GSGameClient.map_changed`) |
| [docs/config-binder.md](docs/config-binder.md) | a game's `*Config` made server-tunable: `GSGameConfigBinder`, strict boot, the cvars, the workbench kind, the yml diff |
| [docs/avatar-actions.md](docs/avatar-actions.md) | emotes, poses and gestures: the checked message and relay, `GSGameClient.add_avatar_actions`, the module's `_avatar_actions_equipped` and `_avatar_action_veto` hooks, the server-read loadouts (`GSGameAvatarLoadouts`) and uploaded clips on other players |
| [docs/noblock.md](docs/noblock.md) | teammates passing through each other: `GSGameNoblock`, the module's `_noblock_*` hooks, `GSGameClient.add_noblock`, the `noblock` cfg kind |
| [docs/workbench.md](docs/workbench.md) | hosting GameSpice Workbench: `GSGameWorkbench`, `GSGameClient.add_workbench`, GameSpice Auth accounts (`GSGameWorkbenchAuth`) |
| [docs/visual-qa.md](docs/visual-qa.md) | checking how a weapon, avatar or NPC looks: `GSGameVisualQaCapture` (the capture scene contract), `GSGameVisualQaViews`, the shot, driver and post tools, the checklist, 60 fps clips in the nightly viewer, and the judge loop (`gs_game_visual_judge.sh`: a fresh judge's `verdict.json` with [visual-judge-rubric.md](docs/visual-judge-rubric.md); the post tools refuse clips without it). Do this loop after any change to a model, animation, grip or muzzle, without being asked, until the judge says production_ready |
| [docs/qa.md](docs/qa.md) | `tools/perf_budget.sh`, `visual_check.sh`, `netchaos.sh` and the `GSGameNetchaos*` classes: what a game supplies (`tools/qa.conf`, the two netchaos scripts) |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/gs_game/core/` | `GSGameModule` (the `GSModule` a game subclasses; `GSGameModuleWiring` holds its static wiring helpers), `GSGameContent` |
| `addons/gs_game/net/` | `GSGameNetcode`: the GameSpice Net manager with the four settings every game had, and `refuse_peer`; `GSGameLink`, a game's RPC link attached under the server node and freed with its bridge |
| `addons/gs_game/runtime/` | `GSGameRoster`, `GSGameServices`, `GSGameChatClient`, `GSGameClient` (the client's platform layer), `GSGameWorkbench` (F9 tuning window and optional HTTP), `GSGameMapConfig` (per-map settings) |
| `addons/gs_game/runtime/` helpers | `GSGameClient` delegates to static helpers taking the client: `GSGameClientLook` (look and mute), `GSGameUserCfg` (the user cfg tier), `GSGameClientAvatars`, `GSGamePageGuard` (browser leave guard); `GSGameAvatarActionSupport` holds the action client's row building and optional-script cache |
| `addons/gs_game/qa/`, `tools/` | `gs_game_phone_shot.sh` (a phone-size touch frame of a game), `GSGamePerfBench` with `gs_game_perf_bench.sh` and its compare script (the solo-client benchmark on a GPU box), `GSGameNetchaosServer` and `GSGameNetchaosClient` (tool-only: a pack never calls them, so no API level) and the shared perf, visual and netchaos scripts; `GSGameVisualQaCapture` and `GSGameVisualQaViews` with `gs_game_visual_qa{,_shot,_post}.sh` (the visual QA loop, [visual-qa](docs/visual-qa.md)). [qa](docs/qa.md) |
| `addons/gs_game/gs_game_api.gd` | the API level (`LEVEL`, `OLDEST`); the bump rule is on `GSAddonApi` |
| `examples/game_selftest.tscn` | the suite (sections inherit through `examples/selftest/selftest_{base,avatar,extra,cvars,slide,stats,hooks,netcfg,client}.gd`); `examples/fixtures/` the module, bridge, identity and services it loads |

## Running and testing

- The family's two steps ([family CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 200 godot --headless --path . res://examples/game_selftest.tscn`.
- **A new `class_name` here breaks every consumer until each is re-imported.** Every converted game links this addon. [history](docs/history.md#a-new-class_name-broke-a-game-three-repositories-away)
- The suite runs with none of the addons the base loads by path; the wire half is in the games' suites. [design](docs/design.md#the-suite)
- Fixtures await a frame in `setup()` on purpose; keep them suspending. [design](docs/design.md#the-suite)

## Rules that bite

- Something belongs here only if every game would write it the same way with only class names changed; rules, rotations and objectives do not. [design](docs/design.md#the-split-and-where-the-line-is)
- Seat from `client_spawn`'s `userid`, never `peer_id`; `GSGameRoster.session_fn` lets the suite prove it. [history](docs/history.md#the-line-two-games-got-wrong)
- Only a missing game object, a netcode that will not start, or a refused `_game_load` (which unwinds) is fatal; identity and services failures are logged. [design](docs/design.md#what-is-fatal-and-what-is-not)
- Teardown runs signals, roster, services, identity, bridge, manager; `GSGameRoster.clear()` notifies nobody. [design](docs/design.md#teardown-is-in-reverse-and-the-order-is-not-cosmetic)
- A GameSpice Platform module this module loaded (`_loaded_platform`) is unloaded in `_teardown`, before the identity layer. [design](docs/design.md#teardown-is-in-reverse-and-the-order-is-not-cosmetic)
- Moderation is built before chat and voice, because they look up `gs_mute_source` when they start. [services](docs/services.md#moderation-first)
- gs-chat, gs-voice, gs-moderation, gs-ui and gs-platform are never dependencies: load by path, drive by `set`/`call`, skip a missing one with a line. [services](docs/services.md#why-it-names-none-of-the-three-addons-it-drives)
- Mod-tool commands are unbound in `_exit_tree`; the roster calls `forget_player` and `forget_voter` as somebody leaves. [services](docs/services.md#the-live-tools-are-a-fourth-layer-and-the-verbs-are-the-subclasss)
- A new hook defaults to exactly the old behaviour. [services](docs/services.md#the-hooks-the-first-converted-game-needed)
- Anything set on the server that an older GameSpice Server may lack (`set_current_map`, the board properties) is duck-typed behind `has_method` / `in`; detach only a hook this module set. [design](docs/design.md#the-tab-boards-server-half)
- `GSGameChatClient` also draws GameSpice Server's own `system` and `admin` lines from the client link (never a player's line: that is the bridge's); a game that reads the link itself sets `server_lines = false`, and a game with its own box calls `draw_server_line`. [design](docs/design.md#gsgamechatclient-the-clients-half)
- `GSGameChatClient` drops a self-muted player's line and hands its voice manager to the block list (GameSpice Chat's `GSChatSelfMute`, by path); `!sm` is stopped by the box, before the bridge. [design](docs/design.md#gsgamechatclient-the-clients-half)
- `describe()` overrides merge `super.describe()`. [history](docs/history.md#two-bugs-in-gs-server-the-first-suite-found)
- `GSGameChatClient` never opens the microphone on attach: the first press of gs-voice's `gs_voice_talk` action does (`update_talk`), so a browser asks then. It follows the replicated `sv_voice_enable` and publishes its manager as `gs_voice_client`; `GSGameModule` binds `sv_voice_enable`/`sv_voice_mode` on the services' router. [design](docs/design.md#gsgamechatclient-the-clients-half)
- A headless server gets GameSpice Cloud's `GSCloudAutoUpdate` (by path, one per process, parented to the `GSServer`, `start_auto_update`): it watches every delivered game's packs (`watched_packs`), counts `sessions()`, warns through `broadcast_message` and exits 75 after `shutdown`. A game built into the binary watches nothing. Contract: GameSpice Cloud's `docs/auto-update.md`.
- `GSGameClient` mounts what a `content.lock.json` pins (`GSGameLockedContent`: `res://`, or beside a linked `res://maps`) through gs-cloud's `ensure_locked`, found by `has_method`, behind the gate reason `locked_content`. No lock means nothing happens; `use_locked_content`, `locked_content_offline` (an offline, forced-offline or headless client skips the lock unless set), `--locked_content=0|PATH` and `GS_PACKS_FROM=none` control it. The server side is not wired: servers get packs from gs-server-deploy's `fetch-content`.
- `GSGameClassImmunity.apply(combat, class_def, player_id)` (duck-typed, GameSpice Combat and GameSpice Player Class by path) writes a class's `immune_to` onto the resolver's `GSDamageImmunity`; a game calls it where it applies a class at spawn (null def clears). Immunity matches `GSDamageType.id`, so the game must register the kind (`fall`) as a damage type.
- Slide sounds are on for every `GSGameClient` (`use_slide_sounds`): it follows each `GSFpsController` that enters the tree and drives GameSpice Audio's `GSAudioSlide` (by path; silent without a `GSAudioManager` in the registry). `GSGameModule` binds `sv_slide_sounds` (replicated); `slide_volume` is declared on GameSpice Menu's schema by `setup()`, or by `GSGameClient.declare_slide_setting(schema)` plus `slide_settings = manager` for a game with its own settings. GameSpice Menu's stock audio page has no row for it yet.
- Landing is on for every `GSGameClient` (`use_landing`, `GSGameLanding`): it plays GameSpice Audio's landing stock by impact at the body (`cl_landing_volume`) and sets each controller view's `landing_strength` from `cl_landing_kick`; both are client console vars. Fall damage itself is GameSpice Combat's, server-side, and off until a game builds `GSFallDamage`.
- The profiler is placed for every game, client and server, when GameSpice Profiler is linked (`use_profiler` on `GSGameClient` and `GSGameModule`; `--no-profiler` or `GS_GAME_PROFILER=0` turns it off): `GSGameProfiler` loads it by path, never by `class_name`, so a build without the addon places nothing. The Performance card in GameSpice Menu's Advanced page and `sv_profiler_*` follow from the registered `gs_profiler` service. A game that builds its own console calls `GSGameProfiler.bind_client_console` itself. The placed profiler is told the game for its perf reports (`configure`: `game_id` from `gamespice/perf_game_id` in project.godot, else `GSAddonConfig.game`, else the repo directory name without `game-`/`mg-`; `repo` and `platform` tags; the map on `map_changed`), and a game-owned transport or hot emit site reports through `GSGameProfiler.net_cost(class, dir, bytes)` and `signal_emitted(obj, name)` (one dynamic read when no recording runs; nothing when the profiler or its signals counter is not in the build).
- Positional voice needs `voice_position_fn`; without it voices are flat.
- Only the server starts a loading state (a spawn, `report_map` with a new map, `mark_reloading`); a client's `game.cover` report can confirm or end one, never start one, and `load_timeout_sec` bounds it. [design](docs/design.md#still-loading-the-server-knows-who-is-behind-a-cover) [design](docs/design.md#gsgamechatclient-the-clients-half)
- A peer whose GameSpice Net schema is refused is kicked through `GSGameNetcode.refuse_peer`.
- `GSGameClient` is a child the client root adds first in `_ready`, never a base class (roots are Node, Node2D and Node3D); `setup()` comes after the HUD, the chat and what the settings bind to. GameSpice Menu and GameSpice Console are loaded by path, never named. [design](docs/design.md#gsgameclient-the-platform-layer-every-client-wires) [design](docs/design.md#a-client-whose-message-schema-cannot-play-is-disconnected-here)

- A game's RPC link node is attached with `GSGameLink.attach(link, parent, bridge, NODE_NAME)`, never a bare `parent.add_child` and never `remove_child` in an `_exit_tree`: the first leaves a second link after a reload (RPCs silently lost), the second errors when the server tree is torn down. [design](docs/design.md#gsgamelink-the-rpc-link-outlives-nothing)

## Where a game plugs in

| To change | Where |
| --- | --- |
| The game itself | `GSGameModule._game_service()`, `_game_load()`, `_game_hibernation()`, `_can_tick()` |
| The operator's net limits (rate, budget, mtu) on the game's own | the host sets the `gs_net_ceiling` meta on the `GSServer` (`GSGameNetcode.CEILING_META`); `GSGameModule._net_ceiling()` reads it and `GSGameNetcode.cap` applies min(game, operator), 0 = no limit |
| Identity | `_make_identity()` returning GameSpice Platform's `GSPlatformIdentity`; `_wants_platform_module()` |
| Chat, voice, moderation | a `GSGameServices` subclass: channels, rules, voice config, `_can_hear`, `_peer_can_receive` |
| The live admin tools | `_mod_abilities()`, `_mod_unsupported()`, `_mod_can_teleport()` / `_mod_position()` / `_mod_teleport()`, `_mod_configure_commands()`, `_mod_configure_tools()`; call `mod_player_respawned(id)` from the spawn path |
| The map the server lists, and the per-map settings it applies | `report_map(map_id)`, on every change; `_map_config_keys()` (+ `_map_config_defaults`, `_map_config_game`, `_map_config_get`/`_set`); client `map_changed`. [map-config](docs/map-config.md) |
| Tab board columns and teams | `_game_board_fields`, `_game_board_extra` |
| The client's chat and voice | `GSGameChatClient`: `channels`, `line_colours`, `max_length`, `voice_config`, `window_settings`, `voice_method`, `server_lines`, `self_mute_enabled`, `attach(bridge)` |
| Who a peer is, for a lobby | `GSGameRoster.session_fn` |
| Who is still loading (not to be hurt, eliminated or counted) | server: `GSGameModule.is_loading(seat)` / `is_peer_loading(peer_id)`, `can_be_harmed` / `can_peer_be_harmed` (override for a spawn shield), `loading_changed`, `load_timeout_sec`, `reload_grace_sec`, `mark_reloading()`, or `var peer_loading_fn: Callable` on the game object; the client side is automatic on `GSGameClient` (`report_loading`), else `GSGameClient.report_cover(link, covered)` ([design](docs/design.md#still-loading-the-server-knows-who-is-behind-a-cover)) |
| Look at a player to gag (G) or mute (K) them | `GSGameClient`: on by default when the chat has a voice and GameSpice Voice is in the build; `use_look_mute`, `look_gag_action` / `look_mute_action`, `look_separate_keys`, `look_position_fn(roster row) -> head position` (the one hook a game needs; the chat block list supplies who is whose peer), or `look_positions_fn` / `look_target_fn`, `look_chat_mute_fn` (default: the `!sm` block list); a client with its own voice manager and chat sets `look_voice` / `look_chat` and calls `build_look_mute()` once the voice exists; rows are added to the game's key table unless it has its own on those actions; `look_conflicts` / `find_look_conflicts()` report a key another action holds. Never default to H: GameSpice Menu's help |
| A phone or tablet screen | `GSGameScreenFit`, attached by `GSGameClient` when `GSPlatform.has_touch()`: aspect expand (no pillarbox), the canvas short side 720 units (never more than the project's base), and `fit_touch_buttons(buttons, layout)` sizes GameSpice UI's `GSTouchButtons` so the smallest is at least 44 real px across (9 mm where the reported DPI is true; on the web and headless it is a guess), capped to fit, never below the design, refitted on resize; leaving the tree restores the window's stretch. Opt out with `use_screen_fit = false`; tune by assigning `screen_fit` (`short_side`, `button_mm`, `button_min_px`, `button_max_*`) before the client enters the tree. Suite: `examples/headless_screen_fit.tscn` |
| Which touch buttons, where, and their ids | `GSGameTouchLayout.build(preset, overrides)`: presets `fps`, `driving`, `platformer` (`minigame`), canonical ids (`fire`, `jump`, `crouch`, `reload`...), named slots, fire/jump/crouch/reload in one home everywhere, `validate()` refuses alias ids and overlaps; `apply(buttons, client)` sets and fits them. [touch-layout](docs/touch-layout.md). Suite: `examples/headless_touch_layout.tscn` |
| The client's cover, settings, menu, console, Tab, M, pointer | `GSGameClient`: `spawned_fn`, `require_camera`, `use_gate` / `use_settings` / `use_console` / `capture_pointer` / `sync_on_exit`, `settings`, `hud` + `hud_accent`, `chat`, `busy_fn`, `board_snapshot_fn`, `maps_*`, `scoreboard_action`; `_make_gate()`, `_make_settings()`; holds on `gate` ([migration](docs/client-migration.md)) |

## Open

- **FC, Airdrift and hungario are not converted** to `GSGameModule` or `GSGameServices`, and still carry their own copies of both (including `_refuse_peer`). **Convert FC first**: it is the reference game and the smallest of the hand-written modules, and its `headless_match` must still play a whole deathmatch before touching the others. Not started.
- **game-playlot is half-way**: its services subclass `GSGameServices` (hook overrides only, base mod tools switched off), but its module is still a `GSModule`, deliberately for now; why is in [game-playlot/docs/simulation.md](../game-playlot/docs/simulation.md#the-server-module).
- Every game written since (the `mg-*` games, game-hide-n-seek, game-zombie-zone) is on both bases.
- `GSGameModule` binds GameSpice Player Controller's movement cvars (`sv_gravity` and the rest, REPLICATED) after `_game_load`, over `_movement_targets()` (default: the game object's `movement_targets()`, an Array of `GSFpsTunables`, swim, ladder); a game exposes that one method and writes no cvar code. `GSFpsCvars` is loaded by path (`fps_cvars_script`), and the result is `movement_cvars` (use its `map_config_keys()` for `_map_config_keys`).
