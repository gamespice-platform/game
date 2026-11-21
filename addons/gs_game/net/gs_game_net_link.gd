class_name GSGameNetLink
extends Node

## The five remote calls a game's own wire needs, on one node that exists on both ends. A game subclasses this and sets [member channel]; nothing else.
## Godot refuses an RPC unless both ends declare the same `@rpc` set and routes it by NODE PATH: one script on both ends, the node named the same under a same-named parent ([GSServer] and [GSClientLink], both `Server`). Place it with [GSGameLink].
## Getting it wrong is no error: a client connects, goes quiet, and is timed out for not authenticating. `@rpc` annotations are inherited, so a subclass on both ends keeps the set identical by construction.

const _Perf := preload("res://addons/gs_game/runtime/gs_game_profiler.gd")

## The ordered state channel: snapshots, events, input, requests. Kept apart from voice so fifty packets a second never sit behind a chat line.
const CHANNEL_STATE := 1
## Voice gets a channel to itself.
const CHANNEL_VOICE := 2

## The log channel, set by the subclass (for example `"ph.link"`).
var channel: String = "link"
## The game's bridge: `send_chat`, `receive_snapshot`, `receive_event`, `receive_input`, `receive_request`, `receive_voice`.
var bridge: Node = null
## Whether this end is the authority; refuses an obviously misrouted call early.
var is_server: bool = false
## Where calls go instead of onto the network: `func(method: StringName, peer_id: int, payload: PackedByteArray)`, `method` one of `snapshot`, `event`, `input`, `request` or `voice`.
## A test seam: `headless_net` puts a server and a client in one process with a lossy loopback, since a real socket never reproduces the same loss twice. Unset in every real deployment.
var loopback: Callable = Callable()

var _was_live: bool = false

var snapshots_sent: int = 0
var snapshots_received: int = 0
var events_sent: int = 0
var events_received: int = 0
var inputs_sent: int = 0
var inputs_received: int = 0
var requests_sent: int = 0
var requests_received: int = 0
var voice_sent: int = 0
var voice_received: int = 0


## Whether anything this end sends can actually go anywhere.
## Reported on its EDGES, not per call: a dead link drops silently (an error per snapshot would be thirty a second), so the transition is logged once each way at DEBUG and [method describe] counts what got through.
func _live() -> bool:
	var live := (
		true if loopback.is_valid()
		else is_inside_tree() and multiplayer != null and multiplayer.has_multiplayer_peer()
	)
	if live != _was_live:
		_was_live = live
		GSLog.debug(channel, "the link went %s" % ("live" if live else "quiet"), {
			"end": "server" if is_server else "client",
			"loopback": loopback.is_valid(),
		})
	return live


## One routed chat line, to one peer. An EVENT on this game's own wire, not gs-server's chat manager: [GSChatRouter] has the rules, and a second path would be a second rule set.
func send_chat(peer_id: int, wire: Dictionary) -> void:
	if bridge != null:
		bridge.send_chat(peer_id, wire)


