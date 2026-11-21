class_name GSGameClientStats
extends RefCounted

## The stats half of [GSGameClient]'s board wiring: lifetime columns on the Tab board and a card for the player's own figures, both from GameSpice Menu by path, both off with `cl_stats_ui 0`. Needs a server whose module has a stats board.

const CVAR := "cl_stats_ui"
const COLUMNS_SCRIPT := "res://addons/gs_menu/ui/gs_menu_stats.gd"
const PANEL_SCRIPT := "res://addons/gs_menu/ui/gs_menu_stats_panel.gd"
const _Vis := preload("res://addons/gs_game/runtime/gs_game_client_vis.gd")


## Installs the columns on [member GSGameClient.board] and builds the card beside it; idempotent.
static func wire(c: Node) -> void:
	var board: Object = c.board
	if board == null or not (board is Node) or not ResourceLoader.exists(COLUMNS_SCRIPT):
		return
	var columns: Variant = (load(COLUMNS_SCRIPT) as GDScript).call(&"install", board)
	c.stats_columns = columns if columns is Object else null
	if c.stats_panel == null or not is_instance_valid(c.stats_panel):
		if ResourceLoader.exists(PANEL_SCRIPT) and (board as Node).get_parent() != null:
			var made: Variant = (load(PANEL_SCRIPT) as GDScript).new()
			if made is Node:
				c.stats_panel = made
				var kit: Variant = board.get(&"kit")
				if kit != null:
					c.stats_panel.set(&"kit", kit)
				(board as Node).get_parent().add_child(c.stats_panel)
	if c.stats_panel != null and not c.offline and c.link != null:
		c.stats_panel.call(&"feed_from", c.link)
	apply(c)


## Pushes [member GSGameClient.stats_ui] to the columns and the card.
static func apply(c: Node) -> void:
	if c.stats_columns != null:
		c.stats_columns.set(&"enabled", c.stats_ui)
	if c.stats_panel != null:
		c.stats_panel.set(&"enabled", c.stats_ui)


## Makes `cl_stats_ui` typable in the console unless the game defines it.
static func add_console_var(c: Node) -> void:
	var local: Object = _Vis.local_source(c, StringName(CVAR))
	if local == null:
		return
	local.call(&"add_var", CVAR, "Lifetime stats on the board and the stats card: 1 (default) or 0",
		func() -> Variant: return 1 if c.stats_ui else 0,
		func(v: Variant) -> Variant:
			c.stats_ui = str(v) not in ["0", "false", "off"]
			apply(c)
			return GSResult.success(1 if c.stats_ui else 0))


## Opens the card for [param seconds] (0 until closed): an end-of-round screen calls this.
static func show(c: Node, seconds: float) -> void:
	if c.stats_panel != null and is_instance_valid(c.stats_panel):
		c.stats_panel.call(&"show_for", seconds)
