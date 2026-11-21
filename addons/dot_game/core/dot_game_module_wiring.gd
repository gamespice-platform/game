class_name GSGameModuleWiring
extends RefCounted

## What [GSGameModule] wires for avatars and noblock once its pieces exist; the hooks a game overrides stay on the module.

const CHANNEL := "game.module"


## The roster tells the relay's loadouts who joins and leaves, so each equipped set is read and told to everybody.
static func follow_loadouts(m: GSGameModule) -> void:
	var relay: Variant = m.net.get_meta(GSGameAvatarActionRelay.NET_META, null) if m.net != null else null
	if relay is GSGameAvatarActionRelay and (relay as GSGameAvatarActionRelay).loadouts != null:
		(relay as GSGameAvatarActionRelay).loadouts.server = m.server
		m.roster.follow((relay as GSGameAvatarActionRelay).loadouts)


## The relay asks the module, which defers to the game object when it does not override; the netcode only knows the game.
static func bind_hooks(m: GSGameModule) -> void:
	var relay: Variant = m.net.get_meta(GSGameAvatarActionRelay.NET_META, null) if m.net != null else null
	if relay is GSGameAvatarActionRelay:
		(relay as GSGameAvatarActionRelay).equipped_fn = m._avatar_actions_equipped
		(relay as GSGameAvatarActionRelay).veto_fn = m._avatar_action_veto


## Publishes the site server id, and keeps looking while GameSpice Auth has not read it.
static func advertise_site_server(m: GSGameModule) -> void:
	if m.console == null:
		return
	var id := m._site_server_id()
	var cv := m.add_cvar(GSGameAvatarContent.SERVER_CVAR, str(id),
		"This server's id on the site, where clients read its avatar library.",
		GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED)
	if cv == null or id > 0 or m.site_server_retries <= 0 or not m.is_inside_tree():
		return
	# A Timer child, so a module freed mid-wait takes the retry with it.
	var timer := Timer.new()
	timer.name = "SiteServerRetry"
	timer.wait_time = maxf(0.05, m.site_server_retry_sec)
	m.add_child(timer)
	var left := [m.site_server_retries]
	timer.timeout.connect(func() -> void:
		var found: int = m._site_server_id()
		left[0] -= 1
		if found > 0:
			var _set := cv.set_value(str(found))
		if found > 0 or left[0] <= 0:
			timer.queue_free())
	timer.start()


## Publishes the files a client must fetch before it joins, as `sv_avatar_content`.
static func advertise_content(m: GSGameModule) -> void:
	var ids: Array = m._avatar_content_required()
	if ids.is_empty() or m.console == null:
		return
	var made := m.add_cvar(GSGameAvatarContent.CVAR, GSGameAvatarContent.format(ids),
		"Avatar and action files a client downloads before it joins.", GSConVar.FLAG_NOTIFY)
	if made == null:
		GSLog.warn(CHANNEL, "avatar content not advertised: no cvar")


## Binds `sv_slide_sounds`, which every client's slide scrape follows.
static func bind_slide_sounds(m: GSGameModule) -> void:
	var spec: Dictionary = preload("res://addons/dot_game/runtime/dot_game_slide_sounds.gd").cvar_spec()
	var _cv := m.add_cvar(
		String(spec["name"]), String(spec["value"]), String(spec["description"]),
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
	)


## Binds GameSpice Audio's `sv_surf_*` cvars (glide volume, speed range, pitch, whether steps stop on a ramp), which every client follows. Nothing without GameSpice Audio.
static func bind_surf_sounds(m: GSGameModule) -> void:
	for spec: Dictionary in preload("res://addons/dot_game/runtime/dot_game_slide_sounds.gd").surf_cvar_specs():
		var cv := m.add_cvar(
			String(spec["name"]), String(spec["value"]), String(spec["description"]),
			GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
		)
		if cv != null and cv.has_method(&"with_range"):
			cv.call(&"with_range", float(spec["min"]), float(spec["max"]))


## Wires the roster to the bridge and to whatever else wants to know.
static func build_roster(m: GSGameModule) -> void:
	var roster := GSGameRoster.new()
	m.roster = roster
	roster.server = m.server
	roster.load_timeout_sec = m.load_timeout_sec
	roster.reload_grace_sec = m.reload_grace_sec
	roster.loading_changed.connect(m._on_loading_changed)
	m._handle_cover_reports()

	if m.game != null and GSGameModule.PEER_LOADING_PROPERTY in m.game:
		m.game.set(GSGameModule.PEER_LOADING_PROPERTY, Callable(m, "is_peer_loading"))
		m._set_peer_loading = true

	if m.bridge != null:
		roster.add_fn = func(session: GSClientSession) -> Variant:
			if m.bridge == null or not m.bridge.has_method("add_player"):
				return null
			return m.bridge.call(
				"add_player",
				session.peer_id,
				session.userid,
				session.display_name
			)

		roster.remove_fn = func(session: GSClientSession) -> void:
			if m.bridge != null and m.bridge.has_method("remove_peer"):
				m.bridge.call("remove_peer", session.peer_id)
			if m.noblock != null:
				m.noblock.rules.call(&"forget", session.userid)

	roster.follow(m.services)
	m._follow_avatar_loadouts()
	# Any GameSpice Loadout manager the game built gets the site store's entitlements; idempotent per manager.
	roster.seated.connect(func(_s: GSClientSession) -> void:
		if m.is_inside_tree():
			GSGameStoreEntitlements.attach_tree(m.get_tree().root))
	var feed := GSGameStatsFeed.new()
	m.stats_feed = feed
	feed.map_fn = func() -> String: return m._reported_map
	feed.follow(roster)
	m.stats_board = GSGameStatsBoard.attach(feed, roster)

	# Through the module's helper, so it is unhooked on unload; a stale hook crashes the next spawn.
	m.hook_post("client_spawn", m._on_client_spawn)

	if m.server != null:
		m.server.client_disconnected.connect(roster.on_client_disconnected)


