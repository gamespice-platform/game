extends "selftest_base.gd"

## The avatar sections of game_selftest.gd: actions, loadouts, prejoin, content.

func _test_avatar_actions() -> void:
	_section("avatar actions: checked on the server, then told to everybody")
	var loaded: GSResult = await _load_module()
	if _check(loaded.ok, "the module loads", str(loaded.error)):
		var module := loaded.value as GSGameModule
		var relay := module.net.get_meta(GSGameAvatarActionRelay.NET_META, null) as GSGameAvatarActionRelay
		if _check(relay != null, "the netcode serves the relay"):
			var clock := [10000]
			relay.now_fn = func() -> int: return clock[0]
			var sent := []
			module.net.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: sent.append([peer, payload])
			var ask := func(peer: int, id: String) -> void:
				var m := GSGameAvatarActionMessage.new()
				m.sender_peer_id = peer
				m.id = id
				m.loop = true
				module.net.messages.dispatch(m)
			ask.call(7, "wave")
			_check(sent.size() == 1 and sent[0][0] == 0, "a starter action is sent to everyone")
			var back := GSGameAvatarActionMessage.new()
			var read := module.net.messages.decode(GSNetReader.new(sent[0][1]), 1, false) if not sent.is_empty() else null
			_check(read != null and read.ok and read.value is GSGameAvatarActionMessage and read.value.actor == 7 and read.value.id == "wave",
				"naming who and what")
			_check(read != null and read.ok and read.value.loop == false, "a built-in's loop is its own, not the client's (asked true)")
			clock[0] += 1000
			var asked_loop := func(peer: int, id: String, loop: bool) -> void:
				var m := GSGameAvatarActionMessage.new()
				m.sender_peer_id = peer
				m.id = id
				m.loop = loop
				module.net.messages.dispatch(m)
			asked_loop.call(7, "dance", false)
			var dance := module.net.messages.decode(GSNetReader.new(sent[1][1]), 1, false) if sent.size() == 2 else null
			_check(dance != null and dance.ok and dance.value.loop == true, "a looping built-in loops though the client asked not to")
			sent.resize(1)
			clock[0] += 1000
			TestModule.avatar_veto = ["bow"]
			ask.call(7, "bow")
			TestModule.avatar_veto = []
			_check(sent.size() == 1, "the module's own _avatar_action_veto override stops it")
			var game_hook := Node.new()
			game_hook.set_script(_veto_game_script())
			var kept_game: Object = module.game
			module.game = game_hook
			ask.call(7, "bow")
			module.game = kept_game
			game_hook.free()
			_check(sent.size() == 1, "and so does the game object's, when the module does not override it")
			ask.call(7, "bow")
			_check(sent.size() == 2, "with neither, it plays")
			sent.resize(1)
			ask.call(7, "dance")
			_check(sent.size() == 1, "a second one inside the interval is dropped")
			clock[0] += 1000
			ask.call(7, "not_an_action")
			_check(sent.size() == 1, "an id that is not equipped is dropped")
			relay.equipped_fn = func(_p: int) -> Variant: return ["custom_clip"]
			ask.call(7, "custom_clip")
			_check(sent.size() == 2, "an equipped uploaded id passes")
			clock[0] += 1000
			relay.veto_fn = func(_p: int, _i: String) -> bool: return true
			ask.call(7, "custom_clip")
			_check(sent.size() == 2, "the game's veto stops it")
			relay.veto_fn = Callable()
			ask.call(0, "custom_clip")
			_check(sent.size() == 2, "a request with no peer is dropped")
			_check(GSGameAvatarActionRelay.STARTER_IDS.size() == 13, "thirteen starter ids")
			_unload_module()
	_done()


func _veto_game_script() -> GDScript:
	var g := GDScript.new()
	g.source_code = "extends Node\nfunc _avatar_action_veto(_p: int, id: String) -> bool:\n\treturn id == \"bow\"\n"
	var _r := g.reload()
	return g


