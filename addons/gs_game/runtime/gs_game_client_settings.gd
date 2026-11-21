extends RefCounted

## [GSGameClient]'s settings build: the node, its rows, its menu. No class_name: the client preloads it.

const CHANNEL := "game.client"


static func build(c: Node) -> void:
	if c.settings == null:
		c.settings = c._make_settings()
	if c.settings == null:
		return
	if c.settings.name == &"":
		c.settings.name = "Settings"
	if not c.settings.is_inside_tree():
		c.add_child(c.settings)
	if not c.settings.has_method(&"setup"):
		GSLog.warn(CHANNEL, "the settings node has no setup(); it is left alone", {"node": str(c.settings)})
		return

	GSGameClientLook.add_rows(c)
	if c.use_slide_sounds:
		preload("res://addons/gs_game/runtime/gs_game_slide_sounds.gd").declare_on(c.settings)
	var built: Variant = c.settings.call(&"setup")
	if built is GSResult and not (built as GSResult).ok:
		GSLog.warn(CHANNEL, "no settings; everything is at its default", {"why": (built as GSResult).error.message})
		c.settings.queue_free()
		c.settings = null
		return

	var got: Variant = c.settings.get(&"menu")
	c.menu = got if got is Object else null
	GSGameUserCfg.add_entry(c)


## The stock GameSpice Menu settings node, or null when GameSpice Menu is not in the build.
static func make(c: Node) -> Node:
	if not ResourceLoader.exists(c.SETTINGS_SCRIPT):
		GSLog.info(CHANNEL, "gs-menu is not in this build: no settings or Escape menu")
		return null
	var script: Variant = load(c.SETTINGS_SCRIPT)
	if not (script is GDScript):
		GSLog.warn(CHANNEL, "gs-menu's settings would not load", {"path": c.SETTINGS_SCRIPT})
		return null
	var made: Node = (script as GDScript).new()
	made.set(&"app_namespace", c.app_namespace)
	made.set(&"avatar_actions", true)
	made.set(&"directory", c.settings_directory if c.settings_directory != "" else "user://%s_settings" % c.app_namespace)
	return made