## Builds the block rules when the game has a `body_rules`; null in the result when off.
static func build_noblock(m: GSGameModule) -> GSResult:
	if not m._noblock_enabled():
		GSLog.debug(CHANNEL, "noblock off: no body_rules, or the game wires its own")
		return GSResult.success(null)
	if not GSGameNoblock.available():
		GSLog.warn(CHANNEL, "noblock unavailable: dot-team is not in this build (players block each other)")
		return GSResult.success(null)
	var made := GSGameNoblock.create(String(m._map_config_game()), Callable(m, "_noblock_side"))
	if not made.ok:
		return made
	var built: GSGameNoblock = made.value
	var bound := built.bind(m.add_cvar, m, m._noblock_runtime())
	if not bound.ok:
		return bound.wrap("noblock")
	built.feed(m.game.get("body_rules"))
	if "block_rules" in m.game:
		m.game.set("block_rules", built.rules)
	m.noblock = built
	return GSResult.success(built)


## Starts GameSpice Cloud's auto-update once per headless server process, under the server. No-op without GameSpice Cloud, on a listen server and in a browser.
static func start_auto_update(host: GSServer) -> Node:
	if host == null or not GSPlatform.is_headless() or not ResourceLoader.exists(GSGameModule.AUTO_UPDATE_SCRIPT):
		return null
	var existing := GSRegistry.get_node_service(GSGameModule.AUTO_UPDATE_SERVICE)
	if existing != null:
		return existing
	var script := load(GSGameModule.AUTO_UPDATE_SCRIPT) as Script
	if script == null or not bool(script.call("supported")):
		return null
	var node: Node = script.new()
	node.name = "GSCloudAutoUpdate"
	node.set("watch_fn", func() -> Array: return watched_packs(host))
	node.set("players_fn", func() -> int: return host.sessions().size())
	node.set("warn_fn", func(text: String) -> void: host.broadcast_message(text))
	node.set("restart_fn", func(code: int, reason: String) -> void:
		host.shutdown("Server restarting to update (%s)" % reason)
		host.get_tree().quit(code))
	host.add_child(node)
	node.call("bind_console", host.console)
	return node


## Every delivered pack the server's games run, as `{id, version}` (games, dependencies, maps).
static func watched_packs(host: Object) -> Array:
	var out: Array = []
	var manager: Object = host.get(&"games") if host != null else null
	var listed: Variant = manager.get(&"games") if manager != null else null
	if not (listed is Array):
		return out
	for d: Variant in listed:
		if not (d is GSGameDescriptor) or not (d as GSGameDescriptor).needs_delivered_content():
			continue
		out.append({"id": d.effective_content_id(), "version": d.version})
		for list_name: StringName in [&"dependencies", &"server_dependencies", &"maps"]:
			if not (list_name in d):
				continue
			for key: String in d.get(list_name):
				var parts := GSGameDescriptor.split_key(key)
				out.append({"id": parts[0], "version": parts[1]})
	return out


## Applies the map's scripts and per-map config, building the config on first use.
static func apply_map_config(m: GSGameModule, map_id: String) -> void:
	if m.map_scripts != null:
		if m.map_scripts.console == null:
			m.map_scripts.console = m.console
		m.map_scripts.map_changed()
	if m.map_config == null:
		var keys := m._map_config_keys()
		if m.map_scripts != null:
			keys.merge(m.map_scripts.config_keys())
		var defaults := m._map_config_defaults()
		if keys.is_empty() and defaults.is_empty():
			return
		m.map_config = GSGameMapConfig.new()
		m.map_config.game_id = m._map_config_game()
		m.map_config.keys = keys
		m.map_config.defaults = defaults
		m.map_config.get_fn = m._map_config_get
		m.map_config.set_fn = m._map_config_set
	m.map_config.apply(map_id)


