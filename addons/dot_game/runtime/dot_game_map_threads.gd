extends RefCounted

## The `map_load_threads` cvar (workers for the pure-CPU stages of a map load, GameSpice Map's docs/load-threads.md) and its copy into GameSpice Map's `GSMapParallelBuild.default_workers`. GameSpice Map is reached by path and never named; without it the cvar exists and does nothing. No class_name: the module and the client preload it.

const CHANNEL := "game.map_threads"
const CVAR := "map_load_threads"
const BUILD_SCRIPT := "res://addons/dot_map/bsp/dot_map_parallel_build.gd"
const HELP := "Worker threads for map loading: 0 inline (default), N workers, -1 automatic. Never used on the web."

## What the client console variable last held; the server reads its cvar instead.
static var client_value: int = 0


## Registers the server cvar on [param console] (once), applies it, and returns it.
static func ensure_cvar(console: GSConsole) -> GSConVar:
	var cv := console.find_cvar(CVAR)
	if cv == null:
		cv = console.cvar(CVAR, "0", HELP, GSConVar.FLAG_ARCHIVE)
		cv.with_range(-1, 64)
	apply(cv.get_int())
	return cv


## Per tick on the server: copies the cvar again when it changed, so `map_load_threads` is live.
static func follow(console: GSConsole) -> void:
	var cv := console.find_cvar(CVAR) if console != null else null
	if cv != null and cv.get_int() != current():
		apply(cv.get_int())


## Sets GameSpice Map's default worker count; false when GameSpice Map is not in this build.
static func apply(workers: int) -> bool:
	var script := _script()
	if script == null:
		return false
	script.set(&"default_workers", workers)
	GSLog.debug(CHANNEL, "map load workers set", {"workers": workers})
	return true


## What GameSpice Map will use for a load now, or 0 without GameSpice Map.
static func current() -> int:
	var script := _script()
	return int(script.get(&"default_workers")) if script != null else 0


## Adds the variable to a client console source (looked up by [GSGameClient]'s vis helper) and applies the value it holds.
static func add_client_var(local: Object) -> void:
	local.call(&"add_var", StringName(CVAR), HELP,
		func() -> Variant: return client_value,
		func(v: Variant) -> Variant:
			if not str(v).is_valid_int() or int(str(v)) < -1 or int(str(v)) > 64:
				return GSResult.fail(GSError.CODE_INVALID, "%s is -1 (auto), 0 (off) or a count up to 64" % CVAR)
			client_value = int(str(v))
			var _ok := apply(client_value)
			return GSResult.success(client_value))


## Applies a [code]--map_load_threads=[/code] user argument, before any map loads.
static func apply_cmdline() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % CVAR) and a.get_slice("=", 1).is_valid_int():
			client_value = clampi(int(a.get_slice("=", 1)), -1, 64)
			var _ok := apply(client_value)


static func _script() -> Script:
	return load(BUILD_SCRIPT) as Script if ResourceLoader.exists(BUILD_SCRIPT) else null