class FakeActionInput extends Node:
	signal action_requested(entry: Dictionary)
	var enabled := true
	var actions: Object = RefCounted.new()


class FakeSkeletonFigure extends RefCounted:
	var bones := Skeleton3D.new()

	func skeleton() -> Skeleton3D:
		return bones


class FakeActionFigure extends RefCounted:
	var clips := {}
	var played: Array = []
	var added: Array = []

	func play_action(id: StringName, loop: bool = false, elapsed: float = 0.0) -> bool:
		if String(id).contains("/") and not clips.has(id):
			return false
		played.append([String(id), loop, elapsed])
		return true

	func add_action_scene(id: StringName, scene: Node, clip: String, loop: bool) -> GSResult:
		added.append([String(id), scene, clip, loop])
		clips[id] = true
		return GSResult.success(true)


func _loadout_sent(module: GSGameModule, sent: Array) -> Array:
	var out := []
	for s: Array in sent:
		var read := module.net.messages.decode(GSNetReader.new(s[1]), 1, false)
		if read.ok and read.value is GSGameAvatarLoadoutMessage:
			out.append([s[0], read.value])
	return out


const UPLOAD := {"contentId": "action/9/1", "clip": "Hop", "loop": false, "fileUrl": "https://cdn.test/a.glb"}


func _test_avatar_loadouts() -> void:
	_section("avatar loadouts: read by the server, checked, bounded, told to everybody and to a late joiner")
	_loadouts_parse()

	var loaded: GSResult = await _load_module()
	if not _check(loaded.ok, "the module loads", str(loaded.error)):
		_done()
		return
	var module := loaded.value as GSGameModule
	var relay := module.net.get_meta(GSGameAvatarActionRelay.NET_META, null) as GSGameAvatarActionRelay
	var lo: GSGameAvatarLoadouts = relay.loadouts if relay != null else null
	if not _check(lo != null and module.roster.followers.has(lo) and lo.server == module.server, "the relay's loadouts follow the roster"):
		_unload_module()
		_done()
		return
	var clock := [100000]
	relay.now_fn = func() -> int: return clock[0]
	lo.now_fn = func() -> int: return clock[0]
	var sent := []
	module.net.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: sent.append([peer, payload])
	var asked := []
	lo.key_fn = func(peer: int) -> String: return "key-of-peer-%d" % peer if peer != 6 else ""
	lo.fetch_fn = func(key: String) -> GSResult:
		asked.append(key)
		await get_tree().process_frame
		return GSResult.success({"EMOTE": [UPLOAD], "GESTURE": [{"builtin": "wave"}]})
	var ask := func(peer: int, id: String) -> int:
		var before := sent.size()
		var m := GSGameAvatarActionMessage.new()
		m.sender_peer_id = peer
		m.id = id
		m.loop = true
		module.net.messages.dispatch(m)
		clock[0] += 1000
		return sent.size() - before

	lo.add_peer(6)
	lo.add_peer(5)
	for i in 4:
		await get_tree().process_frame
	_check(asked == ["key-of-peer-5"], "only a peer with a key is read from the backbone", str(asked))
	var told := _loadout_sent(module, sent)
	_check(told.size() == 2 and told[0][1].actor == 5 and told[0][1].ids().has("action/9/1"), "the read loadout is told to every player in", str(told.size()))
	sent.clear()
	_check(ask.call(5, "action/9/1") == 1, "an equipped upload passes")
	var start := module.net.messages.decode(GSNetReader.new(sent[0][1]), 1, false) if not sent.is_empty() else null
	_check(start != null and start.ok and start.value.loop == false, "with the loop the loadout says, not the client's")
	_check(ask.call(5, "dance") == 0, "a starter emote they replaced is refused")
	_check(ask.call(5, "action/8/1") == 0, "an upload they have not equipped is refused")
	_check(ask.call(6, "dance") == 1 and ask.call(6, "action/9/1") == 0, "a player with no key plays the starter set, and nothing else")

	sent.clear()
	lo.add_peer(8)
	for i in 4:
		await get_tree().process_frame
	told = _loadout_sent(module, sent)
	var late := told.filter(func(t: Array) -> bool: return t[0] == 8 and t[1].actor == 5)
	_check(late.size() == 1, "a late joiner is told the loadouts already read", str(told.size()))

	await _loadouts_ask(module, lo, sent, clock)
	await _loadouts_reequip(module, lo, sent, clock)
	await _loadouts_leave(module, lo, sent)
	_unload_module()
	_done()


