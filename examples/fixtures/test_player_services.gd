extends GSPlayerGameServices

## [GSPlayerGameServices] with one extra ability and a body that can be switched immovable, for the suite's player-services section.

## What [method _mod_movable] answers.
var movable := false


func _mod_movable(_p: Object) -> bool:
	return movable


func _mod_extra_abilities() -> Dictionary:
	return {"respawn": func(_id: StringName, _args: Dictionary) -> GSResult: return GSResult.success(null)}


class FakeState extends RefCounted:
	var position := Vector3(1.0, 2.0, 3.0)
	var yaw := 0.0


class FakeController extends RefCounted:
	var state := FakeState.new()


class FakePlayer extends RefCounted:
	var controller := FakeController.new()
	var display_name := "Ada"
	var blinded := false
	var beacon := false


class FakeGame extends Node:
	var players: Dictionary = {}
