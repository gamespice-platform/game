extends Node

## GSGameMapEditBundle with and without GameSpice Map's GSMapDataBundle in the project: the dictionary fallback always, and the native class when its script is present.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _expected := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _run() -> void:
	var native := GSGameMapEditBundle.native()
	var map := {"game": "tg", "id": "dm_box", "version": "3", "digest": "abc"}
	var sections := {"spawns": {"version": 1, "points": []}, "nav_links": {"links": {}}}
	var made: Variant = GSGameMapEditBundle.make("tg", map, "admin#7", sections, "note")
	var d := GSGameMapEditBundle.as_dict(made)
	print("dot-game: map edit bundle (native dot-map bundle: %s)" % (native != null))
	_expected = 13 + (6 if native != null else 0)
	_check((made is Dictionary) == (native == null), "a dictionary without dot-map, the class with it")
	_check(d["format"] == "dot-map-data" and d["map"]["id"] == "dm_box" and d["map"]["version"] == "3", "the file shape is the plan's")
	_check(d["meta"]["author"] == "admin#7" and d["meta"]["note"] == "note" and d["sections"].has("spawns"), "author, note and sections")
	var text := JSON.stringify(d)
	var ok := GSGameMapEditBundle.check(text, map)
	_check(ok.ok and ok.value["warnings"].is_empty() and ok.value["bundle"]["sections"].has("nav_links"), "an own export checks clean")
	var other := GSGameMapEditBundle.check(text, {"id": "dm_other", "version": "3"})
	_check(not other.ok and other.error.code == GSError.CODE_CONFLICT, "another map's bundle is refused")
	var newer := GSGameMapEditBundle.check(text, {"id": "dm_box", "version": "4", "digest": "zzz"})
	_check(newer.ok and newer.value["warnings"].size() == 2, "a different version and digest are warnings")
	_check(not GSGameMapEditBundle.check("not json", map).ok, "text that is not JSON is refused")
	var future: Dictionary = JSON.parse_string(text)
	future["schema"] = 99
	_check(not GSGameMapEditBundle.check(JSON.stringify(future), map).ok, "a newer schema is refused")
	var extra: Dictionary = JSON.parse_string(text)
	extra["sections"]["evil"] = {"note": "x"}
	var kept := GSGameMapEditBundle.check(JSON.stringify(extra), map)
	_check(kept.ok and not kept.value["bundle"]["sections"].has("evil"), "an unknown section is dropped")
	var deep: Variant = "x"

	for i in 20:
		deep = {"k": deep}

	var nested: Dictionary = JSON.parse_string(text)
	nested["sections"]["spawns"] = {"deep": deep}
	_check(not GSGameMapEditBundle.check(JSON.stringify(nested), map).ok, "nesting past the cap is refused")
	var long: Dictionary = JSON.parse_string(text)
	long["sections"]["cull"] = {"s": "a".repeat(5000)}
	_check(not GSGameMapEditBundle.check(JSON.stringify(long), map).ok, "a long string is refused")
	_check(GSGameMapEditBundle.as_dict(5).is_empty() and GSGameMapEditBundle.as_dict(null).is_empty(), "as_dict of something else is empty")
	var back := GSGameMapEditBundle.check(JSON.stringify(ok.value["bundle"]), map)
	_check(back.ok, "a checked bundle checks again")

	if native != null:
		var obj: Object = made
		_check(obj.get("map_id") == "dm_box" and obj.get("game") == "tg" and obj.get("meta")["author"] == "admin#7", "the class carries the map and meta")
		var json: GSResult = obj.call("to_json")
		_check(json.ok, "the class writes its own JSON")
		var bad := GSGameMapEditBundle.check(JSON.stringify({"format": "dot-map-data", "schema": 1, "game": "../x", "map": {"id": "dm_box", "version": "3"}, "sections": {}}), map)
		_check(not bad.ok, "dot-map's id rules apply to an import")
		var loadable: Dictionary = JSON.parse_string(text)
		loadable["sections"]["cull"] = {"script": "res://addons/x.gd"}
		_check(not GSGameMapEditBundle.check(JSON.stringify(loadable), map).ok, "dot-map refuses a loadable resource path")
		_check(ok.value["bundle"] is Dictionary, "the checked bundle is handed on as a dictionary")
		_check(GSGameMapEditBundle.as_dict(obj)["map"]["digest"] == "abc", "as_dict reads the class")

	print("map edit bundle: %d passed, %d failed (expected %d checks)" % [_passed, _failed, _expected])

	for f in _failures:
		print("  FAIL: ", f)

	get_tree().quit(0 if _failed == 0 and _passed == _expected else 1)