func _loadouts_parse() -> void:
	var parsed: Variant = GSGameAvatarLoadouts.parse({"EMOTE": [UPLOAD, UPLOAD, {"builtin": "wave"}, {"builtin": "nope"}],
		"POSE": [{"contentId": "avatar/3/1", "clip": "X"}, {"contentId": "action/4/1", "clip": ""}],
		"GESTURE": [{"builtin": "wave"}]})
	var ids := []
	for e: Dictionary in (parsed if parsed is Array else []):
		ids.append(e["id"])
	_check(ids == ["action/9/1", "wave"], "parse keeps an upload once and a built-in only of its own kind; a kind the site answered is not topped up with starters", str(ids))
	var many := []
	for i in 30:
		many.append({"contentId": "action/%d/1" % (i + 1), "clip": "c"})
	var capped: Variant = GSGameAvatarLoadouts.parse({"EMOTE": many})
	_check(capped is Array and (capped as Array).size() == 30 + 4 + 5, "no cap by default: 30 emotes, the absent kinds get starters", str((capped as Array).size() if capped is Array else capped))
	GSGameAvatarLoadouts.max_per_kind = 8
	_check(GSGameAvatarLoadouts.parse({"EMOTE": many}) == null, "over max_per_kind the read is refused, not trimmed")
	GSGameAvatarLoadouts.max_per_kind = 0
	var switched_off: Variant = GSGameAvatarLoadouts.parse({"EMOTE": [], "POSE": [{"builtin": "sit"}], "GESTURE": []})
	_check(switched_off is Array and (switched_off as Array).size() == 1, "a kind the site answered empty stays empty (switched off)")
	_check(GSGameAvatarLoadouts.parse("junk") == null and GSGameAvatarLoadouts.parse(null) == null, "anything but an object is no loadout")
	var big := GSGameAvatarLoadoutMessage.new()
	big.actor = 3
	for i in 40:
		big.entries.append({"id": "wave", "kind": 2, "loop": false, "clip": ""})
	_check(big.validate().ok, "no cap by default")
	var w := GSNetWriter.new()
	big._write(w)
	var back := GSGameAvatarLoadoutMessage.new()
	back._read(GSNetReader.new(w.to_bytes()))
	_check(back.entries.size() == 40, "40 entries round-trip on the wire", str(back.entries.size()))
	GSGameAvatarLoadoutMessage.max_entries = 24
	_check(big.validate().error.code == GSError.CODE_QUOTA, "over max_entries is refused loudly")
	GSGameAvatarLoadoutMessage.max_entries = 0


func _loadouts_ask(module: GSGameModule, lo: GSGameAvatarLoadouts, sent: Array, clock: Array) -> void:
	# A client that wired its handler after that message asks, and is told again.
	var ask_from := func(peer: int) -> int:
		var before := sent.size()
		var q := GSGameAvatarLoadoutAsk.new()
		q.sender_peer_id = peer
		module.net.messages.dispatch(q)
		return _loadout_sent(module, sent.slice(before)).filter(func(t: Array) -> bool: return t[0] == peer and t[1].actor == 5).size()
	sent.clear()
	_check(ask_from.call(8) == 1, "a client's ask is answered with the loadouts already read")
	_check(ask_from.call(8) == 0, "a second ask inside the interval is not")
	clock[0] += 2500
	_check(ask_from.call(8) == 1 and ask_from.call(77) == 0, "again after it, and never to a peer not in the game")

	_check(not lo.refresh(5), "a second read inside the interval is refused")
	clock[0] += 31000
	_check(lo.refresh(5), "and allowed after it")
	for i in 4:
		await get_tree().process_frame



