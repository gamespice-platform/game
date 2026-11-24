@tool
class_name GSPlayerGameServices
extends GSGameServices

## [GSGameServices] for a round game whose `game.players` is a Dictionary of player objects: the admin abilities every such game answered the same way.
##
## A player object is duck-typed: `controller` (a GSFpsController), `health` (a GSHealth), `entity_id`, `display_name`, `blinded`, `beacon`, `player_id`, `place_at(pos, yaw)`, `is_alive()`, `team`. The game holds `players` (keyed `u<session id>`), `combat` (a GSCombatManager) and `team_of(player_id)`, and emits `round_began(number, layout)`.
##
## A game overrides [method _chat_channels], [method _chat_rules] and the voice hooks, and adds its own abilities through [method _mod_extra_abilities] (a respawn goes there: where a body starts again is the game's); an extra with a stock key replaces it.
## What differs between games is a hook: [method _mod_movable], [method _persist_on_respawn], [method _player_key].

## GSFpsAdminModifiers by path, so this file parses in a build without gs_player_controller (a game that has none never calls it).
const ADMIN_MODIFIERS := "res://addons/gs_player_controller/fp/core/gs_fps_admin_modifiers.gd"

## GSFpsState.Mode.AIR, for the same reason.
const AIR_MODE := 1

## The bridge, for the roster lookup [method _position_of] needs. Set before [method setup]. An Object: it only has to answer `player_for_peer(peer_id) -> int`.
var bridge: Object = null

var _tools_layout: StringName = &""


## The key a session id is stored under in `game.players`.
func _player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


## Admin toggles that outlive a new body, beyond gs-moderation's own god and buddha.
func _persist_on_respawn() -> Array[String]:
	return ["blind", "beacon"]


## Whether a player's body can be placed, moved or shoved by an admin right now (false while something else carries it).
func _mod_movable(_p: Object) -> bool:
	return true


## Abilities the game adds to, or replaces in, the stock set.
func _mod_extra_abilities() -> Dictionary:
	return {}


## Which side somebody is on, for the team channel and for team voice. Read off the game rather than cached, because sides change between rounds.
func _team_of(peer_id: int) -> int:
	var player := _player_of(peer_id)
	return int(game.call("team_of", player.get("player_id"))) if player != null else 0


## The simulated state, not the node: the node is where the last frame drew them, and a proximity channel resolved against a rendered position has a range a frame's walking out.
func _position_of(peer_id: int) -> Vector3:
	var player := _player_of(peer_id)
	return player.controller.state.position if player != null else Vector3.ZERO


func _player_of(peer_id: int) -> Object:
	if bridge == null or game == null:
		return null

	var session_id: int = bridge.call("player_for_peer", peer_id)

	if session_id == 0:
		return null

	return game.players.get(_player_key(session_id))


