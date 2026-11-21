class_name GSGameClientExtras
extends RefCounted

## The optional parts [GSGameClient] adds in setup: profiler, render quality, landing, slide sounds, latency, chat and team-menu wiring.

const _Vis := preload("res://addons/gs_game/runtime/gs_game_client_vis.gd")
const _RenderQuality := preload("res://addons/gs_game/runtime/gs_game_render_quality.gd")
const _Profiler := preload("res://addons/gs_game/runtime/gs_game_profiler.gd")


static func add_profiler(c: Node) -> void:
	if not c.use_profiler:
		return
	c.profiler = _Profiler.add(c)
	if c.profiler == null:
		return
	# F10 captures profiler_capture_seconds; a GameSpice Profiler older than level 2 has no capture key.
	if c.profiler.has_method(&"enable_capture_key"):
		c.profiler.call(&"enable_capture_key")
	if not bind_profiler_console(c):
		# A game that builds its own console registers it later; bind then (deferred, so its own commands are on it).
		GSRegistry.signals().service_registered.connect(c._on_console_service)


## Drops the client's connections to the registry's static bus, which outlives it; called on exit tree.
static func disconnect_registry_bus(c: Node) -> void:
	var bus := GSRegistry.signals()
	if bus.service_registered.is_connected(c._on_console_service):
		bus.service_registered.disconnect(c._on_console_service)
	if bus.service_registered.is_connected(c._on_replay_service):
		bus.service_registered.disconnect(c._on_replay_service)
	if bus.service_registered.is_connected(c._on_latency_service):
		bus.service_registered.disconnect(c._on_latency_service)


## The registry outlives a client, so a deferred bind holds its instance id: a freed object as an argument errors.
static func _bind_if_alive(id: int) -> void:
	var c := instance_from_id(id) as Node
	if c != null:
		bind_profiler_console(c)


static func on_console_service(service: StringName, c: Node) -> void:
	if service == &"gs_console":
		_bind_if_alive.call_deferred(c.get_instance_id())


static func bind_profiler_console(c: Node) -> bool:
	if c._profiler_bound or c.profiler == null or not is_instance_valid(c.profiler):
		return c._profiler_bound
	var con: Object = c.console if c.console != null and is_instance_valid(c.console) else GSRegistry.get_service(&"gs_console")
	if con == null or not con.has_method(&"sources"):
		return false
	var local: Object = null
	for s: Object in con.call(&"sources"):
		if s.has_method(&"add_var"):
			if s.has_method(&"claims") and bool(s.call(&"claims", "profiler_enabled")):
				c._profiler_bound = true
				return true
			local = s
	if local == null:
		return false
	_Profiler.bind_client_console(c.profiler, local)
	c._profiler_bound = true
	return true


static func add_render_quality(c: Node) -> void:
	if not c.use_render_quality or c.gate_only:
		return
	var store: Object = null
	if c.settings != null and is_instance_valid(c.settings):
		store = c.settings.get(&"settings")
	c.render_quality = preload("res://addons/gs_game/runtime/gs_game_client_render.gd").add(c, store)


## GameSpice Audio scripts the slide and landing pieces load, by path. Compiling them is most of those pieces' frame cost.
const AUDIO_SCRIPTS: Array[String] = [
	"res://addons/gs_audio/runtime/gs_audio_slide.gd",
	"res://addons/gs_audio/runtime/gs_audio_surf.gd",
	"res://addons/gs_audio/core/gs_audio_surf_rules.gd",
	"res://addons/gs_audio/core/gs_audio_landing_rules.gd",
]


## Starts compiling the [constant AUDIO_SCRIPTS] on loader threads, so the sound pieces find them cached. Nothing without threads (web) or without GameSpice Audio.
static func request_audio_scripts() -> void:
	if not GSPlatform.has_threads():
		return
	for path in AUDIO_SCRIPTS:
		if ResourceLoader.exists(path) and not ResourceLoader.has_cached(path):
			var _err := ResourceLoader.load_threaded_request(path)


## Collects what [method request_audio_scripts] started (waits only for a load still running) and holds it on the client.
static func collect_audio_scripts(c: Node) -> void:
	for path in AUDIO_SCRIPTS:
		if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			c._audio_scripts.append(ResourceLoader.load_threaded_get(path))


static func add_landing(c: Node) -> void:
	if not c.use_landing:
		return
	var node: Node = preload("res://addons/gs_game/runtime/gs_game_landing.gd").new()
	node.name = "Landing"
	node.set(&"surf_rules_fn", func() -> Object: return c.slide_sounds.get(&"surf_rules") if c.slide_sounds != null and is_instance_valid(c.slide_sounds) else null)
	c.add_child(node)
	if node.call(&"start"):
		c.landing = node
		if c.console != null and is_instance_valid(c.console):
			var _bound: Variant = node.call(&"bind_console", c.console)
	else:
		node.queue_free()


static func add_slide_sounds(c: Node) -> void:
	if not c.use_slide_sounds:
		return
	var node: Node = preload("res://addons/gs_game/runtime/gs_game_slide_sounds.gd").new()
	node.name = "SlideSounds"
	node.set(&"link_fn", func() -> Object: return c.link)
	node.set(&"settings_fn", func() -> Object:
		if c.slide_settings != null:
			return c.slide_settings
		return c.settings.get(&"settings") if c.settings != null and is_instance_valid(c.settings) else null)
	c.add_child(node)
	if node.call(&"start"):
		c.slide_sounds = node
	else:
		node.queue_free()


