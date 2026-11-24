class_name GSAudioSceneProbe
extends SceneTree

## The SceneTree-style twin of GSAudioProbe: run as `xvfb-run -a godot --path . --script tools/audio_probe.gd` (never `--headless`, whose audio driver is Dummy). Does the game make a noise? Builds the game's audio the way a client does, plays each cue two metres to the side through the MANAGER (limits, culling and mixer are what a stand-in must survive), and asks the sink `is_playing`, not "did I get a handle": a handle says the pool had room, only is_playing says a speaker is moving.
## Runs in `_process`, not `_initialize`: during `_initialize` the root viewport is not live, and an AudioStreamPlayer under it refuses to play. Exit code 0 all sounded, 1 something silent, 2 no audio device. Tool-only (a pack never calls it, so no API level).
## A game's tools/audio_probe.gd extends this and overrides `_make_node`, `_probe_ids` and, if it needs them, the other hooks. Duck-typed: the node needs `setup()` returning something with `ok`/`error`; the object `_audio_of` returns needs `sink`, `catalogue` and `play_at(id, pos)`; the sink `bank`, `is_playing(handle)` and `sink_name()`.

## Frames to let the tree come up before asking anything.
const SETTLE := 2

var _node: Node = null
var _frame := 0
var _failed := 0
var _code := -1
var _draining := 0


## Build the game's audio-owning node (not yet in the tree).
func _make_node() -> Node:
	return null


## The cue ids to play, one of each kind the game makes.
func _probe_ids() -> Array[StringName]:
	return []


## The object that owns `sink`, `catalogue` and `play_at`. Default: the node itself.
func _audio_of(node: Node) -> Object:
	return node


## Before anything: point the game's settings at a scratch directory, set the log level.
func _prepare() -> void:
	pass


## Where each cue is played, relative to the listener.
func _cue_position() -> Vector3:
	return Vector3(2.0, 0.0, 0.0)


## Width of the id column in the report.
func _id_width() -> int:
	return 16


## True to stop the voices, free the node and let the mixer drain before quitting, so the exit reports no leaked streams.
func _free_before_quit() -> bool:
	return false


func _initialize() -> void:
	_prepare()
	print("driver:  %s" % AudioServer.get_driver_name())


func _process(_delta: float) -> bool:
	_frame += 1
	if _code >= 0:
		return _drain()
	if _frame < SETTLE:
		return false
	if not GSAudioSink.device_present():
		print("")
		print("No audio device. Run this through tools/audio_probe.sh, which uses xvfb-run;")
		print("--headless gives a Dummy driver and this probe cannot say anything.")
		quit(2)
		return true
	if _node == null:
		return _build()
	return _sound()


func _build() -> bool:
	var node := _make_node()
	node.name = "AudioProbe"
	root.add_child(node)
	var ready_now: Variant = node.call("setup")
	if not bool(ready_now.get("ok")):
		print("the audio did not set up: %s" % ready_now.get("error").get("message"))
		quit(1)
		return true
	_node = node
	var audio := _audio_of(node)
	var sink := audio.get("sink") as GSAudioSinkGodot
	print("sink:    %s" % audio.get("sink").sink_name())
	if sink == null:
		print("")
		print("The device is present and the manager still built a null sink.")
		quit(1)
		return true
	var catalogue: Object = audio.get("catalogue")
	print("bank:    %d entries over %d ids" % [sink.bank.size(), catalogue.ids().size()])
	print("files:   %d of the catalogue's paths do not exist" % catalogue.missing_files().size())
	print("")
	# Not the next frame: a voice needs a moment to start before is_playing means anything.
	return false


func _sound() -> bool:
	var audio := _audio_of(_node)
	var sink := audio.get("sink") as GSAudioSinkGodot
	var ids := _probe_ids()
	for id in ids:
		var handle: int = audio.call("play_at", id, _cue_position())
		var sounding: bool = handle != 0 and sink.is_playing(handle)
		print("  %-*s %s" % [_id_width(), String(id), "sounding" if sounding else "SILENT"])
		if not sounding:
			_failed += 1
	print("")
	if _failed > 0:
		print("RESULT: %d of %d made no sound." % [_failed, ids.size()])
		_code = 1
	else:
		print("RESULT: all %d sounded, from %d synthesised stand-ins." % [ids.size(), sink.bank.size()])
		_code = 0
	if not _free_before_quit():
		quit(_code)
		return true
	audio.call("stop_all")
	root.remove_child(_node)
	_node.free()
	_node = null
	_draining = 10
	return false


func _drain() -> bool:
	_draining -= 1
	if _draining > 0:
		return false
	quit(_code)
	return true
