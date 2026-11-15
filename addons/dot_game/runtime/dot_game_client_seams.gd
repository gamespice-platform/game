extends Node

## [DotGameClient]'s stateless half: the store and avatar-read entry points and the two pointer seams, none of which touch client state. Not used on its own.


# Two seams: a headless display server keeps no captured mode, so the suite overrides these.
func _pointer_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _free_pointer() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Adds the site-store page (what the player owns, and a button to the store) to the game's dot-menu. [param player_key_fn] returns the signed-in player's key; empty shows an empty list. Call after the menu is built.
func add_store_panel(game_menu: Object, player_key_fn: Callable) -> Object:
	return DotGameStorePanel.add_to_menu(game_menu, player_key_fn)


## Shows the items the player does not own in the loadout menu, greyed with a "Get in store" button, solo and connected. [param loadout_menu] is what dot-menu's `use_loadout` returned; [param command_fn] returns the game's dot-loadout command (null until the match exists); [param key_fn] the player's storage key. Call right after `use_loadout`.
func add_loadout_store(loadout_menu: Object, command_fn: Callable, key_fn: Callable) -> bool:
	return DotGameStoreEntitlements.wire_menu(loadout_menu, command_fn, key_fn)


## The signed-in member's equipped actions from the avatar read, for [method add_avatar_actions]. Null (starters) when none.
func read_avatar_actions(http: DotHttp, user_key: String, headers: Dictionary = {}) -> DotResult:
	return await DotGameClientAvatars.read_actions(http, user_key, headers)
