class_name GSGameAvatarLoadoutMessage
extends GSNetMessage

## One player's equipped emotes, poses and gestures, as the server read them from the backbone:
## server to client only, so a client never claims a loadout. No entries means "forget this
## player" (they left, or play the starter set). Registered by [method GSGameAvatarActionMessage.register].

const NAME := &"game.avatar_loadout"

## Most entries one message may carry; 0 = unlimited (the site's play.avatar.maxActionsEquipped is the
## real limit, and the count is a varint). Over it, [method validate] fails; nothing is trimmed.
static var max_entries: int = 0
const MAX_ID := 32
const MAX_CLIP := 64
## Wearable slots the site has (GameSpice User Avatar's GSAvatarWearables.SLOT_BONES), one item each.
const MAX_WEARABLES := 7

## Wire order of [code]kind[/code]: emote, pose, gesture.
const KINDS: PackedStringArray = ["emote", "pose", "gesture"]

var actor: int = 0

## [code]{"id": String, "kind": int, "loop": bool, "clip": String}[/code]; clip is "" for a built-in.
var entries: Array = []

## The equipped wearables' content ids (`wearable/<id>/<version>`), in slot order. Ids only: the
## client reads slot, bone, offset, url and hash from the site library and verifies the file.
var wearables: PackedStringArray = PackedStringArray()


func _type_name() -> StringName:
	return NAME


func _write(w: GSNetWriter) -> void:
	w.write_varint(actor)
	var n := entries.size()
	w.write_varint(n)
	for i in n:
		var e: Dictionary = entries[i]
		w.write_string(String(e.get("id", "")), MAX_ID)
		w.write_uint(clampi(int(e.get("kind", 0)), 0, 2), 2)
		w.write_bool(bool(e.get("loop", false)))
		w.write_string(String(e.get("clip", "")), MAX_CLIP)
	var worn := wearables.size()
	w.write_uint(worn, 3)
	for i in worn:
		w.write_string(wearables[i], MAX_ID)


func _read(r: GSNetReader) -> void:
	actor = r.read_varint()
	var n := r.read_varint()
	entries = []
	for i in n:
		if r.exhausted:
			break
		var id := r.read_string(MAX_ID)
		var kind := r.read_uint(2)
		var loop := r.read_bool()
		var clip := r.read_string(MAX_CLIP)
		entries.append({"id": id, "kind": kind, "loop": loop, "clip": clip})
	wearables = PackedStringArray()
	for i in r.read_uint(3):
		wearables.append(r.read_string(MAX_ID))


func _validate() -> GSResult:
	if actor <= 0 or wearables.size() > MAX_WEARABLES:
		return GSResult.fail(GSError.CODE_INVALID, "avatar loadout out of range")
	if max_entries > 0 and entries.size() > max_entries:
		return GSResult.fail(GSError.CODE_QUOTA, "avatar loadout has more entries than max_entries", "%d > %d" % [entries.size(), max_entries])
	for e: Dictionary in entries:
		var id := String(e.get("id", ""))
		if id == "" or id.length() > MAX_ID or int(e.get("kind", 0)) > 2 or String(e.get("clip", "")).length() > MAX_CLIP:
			return GSResult.fail(GSError.CODE_INVALID, "avatar loadout entry out of range")
	return GSResult.success(true)


## The equipped ids, in order.
func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for e: Dictionary in entries:
		out.append(String(e["id"]))
	return out