func _mod_abilities() -> Dictionary:
	var stock := {
		"noclip": func(id: StringName, args: Dictionary) -> GSResult:
			return _on_foot(id, func(p: Object) -> GSResult:
				return _modifiers("set_noclip", p.controller, bool(args["on"]))),
		"freeze": func(id: StringName, args: Dictionary) -> GSResult:
			return _on_foot(id, func(p: Object) -> GSResult:
				return _modifiers("set_frozen", p.controller, bool(args["on"]))),
		"speed": func(id: StringName, args: Dictionary) -> GSResult:
			return _on_foot(id, func(p: Object) -> GSResult:
				return _modifiers("set_speed", p.controller, float(args["scale"]))),
		"gravity": func(id: StringName, args: Dictionary) -> GSResult:
			return _on_foot(id, func(p: Object) -> GSResult:
				return _modifiers("set_gravity", p.controller, float(args["scale"]))),
		"god": func(id: StringName, args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			if p == null or p.health == null:
				return _mod_absent(id)
			p.health.invulnerable = bool(args["on"])
			return GSResult.success(p.health.invulnerable),
		"buddha": func(id: StringName, args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			if p == null or p.health == null:
				return _mod_absent(id)
			p.health.cannot_die = bool(args["on"])
			return GSResult.success(p.health.cannot_die),
		"health": func(id: StringName, args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			if p == null or p.health == null:
				return _mod_absent(id)
			if not p.health.alive:
				return GSResult.fail(GSError.CODE_STATE, "They are out until the next round.")
			p.health.health = minf(float(args["value"]), 2000.0)
			return GSResult.success(p.health.health),
		"slay": func(id: StringName, _args: Dictionary) -> GSResult:
			return _mod_hurt(id, -1.0),
		"slap": func(id: StringName, args: Dictionary) -> GSResult:
			return _mod_hurt(id, float(args.get("damage", 0.0))),
		"rename": func(id: StringName, args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			if p == null:
				return _mod_absent(id)
			p.display_name = str(args["name"]).strip_edges().substr(0, 32)
			return GSResult.success(p.display_name),
		# The screen and nothing else: a blinded player still moves and can still be hit; freeze is the verb for stopping them, and one verb that did both could not be used for only the first.
		"blind": func(id: StringName, args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			if p == null:
				return _mod_absent(id)
			p.blinded = bool(args["on"])
			return GSResult.success(p.blinded),
		"beacon": func(id: StringName, args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			if p == null:
				return _mod_absent(id)
			p.beacon = bool(args["on"])
			return GSResult.success(p.beacon),
	}
	stock.merge(_mod_extra_abilities(), true)
	return stock


func _modifiers(verb: String, controller: Object, value: Variant) -> GSResult:
	var script: GDScript = load(ADMIN_MODIFIERS)

	if script == null:
		return GSResult.fail(GSError.CODE_STATE, "This build has no player controller to %s." % verb)

	return script.call(verb, controller, value)


func _mod_can_teleport() -> bool:
	return true


func _mod_position(id: StringName) -> Variant:
	var p := _mod_player(id)
	return p.controller.state.position if p != null and _mod_movable(p) else null


func _mod_teleport(id: StringName, to: Variant) -> void:
	var p := _mod_player(id)

	if p != null and _mod_movable(p) and to is Vector3:
		p.place_at(to as Vector3, p.controller.state.yaw)


func _mod_configure_commands(commands: Object) -> void:
	commands.set("alive_fn", func(id: StringName) -> bool:
		var p := _mod_player(id)
		return p != null and p.is_alive())
	commands.set("team_fn", func(id: StringName) -> String:
		var p := _mod_player(id)
		return str(p.team) if p != null else "")


func _mod_player(id: StringName) -> Object:
	if game == null or not String(id).is_valid_int():
		return null

	return game.players.get(_player_key(String(id).to_int()))


func _mod_absent(id: StringName) -> GSResult:
	return GSResult.fail(GSError.CODE_STATE, "Player %s is not in the round." % String(id))


func _on_foot(id: StringName, act: Callable) -> GSResult:
	var p := _mod_player(id)

	if p == null:
		return _mod_absent(id)

	return act.call(p)


## A slay (amount < 0) or a slap, as ordinary damage through the combat manager, so the round hears about a slain player exactly as it hears about a shot.
## The damage carries `context.admin`, which a game's own rules can read to let an admin's damage through.
func _mod_hurt(id: StringName, amount: float) -> GSResult:
	var p := _mod_player(id)

	if p == null or p.health == null:
		return _mod_absent(id)

	if not p.health.alive:
		return GSResult.fail(GSError.CODE_STATE, "They are already out.")

	if amount < 0.0:
		var was_god: bool = p.health.invulnerable
		var was_buddha: bool = p.health.cannot_die
		p.health.invulnerable = false
		p.health.cannot_die = false
		p.health.invulnerable_until_tick = -1
		var fatal := GSDamage.make(0, p.entity_id, p.health.health + 1000.0, null)
		fatal.weapon_id = &"slay"
		fatal.context = {"admin": true}
		game.combat.apply_damage(fatal)
		p.health.invulnerable = was_god
		p.health.cannot_die = was_buddha
		return GSResult.success(null) if fatal.lethal else GSResult.fail(
			GSError.CODE_STATE, "The slay was refused: %s" % fatal.refusal
		)

	if _mod_movable(p):
		# Into the simulated velocity, which replicates, so the owning client reconciles to the shove.
		p.controller.state.velocity += Vector3(3.0, 4.0, 3.0)
		p.controller.state.mode = AIR_MODE

	if amount > 0.0:
		var hurt := GSDamage.make(0, p.entity_id, amount, null)
		hurt.weapon_id = &"slap"
		hurt.context = {"admin": true}
		game.combat.apply_damage(hurt)

	return GSResult.success(null)


## A round is everybody's new body: a noclip or a freeze from last round ends, god carries.
## A new map clears the `return` history and the same map keeps it, because a return point is a place on some map and would drop a player inside a wall (`[modtools-return-1]`).
func _on_round_began_for_tools(_number: int, layout: StringName) -> void:
	for key: StringName in game.players:
		mod_player_respawned(StringName(String(key).trim_prefix("u")))

	if layout != _tools_layout and mod_tools != null:
		mod_tools.clear_history()
	_tools_layout = layout


## The team seam gs-chat and gs-voice both ask for, which [GSGameServices] cannot wire (a lobby has no teams), and the round hook for the live tools.
func setup(p_server: GSServer, p_game: Object, p_link: Object) -> GSResult:
	var ready_now: GSResult = await super.setup(p_server, p_game, p_link)

	if not ready_now.ok:
		return ready_now

	if chat != null:
		chat.set("team_fn", Callable(self, "_team_of"))

	if voice != null:
		voice.set("team_fn", Callable(self, "_team_of"))

	if mod_tools != null:
		# Read, extended and written back: the property is a PackedStringArray, and a packed array read through `get` is a copy.
		var keep: PackedStringArray = mod_tools.get("persist_on_respawn")
		for action in _persist_on_respawn():
			if not keep.has(action):
				keep.append(action)
		mod_tools.set("persist_on_respawn", keep)

	if game.has_signal("round_began") and not game.is_connected("round_began", _on_round_began_for_tools):
		game.connect("round_began", _on_round_began_for_tools)

	GSLog.info(CHANNEL, "chat, voice and moderation are up for this game", describe())
	return ready_now