func _loadouts_reequip(module: GSGameModule, lo: GSGameAvatarLoadouts, sent: Array, clock: Array) -> void:
	# A re-equip on the site reaches the game by itself, and only a change is told.
	var current := {"EMOTE": [{"builtin": "dance"}]}
	lo.fetch_fn = func(_key: String) -> GSResult:
		await get_tree().process_frame
		return GSResult.success(current)
	lo.auto_refresh_sec = 60.0
	clock[0] += 31000
	sent.clear()
	lo._process(30.0)
	for i in 4:
		await get_tree().process_frame
	_check(lo.reads > 0 and sent.is_empty() and lo.ids_for(5).has("action/9/1"), "the periodic read waits for its interval", str(lo.ids_for(5)))
	lo._process(31.0)
	for i in 4:
		await get_tree().process_frame
	_check(lo.ids_for(5).has("dance") and not lo.ids_for(5).has("action/9/1") and not _loadout_sent(module, sent).is_empty(), "a player who re-equips is read again and told", str(lo.ids_for(5)))
	clock[0] += 31000
	sent.clear()
	lo._process(61.0)
	for i in 4:
		await get_tree().process_frame
	_check(_loadout_sent(module, sent).is_empty(), "a re-read that changed nothing tells nobody")
	lo.auto_refresh_sec = 0.0



func _loadouts_leave(module: GSGameModule, lo: GSGameAvatarLoadouts, sent: Array) -> void:
	sent.clear()
	lo.remove_peer(5)
	var told := _loadout_sent(module, sent)
	_check(lo.ids_for(5) == null and told.size() == 2 and told[0][1].actor == 5 and told[0][1].entries.is_empty(), "a leaver is forgotten, and everybody told")

	lo.add_peer(9)
	lo.remove_peer(9)
	lo.add_peer(9)
	lo.fetch_fn = func(_key: String) -> GSResult:
		await get_tree().process_frame
		return GSResult.success({"EMOTE": [UPLOAD]})
	for i in 6:
		await get_tree().process_frame
	_check(lo.ids_for(9) != null, "a peer id that rejoins is read again")
	lo.add_peer(10)
	lo.remove_peer(10)
	for i in 6:
		await get_tree().process_frame
	_check(lo.ids_for(10) == null, "a read that lands after its player left is dropped")

	var forged := GSGameAvatarLoadoutMessage.new()
	forged.actor = 6
	forged.entries = [{"id": "action/77/1", "kind": 0, "loop": false, "clip": "c"}]
	var w := GSNetWriter.new()
	var _enc := module.net.messages.encode(forged, w)
	var from_client := module.net.messages.decode(GSNetReader.new(w.to_bytes()), 6, true)
	_check(not from_client.ok and lo.ids_for(6) == null, "a client cannot send a loadout")
	_check(lo.describe().has("reads"), "describe() reports it")