## Builds a `GSFpsCvars` (by path: GameSpice Player Controller is not a dependency) over [param targets] and registers its cvars, replicated, since a client predicts its own movement from them.
static func bind_movement_cvars(m: GSGameModule, targets: Array) -> Array:
	if targets.is_empty() or m.console == null:
		return []
	var script: Variant = load(GSGameModule.fps_cvars_script) if ResourceLoader.exists(GSGameModule.fps_cvars_script) else null
	if not (script is GDScript):
		GSLog.debug(CHANNEL, "no dot-player-controller; movement cvars not bound")
		return []
	var binder: Object = (script as GDScript).new()
	for target: Variant in targets:
		if target is Object:
			binder.call(&"add_target", target)
	m.movement_cvars = binder
	var made: Array = binder.call(&"bind_cvars", Callable(m, "add_cvar"), GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED)
	GSLog.debug(CHANNEL, "movement cvars bound", {"count": made.size()})
	return made


## Builds the identity layer and loads GameSpice Platform beside it.
static func build_identity(m: GSGameModule) -> GSResult:
	m.identity = m._make_identity()

	if m.identity == null:
		return GSResult.success(null)

	m.identity.name = "Identity"
	m.add_child(m.identity)

	if not m.identity.has_method("setup"):
		m._drop(m.identity)
		m.identity = null
		return GSResult.fail(
			GSError.CODE_UNSUPPORTED,
			"The identity layer has no setup()."
		)

	# Awaited and typed: an un-awaited coroutine returns at its first suspension.
	var ready: Variant = await m.identity.call("setup")

	if not (ready is GSResult) or not (ready as GSResult).ok:
		m._drop(m.identity)
		m.identity = null
		return ready if ready is GSResult else GSResult.fail(
			GSError.CODE_INTERNAL, "The identity layer's setup() returned no result."
		)

	if m._wants_platform_module() and m.server != null and m.server.modules != null:
		if not m.server.modules.has_module("platform"):
			# Awaited: a module's `_module_load` may be a coroutine, and GameSpice Platform's is.
			var loaded: GSResult = await m.server.modules.load_module(
				m.PLATFORM_MODULE_PATH
			)

			m._loaded_platform = loaded.ok

			if not loaded.ok:
				# Reported, not fatal: without the platform module everybody is a guest.
				GSLog.result(CHANNEL, "the platform module", loaded)

	return GSResult.success(m.identity)


## Builds the services layer over whatever link the bridge opened.
static func build_services(m: GSGameModule) -> GSResult:
	m.services = m._make_services()

	if m.services == null:
		return GSResult.success(null)

	m.services.name = "Services"

	# Before `setup`: the services build their relay inside it.
	if m.identity != null and "backbone" in m.identity and "backbone" in m.services:
		m.services.set("backbone", m.identity.get("backbone"))

	m.add_child(m.services)

	if not m.services.has_method("setup"):
		m._drop(m.services)
		m.services = null
		return GSResult.fail(
			GSError.CODE_UNSUPPORTED, "The services layer has no setup()."
		)

	var link: Object = m.bridge.get("link") if m.bridge != null else null
	var ready: Variant = await m.services.call("setup", m.server, m.game, link)

	if not (ready is GSResult) or not (ready as GSResult).ok:
		m._drop(m.services)
		m.services = null
		return ready if ready is GSResult else GSResult.fail(
			GSError.CODE_INTERNAL, "The services layer's setup() returned no result."
		)

	# The bridge is the only thing that names both ends of the voice path, so it is set here.
	if m.bridge != null and "voice_relay_fn" in m.bridge and m.services.has_method("relay_voice"):
		m.bridge.set("voice_relay_fn", Callable(m.services, "relay_voice"))

	# Voice enable/mode on the router, replicated so clients hide the talk key; read back so content.yml wins. Duck-typed.
	var router: Variant = m.services.get("voice") if "voice" in m.services else null
	if router is Object and (router as Object).has_method("bind_cvars"):
		var _voice_cvars: Variant = (router as Object).call(
			"bind_cvars", Callable(m, "add_cvar"), GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
		)

		var look_script := load(m.LOOK_MUTE_SCRIPT) if ResourceLoader.exists(m.LOOK_MUTE_SCRIPT) else null
		if look_script is Script and (look_script as Script).has_method("cvar_specs"):
			for spec in (look_script as Object).call("cvar_specs"):
				var _made := m.add_cvar(
					String(spec["name"]), String(spec["value"]), String(spec["description"]),
					GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
				)

	return GSResult.success(m.services)


## Lowers the snapshot rate on a server of many slots, unless the operator turned `net_snapshot_auto` off.
static func adapt_snapshot_rate(m: GSGameModule, config: Object) -> void:
	if m.console == null or m.server == null:
		return
	var auto_cv: GSConVar = m.console.find_cvar("net_snapshot_auto")
	if auto_cv == null:
		auto_cv = m.console.cvar("net_snapshot_auto", "1", "Lower the snapshot rate on a server of many slots (0 keeps the game's rate).", GSConVar.FLAG_ARCHIVE).with_range(0, 1)
	if auto_cv.get_int() == 0:
		return
	var tiered := GSGameNetcode.adapt_snapshot_rate(config, m.server.config.max_players)
	if tiered != "":
		GSLog.info(CHANNEL, "snapshot rate adapted to the server size", {"module": String(m._module_name()), "change": tiered})
