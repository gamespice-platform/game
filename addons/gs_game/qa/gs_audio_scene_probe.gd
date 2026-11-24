class_name GSAudioSceneProbe
extends SceneTree

## The SceneTree-style twin of GSAudioProbe: run as `xvfb-run -a godot --path . --script tools/audio_probe.gd` (never `--headless`, whose audio driver is Dummy). Does the game make a noise? Builds the game's audio the way a client does, plays each cue two metres to the side through the MANAGER (limits, culling and mixer are what a stand-in must survive), and asks the sink `is_playing`, not "did I get a handle": a handle says the pool had room, only is_playing says a speaker is moving.
## Waits SETTLE frames before building anything: during `_initialize` the root viewport is not live, and an AudioStreamPlayer under it refuses to play. Exit code 0 all sounded, 1 something silent, 2 no audio device. Tool-only (a pack never calls it, so no API level).
## A game's tools/audio_probe.gd extends this and overrides `_make_node`, `_probe_ids` and, if it needs them, the other hooks. Duck-typed: the node needs `setup()` returning something with `ok`/`error`; the object `_audio_of` returns needs `sink`, `catalogue` and `play_at(id, pos)`; the sink `bank`, `is_playing(handle)` and `sink_name()`.

## Frames to let the tree come up before asking anything.
const SETTLE := 2

var _failed := 0


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
	report("driver:  %s" % AudioServer.get_driver_name())
	_run()


## Where a line goes.
func report(line: String) -> void:
	print(line)


func _run() -> void:
	for _i in SETTLE:
		await process_frame
	if AudioServer.get_driver_name() == "Dummy":
		report("\nNo audio device. Run this through tools/audio_probe.sh, which uses xvfb-run;")
		report("--headless gives a Dummy driver and this probe cannot say anything.")
		quit(2)
		return
	var node := _make_node()
	node.name = "AudioProbe"
	root.add_child(node)
	var ready_now: Variant = node.call("setup")
	if not bool(ready_now.get("ok")):
		report("the audio did not set up: %s" % ready_now.get("error").get("message"))
		quit(1)
		return
	var audio := _audio_of(node)
	var sink: Object = audio.get("sink")
	report("sink:    %s" % audio.get("sink").sink_name())
	if sink == null or not (sink.get("bank") is Dictionary):
		report("\nThe device is present and the manager still built a null sink.")
		quit(1)
		return
	var catalogue: Object = audio.get("catalogue")
	report("bank:    %d entries over %d ids" % [(sink.get("bank") as Dictionary).size(), catalogue.ids().size()])
	report("files:   %d of the catalogue's paths do not exist\n" % catalogue.missing_files().size())
	# A voice needs a moment to start before is_playing means anything.
	await process_frame
	var code := await _sound(audio, sink)
	if _free_before_quit():
		audio.call("stop_all")
		root.remove_child(node)
		node.free()
		for _i in 10:
			await process_frame
	quit(code)


## Plays every probe id; returns the exit code.
func _sound(audio: Object, sink: Object) -> int:
	var ids := _probe_ids()
	for id in ids:
		var handle: int = audio.call("play_at", id, _cue_position())
		var sounding: bool = handle != 0 and bool(sink.call("is_playing", handle))
		report("  %-*s %s" % [_id_width(), String(id), "sounding" if sounding else "SILENT"])
		if not sounding:
			_failed += 1
	if _failed > 0:
		report("\nRESULT: %d of %d made no sound." % [_failed, ids.size()])
		return 1
	report("\nRESULT: all %d sounded, from %d synthesised stand-ins." % [ids.size(), (sink.get("bank") as Dictionary).size()])
	return 0