func _test_avatar_loadout_client() -> void:
	_section("avatar loadouts on a client: an uploaded clip is fetched once and handed to the figure")
	var server_net := _loadout_net(true)
	var net := _loadout_net(false, 4)
	_check(net.messages.type_names().has(String(GSGameAvatarLoadoutMessage.NAME)), "registering the action message registers the loadout too")
	add_child(net)
	var input := FakeActionInput.new()
	add_child(input)
	var figures := {7: FakeActionFigure.new()}
	var client := GSGameAvatarActionClient.new()
	add_child(client)
	var asks := []
	net.send_fn = func(_peer: int, payload: PackedByteArray, _d: int) -> void:
		var r := server_net.messages.decode(GSNetReader.new(payload), 4, true)
		if r.ok and r.value is GSGameAvatarLoadoutAsk:
			asks.append(true)
	var fetched := []
	client.content_fn = func(entry: Dictionary) -> GSResult:
		fetched.append(entry["id"])
		await get_tree().process_frame
		return GSResult.success(Node3D.new())
	client.attach(net, input, func(peer: int) -> Object: return figures.get(peer))
	var deliver := func(m: GSNetMessage) -> void:
		var w := GSNetWriter.new()
		var _e := server_net.messages.encode(m, w)
		var read := net.messages.decode(GSNetReader.new(w.to_bytes()), 1, false)
		if read.ok:
			net.messages.dispatch(read.value)
	var lm := GSGameAvatarLoadoutMessage.new()
	lm.actor = 7
	lm.entries = [{"id": "action/9/1", "kind": 0, "loop": true, "clip": "Hop"}, {"id": "wave", "kind": 2, "loop": false, "clip": ""}]
	_check(asks.size() == 1, "attaching asks the server for the loadouts it may have missed", str(asks.size()))
	client._process(1.1)
	_check(asks.size() == 2, "and asks again while none has come")
	deliver.call(lm)
	deliver.call(lm)
	client._process(10.0)
	_check(asks.size() == 2, "and stops once one arrives")
	var blocked := [true]
	client.blocked_fn = func() -> bool: return blocked[0]
	client._process(0.01)
	var off := not input.enabled
	blocked[0] = false
	client._process(0.01)
	var on := input.enabled
	input.enabled = false
	client._process(0.01)
	var kept := not input.enabled
	blocked[0] = true
	client._process(0.01)
	blocked[0] = false
	client._process(0.01)
	_check(off and on and kept and input.enabled, "the input follows blocked_fn, written only when it changes")
	client.blocked_fn = Callable()
	for i in 3:
		await get_tree().process_frame
	_check(fetched == ["action/9/1"], "the upload is fetched once, the built-in not at all", str(fetched))
	var start := GSGameAvatarActionMessage.new()
	start.actor = 7
	start.id = "action/9/1"
	start.loop = true
	start.start_tick = 0
	deliver.call(start)
	var fig: FakeActionFigure = figures[7]
	_check(fig.added.size() == 1 and fig.added[0][2] == "Hop" and fig.played.size() == 1 and fig.played[0][0] == "action/9/1", "another player's upload plays on their figure", str(fig.added))
	lm.entries = []
	deliver.call(lm)
	_check(not client.loadouts.has(7), "an empty loadout forgets them")
	var seen_rows := []
	client.actions_fn = func(rows: Dictionary) -> GSResult:
		seen_rows.append(rows)
		return GSResult.success("actions")
	var own := GSGameAvatarLoadoutMessage.new()
	own.actor = 4
	own.entries = [{"id": "action/9/1", "kind": 0, "loop": true, "clip": "Hop"}, {"id": "wave", "kind": 2, "loop": false, "clip": ""}]
	deliver.call(own)
	_check(seen_rows.size() == 1 and seen_rows[0]["EMOTE"][0]["contentId"] == "action/9/1" and seen_rows[0]["GESTURE"][0]["builtin"] == "wave", "the local player's keys are rebuilt from their own relayed loadout", str(seen_rows))
	_check(seen_rows[0]["EMOTE"][0]["fileUrl"] == "/", "with no library read yet the row keeps the valid placeholder")
	client.url_fn = func(id: String) -> String:
		return "https://cdn.test/hop.glb" if id == "action/9/1" else ""
	var _ap := client.apply_to_input(own.entries)
	_check(seen_rows.size() == 2 and seen_rows[1]["EMOTE"][0]["fileUrl"] == "https://cdn.test/hop.glb", "once the library names it, the keys get the real file url", str(seen_rows[-1]))
	lm.actor = 7
	lm.entries = [{"id": "wave", "kind": 2, "loop": false, "clip": ""}]
	deliver.call(lm)
	_check(seen_rows.size() == 2, "another player's loadout leaves the local keys alone")
	var skel_fig := _loadout_wearables(client, figures, deliver, server_net, net)
	skel_fig.bones.free()
	client.queue_free()
	input.queue_free()
	net.queue_free()
	server_net.free()
	_done()