## Finds the client's GSNetManager in the registry now or when it registers (a server's is skipped).
static func watch_latency_net(c: Node) -> void:
	var bus := GSRegistry.signals()
	if not bus.service_registered.is_connected(c._on_latency_service):
		bus.service_registered.connect(c._on_latency_service)
	for service_name in GSRegistry.names():
		on_latency_service(service_name, GSRegistry.get_service(service_name), c)


static func on_latency_service(service_name: StringName, instance: Object, client: Node) -> void:
	if not String(service_name).begins_with(String(GSNetManager.SERVICE)) or not (instance is GSNetManager):
		return
	if (instance as GSNetManager).is_server:
		return
	client.add_latency(instance as GSNetManager)


## Tunes the client's replay settings from _ready, so a client that never calls setup() (a game with its own menu and console) gets them too.
static func watch_replay_tuning(c: Node) -> void:
	var bus := GSRegistry.signals()
	if not bus.service_registered.is_connected(c._on_replay_service):
		bus.service_registered.connect(c._on_replay_service)
	for service_name in GSRegistry.names():
		on_replay_service(service_name, GSRegistry.get_service(service_name), c)


static func on_replay_service(service_name: StringName, instance: Object, client: Node) -> void:
	if not client.tune_replay or not String(service_name).begins_with(String(GSNetManager.SERVICE)) or not (instance is GSNetManager):
		return
	var m := instance as GSNetManager
	if not m.is_server and m.config != null:
		m.config.reconcile_once_per_frame = true
		m.config.skip_matching_replays = true


static func bind_latency(c: Node) -> void:
	if c._latency_net == null or c._latency_net.latency == null or c._latency_bound == c._latency_net:
		return
	var latency: GSNetLatency = c._latency_net.latency
	var source: Object = c.link if c.link != null else GSRegistry.get_service(c.LINK_SERVICE)
	var _followed := latency.follow_cvars(source)
	var local := _Vis.local_source(c, StringName(latency.CVAR_BASELINE))
	if local == null:
		return
	c._latency_bound = c._latency_net
	var _bound := latency.bind_client_cvar(func(n: String, _d: String, help: String, _f: int) -> Object:
		local.call(&"add_var", StringName(n), help,
			func() -> Variant: return latency.requested,
			func(v: Variant) -> Variant:
				if latency.set_cvar(n, str(v)):
					return GSResult.success(latency.requested)
				return GSResult.fail(GSError.CODE_INVALID, "%s takes seconds, e.g. 0.1" % n))
		return null)


static func wire_chat(c: Node) -> void:
	if c.chat == null:
		return
	if not c.chat.is_inside_tree():
		c.add_child(c.chat)
	# typing_changed(bool) on GSGameChatClient, opened(channel) / closed() on GameSpice UI's box.
	for signal_name: StringName in [&"typing_changed", &"opened", &"closed"]:
		if c.chat.has_signal(signal_name):
			c.chat.connect(signal_name, c._refresh_blocked)


static func wire_team_menu(c: Node) -> void:
	# By name and only when unset: an older GameSpice Menu has no team menu, and a game's own offer stays.
	if not c.use_team_menu or c.menu == null or not c.menu.has_method(&"use_teams"):
		return
	if &"teams" in c.menu and c.menu.get(&"teams") != null:
		return
	var teams: Variant = c.menu.call(&"use_teams")
	if teams is Object and &"default_when_unwired" in (teams as Object):
		(teams as Object).set(&"default_when_unwired", c.team_menu_default_when_unwired)


## The body of [method GSGameClient.add_console]: the kit's console, then the client's own vars on it.
static func build_console(c: Node, manager: Object) -> Node:
	if not ResourceLoader.exists(c.console_kit_path):
		GSLog.info(c.CHANNEL, "gs-console is not in this build: no console")
		return null
	var kit: Variant = load(c.console_kit_path)
	if not (kit is GDScript):
		GSLog.warn(c.CHANNEL, "gs-console's kit would not load", {"path": c.console_kit_path})
		return null
	if manager == null and c.settings != null:
		var got: Variant = c.settings.get(&"settings")
		manager = got if got is Object else null
	var built: Variant = (kit as GDScript).call(&"build", c, manager, c.menu)
	c.console = built if built is Node else null
	var _v := _Vis.add_console_var(c)
	var quality := _Vis.local_source(c, &"r_msaa")
	if quality != null:
		_RenderQuality.add_client_vars(quality, func() -> void: _RenderQuality.apply(c.get_viewport(), c.get_tree().root))
	GSGameClientStats.add_console_var(c)
	if c._latency_net != null:
		bind_latency(c)
	return c.console


static func map_changed(c: Node, map_id: String) -> void:
	_Profiler.set_map(c.profiler, map_id)
	if c.map_config == null:
		if (c.map_config_keys.is_empty() and c.map_config_defaults.is_empty()) \
				or not c.map_config_get_fn.is_valid() or not c.map_config_set_fn.is_valid():
			return
		c.map_config = GSGameMapConfig.new()
		c.map_config.game_id = c.map_config_game if c.map_config_game != "" else GSAddonConfig.game
		c.map_config.keys = c.map_config_keys
		c.map_config.defaults = c.map_config_defaults
		c.map_config.get_fn = c.map_config_get_fn
		c.map_config.set_fn = c.map_config_set_fn
	c.map_config.apply(map_id)


## The sound, landing, render-quality and latency parts a client adds after its menu.
static func add_late_parts(c: Node) -> void:
	add_slide_sounds(c)
	add_landing(c)
	add_render_quality(c)
	watch_latency_net(c)