## One snapshot, unreliable. [param peer_id] 0 is every peer.
func send_snapshot(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return
	snapshots_sent += 1
	_cost(&"snapshot", 1, payload)
	if loopback.is_valid():
		loopback.call(&"snapshot", peer_id, payload)
	elif peer_id == 0:
		_net_snapshot.rpc(payload)
	else:
		_net_snapshot.rpc_id(peer_id, payload)


## Anything from the authority that must arrive, reliable.
func send_event(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return
	events_sent += 1
	_cost(&"event", 1, payload)
	if loopback.is_valid():
		loopback.call(&"event", peer_id, payload)
	elif peer_id == 0:
		_net_event.rpc(payload)
	else:
		_net_event.rpc_id(peer_id, payload)


## A client's input to the server, unreliable.
func send_input(payload: PackedByteArray) -> void:
	if not _live():
		return
	inputs_sent += 1
	_cost(&"input", 1, payload)
	if loopback.is_valid():
		loopback.call(&"input", 1, payload)
	else:
		_net_client_input.rpc_id(1, payload)


## One encoded voice packet, in whichever direction this end is. [param peer_id] is the recipient on a server and ignored on a client. Zero is not "everybody": the router names its listeners one at a time.
func send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return
	voice_sent += 1
	_cost(&"voice", 1, payload)
	if loopback.is_valid():
		loopback.call(&"voice", peer_id if is_server else 1, payload)
	elif is_server:
		# The voice router knows a peer from signon, before its client has built this node: a bridge may hold voice back with is_peer_ready.
		if peer_id > 0 and (bridge == null or not bridge.has_method(&"is_peer_ready") or bridge.call(&"is_peer_ready", peer_id)):
			_net_voice.rpc_id(peer_id, payload)
	else:
		_net_voice.rpc_id(1, payload)


## A client's request to the server, reliable.
func send_request(payload: PackedByteArray) -> void:
	if not _live():
		return
	requests_sent += 1
	_cost(&"request", 1, payload)
	if loopback.is_valid():
		loopback.call(&"request", 1, payload)
	else:
		_net_request.rpc_id(1, payload)


@rpc("authority", "unreliable", "call_remote", CHANNEL_STATE)
func _net_snapshot(payload: PackedByteArray) -> void:
	snapshots_received += 1
	_cost(&"snapshot", 0, payload)
	if bridge != null:
		bridge.receive_snapshot(payload)


@rpc("authority", "reliable", "call_remote", CHANNEL_STATE)
func _net_event(payload: PackedByteArray) -> void:
	events_received += 1
	_cost(&"event", 0, payload)
	if bridge != null:
		bridge.receive_event(payload)


@rpc("any_peer", "unreliable", "call_remote", CHANNEL_STATE)
func _net_client_input(payload: PackedByteArray) -> void:
	inputs_received += 1
	_cost(&"input", 0, payload)
	if bridge != null:
		# The sender comes from the transport, never from inside the payload.
		bridge.receive_input(multiplayer.get_remote_sender_id(), payload)


@rpc("any_peer", "reliable", "call_remote", CHANNEL_STATE)
func _net_request(payload: PackedByteArray) -> void:
	requests_received += 1
	_cost(&"request", 0, payload)
	if bridge != null:
		bridge.receive_request(multiplayer.get_remote_sender_id(), payload)


@rpc("any_peer", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice(payload: PackedByteArray) -> void:
	voice_received += 1
	_cost(&"voice", 0, payload)
	if bridge != null:
		bridge.receive_voice(multiplayer.get_remote_sender_id(), payload)


## What the other end's [member loopback] calls; it goes through the same counters and bridge entry points as the RPCs, so a test exercises the real path minus the socket.
func deliver(method: StringName, from_peer_id: int, payload: PackedByteArray) -> void:
	if bridge == null:
		return
	match method:
		&"snapshot":
			snapshots_received += 1
			_cost(&"snapshot", 0, payload)
			bridge.receive_snapshot(payload)
		&"event":
			events_received += 1
			_cost(&"event", 0, payload)
			bridge.receive_event(payload)
		&"input":
			inputs_received += 1
			_cost(&"input", 0, payload)
			bridge.receive_input(from_peer_id, payload)
		&"request":
			requests_received += 1
			_cost(&"request", 0, payload)
			bridge.receive_request(from_peer_id, payload)
		&"voice":
			voice_received += 1
			_cost(&"voice", 0, payload)
			bridge.receive_voice(from_peer_id, payload)


## What this end has done, for a test or a console.
func describe() -> Dictionary:
	return {
		"server": is_server,
		"snapshots": [snapshots_sent, snapshots_received],
		"events": [events_sent, events_received],
		"inputs": [inputs_sent, inputs_received],
		"requests": [requests_sent, requests_received],
		"voice": [voice_sent, voice_received],
	}


## [method describe] as lines.
func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"link       %s" % ("server" if is_server else "client"),
		"snapshots  %d sent, %d received" % [snapshots_sent, snapshots_received],
		"events     %d sent, %d received" % [events_sent, events_received],
		"inputs     %d sent, %d received" % [inputs_sent, inputs_received],
		"requests   %d sent, %d received" % [requests_sent, requests_received],
		"voice      %d sent, %d received" % [voice_sent, voice_received],
	])


## Counts the message in the perf report's network table (`0` in, `1` out).
func _cost(kind: StringName, sent: int, payload: PackedByteArray) -> void:
	_Perf.net_cost(kind, sent, payload.size())