func _loadout_net(server: bool, peer := 0) -> GSNetManager:
	var n := GSNetManager.new()
	n.is_server = server
	n.local_peer_id = peer
	n.config_file = ""
	var _s := n.setup()
	var _r := GSGameAvatarActionMessage.register(n)
	n.messages.seal()
	return n


func _loadout_wearables(client: GSGameAvatarActionClient, figures: Dictionary, deliver: Callable, server_net: GSNetManager, net: GSNetManager) -> FakeSkeletonFigure:
	var wm := GSGameAvatarLoadoutMessage.new()
	wm.actor = 9
	wm.wearables = PackedStringArray(["wearable/3/1", "wearable/4/2"])
	var ww := GSNetWriter.new()
	var _we := server_net.messages.encode(wm, ww)
	var wr := net.messages.decode(GSNetReader.new(ww.to_bytes()), 1, false)
	_check(wr.ok and wr.value is GSGameAvatarLoadoutMessage and wr.value.wearables == wm.wearables, "the wearable ids ride the loadout message", str(wr.error.message if not wr.ok else ""))
	wm.wearables = PackedStringArray(["a", "b", "c", "d", "e", "f", "g", "h"])
	_check(not wm.validate().ok, "a loadout message with too many wearables is refused")
	var parsed := GSGameAvatarLoadouts.parse_wearables({"WEARABLES": [
		{"contentId": "wearable/3/1", "slot": "head"}, {"contentId": "wearable/4/2", "slot": "head"},
		{"contentId": "wearable/../1", "slot": "back"}, {"contentId": "wearable/5/1", "slot": "back"}, 7]})
	_check(parsed == PackedStringArray(["wearable/3/1", "wearable/5/1"]), "the read's wearables: well-formed ids, one per slot", str(parsed))
	_check(GSGameAvatarLoadouts.parse_wearables("junk").is_empty() and GSGameAvatarLoadouts.parse_wearables({}).is_empty(), "no wearables in the read is none")
	var skel_fig := FakeSkeletonFigure.new()
	figures[9] = skel_fig
	var looked := []
	client.wearable_row_fn = func(id: String) -> Dictionary:
		looked.append(id)
		return {}
	var wl := GSGameAvatarLoadoutMessage.new()
	wl.actor = 9
	wl.wearables = PackedStringArray(["wearable/3/1"])
	deliver.call(wl)
	_check(not client.wear(9) and looked.has("wearable/3/1") and client.worn[9] == wl.wearables, "wearables wait for the library row, and are asked for once", str(looked))
	wl.wearables = PackedStringArray()
	deliver.call(wl)
	_check(not client.worn.has(9) and client.wear(9), "a loadout with no wearables takes them off")
	return skel_fig


