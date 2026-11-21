extends GSGameCheckSuite

## GSGameLockedContent: no lock does nothing, a lock is handed to ensure_locked behind the gate, a failure releases the gate, the switch.

const Stub := preload("res://examples/fixtures/locked_cloud_stub.gd")
const DIR := "user://locked_content_test"


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("dot-game: locked content")
	GSGameLockedContent.lock_override = ""
	var gate := GSLoadGate.new()
	add_child(gate)
	gate.hold(&"other", "x")
	var cloud: Node = Stub.new()
	add_child(cloud)

	var none: GSResult = await GSGameLockedContent.run(cloud, gate)
	_check(none.ok and none.value == null, "no lock file: nothing to do")
	_check(cloud.calls.is_empty() and not gate.is_holding(GSGameLockedContent.REASON), "no lock file: dot-cloud not called, gate untouched")

	GSPaths.write_bytes(DIR + "/content.lock.json", '{"format":1,"packs":[]}'.to_utf8_buffer())
	GSGameLockedContent.lock_override = DIR + "/content.lock.json"
	_check(GSGameLockedContent.find_lock() == DIR + "/content.lock.json", "an override names the lock")
	cloud.gate = gate
	var got: GSResult = await GSGameLockedContent.run(cloud, gate)
	_check(cloud.held_during, "the gate is held while it mounts")
	_check(got.ok and got.value["mounted"] == ["me/pack@1.0.0"], "the report is returned")
	_check(cloud.calls.size() == 1 and cloud.calls[0]["lock"] == DIR + "/content.lock.json", "ensure_locked got the lock path")
	_check(not gate.is_holding(GSGameLockedContent.REASON), "the gate is released afterwards")

	cloud.fail = true
	got = await GSGameLockedContent.run(cloud, gate)
	_check(not got.ok and not gate.is_holding(GSGameLockedContent.REASON), "a failure is returned and does not keep the gate shut")

	got = await GSGameLockedContent.run(null, gate)
	_check(got.ok and got.value == null, "a lock with no cloud client is skipped")

	GSGameLockedContent.lock_override = DIR + "/missing.json"
	_check(GSGameLockedContent.find_lock() == "", "a named lock that is not there is no lock")
	_check(not GSGameLockedContent.disabled_by_cmdline(), "on by default")

	GSGameLockedContent.lock_override = ""
	GSPaths.remove_tree(DIR)
	_report()
