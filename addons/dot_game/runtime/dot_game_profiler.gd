extends RefCounted

## Places GameSpice Profiler for a game, client and server, from one spot so no game wires it.
## No class_name: callers preload it. GameSpice Profiler is optional and located by path, so a build without it parses and runs.

const CHANNEL := "game.profiler"
const SCRIPT := "res://addons/dot_profiler/runtime/dot_profiler.gd"
const SERVER_SCRIPT := "res://addons/dot_profiler/runtime/dot_profiler_server.gd"
const NODE_NAME := "Profiler"
const OFF_FLAG := "--no-profiler"
const OFF_ENV := "DOT_GAME_PROFILER"
## project.godot, section [gamespice]: the one line a game adds for its perf reports (`perf_game_id="fatal-contact"`); `perf_repo` overrides the repository name read from the checkout.
const SETTING_GAME_ID := "gamespice/perf_game_id"
const SETTING_REPO := "gamespice/perf_repo"
const NET_SCRIPT := "res://addons/dot_profiler/core/dot_profiler_net_cost.gd"
const SIGNALS_SCRIPT := "res://addons/dot_profiler/core/dot_profiler_signals.gd"

## The profiler's static counters, resolved once by path (false: not in this build). Never named by class_name here.
static var _net_cls: Variant = null
static var _sig_cls: Variant = null


## False when the operator turned the placement off: `--no-profiler` or GS_GAME_PROFILER=0.
static func wanted() -> bool:
	if OFF_FLAG in OS.get_cmdline_user_args() or OFF_FLAG in OS.get_cmdline_args():
		return false
	return GSConfig.gs_env(OFF_ENV) != "0"


## Starts compiling the profiler script on a loader thread, so [method add] later finds it cached instead of compiling it in one frame. True while a load is already in flight; false when there is nothing to load or no threads (web): [method add] then loads it itself.
static func request_script() -> bool:
	if requested():
		return true
	if not wanted() or not ResourceLoader.exists(SCRIPT) or ResourceLoader.has_cached(SCRIPT) or not GSPlatform.has_threads():
		return false
	return ResourceLoader.load_threaded_request(SCRIPT) == OK


## Whether a load [method request_script] started is still to be collected.
static func requested() -> bool:
	return ResourceLoader.load_threaded_get_status(SCRIPT) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE


## Awaits the load [method request_script] started, one process frame at a time, and returns the script (null if it failed). [param block] waits on this thread instead: a caller whose frames are the game's own must not end one here. Hold the result until [method add] ran: the cache keeps a script only while something references it.
static func await_script(tree: SceneTree, block: bool = false) -> Resource:
	while not block and ResourceLoader.load_threaded_get_status(SCRIPT) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await tree.process_frame
	if not requested():
		return null
	var script := ResourceLoader.load_threaded_get(SCRIPT)
	return script if script is GDScript else null


## Adds the profiler under [param host] (the Performance tab then appears in the menu). Null when it is off, not in this build, or already placed.
## It watches no frames until profiler_enabled or a recording turns that on, so an idle one costs nothing.
static func add(host: Node) -> Node:
	if not wanted() or not ResourceLoader.exists(SCRIPT) or host.get_node_or_null(NODE_NAME) != null:
		return null
	if GSRegistry.get_service(&"dot_profiler") != null:
		return null
	var script: Variant = ResourceLoader.load_threaded_get(SCRIPT) if requested() else load(SCRIPT)
	if not (script is GDScript):
		return null
	var node: Node = (script as GDScript).new()
	node.name = NODE_NAME
	# The profiler builds its config in _ready; identify the game right after.
	node.ready.connect(configure.bind(node), CONNECT_ONE_SHOT)
	host.add_child(node)
	GSLog.debug(CHANNEL, "profiler placed", {"host": str(host.get_path())})
	return node


## Registers profiler_* and the record/stop commands on a client's local console source.
static func bind_client_console(node: Node, local: Object) -> void:
	if node != null and local != null:
		node.call(&"bind_console", local)