func _test_prejoin() -> void:
	_section("prejoin: avatar files come down before the shell connects, and never block it")
	var host := Node.new()
	add_child(host)
	var progress := []
	var pj := GSGamePrejoin.new()
	pj.progress_fn = func(f: float, t: String) -> void: progress.append([f, t])
	pj.rules_fn = func(_a: String) -> Dictionary: return {}
	var none: GSResult = await pj.prepare(host, "127.0.0.1:1")
	_check(none.ok and none.value == 0, "a server advertising nothing needs nothing")

	var calls := []
	pj.rules_fn = func(_a: String) -> Dictionary: return {"sv_avatar_content": "avatar/5/1"}
	pj.fetch_fn = func(ids: Array, gate: GSLoadGate) -> GSResult:
		calls.append(ids)
		gate.hold(&"avatar_content", "Downloading avatars")
		gate.set_progress(0.5, "Downloading avatar/5/1 (1 of 1)")
		await get_tree().process_frame
		gate.release(&"avatar_content")
		return GSResult.success(1)
	var got: GSResult = await pj.prepare(host, "127.0.0.1:1")
	_check(got.ok and got.value == 1 and calls == [["avatar/5/1"]], "the advertised ids are fetched before the join")
	_check(not progress.is_empty() and progress.back()[0] == 0.5, "progress reaches the loading screen's callback")

	pj.fetch_fn = func(_ids: Array, _gate: GSLoadGate) -> GSResult:
		return GSResult.fail(GSError.CODE_NETWORK, "cdn down")
	var failed: GSResult = await pj.prepare(host, "127.0.0.1:1")
	_check(not failed.ok and failed.error.code == GSError.CODE_NETWORK, "a failed download is reported so the caller can log it and join anyway")

	var steps := []
	pj.fetch_fn = func(_ids: Array, _gate: GSLoadGate) -> GSResult: return GSResult.success(1)
	pj.extra_steps.append(func(rules: Dictionary) -> GSResult:
		steps.append(rules.get("sv_avatar_content", ""))
		return GSResult.fail(GSError.CODE_NETWORK, "pack host down"))
	var stepped: GSResult = await pj.prepare(host, "127.0.0.1:1")
	_check(steps == ["avatar/5/1"], "an extra pre-join step is handed the server's rules")
	_check(stepped.ok and stepped.value == 1, "a failing extra step never blocks the join or the avatar files")
	pj.extra_steps.clear()

	pj.timeout_sec = 0.3
	pj.fetch_fn = func(_ids: Array, _gate: GSLoadGate) -> GSResult:
		await get_tree().create_timer(5.0).timeout
		return GSResult.success(1)
	var t0 := Time.get_ticks_msec()
	var slow: GSResult = await pj.prepare(host, "127.0.0.1:1")
	_check(not slow.ok and slow.error.code == GSError.CODE_TIMEOUT and Time.get_ticks_msec() - t0 < 2000, "a hung CDN times out and does not hold the join")
	host.queue_free()
	_done()


class FakeAuthServer extends RefCounted:
	var audience := ""
	func join_audience() -> String:
		return audience


class FakeAuthConfig extends RefCounted:
	var backbone_url := "https://site.test/"


class FakeAuthClient extends RefCounted:
	var config := FakeAuthConfig.new()


class FakeLink extends RefCounted:
	var replicated_cvars := {}


