class_name DotGameConfigSchemas
extends RefCounted

## The profile schemas of a game's grouped `config_<file>` kinds, for dot-profile's profile_check (any registered class with this static is a provider, so a game enables `profiles: true` with no provider of its own).

const MAKER := "static func make_binder("
## Directories that never hold a game's config (addons carry their own providers).
const SKIP_DIRS := ["addons", "maps", "assets", "images", "cfg", "build"]


## Every game config script (registered or not: configs rarely have a `class_name`) that declares `static func make_binder(config, json_path)` contributes its binder's sets, kind -> field Array.
static func profile_schemas() -> Dictionary:
	return schemas_for(config_scripts())


## The game's config scripts (those declaring a static `make_binder`), found under `res://`.
static func config_scripts() -> Array:
	var scripts: Array = []
	_scan("res://", scripts)
	return scripts


static func _scan(dir: String, scripts: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd") and FileAccess.get_file_as_string(dir.path_join(f)).contains(MAKER):
			scripts.append(load(dir.path_join(f)))
	for d in DirAccess.get_directories_at(dir):
		if not (d.begins_with(".") or d in SKIP_DIRS):
			_scan(dir.path_join(d), scripts)


## The binder of a script declaring [code]make_binder[/code], as a [DotResult]. Its config is the script's own [code]static func make_config()[/code] when it has one (a game's flashlight script hands a DotFlashlightConfig to a binder on a script that is not itself a config), else [code]s.new()[/code] (a config whose make_binder takes its own instances). A config the binder's first parameter would not accept is refused with the reason: calling it anyway is a script error that stops the caller, which in a [code]--script[/code] tool means it never quits.
static func binder_of(s: Script) -> DotResult:
	var config: Variant = s.call("make_config") if s.has_method("make_config") else s.new()
	var wanted := _first_arg_class(s, "make_binder")
	if not _is_a(config, wanted):
		return DotResult.fail(DotError.CODE_INVALID,
			"%s: make_binder takes a %s, but the config it would get is a %s; give the script a static make_config() returning one."
			% [s.resource_path, wanted, _class_of(config)])
	var binder: Variant = s.call("make_binder", config)
	if not (binder is DotGameConfigBinder):
		return DotResult.fail(DotError.CODE_INVALID, "%s: make_binder returned no DotGameConfigBinder." % s.resource_path)
	return DotResult.success(binder)


static func _first_arg_class(s: Script, method: String) -> StringName:
	for m: Dictionary in s.get_script_method_list():
		if m["name"] == method and not (m["args"] as Array).is_empty():
			return StringName(m["args"][0]["class_name"])
	return &""


static func _is_a(value: Variant, cls: StringName) -> bool:
	if cls == &"":
		return true
	if not (value is Object):
		return false
	var sc: Script = (value as Object).get_script()
	while sc != null:
		if sc.get_global_name() == cls:
			return true
		sc = sc.get_base_script()
	return (value as Object).is_class(cls)


static func _class_of(value: Variant) -> String:
	if not (value is Object):
		return type_string(typeof(value))
	var sc: Script = (value as Object).get_script()
	while sc != null:
		if sc.get_global_name() != &"":
			return sc.get_global_name()
		sc = sc.get_base_script()
	return (value as Object).get_class()


## [method profile_schemas] over the given config scripts.
static func schemas_for(scripts: Array) -> Dictionary:
	var out := {}
	for s: Script in scripts:
		if s == null or not s.has_method("make_binder"):
			continue
		var made := binder_of(s)
		if not made.ok:
			push_error(made.error.message)
			continue
		var binder: DotGameConfigBinder = made.value
		for set: DotProfileSet in binder.profile_sets():
			out[set.rel_path] = set.schema
	return out