## Installs sv_profiler_* on the server's console. Failure is logged and leaves the profiler placed.
static func install_server(node: Node) -> void:
	if node == null or not ResourceLoader.exists(SERVER_SCRIPT):
		return
	var script: Variant = load(SERVER_SCRIPT)
	if not (script is GDScript):
		return
	var res: Variant = ((script as GDScript).new() as Object).call(&"install", node)
	if res is GSResult and not (res as GSResult).ok:
		GSLog.info(CHANNEL, "server profiler commands not installed", {"why": (res as GSResult).error.message})


## The game id for perf reports: the game's `gamespice/perf_game_id` setting, else [member GSAddonConfig.game] when a game set it, else the repository directory name without its `game-` or `mg-` prefix, else the project name as a slug.
static func perf_game_id() -> String:
	var id := str(ProjectSettings.get_setting(SETTING_GAME_ID, ""))
	if id == "":
		id = GSAddonConfig.game
	if id == "":
		id = repo_name()
		for prefix: String in ["game-", "mg-"]:
			if id.begins_with(prefix):
				id = id.trim_prefix(prefix)
				break
	if id == "":
		id = str(ProjectSettings.get_setting("application/config/name", "")).to_lower().replace(" ", "-").replace("'", "")
	return id


## The repository name: `gamespice/perf_repo`, else the checkout directory's name when it has a .git; "" in an export.
static func repo_name() -> String:
	var set := str(ProjectSettings.get_setting(SETTING_REPO, ""))
	if set != "":
		return set
	var dir := ProjectSettings.globalize_path("res://").trim_suffix("/")
	return dir.get_file() if FileAccess.file_exists(dir.path_join(".git")) or DirAccess.dir_exists_absolute(dir.path_join(".git")) else ""


## Tells a placed profiler which game this is: its perf reports' `game_id` (unless a cvar, env or flag chose one) and the `repo` and `platform` tags. The commit and build version come from the profiler's own build context. Runs once, from the profiler's ready signal.
static func configure(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var config: Variant = node.get(&"config")
	if config is Object and str((config as Object).get(&"perf_game_id")) == "":
		(config as Object).set(&"perf_game_id", perf_game_id())
	if node.has_method(&"set_perf_option"):
		node.call(&"set_perf_option", "tags", {"repo": repo_name(), "platform": "web" if OS.has_feature("web") else "native"})


## Names the map a recording ran on in its perf report.
static func set_map(node: Node, map_id: String) -> void:
	if node != null and is_instance_valid(node) and node.has_method(&"set_perf_option"):
		node.call(&"set_perf_option", "map", map_id)


## Counts a message of [param bytes] for [param cls] in the perf report's network table (`0` in, `1` out), for a transport that does not go through GameSpice Net. One dynamic property read when no recording runs; nothing when GameSpice Profiler is not in the build.
static func net_cost(cls: StringName, dir: int, bytes: int) -> void:
	if _net_cls == null:
		_net_cls = _resolve(NET_SCRIPT)
	if _net_cls is GDScript and (_net_cls as GDScript).get(&"enabled"):
		(_net_cls as GDScript).call(&"add", cls, dir, bytes)


## Counts one emit of [param signal_name] on [param obj] and the receivers it reaches in the perf report's signal fan-out table, for a signal that fires every frame or per entity. Nothing when GameSpice Profiler lacks it. Call it beside the `emit`, never instead.
static func signal_emitted(obj: Object, signal_name: StringName) -> void:
	if _sig_cls == null:
		_sig_cls = _resolve(SIGNALS_SCRIPT)
	if _sig_cls is GDScript and (_sig_cls as GDScript).get(&"enabled"):
		(_sig_cls as GDScript).call(&"emitted", obj, signal_name)


static func _resolve(path: String) -> Variant:
	if not ResourceLoader.exists(path):
		return false
	var script: Variant = load(path)
	return script if script is GDScript else false