func _test_site_server() -> void:
	_section("the server's site id: advertised as a replicated rule, read by prejoin and the client")
	_check(GSGameAvatarContent.server_id_from_audience("server:42") == 42 and GSGameAvatarContent.server_id_from_audience("app:42") == 0
		and GSGameAvatarContent.server_id_from_audience("server:x") == 0, "only a server: audience is a site server id")
	_check(GSGameAvatarContent.server_id_from_rules({"sv_site_server": "17"}) == 17 and GSGameAvatarContent.server_id_from_rules({"sv_site_server": "-3"}) == 0
		and GSGameAvatarContent.server_id_from_rules({}) == 0, "the rule parses, and nonsense is no id")
	var auth := FakeAuthServer.new()
	GSRegistry.register(&"gs_auth_server", auth)
	TestModule.site_server = -1
	var loaded: GSResult = await _load_module()
	if _check(loaded.ok, "the module loads", str(loaded.error)):
		var module := loaded.value as GSGameModule
		var cv := module.console.find_cvar(GSGameAvatarContent.SERVER_CVAR)
		_check(cv != null and cv.get_string() == "0" and cv.has_flag(GSConVar.FLAG_NOTIFY) and cv.has_flag(GSConVar.FLAG_REPLICATED),
			"advertised as a notify, replicated cvar, 0 while gs-auth has not read it")
		var timer := module.get_node_or_null("SiteServerRetry") as Timer
		auth.audience = "server:42"
		if _check(timer != null, "and looked for again"):
			timer.timeout.emit()
		_check(cv != null and cv.get_string() == "42", "it takes the audience gs-auth read", cv.get_string() if cv != null else "")
		_unload_module()
	GSRegistry.unregister_instance(&"gs_auth_server", auth)

	var pj := GSGamePrejoin.new()
	pj.rules_fn = func(_a: String) -> Dictionary: return {"sv_avatar_content": "avatar/5/1", "sv_site_server": "42"}
	pj.fetch_fn = func(_ids: Array, _g: Object) -> GSResult: return GSResult.success(1)
	var _p: GSResult = await pj.prepare(self, "127.0.0.1:1")
	_check(pj.server_id == 42, "prejoin reads the server id from the rules", str(pj.server_id))

	var ac := FakeAuthClient.new()
	GSRegistry.register(&"gs_auth_client", ac)
	_check(GSGameAvatarContent.default_site_url() == "https://site.test", "the site defaults to the one the client signs in against")
	var platform := GSGameClient.new()
	var link := FakeLink.new()
	link.replicated_cvars = {"sv_site_server": "42"}
	platform.link = link
	_check(platform.avatar_site() == "https://site.test" and platform.avatar_server() == 42, "the client finds both by itself")
	platform.avatar_site_url = "https://other.test"
	platform.avatar_server_id = 9
	_check(platform.avatar_site() == "https://other.test" and platform.avatar_server() == 9, "and a game's own values win")
	var figure := Node.new()
	GSGameClientAvatars.publish_figures(platform, func(peer: int) -> Node: return figure if peer == 5 else null)
	_check(GSGameClientAvatars.figure_of(5) == figure and GSGameClientAvatars.figure_of(6) == null, "an addon finds a player's figure through the published client")
	GSRegistry.unregister_instance(GSGameClientAvatars.SERVICE, platform)
	_check(GSGameClientAvatars.figure_of(5) == null, "and nothing once it is gone")
	figure.free()
	platform.free()
	GSRegistry.unregister_instance(&"gs_auth_client", ac)
	_done()


func _test_avatar_content() -> void:
	_section("avatar content: advertised as a rule, refused cleanly when it cannot be fetched")
	_check(GSGameAvatarContent.parse(" avatar/5/1, action/7/2 ,,") == ["avatar/5/1", "action/7/2"], "the advertisement parses")
	_check(GSGameAvatarContent.ids_from_rules({}) == [], "no rule is no ids")
	_check(GSGameAvatarContent.ids_from_rules({"sv_avatar_content": "avatar/5/1"}) == ["avatar/5/1"], "ids come from a query rule")
	var plain: GSResult = await _load_module()
	var plain_module := _server.modules.get_module("testgame") if plain.ok else null
	_check(plain_module != null and plain_module.console.find_cvar(GSGameAvatarContent.CVAR) == null, "a game requiring nothing publishes no cvar")
	_unload_module()
	TestModule.avatar_content = ["avatar/5/1", "action/7/1"]
	var loaded: GSResult = await _load_module()
	TestModule.avatar_content = []
	var module := _server.modules.get_module("testgame") if loaded.ok else null
	var cv: GSConVar = module.console.find_cvar(GSGameAvatarContent.CVAR) if module != null else null
	_check(cv != null and cv.get_string() == "avatar/5/1,action/7/1" and cv.has_flag(GSConVar.FLAG_NOTIFY), "the module advertises it as a notify cvar")
	_unload_module()
	var host := Node.new()
	add_child(host)
	var empty: GSResult = await GSGameAvatarContent.prepare(host, [], "https://site.test", 3, null, null)
	_check(empty.ok, "nothing required is ready at once")
	if not GSGameAvatarContent.available():
		var missing: GSResult = await GSGameAvatarContent.prepare(host, ["avatar/5/1"], "https://site.test", 3, null, null)
		_check(not missing.ok and missing.error.code == GSError.CODE_UNSUPPORTED, "required files without gs-user-avatar refuse the connect")
	else:
		_check(true, "gs-user-avatar is present (its own suite covers the fetch)")
	host.free()
	_check(GSGameAvatarContent.format(["a/1/1", "b/2/1"]) == "a/1/1,b/2/1", "ids format back")
	_done()
