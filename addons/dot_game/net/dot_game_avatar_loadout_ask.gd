class_name GSGameAvatarLoadoutAsk
extends GSNetMessage

## A client asking the server for every player's loadout, sent once its handler is attached: the
## loadouts told at its join land before a game that wires avatar actions late is listening.
## Client to server only; the server answers at most once per [constant GSGameAvatarLoadouts.ASK_MIN_SEC].

const NAME := &"game.avatar_loadout_ask"


func _type_name() -> StringName:
	return NAME


func _write(_w: GSNetWriter) -> void:
	pass


func _read(_r: GSNetReader) -> void:
	pass
